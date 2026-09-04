using CSV
using DataFrames
using HiGHS
using JuMP

function scaling_test_resource()
    return GenX.Thermal(Dict{Symbol, Any}(
        :resource => "Scaling resource",
        :zone => 1,
        :region => "Scaling region",
        :cluster => 1,
        :derating_factor_1 => 1.0,
        :max_cap_mw => 2_000.0,
        :inv_cost_per_mwyr => 100.0,
        :fixed_om_cost_per_mwyr => 0.0,
        :fixed_amt_cost_per_mwyr => 0.0,
        :fixed_subsidy_per_mwyr => 0.0,
    ))
end

function common_scaling_policy_inputs(resource, demand)
    return Dict(
        "NCapacityReserveMargin" => 1,
        "pD" => reshape(demand, length(demand), 1),
        "dfCapRes" => reshape([0.10], 1, 1),
        "RESOURCES" => [resource],
        "RESOURCE_NAMES" => ["Scaling resource"],
        "R_ZONES" => [1],
        "REP_PERIOD" => 1,
        "G" => 1,
        "THERM_ALL" => [1],
        "VRE" => Int[],
        "HYDRO_RES" => Int[],
        "STOR_ALL" => Int[],
        "FLEX" => Int[],
        "MUST_RUN" => Int[],
        "VRE_STOR" => Int[],
    )
end

function capacity_payment_scaling_result(parameter_scale)
    factor = parameter_scale == 1 ? GenX.ModelScalingFactor : 1.0
    settings = GenX.default_settings()
    settings["CapacityPayment"] = 1
    settings["ParameterScale"] = parameter_scale
    resource = scaling_test_resource()
    inputs = Dict(
        "G" => 1,
        "NEW_CAP" => [1],
        "RESOURCES" => [resource],
        "R_ZONES" => [1],
    )
    inputs["NCapacityPaymentRegions"] = 1
    inputs["capacity_payment_price"] = [50.0 / factor]
    inputs["CAPACITY_PAYMENT_DERATING_FACTOR"] = reshape([1.0], 1, 1)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, capacity >= 0)
    model[:eTotalCap] = [capacity]
    model[:eObj] = AffExpr(0.0)
    GenX.create_empty_expression!(model, :eCapPayment, 1)
    GenX.capacity_payment!(model, inputs, settings)
    @constraint(model, capacity == 2_000.0 / factor)
    @objective(model, Min, model[:eObj])
    optimize!(model)

    mktempdir() do output_path
        GenX.write_capacity_payment(model, inputs, output_path, settings)
        result = CSV.read(
            joinpath(output_path, "capacity_payment_per_unit.csv"), DataFrame)
        return (
            capacity_mw=value(capacity) * factor,
            payment=only(result.CapacityPaymentTotal),
            objective_dollars=objective_value(model) * factor^2,
        )
    end
end

function peak_scaling_result(parameter_scale; slack=false)
    factor = parameter_scale == 1 ? GenX.ModelScalingFactor : 1.0
    settings = GenX.default_settings()
    settings["CRM_peakload"] = 1
    settings["ParameterScale"] = parameter_scale
    resource = scaling_test_resource()
    inputs = common_scaling_policy_inputs(resource, [1_000.0 / factor])
    inputs["peak_hour_idx"] = [1]
    slack && (inputs["dfCapRes_slack"] = DataFrame(PriceCap=[200.0 / factor]))

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    if slack
        model[:eTotalCap] = [AffExpr(0.0)]
    else
        @variable(model, capacity >= 0)
        model[:eTotalCap] = [capacity]
    end
    model[:eObj] = AffExpr(0.0)
    model[:eCapResMarBalancePeak] = [AffExpr(0.0)]
    if !slack
        add_to_expression!(model[:eCapResMarBalancePeak][1], capacity)
        add_to_expression!(model[:eObj], 100.0 / factor, capacity)
    end
    GenX.cap_reserve_margin_peakload!(model, inputs, settings)
    @objective(model, Min, model[:eObj])
    optimize!(model)

    if slack
        return value(model[:vCapResSlack][1]) * factor,
               value(model[:eCTotalCapResSlack]) * factor^2
    end
    mktempdir() do output_path
        revenue = GenX.write_reserve_margin_revenue_peakload(
            output_path, inputs, settings, model)
        return (
            capacity_mw=value(capacity) * factor,
            price=GenX.capacity_reserve_margin_price_peakload(
                model, inputs, settings, 1),
            revenue=only(revenue.AnnualSum),
        )
    end
end

function multihour_scaling_result(parameter_scale; slack=false)
    factor = parameter_scale == 1 ? GenX.ModelScalingFactor : 1.0
    settings = GenX.default_settings()
    settings["CRM_multihours"] = 1
    settings["ParameterScale"] = parameter_scale
    resource = scaling_test_resource()
    inputs = common_scaling_policy_inputs(resource, [1_000.0, 1_100.0] ./ factor)
    inputs["selected_capres_multihours"] = Dict(1 => [1, 2])
    inputs["omega"] = [2.0, 3.0]
    slack && (inputs["dfCapRes_slack"] = DataFrame(PriceCap=[200.0 / factor]))

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    if slack
        model[:eTotalCap] = [AffExpr(0.0)]
    else
        @variable(model, capacity >= 0)
        model[:eTotalCap] = [capacity]
    end
    model[:eObj] = AffExpr(0.0)
    model[:eCapResMarBalanceMultihour] = [AffExpr(0.0) AffExpr(0.0)]
    if !slack
        for t in 1:2
            add_to_expression!(model[:eCapResMarBalanceMultihour][1, t], capacity)
        end
        add_to_expression!(model[:eObj], 100.0 / factor, capacity)
    end
    GenX.cap_reserve_margin_multihours!(model, inputs, settings)
    @objective(model, Min, model[:eObj])
    optimize!(model)

    if slack
        slack_mw = sum(value(model[:vCapResSlack][1, t]) for t in 1:2) * factor
        penalty = value(model[:eCTotalCapResSlack]) * factor^2
        return slack_mw, penalty
    end
    mktempdir() do output_path
        revenue = GenX.write_reserve_margin_revenue_multihours(
            output_path, inputs, settings, model)
        prices = [GenX.capacity_reserve_margin_price_multihours(
            model, settings, 1, t) for t in 1:2]
        return (
            capacity_mw=value(capacity) * factor,
            prices=prices,
            revenue=only(revenue.AnnualSum),
        )
    end
end

function vre_stor_esr_revenue(parameter_scale)
    factor = parameter_scale == 1 ? GenX.ModelScalingFactor : 1.0
    settings = GenX.default_settings()
    settings["ParameterScale"] = parameter_scale

    case_path = joinpath(@__DIR__, "load_resources", "test_gen_vre_stor")
    resources_path = joinpath(case_path, settings["ResourcesFolder"])
    gen = GenX.create_resource_array(settings, resources_path)
    GenX.add_policies_to_resources!(
        gen, joinpath(resources_path, settings["ResourcePoliciesFolder"]))

    solar = GenX.solar(gen)
    wind = GenX.wind(gen)
    model = Model(HiGHS.Optimizer)
    @variable(model, vP_SOLAR[solar, 1:1] >= 0)
    @variable(model, vP_WIND[wind, 1:1] >= 0)
    fix.(vP_SOLAR, 2_000.0 / factor; force=true)
    fix.(vP_WIND, 3_000.0 / factor; force=true)
    @objective(model, Min, 0)
    optimize!(model)

    inputs = Dict(
        "RESOURCES" => gen,
        "RESOURCE_NAMES" => GenX.resource_name.(gen),
        "G" => length(gen),
        "nESR" => 1,
        "omega" => [2.0],
        "VRE_STOR" => GenX.vre_stor(gen),
        "VS_SOLAR" => solar,
        "VS_WIND" => wind,
    )
    power = DataFrame(AnnualSum=zeros(length(gen)))
    prices = DataFrame(ESR_Price=[50.0])

    mktempdir() do output_path
        revenue = GenX.write_esr_revenue(
            output_path, inputs, settings, power, prices, model)
        return revenue.Total
    end
end

@testset "new policies are invariant to ParameterScale" begin
    cp_unscaled = capacity_payment_scaling_result(0)
    cp_scaled = capacity_payment_scaling_result(1)
    @test cp_scaled.capacity_mw ≈ cp_unscaled.capacity_mw ≈ 2_000.0
    @test cp_scaled.payment ≈ cp_unscaled.payment ≈ 100_000.0
    @test cp_scaled.objective_dollars ≈ cp_unscaled.objective_dollars ≈ -100_000.0

    peak_unscaled = peak_scaling_result(0)
    peak_scaled = peak_scaling_result(1)
    @test peak_scaled.capacity_mw ≈ peak_unscaled.capacity_mw ≈ 1_100.0
    @test peak_scaled.price ≈ peak_unscaled.price ≈ 100.0
    @test peak_scaled.revenue ≈ peak_unscaled.revenue ≈ 110_000.0
    peak_slack_scaled = peak_scaling_result(1; slack=true)
    peak_slack_unscaled = peak_scaling_result(0; slack=true)
    @test collect(peak_slack_scaled) ≈ collect(peak_slack_unscaled) ≈
          [1_100.0, 220_000.0]

    multi_unscaled = multihour_scaling_result(0)
    multi_scaled = multihour_scaling_result(1)
    @test multi_scaled.capacity_mw ≈ multi_unscaled.capacity_mw ≈ 1_210.0
    @test multi_scaled.prices ≈ multi_unscaled.prices
    @test sum(multi_scaled.prices) ≈ sum(multi_unscaled.prices) ≈ 100.0
    @test multi_scaled.revenue ≈ multi_unscaled.revenue ≈ 121_000.0
    multi_slack_scaled = multihour_scaling_result(1; slack=true)
    multi_slack_unscaled = multihour_scaling_result(0; slack=true)
    @test collect(multi_slack_scaled) ≈ collect(multi_slack_unscaled) ≈
          [2_310.0, 1_166_000.0]

    vre_stor_unscaled = vre_stor_esr_revenue(0)
    vre_stor_scaled = vre_stor_esr_revenue(1)
    @test vre_stor_scaled ≈ vre_stor_unscaled
    @test sum(vre_stor_scaled) > 0
end
