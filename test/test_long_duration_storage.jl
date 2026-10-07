using DataFrames
using CSV
using HiGHS
using JuMP

function independent_lds_test_resource(; zone = 1, lds = 1, model = 1)
    return GenX.Storage(Dict{Symbol, Any}(
        :resource => "Independent LDES",
        :zone => zone,
        :region => "Test region",
        :cluster => 1,
        :model => model,
        :lds => lds,
        :self_disch => 0.0,
        :eff_up => 1.0,
        :eff_down => 1.0,
        :derating_factor_1 => 0.8,
    ))
end

@testset "manual representative-week maps do not require TDR" begin
    for (representative_periods, weights) in (
        (4, [2208.0, 2208.0, 2184.0, 2160.0]),
        (12, Float64.([31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] .* 24)),
        (4, fill(2184.0, 4)),
        (12, Float64.([31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 30] .* 24)),
    )
        inputs = Dict{String, Any}(
            "REP_PERIOD" => representative_periods,
            "hours_per_subperiod" => 168,
            "Weights" => weights,
        )
        GenX.build_manual_representative_week_period_map!(inputs)
        period_map = inputs["Period_Map"]
        @test nrow(period_map) == 52
        @test period_map.Period_Index == 1:52
        @test Set(period_map.Rep_Period_Index) == Set(1:representative_periods)
        @test sum(weights) in (8736.0, 8760.0)
        @test inputs["Period_Map_Source"] ==
              "automatic manual representative-week calendar"
    end

    seasonal_inputs = Dict{String, Any}(
        "REP_PERIOD" => 4,
        "hours_per_subperiod" => 168,
        "Weights" => [2208.0, 2208.0, 2184.0, 2160.0],
    )
    GenX.build_manual_representative_week_period_map!(seasonal_inputs)
    period_map = seasonal_inputs["Period_Map"]
    @test period_map.Rep_Period_Index[[1, 14, 27, 40, 52]] == [4, 1, 2, 3, 4]

    invalid_resource = independent_lds_test_resource(lds = 2)
    @test length(GenX.check_LDS_applicability(invalid_resource)) == 1
    invalid_model = independent_lds_test_resource(model = 0)
    @test length(GenX.check_LDS_applicability(invalid_model)) == 1

    invalid_setup = GenX.default_settings()
    invalid_setup["LDSAdditionalConstraints"] = 2
    @test_throws AssertionError GenX.validate_settings!(invalid_setup)

    # A stale TDR map must not suppress automatic mapping when TDR is disabled.
    mktempdir() do case_path
        mkpath(joinpath(case_path, "system"))
        mkpath(joinpath(case_path, "TDR_results"))
        CSV.write(joinpath(case_path, "TDR_results", "Period_map.csv"),
            DataFrame(Period_Index = [1], Rep_Period = [1], Rep_Period_Index = [1]))
        map_setup = GenX.default_settings()
        map_setup["TimeDomainReduction"] = 0
        @test !GenX.is_period_map_exist(map_setup, case_path)
        map_setup["TimeDomainReduction"] = 1
        @test GenX.period_map_path(map_setup, case_path) ==
              joinpath(case_path, "TDR_results", "Period_map.csv")
    end

    # Numeric CSV columns are normalized to integers before they are used as indices.
    floating_map = DataFrame(
        Period_Index = [1.0, 2.0],
        Rep_Period = [1.0, 2.0],
        Rep_Period_Index = [1.0, 2.0],
    )
    GenX.validate_period_map!(floating_map, Dict("REP_PERIOD" => 2))
    @test eltype(floating_map.Period_Index) == Int
    @test eltype(floating_map.Rep_Period) == Int
    @test eltype(floating_map.Rep_Period_Index) == Int

    unsupported_weights = Dict{String, Any}(
        "REP_PERIOD" => 4,
        "hours_per_subperiod" => 168,
        "Weights" => fill(2190.0, 4),
    )
    @test_throws ErrorException begin
        GenX.build_manual_representative_week_period_map!(unsupported_weights)
    end
end

@testset "independent LDS transfers energy between representative periods" begin
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, eTotalCapEnergy[1:1] >= 0)
    @variable(model, eTotalCap[1:1] >= 0)
    @variable(model, vCHARGE[1:1, 1:8] >= 0)
    @variable(model, vS[1:1, 1:8] >= 0)
    @variable(model, vP[1:1, 1:8] >= 0)
    model[:eTotalCapEnergy] = eTotalCapEnergy
    model[:eTotalCap] = eTotalCap
    model[:vCHARGE] = vCHARGE
    model[:vS] = vS
    model[:vP] = vP
    fix(eTotalCapEnergy[1], 10.0; force = true)
    fix(eTotalCap[1], 1.0; force = true)

    for t in 1:8
        fix(vCHARGE[1, t], t == 2 ? 1.0 : 0.0; force = true)
        fix(vP[1, t], t == 6 ? 1.0 : 0.0; force = true)
        @constraint(model, vS[1, t] <= eTotalCapEnergy[1])
    end
    @constraint(model, [t in [2, 3, 4, 6, 7, 8]],
        vS[1, t] == vS[1, t - 1] - vP[1, t] + vCHARGE[1, t])

    inputs = Dict{String, Any}(
        "RESOURCES" => [independent_lds_test_resource()],
        "REP_PERIOD" => 2,
        "STOR_LONG_DURATION" => [1],
        "hours_per_subperiod" => 4,
        "Period_Map" => DataFrame(
            Period_Index = 1:4,
            # The second profile's source anchor is period 2 even though that
            # chronological period is assigned to profile 1. LDS must use the
            # explicit anchor, not infer anchors from self-assignment.
            Rep_Period = [1, 1, 2, 2],
            Rep_Period_Index = [1, 1, 2, 2],
        ),
        "Period_Map_Source" => "unit-test explicit map",
        "G" => 1,
        "RESOURCE_NAMES" => ["Independent LDES"],
        "STOR_HYDRO_LONG_DURATION" => Int[],
        "VRE_STOR" => Int[],
        "pP_Max" => zeros(1, 8),
    )
    GenX.validate_period_map!(inputs["Period_Map"], inputs)
    setup = GenX.default_settings()
    setup["LDSAdditionalConstraints"] = 1
    GenX.long_duration_storage!(model, inputs, setup)
    @objective(model, Min, 0)
    optimize!(model)

    @test termination_status(model) == MOI.OPTIMAL
    @test value(model[:vdSOC][1, 1]) ≈ 1.0
    @test value(model[:vdSOC][1, 2]) ≈ -1.0
    @test all(0 .<= value.(model[:vSOCw][1, :]) .<= 10)
    @test haskey(model, :cSoCLongDurationStorageMaxInt)
    @test haskey(model, :cSoCLongDurationStorageMinInt)

    mktempdir() do output_path
        GenX.write_opwrap_lds_stor_init(output_path, inputs, setup, model)
        GenX.write_opwrap_lds_dstor(output_path, inputs, setup, model)
        period_map_used = CSV.read(joinpath(output_path, "Period_map_used.csv"), DataFrame)
        @test period_map_used.Mapping_Source == fill("unit-test explicit map", 4)
        @test isfile(joinpath(output_path, "StorageInit.csv"))
        @test isfile(joinpath(output_path, "StorageEvol.csv"))
        @test isfile(joinpath(output_path, "dStorage.csv"))
    end
end

@testset "independent LDS uses ordinary storage capacity accreditation" begin
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, capacity >= 0)
    model[:eTotalCap] = [capacity]
    fix(capacity, 5.0; force = true)
    inputs = Dict("RESOURCES" => [independent_lds_test_resource()], "THERM_ALL" => Int[])
    contribution = GenX.peakload_resource_capacity_contribution(model, inputs, 1, 1)
    @objective(model, Min, 0)
    optimize!(model)
    @test JuMP.value(contribution) == 4.0
end

@testset "peak-load LDS output respects external delivery cap" begin
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, capacity >= 0)
    @variable(model, delivered_capacity >= 0)
    model[:eTotalCap] = [capacity]
    model[:vPeakPairedCapCredit] = Dict((1, 2) => delivered_capacity)
    model[:ePeakPairedRawCapacity] = Dict((1, 2) => 0.8 * capacity)
    fix(capacity, 5.0; force = true)
    fix(delivered_capacity, 2.0; force = true)
    @objective(model, Min, 0)
    optimize!(model)

    inputs = Dict{String, Any}(
        "STOR_ALL" => [1],
        "NCapacityReserveMargin" => 1,
        "RESOURCE_NAMES" => ["Independent LDES"],
        "R_ZONES" => [2],
        "RESOURCES" => [independent_lds_test_resource(zone = 2)],
        "peak_hour_idx" => [7],
    )
    setup = GenX.default_settings()
    mktempdir() do output_path
        GenX.write_virtual_discharge_peakload(output_path, inputs, setup, model)
        output = CSV.read(joinpath(output_path, "virtual_discharge_peakload.csv"), DataFrame)
        @test only(output.CRM_1) == 2.0
        @test only(output.PeakHour_1) == 7
    end
end
