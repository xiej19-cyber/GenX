using CSV
using DataFrames

function minvar_test_thermal(name, id; min_power, minvar = "None", maxvar = "None")
    GenX.Thermal(Dict{Symbol, Any}(
        :resource => name,
        :id => id,
        :zone => 1,
        :model => 1,
        :min_power => min_power,
        :minvar => minvar,
        :maxvar => maxvar,
    ))
end

@testset "Narrow minimum-power variability" begin
    mktempdir() do case_path
        system_path = joinpath(case_path, "system")
        mkpath(system_path)
        setup = Dict{String, Any}(
            "TimeDomainReduction" => 0,
            "TimeDomainReductionFolder" => "TDR_results",
            "SystemFolder" => "system",
            "NarrowVariability" => 1,
        )
        gen = [
            minvar_test_thermal("coal", 1;
                min_power = 0.3, minvar = "Coal_Min", maxvar = "Coal_Max"),
            minvar_test_thermal("gas", 2; min_power = 0.2),
        ]
        inputs = Dict{String, Any}(
            "T" => 3,
            "G" => 2,
            "RESOURCES" => gen,
            "RESOURCE_NAMES" => ["coal", "gas"],
            "THERM_COMMIT" => [1, 2],
        )

        CSV.write(joinpath(system_path, "Generators_variability.csv"),
            DataFrame(Time_Index = 1:3,
                Coal_Max = [1.0, 0.8, 0.9], Coal_Min = [0.5, 0.4, 0.45]))
        GenX.load_generators_variability!(setup, case_path, inputs)

        @test inputs["pP_Min"][1, :] == [0.5, 0.4, 0.45]
        @test inputs["pP_Min"][2, :] == fill(0.2, 3)
        @test inputs["pP_Max"][1, :] == [1.0, 0.8, 0.9]
        @test inputs["pP_Max"][2, :] == ones(3)

        CSV.write(joinpath(system_path, "Generators_variability.csv"),
            DataFrame(Time_Index = 1:3,
                Coal_Max = [1.0, 0.3, 0.9], Coal_Min = [0.5, 0.4, 0.45]))
        @test_throws AssertionError GenX.load_generators_variability!(
            setup, case_path, inputs)
    end
end
