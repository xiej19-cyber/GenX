module TestRetrofitDecoupling

using Test
using GenX
using JuMP
using HiGHS
using CSV
using DataFrames

function retrofit_setup(; ucommit=2, multistage=0)
    setup = GenX.default_settings()
    merge!(setup, Dict(
        "CO2Cap" => 2,
        "StorageLosses" => 1,
        "MinCapReq" => 1,
        "MaxCapReq" => 1,
        "ParameterScale" => 1,
        "UCommit" => ucommit,
        "EnergyShareRequirement" => 1,
        "CapacityReserveMargin" => 1,
        "MultiStage" => multistage,
    ))
    return setup
end

function with_retrofit_case(f; new_build=false)
    mktempdir() do tmp
        case_path = joinpath(tmp, "retrofit")
        cp(joinpath(@__DIR__, "retrofit"), case_path; force=true)
        thermal_path = joinpath(case_path, "resources", "Thermal.csv")
        thermal = CSV.read(thermal_path, DataFrame)
        source_row = only(findall(==("coal_super_1"), thermal.Resource))
        thermal[source_row, :Can_Retire] = 0
        thermal[source_row, :New_Build] = Int(new_build)
        if new_build
            thermal[source_row, :Max_Cap_MW] = 8000
        end
        CSV.write(thermal_path, thermal)
        return f(case_path)
    end
end

@testset "Thermal retrofit without direct retirement" begin
    for ucommit in (0, 2)
        with_retrofit_case() do case_path
            setup = retrofit_setup(; ucommit)
            inputs = GenX.load_inputs(setup, case_path)
            source = only(findall(==("coal_super_1"), inputs["RESOURCE_NAMES"]))
            option = only(findall(==("20A_retrofit_1"), inputs["RESOURCE_NAMES"]))
            @test source in inputs["RETROFIT_CAP"]
            @test !(source in inputs["RET_CAP"])

            optimizer = GenX.configure_solver(case_path, HiGHS.Optimizer)
            model = GenX.generate_model(setup, inputs, optimizer)
            if ucommit == 0
                @test coefficient(model[:eTotalCap][source],
                    model[:vRETROFITCAP][source]) ≈ -1.0
            else
                fix(model[:vRETROFITCAP][source], 1.0; force=true)
                model, _ = GenX.solve_model(model, setup)
                @test termination_status(model) == JuMP.MOI.OPTIMAL
                @test value(model[:eTotalCap][source]) ≈ 5.7 atol=1e-6
                @test value(model[:eTotalCap][option]) ≈ 0.255 atol=1e-6
            end
        end
    end

    with_retrofit_case(; new_build=true) do case_path
        setup = retrofit_setup()
        inputs = GenX.load_inputs(setup, case_path)
        source = only(findall(==("coal_super_1"), inputs["RESOURCE_NAMES"]))
        @test source in inputs["NEW_CAP"]
        @test source in inputs["RETROFIT_CAP"]
        @test !(source in inputs["RET_CAP"])

        optimizer = GenX.configure_solver(case_path, HiGHS.Optimizer)
        model = GenX.generate_model(setup, inputs, optimizer)
        @test coefficient(model[:eTotalCap][source], model[:vCAP][source]) ≈ 0.3
        @test coefficient(model[:eTotalCap][source], model[:vRETROFITCAP][source]) ≈ -0.3
    end
end

@testset "Other retrofit modes retain their validation" begin
    source = GenX.Thermal(Dict(
        :resource => "source", :can_retrofit => 1, :can_retire => 0,
        :new_build => 0, :retrofit => 0,
    ))
    storage = GenX.Storage(copy(parent(source)))
    @test isempty(GenX.check_retrofit_resource(retrofit_setup(), source))
    @test !isempty(GenX.check_retrofit_resource(retrofit_setup(; multistage=1), source))
    @test !isempty(GenX.check_retrofit_resource(retrofit_setup(), storage))
end

end # module TestRetrofitDecoupling
