using CSV
using DataFrames
using HiGHS
using JuMP

@testset "external dedicated capacity is deliverable in selected hours" begin
    for (line_derating, sign, flows, expected) in (
            (0.0, -1.0, [2.0, 4.0], [2.0, 3.0]),
            (0.0, 1.0, [-2.0, -4.0], [2.0, 3.0]),
            (0.95, -1.0, [2.0, 4.0], [0.0, 0.0]),
            (0.0, 0.0, [2.0, 4.0], [0.0, 0.0]))
        model = Model(HiGHS.Optimizer)
        set_silent(model)
        @variable(model, capacity >= 0)
        @variable(model, flow[1:1, 1:2])
        model[:eTotalCap] = [capacity]
        model[:vFLOW] = flow
        model[:eCapResMarBalanceMultihour] = [AffExpr(0.0) AffExpr(0.0)]
        for t in 1:2
            add_to_expression!(model[:eCapResMarBalanceMultihour][1,t], capacity)
            fix(flow[1,t], flows[t])
        end
        fix(capacity, 3.0; force=true)
        resource = GenX.Thermal(Dict{Symbol,Any}(:resource => "Dedicated",
            :zone => 2, :region => "Base", :cluster => 1, :derating_factor_1 => 1.0))
        inputs = Dict{String,Any}("Z" => 2, "L" => 1,
            "NCapacityReserveMargin" => 1,
            "selected_capres_multihours" => Dict(1 => [1,2]),
            "dfCapRes" => reshape([0.1,0.0],2,1),
            "dfTransCapResMulti_excl" => reshape([sign],1,1),
            "dfDerateTransCapResMulti" => reshape([line_derating],1,1),
            "pTrans_Start_Zone" => [2], "pTrans_End_Zone" => [1],
            "RESOURCES" => [resource], "THERM_ALL" => [1], "THERM_COMMIT" => Int[])
        GenX.add_multihours_external_resource_flow_limits!(model, inputs)
        @objective(model, Max, sum(model[:eCapResMarBalanceMultihour]))
        optimize!(model)
        @test termination_status(model) == MOI.OPTIMAL
        @test [value(model[:eCapResMarBalanceMultihour][1,t]) for t in 1:2] ≈ expected
        @test [GenX.multihours_external_delivery_fraction(model,1,2,t) for t in 1:2] ≈ expected ./ 3

        # Reporting must use the same flow-capped contribution as the constraint.
        merge!(inputs, Dict("G" => 1, "REP_PERIOD" => 1, "RESOURCE_NAMES" => ["Dedicated"],
            "VRE" => Int[], "HYDRO_RES" => Int[], "STOR_ALL" => Int[],
            "FLEX" => Int[], "MUST_RUN" => Int[], "VRE_STOR" => Int[]))
        mktempdir() do path
            settings = GenX.default_settings()
            settings["ParameterScale"] = 0
            GenX.write_capacity_value_multihours(path,inputs,settings,model)
            output = CSV.read(joinpath(path,"CapacityValue_multihours.csv"),DataFrame)
            @test [only(output.t1),only(output.t2)] ≈ expected
        end
    end
end

function multihour_test_resource()
    return GenX.Thermal(Dict{Symbol, Any}(
        :resource => "Multihour resource",
        :zone => 1,
        :region => "Test region",
        :cluster => 1,
        :derating_factor_1 => 1.0,
    ))
end

@testset "multihour input validation" begin
    settings = GenX.default_settings()
    settings["CRM_multihours"] = 1
    inputs = Dict{String, Any}("T" => 3, "Z" => 1)

    mktempdir() do policy_path
        CSV.write(joinpath(policy_path, "CRM_multihours.csv"),
            DataFrame(Zone = [1], CapRes_1 = [0.10]))
        CSV.write(joinpath(policy_path, "CRM_multihours_selected.csv"),
            DataFrame(CapRes = [1, 1], t = [3, 1]))
        GenX.load_cap_reserve_margin_multihours!(settings, policy_path, inputs)
        @test inputs["selected_capres_multihours"] == Dict(1 => [1, 3])

        CSV.write(joinpath(policy_path, "CRM_multihours_selected.csv"),
            DataFrame(CapRes = [1, 1], t = [1, 1]))
        @test_throws ErrorException GenX.load_cap_reserve_margin_multihours!(
            settings, policy_path, inputs)

        CSV.write(joinpath(policy_path, "CRM_multihours_selected.csv"),
            DataFrame(CapRes = [1], t = [4]))
        @test_throws ErrorException GenX.load_cap_reserve_margin_multihours!(
            settings, policy_path, inputs)
    end
end

function multihour_test_inputs(resource; with_slack = false)
    inputs = Dict(
        "NCapacityReserveMargin" => 1,
        "selected_capres_multihours" => Dict(1 => [1, 2]),
        "pD" => reshape([1.0, 1.1], 2, 1),
        "dfCapRes" => reshape([0.10], 1, 1),
        "omega" => [2.0, 3.0],
        "RESOURCES" => [resource],
        "RESOURCE_NAMES" => ["Multihour resource"],
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
    if with_slack
        inputs["dfCapRes_slack"] = DataFrame(PriceCap = [0.2])
    end
    return inputs
end

@testset "multihour price, capacity, and revenue reconcile" begin
    settings = GenX.default_settings()
    settings["CRM_multihours"] = 1
    settings["ParameterScale"] = 1
    resource = multihour_test_resource()
    inputs = multihour_test_inputs(resource)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, capacity >= 0)
    model[:eTotalCap] = [capacity]
    model[:eObj] = AffExpr(0.0)
    model[:eCapResMarBalanceMultihour] = [AffExpr(0.0) AffExpr(0.0)]
    for t in 1:2
        add_to_expression!(model[:eCapResMarBalanceMultihour][1, t], capacity)
    end
    add_to_expression!(model[:eObj], 0.1, capacity)
    GenX.cap_reserve_margin_multihours!(model, inputs, settings)
    @objective(model, Min, model[:eObj])
    optimize!(model)

    @test value(capacity) ≈ 1.21
    prices = [GenX.capacity_reserve_margin_price_multihours(model, settings, 1, t)
              for t in 1:2]

    mktempdir() do output_path
        revenue = GenX.write_reserve_margin_revenue_multihours(
            output_path, inputs, settings, model)
        GenX.write_capacity_value_multihours(output_path, inputs, settings, model)
        capacity_value = CSV.read(
            joinpath(output_path, "CapacityValue_multihours.csv"), DataFrame)

        @test capacity_value.t1 ≈ [1_210.0]
        @test capacity_value.t2 ≈ [1_210.0]
        @test only(revenue.AnnualSum) ≈
              capacity_value.t1[1] * prices[1] + capacity_value.t2[1] * prices[2]
    end
end

@testset "multihour slack penalties are hourly" begin
    settings = GenX.default_settings()
    settings["CRM_multihours"] = 1
    settings["ParameterScale"] = 1
    resource = multihour_test_resource()
    inputs = multihour_test_inputs(resource; with_slack = true)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    model[:eTotalCap] = [AffExpr(0.0)]
    model[:eObj] = AffExpr(0.0)
    model[:eCapResMarBalanceMultihour] = [AffExpr(0.0) AffExpr(0.0)]
    GenX.cap_reserve_margin_multihours!(model, inputs, settings)
    @objective(model, Min, model[:eObj])
    optimize!(model)

    mktempdir() do output_path
        GenX.write_reserve_margin_slack_multihours(output_path, inputs, settings, model)
        slack = CSV.read(joinpath(
            output_path, "ReserveMargin_prices_and_penalties_multihours.csv"), DataFrame)
        @test slack.Slack ≈ [1_100.0, 1_210.0]
        @test slack.Penalty ≈ [440_000.0, 726_000.0]
        @test sum(slack.Penalty) ≈ value(model[:eCTotalCapResSlack]) * 1.0e6
    end
end
