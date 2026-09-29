using CSV
using DataFrames
using HiGHS
using JuMP

function peakload_test_resource()
    return GenX.Thermal(Dict{Symbol, Any}(
        :resource => "Peak resource",
        :zone => 1,
        :region => "Test region",
        :cluster => 1,
        :derating_factor_1 => 1.0,
    ))
end

@testset "settings and input validation" begin
    settings = GenX.default_settings()
    settings["CRM_peakload"] = 2
    @test_throws AssertionError GenX.validate_settings!(settings)

    settings = GenX.default_settings()
    settings["CapacityReserveMargin"] = 1
    settings["CRM_peakload"] = 1
    @test_throws ErrorException GenX.validate_settings!(settings)

    settings = GenX.default_settings()
    settings["CRM_peakload"] = 1
    inputs = Dict("T" => 2, "pD" => reshape([1.0, 2.0], 2, 1))
    mktempdir() do policy_path
        CSV.write(joinpath(policy_path, "CRM_peakload.csv"),
            DataFrame(Zone = [1], CapRes_1 = [0.15]))
        GenX.load_cap_reserve_margin_peakload!(settings, policy_path, inputs)
        @test inputs["peak_hour_idx"] == [2]
        @test inputs["NCapacityReserveMargin"] == 1

        CSV.write(joinpath(policy_path, "CRM_peakload.csv"),
            DataFrame(Zone = [1], CapRes_1 = [0.0]))
        @test_throws ErrorException GenX.load_cap_reserve_margin_peakload!(
            settings, policy_path, inputs)
    end
end

@testset "transmission contribution uses peak-hour flow" begin
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, flow[1:1, 1:2])
    model[:vFLOW] = flow
    model[:eCapResMarBalancePeak] = [AffExpr(0.0), AffExpr(0.0), AffExpr(0.0)]

    inputs = Dict(
        "L" => 1,
        "NCapacityReserveMargin" => 3,
        "peak_hour_idx" => [2, 1, 2],
        "dfTransCapRes_exclPeak" => reshape([-1.0, 1.0, -1.0], 1, 3),
        "dfDerateTransCapResPeak" => reshape([0.95, 0.95, 0.0], 1, 3),
    )

    GenX.add_peakload_transmission_capacity_contribution!(model, inputs)
    @constraint(model, flow[1, 1] == 1.5)
    @constraint(model, flow[1, 2] == 2.5)
    @objective(model, Min, 0)
    optimize!(model)

    # The receiving region is credited with its peak-hour delivered flow.
    @test value(model[:eCapResMarBalancePeak][1]) ≈ 2.375
    # A different CRM peak hour uses that hour's flow and deducts the export.
    @test value(model[:eCapResMarBalancePeak][2]) ≈ -1.425
    # A zero external derating factor disables line credit without a code change.
    @test value(model[:eCapResMarBalancePeak][3]) ≈ 0.0
end

@testset "external resource contribution is capped by peak-hour flow" begin
    function solve_external_credit(capacity_value, flow_value)
        model = Model(HiGHS.Optimizer)
        set_silent(model)
        @variable(model, capacity >= 0)
        @variable(model, flow[1:1, 1:1] >= 0)
        model[:eTotalCap] = [capacity]
        model[:vFLOW] = flow
        model[:eObj] = AffExpr(0.0)
        model[:eCapResMarBalancePeak] = [AffExpr(0.0)]
        add_to_expression!(model[:eCapResMarBalancePeak][1], capacity)

        resource = GenX.Thermal(Dict{Symbol, Any}(
            :resource => "External resource",
            :zone => 2,
            :region => "External region",
            :cluster => 1,
            :derating_factor_1 => 1.0,
        ))
        inputs = Dict(
            "T" => 1,
            "Z" => 2,
            "L" => 1,
            "G" => 1,
            "NCapacityReserveMargin" => 1,
            "peak_hour_idx" => [1],
            "dfCapRes" => reshape([0.15, 0.0], 2, 1),
            "dfTransCapRes_exclPeak" => reshape([-1.0], 1, 1),
            "dfDerateTransCapResPeak" => reshape([0.0], 1, 1),
            "pTrans_Start_Zone" => [2],
            "pTrans_End_Zone" => [1],
            "RESOURCES" => [resource],
            "THERM_ALL" => [1],
            "THERM_COMMIT" => Int[],
            "VRE" => Int[],
            "HYDRO_RES" => Int[],
            "STOR_ALL" => Int[],
            "FLEX" => Int[],
            "MUST_RUN" => Int[],
        )

        GenX.add_peakload_external_resource_flow_limits!(model, inputs)
        @constraint(model, capacity == capacity_value)
        @constraint(model, flow[1, 1] == flow_value)
        @objective(model, Max, model[:vPeakPairedCapCredit][(1, 2)])
        optimize!(model)
        return value(model[:vPeakPairedCapCredit][(1, 2)]),
               value(model[:eCapResMarBalancePeak][1]),
               GenX.peakload_external_delivery_fraction(model, 1, 2)
    end

    credit, balance, fraction = solve_external_credit(3.0, 2.0)
    @test credit ≈ 2.0
    @test balance ≈ 2.0
    @test fraction ≈ 2 / 3

    credit, balance, fraction = solve_external_credit(3.0, 4.0)
    @test credit ≈ 3.0
    @test balance ≈ 3.0
    @test fraction ≈ 1.0
end

@testset "price, accredited capacity, and revenue reconcile" begin
    settings = GenX.default_settings()
    settings["CRM_peakload"] = 1
    settings["ParameterScale"] = 1

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, capacity >= 0)
    model[:eTotalCap] = [capacity]
    model[:eObj] = AffExpr(0.0)
    model[:eCapResMarBalancePeak] = [AffExpr(0.0)]
    add_to_expression!(model[:eCapResMarBalancePeak][1], capacity)
    add_to_expression!(model[:eObj], 0.1, capacity)

    resource = peakload_test_resource()
    inputs = Dict(
        "NCapacityReserveMargin" => 1,
        "peak_hour_idx" => [1],
        "pD" => reshape([1.0], 1, 1),
        "dfCapRes" => reshape([0.15], 1, 1),
        "RESOURCES" => [resource],
        "RESOURCE_NAMES" => ["Peak resource"],
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

    GenX.cap_reserve_margin_peakload!(model, inputs, settings)
    @objective(model, Min, model[:eObj])
    optimize!(model)

    @test value(capacity) ≈ 1.15
    @test GenX.capacity_reserve_margin_price_peakload(model, inputs, settings, 1) ≈ 100.0

    mktempdir() do output_path
        revenue = GenX.write_reserve_margin_revenue_peakload(
            output_path, inputs, settings, model)
        GenX.write_capacity_value_peakload(output_path, inputs, settings, model)
        capacity_value = CSV.read(
            joinpath(output_path, "CapacityValue_peakload.csv"), DataFrame)

        @test only(capacity_value.Value) ≈ 1_150.0
        @test only(revenue.AnnualSum) ≈ 115_000.0
        @test only(revenue.AnnualSum) ≈
              only(capacity_value.Value) *
              GenX.capacity_reserve_margin_price_peakload(model, inputs, settings, 1)
    end
end
