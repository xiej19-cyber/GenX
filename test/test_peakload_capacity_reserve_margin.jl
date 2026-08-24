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
