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

@testset "transmission contribution uses final rated capacity" begin
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, reinforcement >= 0)
    model[:eAvail_Trans_Cap] = [2.0 + reinforcement]
    model[:eCapResMarBalancePeak] = [AffExpr(0.0), AffExpr(0.0), AffExpr(0.0)]

    inputs = Dict(
        "L" => 1,
        "NCapacityReserveMargin" => 3,
        "dfTransCapRes_exclPeak" => reshape([-1.0, 1.0, -1.0], 1, 3),
        "dfDerateTransCapResPeak" => reshape([0.95, 0.95, 0.0], 1, 3),
    )

    GenX.add_peakload_transmission_capacity_contribution!(model, inputs)
    @constraint(model, reinforcement == 0.5)
    @objective(model, Min, reinforcement)
    optimize!(model)

    # Existing 2.0 plus reinforcement 0.5, accredited at 0.95. GenX uses -1 for
    # the receiving region, which is credited with the firm capacity transfer.
    @test value(model[:eCapResMarBalancePeak][1]) ≈ 2.375
    # GenX uses +1 for the sending region, from which the same transfer is deducted.
    @test value(model[:eCapResMarBalancePeak][2]) ≈ -2.375
    # A zero external derating factor disables line credit without a code change.
    @test value(model[:eCapResMarBalancePeak][3]) ≈ 0.0
    @test !haskey(JuMP.object_dictionary(model), :vFLOW)
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
