using CSV
using DataFrames
using HiGHS
using JuMP

function generation_hours_resource(name, id;
        max_tag = "none", min_tag = "none")
    return GenX.Thermal(Dict{Symbol, Any}(
        :resource => name,
        :id => id,
        :zone => 1,
        :cluster => 1,
        :maxgenhours => max_tag,
        :mingenhours => min_tag,
    ))
end

@testset "Generation-hours input and validation" begin
    mktempdir() do case_path
        resources = [
            generation_hours_resource("Gas 1", 1;
                max_tag = "Gas", min_tag = "Gas minimum"),
            generation_hours_resource("Gas 2", 2;
                max_tag = "Gas", min_tag = "Gas minimum"),
            generation_hours_resource("Coal", 3),
        ]
        inputs = Dict{String, Any}("RESOURCES" => resources)
        setup = GenX.default_settings()

        CSV.write(joinpath(case_path, "Maximum_generation_hours.csv"), DataFrame(
            ConstraintDescription = ["Gas"], Max_Hours = [3_000.0]))
        CSV.write(joinpath(case_path, "Minimum_generation_hours.csv"), DataFrame(
            ConstraintDescription = ["Gas minimum"], Min_Hours = [1_500.0]))

        GenX.load_maximum_generation_hours!(case_path, inputs, setup)
        GenX.load_minimum_generation_hours!(case_path, inputs, setup)
        @test inputs["MaxGenHoursNames"] == ["Gas"]
        @test inputs["MaxGenHoursValues"] == [3_000.0]
        @test inputs["MaxGenHoursResources"] == [[1, 2]]
        @test inputs["MinGenHoursNames"] == ["Gas minimum"]
        @test inputs["MinGenHoursResources"] == [[1, 2]]

        resources[3].maxgenhours = "Unknown"
        @test_throws ErrorException GenX.load_maximum_generation_hours!(
            case_path, inputs, setup)
    end
end

@testset "Grouped maximum and minimum generation hours" begin
    resources = [
        generation_hours_resource("Gas 1", 1; max_tag = "Gas", min_tag = "Gas"),
        generation_hours_resource("Gas 2", 2; max_tag = "Gas", min_tag = "Gas"),
        generation_hours_resource("Coal", 3),
    ]
    inputs = Dict{String, Any}(
        "T" => 2,
        "omega" => [4_000.0, 4_760.0],
        "RESOURCES" => resources,
        "NumberOfMaxGenHoursReqs" => 1,
        "MaxGenHoursNames" => ["Gas"],
        "MaxGenHoursValues" => [3_000.0],
        "MaxGenHoursResources" => [[1, 2]],
        "NumberOfMinGenHoursReqs" => 1,
        "MinGenHoursNames" => ["Gas"],
        "MinGenHoursValues" => [1_500.0],
        "MinGenHoursResources" => [[1, 2]],
    )

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, vP[1:3, 1:2] >= 0)
    @variable(model, capacity[1:3] >= 0)
    model[:eTotalCap] = capacity
    GenX.maximum_generation_hours!(model, inputs)
    GenX.minimum_generation_hours!(model, inputs)

    # Gas 1 individually operates for 4,000 equivalent hours, but the two-resource
    # group averages 2,000 hours and therefore satisfies the 3,000-hour limit.
    fix.(capacity, [100.0, 100.0, 50.0]; force = true)
    fix.(vP, [100.0 0.0; 0.0 0.0; 50.0 50.0]; force = true)
    @objective(model, Min, 0)
    optimize!(model)

    @test termination_status(model) == MOI.OPTIMAL
    @test value(model[:eMaxGenHoursAnnualGeneration][1]) ≈ 400_000.0
    @test value(model[:eMaxGenHoursTotalCapacity][1]) ≈ 200.0
    @test value(model[:eMaxGenHoursAnnualGeneration][1]) /
          value(model[:eMaxGenHoursTotalCapacity][1]) ≈ 2_000.0
    @test normalized_coefficient(model[:cMaxGenHours][1], vP[1, 1]) == 4_000.0
    @test normalized_coefficient(model[:cMaxGenHours][1], capacity[1]) == -3_000.0
    @test normalized_coefficient(model[:cMaxGenHours][1], vP[3, 1]) == 0.0
    @test normalized_coefficient(model[:cMinGenHours][1], capacity[1]) == -1_500.0

    setup = GenX.default_settings()
    mktempdir() do output_path
        maximum_output = GenX.write_maximum_generation_hours(
            output_path, inputs, setup, model)
        minimum_output = GenX.write_minimum_generation_hours(
            output_path, inputs, setup, model)
        @test maximum_output.Realized_Hours ≈ [2_000.0]
        @test minimum_output.Realized_Hours ≈ [2_000.0]
        @test maximum_output.Annual_Generation_MWh ≈ [400_000.0]
        @test isfile(joinpath(output_path, "Maximum_generation_hours_results.csv"))
        @test isfile(joinpath(output_path, "Minimum_generation_hours_results.csv"))
    end

    scaled_model = Model(HiGHS.Optimizer)
    set_silent(scaled_model)
    @variable(scaled_model, scaled_vP[1:3, 1:2] >= 0)
    @variable(scaled_model, scaled_capacity[1:3] >= 0)
    scaled_model[:vP] = scaled_vP
    scaled_model[:eTotalCap] = scaled_capacity
    GenX.maximum_generation_hours!(scaled_model, inputs)
    fix.(scaled_capacity, [0.1, 0.1, 0.05]; force = true)
    fix.(scaled_vP, [0.1 0.0; 0.0 0.0; 0.05 0.05]; force = true)
    @objective(scaled_model, Min, 0)
    optimize!(scaled_model)

    scaled_setup = GenX.default_settings()
    scaled_setup["ParameterScale"] = 1
    mktempdir() do output_path
        scaled_output = GenX.write_maximum_generation_hours(
            output_path, inputs, scaled_setup, scaled_model)
        @test scaled_output.Annual_Generation_MWh ≈ [400_000.0]
        @test scaled_output.Total_Capacity_MW ≈ [200.0]
        @test scaled_output.Realized_Hours ≈ [2_000.0]
    end
end
