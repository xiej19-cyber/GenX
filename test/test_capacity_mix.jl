using CSV
using DataFrames
using HiGHS
using JuMP
using Test

function capacity_mix_resource(T, name, id)
    return T(Dict{Symbol, Any}(:resource => name, :id => id, :zone => 1, :cluster => 1))
end

function write_capacity_mix_inputs(path; shares = [0.6, 0.4, 0.6, 0.4],
        assignments = DataFrame(Resource = ["Wind", "Battery", "Wind", "Gas"],
            Group = ["Portfolio", "Portfolio", "Second", "Second"],
            Resource_Type = ["Wind", "4h storage", "Wind", "Gas"]))
    mkpath(joinpath(path, "policies"))
    mkpath(joinpath(path, "resources", "policy_assignments"))
    CSV.write(joinpath(path, "policies", "Capacity_mix.csv"), DataFrame(
        Group = ["Portfolio", "Portfolio", "Second", "Second"],
        Resource_Type = ["Wind", "4h storage", "Wind", "Gas"],
        Share = shares))
    CSV.write(joinpath(path, "resources", "policy_assignments", "Resource_capacity_mix.csv"),
        assignments)
end

@testset "Capacity mix loading, modeling, and results" begin
    mktempdir() do path
        write_capacity_mix_inputs(path)
        resources = [
            capacity_mix_resource(GenX.Vre, "Wind", 1),
            capacity_mix_resource(GenX.Storage, "Battery", 2),
            capacity_mix_resource(GenX.Thermal, "Gas", 3),
        ]
        inputs = Dict{String, Any}("RESOURCES" => resources)
        setup = GenX.default_settings()
        setup["CapacityMix"] = 1
        GenX.load_capacity_mix!(setup, path, inputs)

        model = Model(HiGHS.Optimizer)
        set_silent(model)
        @variable(model, capacity[1:3] >= 0)
        model[:eTotalCap] = capacity
        GenX.capacity_mix!(model, inputs)
        fix.(capacity, [60.0, 40.0, 40.0]; force = true)
        @objective(model, Min, 0)
        optimize!(model)
        @test termination_status(model) == MOI.OPTIMAL
        @test length(model[:cCapacityMix]) == 2

        result = GenX.write_capacity_mix(path, inputs, setup, model)
        @test nrow(result) == 4
        @test result.Type_Capacity_MW == [60.0, 40.0, 60.0, 40.0]
        @test result.Group_Capacity_MW == fill(100.0, 4)
        @test result.Realized_Share ≈ [0.6, 0.4, 0.6, 0.4]
        @test isfile(joinpath(path, "Capacity_mix_results.csv"))

        fix.(capacity, 0.0; force = true)
        optimize!(model)
        @test termination_status(model) == MOI.OPTIMAL
        zero_result = GenX.write_capacity_mix(path, inputs, setup, model)
        @test all(ismissing, zero_result.Realized_Share)

        fix.(capacity, [50.0, 50.0, 40.0]; force = true)
        optimize!(model)
        @test termination_status(model) == MOI.INFEASIBLE

        scaled_model = Model(HiGHS.Optimizer)
        set_silent(scaled_model)
        @variable(scaled_model, scaled_capacity[1:3] >= 0)
        scaled_model[:eTotalCap] = scaled_capacity
        GenX.capacity_mix!(scaled_model, inputs)
        fix.(scaled_capacity, [0.06, 0.04, 0.04]; force = true)
        @objective(scaled_model, Min, 0)
        optimize!(scaled_model)
        @test termination_status(scaled_model) == MOI.OPTIMAL
        scaled_setup = GenX.default_settings()
        scaled_setup["ParameterScale"] = 1
        scaled_result = GenX.write_capacity_mix(path, inputs, scaled_setup, scaled_model)
        @test scaled_result.Type_Capacity_MW ≈ [60.0, 40.0, 60.0, 40.0]
    end
end

@testset "Capacity mix rejects inconsistent inputs" begin
    mktempdir() do path
        resources = [
            capacity_mix_resource(GenX.Vre, "Wind", 1),
            capacity_mix_resource(GenX.Storage, "Battery", 2),
            capacity_mix_resource(GenX.Thermal, "Gas", 3),
        ]
        inputs = Dict{String, Any}("RESOURCES" => resources)
        setup = GenX.default_settings()
        setup["CapacityMix"] = 1

        write_capacity_mix_inputs(path; shares = [0.6, 0.5, 0.6, 0.4])
        @test_throws ErrorException GenX.load_capacity_mix!(setup, path, inputs)

        write_capacity_mix_inputs(path; assignments = DataFrame(
            Resource = ["Wind", "Battery", "Wind", "Unknown"],
            Group = ["Portfolio", "Portfolio", "Second", "Second"],
            Resource_Type = ["Wind", "4h storage", "Wind", "Gas"]))
        @test_throws ErrorException GenX.load_capacity_mix!(setup, path, inputs)

        write_capacity_mix_inputs(path; assignments = DataFrame(
            Resource = ["Wind", "Battery", "Wind", "Wind"],
            Group = ["Portfolio", "Portfolio", "Second", "Second"],
            Resource_Type = ["Wind", "4h storage", "Wind", "Gas"]))
        @test_throws ErrorException GenX.load_capacity_mix!(setup, path, inputs)
    end
end
