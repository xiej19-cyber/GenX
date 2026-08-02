using JuMP
using CSV
using DataFrames

function minimum_commitment_test_resource(name, id, zone, cap;
        eligible = 1, model = 1, fuel = "coal_test")
    GenX.Thermal(Dict{Symbol, Any}(
        :resource => name,
        :id => id,
        :zone => zone,
        :cap_size => cap,
        :model => model,
        :fuel => fuel,
        :minimum_commitment => eligible,
    ))
end

@testset "Zonal minimum commitment constraint" begin
    gen = [
        minimum_commitment_test_resource("coal_1", 1, 1, 100.0),
        minimum_commitment_test_resource("coal_2", 2, 1, 200.0),
        minimum_commitment_test_resource("coal_3", 3, 2, 100.0),
    ]
    model = Model()
    @variable(model, vCOMMIT[y in 1:3, t in 1:2] >= 0)
    @expression(model, eTotalCap[y in 1:3], [400.0, 600.0, 200.0][y])
    inputs = Dict{String, Any}(
        "T" => 2,
        "RESOURCES" => gen,
        "MINIMUM_COMMITMENT_ZONES" => [1],
        "MINIMUM_COMMITMENT_BY_ZONE" => [[1, 2], [3]],
        "pMinimumCommitment" => [0.5 0.75; 0.0 0.0],
        "MINIMUM_COMMITMENT_GAS_ZONES" => [1],
        "MINIMUM_COMMITMENT_GAS_BY_ZONE" => [[3], Int[]],
        "pMinimumCommitmentGas" => [0.25 0.5; 0.0 0.0],
    )

    GenX.minimum_commitment!(model, inputs)
    constraint = model[:cMinimumCommitment][1, 1]
    @test normalized_coefficient(constraint, model[:vCOMMIT][1, 1]) == 100.0
    @test normalized_coefficient(constraint, model[:vCOMMIT][2, 1]) == 200.0
    @test normalized_rhs(constraint) == 500.0
    @test normalized_rhs(model[:cMinimumCommitment][1, 2]) == 750.0
    @test normalized_coefficient(
        model[:cMinimumCommitmentGas][1, 1], model[:vCOMMIT][3, 1]) == 100.0
    @test normalized_rhs(model[:cMinimumCommitmentGas][1, 1]) == 50.0

    model_without_profile = Model()
    @variable(model_without_profile, vCOMMIT[y in 1:1, t in 1:1] >= 0)
    GenX.minimum_commitment!(model_without_profile, Dict{String, Any}())
    @test !haskey(JuMP.object_dictionary(model_without_profile), :cMinimumCommitment)
end

@testset "Minimum commitment TDR extraction" begin
    mktempdir() do case_path
        raw_path = joinpath(case_path, "system")
        output_path = joinpath(case_path, "TDR_results")
        mkpath(raw_path)
        mkpath(output_path)
        CSV.write(joinpath(raw_path, "Minimum_commitment_coal.csv"),
            DataFrame(Time_Index = 1:8,
                Zone_1 = collect(0.1:0.1:0.8), Zone_2 = zeros(8)))
        CSV.write(joinpath(raw_path, "Minimum_commitment_gas.csv"),
            DataFrame(Time_Index = 1:8, Zone_1 = collect(0.8:-0.1:0.1)))

        output = GenX.write_tdr_minimum_commitment_from_raw(
            raw_path, output_path, [2, 4], 2)
        @test output.Time_Index == 1:4
        @test output.Zone_1 ≈ [0.3, 0.4, 0.7, 0.8]
        @test isfile(joinpath(output_path, "Minimum_commitment_coal.csv"))
        gas_output = GenX.write_tdr_minimum_commitment_from_raw(
            raw_path, output_path, [2, 4], 2;
            filename = "Minimum_commitment_gas.csv")
        @test gas_output.Zone_1 ≈ [0.6, 0.5, 0.2, 0.1]
    end
end

@testset "Zonal minimum commitment input" begin
    mktempdir() do case_path
        system_path = joinpath(case_path, "system")
        mkpath(system_path)
        setup = Dict{String, Any}(
            "TimeDomainReduction" => 0,
            "TimeDomainReductionFolder" => "TDR_results",
            "SystemFolder" => "system",
        )
        gen = [
            minimum_commitment_test_resource("coal_1", 1, 1, 100.0),
            minimum_commitment_test_resource("coal_2", 2, 1, 200.0; eligible = 0),
            minimum_commitment_test_resource("gas_1", 3, 2, 100.0;
                fuel = "naturalgas_test"),
        ]
        inputs = Dict{String, Any}(
            "T" => 3,
            "Z" => 2,
            "RESOURCES" => gen,
            "THERM_COMMIT" => [1, 2, 3],
        )

        GenX.load_minimum_commitment!(setup, case_path, inputs)
        @test inputs["MINIMUM_COMMITMENT_ZONES"] == Int[]
        @test inputs["MINIMUM_COMMITMENT_BY_ZONE"] == [[1], Int[]]
        @test inputs["MINIMUM_COMMITMENT_GAS_BY_ZONE"] == [Int[], [3]]
        @test inputs["pMinimumCommitment"] == zeros(2, 3)

        CSV.write(joinpath(system_path, "Minimum_commitment_coal.csv"),
            DataFrame(Time_Index = 1:3,
                Zone_1 = [0.0, 0.7, 0.6]))
        CSV.write(joinpath(system_path, "Minimum_commitment_gas.csv"),
            DataFrame(Time_Index = 1:3, Zone_2 = [0.5, 0.5, 0.0]))
        GenX.load_minimum_commitment!(setup, case_path, inputs)
        @test inputs["MINIMUM_COMMITMENT_ZONES"] == [1]
        @test inputs["MINIMUM_COMMITMENT_GAS_ZONES"] == [2]
        @test inputs["pMinimumCommitment"][1, :] == [0.0, 0.7, 0.6]
        @test inputs["pMinimumCommitmentGas"][2, :] == [0.5, 0.5, 0.0]

        CSV.write(joinpath(system_path, "Minimum_commitment_coal.csv"),
            DataFrame(Time_Index = 1:3, Zone_1 = [0.0, 1.1, 0.0]))
        @test_throws AssertionError GenX.load_minimum_commitment!(setup, case_path, inputs)

        CSV.write(joinpath(system_path, "Minimum_commitment_coal.csv"),
            DataFrame(Time_Index = 1:4, Zone_1 = fill(0.5, 4)))
        @test_throws AssertionError GenX.load_minimum_commitment!(setup, case_path, inputs)
    end
end
