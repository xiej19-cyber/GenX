module TestLinePowerFlowLimits

using GenX
using Test
using CSV
using DataFrames
using JuMP
using HiGHS

function write_profile_file(path::AbstractString, profiles::Vector{Pair{String, Vector{Float64}}})
    df = DataFrame(Time_Index = 1:length(last(first(profiles))))
    for (name, values) in profiles
        df[!, Symbol(name)] = values
    end
    CSV.write(path, df)
end

function network_fixture(profile_ids)
    DataFrame(
        Network_zones = Union{Missing, String}["z1", "z2", "z3", missing],
        Network_Lines = Union{Missing, Int}[34, 57, 59, missing],
        Start_Zone = Union{Missing, Int}[1, 2, 3, missing],
        End_Zone = Union{Missing, Int}[2, 3, 1, missing],
        Line_Power_Profile_ID = Union{Missing, String}[
            profile_ids[1], profile_ids[2], profile_ids[3], missing],
    )
end

function base_setup(; kwargs...)
    setup = GenX.default_settings()
    setup["LinePowerFlowLimits"] = 1
    for (key, value) in kwargs
        setup[string(key)] = value
    end
    setup
end

@testset "settings" begin
    @test GenX.default_settings()["LinePowerFlowLimits"] == 0

    setup = base_setup(MultiStage = 1)
    @test_throws ErrorException GenX.validate_settings!(setup)
end

@testset "profile loading and reuse" begin
    mktempdir() do case_path
        mkpath(joinpath(case_path, "system"))
        mkpath(joinpath(case_path, "policies"))
        profile_a = "1号_up 内部-甲"
        profile_b = "中文_down"
        network = network_fixture([profile_a, profile_b, profile_b])
        write_profile_file(
            joinpath(case_path, "system", "Line_power_flow_limits.csv"),
            [
                "$(profile_b)_down" => [-0.4, -0.3],
                "$(profile_a)_up" => [0.8, 0.9],
                "$(profile_a)_down" => [0.2, 0.3],
                "$(profile_b)_up" => [0.6, 0.7],
            ],
        )

        inputs = Dict{Any, Any}("T" => 2, "L" => 3)
        GenX.load_line_power_flow_limits!(base_setup(), case_path, inputs, network)

        @test inputs["LINE_POWER_LIMIT_LINES"] == [1, 2, 3]
        @test inputs["LINE_POWER_LIMIT_LINE_IDS"] == [34, 57, 59]
        @test inputs["LINE_POWER_LIMIT_NETWORK_ROWS"] == [1, 2, 3]
        @test inputs["LINE_POWER_LIMIT_PROFILE_NAMES"] == sort([profile_a, profile_b])
        @test inputs["LinePowerProfileIndexByLine"][2] ==
              inputs["LinePowerProfileIndexByLine"][3]
        @test size(inputs["pLinePowerProfileDown"]) == (2, 2)
        @test size(inputs["pLinePowerProfileUp"]) == (2, 2)

        a = inputs["LinePowerProfileIndexByName"][profile_a]
        b = inputs["LinePowerProfileIndexByName"][profile_b]
        @test inputs["pLinePowerProfileDown"][:, a] == [0.2, 0.3]
        @test inputs["pLinePowerProfileUp"][:, a] == [0.8, 0.9]
        @test inputs["pLinePowerProfileDown"][:, b] == [-0.4, -0.3]
        @test inputs["pLinePowerProfileUp"][:, b] == [0.6, 0.7]
    end
end

@testset "None lines are excluded" begin
    mktempdir() do case_path
        mkpath(joinpath(case_path, "system"))
        mkpath(joinpath(case_path, "policies"))
        network = network_fixture(["A", "None", "A"])
        write_profile_file(
            joinpath(case_path, "system", "Line_power_flow_limits.csv"),
            ["A_up" => [1.0, 1.0], "A_down" => [-1.0, -1.0]],
        )
        inputs = Dict{Any, Any}("T" => 2, "L" => 3)
        GenX.load_line_power_flow_limits!(base_setup(), case_path, inputs, network)
        @test inputs["LINE_POWER_LIMIT_LINES"] == [1, 3]
        @test inputs["LINE_POWER_LIMIT_LINE_IDS"] == [34, 59]
    end
end

@testset "input validation" begin
    mktempdir() do case_path
        mkpath(joinpath(case_path, "system"))
        mkpath(joinpath(case_path, "policies"))
        inputs = Dict{Any, Any}("T" => 2, "L" => 3)

        missing_network_column = select(network_fixture(["A", "None", "A"]),
            Not(:Line_Power_Profile_ID))
        @test_throws ErrorException GenX.load_line_power_flow_limits!(
            base_setup(), case_path, inputs, missing_network_column)

        for invalid_profile in ("", " A", "A ", "A\tB")
            invalid_network = network_fixture([invalid_profile, "None", "None"])
            @test_throws ErrorException GenX.load_line_power_flow_limits!(
                base_setup(), case_path, copy(inputs), invalid_network)
        end

        network = network_fixture(["A", "None", "A"])
        write_profile_file(
            joinpath(case_path, "system", "Line_power_flow_limits.csv"),
            ["A_up" => [0.8, 0.9]],
        )
        @test_throws ErrorException GenX.load_line_power_flow_limits!(
            base_setup(), case_path, copy(inputs), network)

        write_profile_file(
            joinpath(case_path, "system", "Line_power_flow_limits.csv"),
            [
                "A_up" => [0.8, 0.9],
                "A_down" => [0.2, 0.3],
                "Unused_up" => [1.0, 1.0],
                "Unused_down" => [-1.0, -1.0],
            ],
        )
        @test_throws ErrorException GenX.load_line_power_flow_limits!(
            base_setup(), case_path, copy(inputs), network)

        invalid_frames = [
            DataFrame(Time_Index = [1, 3], A_up = [0.8, 0.9], A_down = [0.2, 0.3]),
            DataFrame(Time_Index = [1, 2], A_up = [1.1, 0.9], A_down = [0.2, 0.3]),
            DataFrame(Time_Index = [1, 2], A_up = [0.1, 0.9], A_down = [0.2, 0.3]),
            DataFrame(Time_Index = [1, 2], A_up = [0.8, Inf], A_down = [0.2, 0.3]),
            DataFrame(Time_Index = [1, 2],
                A_up = Union{Missing, Float64}[0.8, missing],
                A_down = [0.2, 0.3]),
        ]
        for frame in invalid_frames
            CSV.write(joinpath(case_path, "system", "Line_power_flow_limits.csv"), frame)
            @test_throws ErrorException GenX.load_line_power_flow_limits!(
                base_setup(), case_path, copy(inputs), network)
        end
    end
end

@testset "duplicate CSV headers are rejected" begin
    mktempdir() do temp_dir
        path = joinpath(temp_dir, "duplicate.csv")
        open(path, "w") do io
            write(io, "\"曲线,A_up\",\"曲线,A_up\"\n0.8,0.9\n")
        end
        @test_throws ErrorException GenX.ensure_unique_csv_columns(path)
    end
end

@testset "slack prices are line-specific and scaled" begin
    mktempdir() do case_path
        mkpath(joinpath(case_path, "system"))
        mkpath(joinpath(case_path, "policies"))
        network = network_fixture(["A", "None", "A"])
        write_profile_file(
            joinpath(case_path, "system", "Line_power_flow_limits.csv"),
            ["A_up" => [0.8, 0.9], "A_down" => [0.2, 0.3]],
        )
        CSV.write(
            joinpath(case_path, "policies", "Line_power_flow_limits_slack.csv"),
            DataFrame(
                Network_Lines = [59, 34],
                LowerBound_PriceCap = [3000.0, 1000.0],
                UpperBound_PriceCap = [4000.0, 2000.0],
            ),
        )
        inputs = Dict{Any, Any}("T" => 2, "L" => 3)
        GenX.load_line_power_flow_limits!(
            base_setup(ParameterScale = 1), case_path, inputs, network)
        @test inputs["pLinePowerDownPrice"] == [1.0, 3.0]
        @test inputs["pLinePowerUpPrice"] == [2.0, 4.0]
        @test inputs["pLinePowerProfileDown"] == reshape([0.2, 0.3], 2, 1)
        @test inputs["pLinePowerProfileUp"] == reshape([0.8, 0.9], 2, 1)

        CSV.write(
            joinpath(case_path, "policies", "Line_power_flow_limits_slack.csv"),
            DataFrame(
                Network_Lines = [34],
                LowerBound_PriceCap = [1000.0],
                UpperBound_PriceCap = [2000.0],
            ),
        )
        @test_throws ErrorException GenX.load_line_power_flow_limits!(
            base_setup(), case_path, copy(inputs), network)
    end
end

@testset "direction and annual minimum-flow compatibility checks" begin
    inputs = Dict{Any, Any}(
        "LINE_POWER_LIMIT_LINES" => [1],
        "LINE_POWER_LIMIT_LINE_IDS" => [34],
        "LinePowerProfileIndexByLine" => [1],
        "pLinePowerProfileDown" => reshape([0.1, 0.2], 2, 1),
        "pLinePowerProfileUp" => reshape([0.8, 0.9], 2, 1),
        "Direction_Multiplier" => [-1.0],
        "LineMinCF" => [0.2],
    )
    setup = base_setup(PowerFlowDirectionRequirement = 1, LineMinCF = 0)
    @test_throws ErrorException GenX.validate_line_power_direction_compatibility!(
        setup, inputs)

    inputs["Direction_Multiplier"] = [1.0]
    inputs["pLinePowerProfileDown"] = reshape([0.0, 0.0], 2, 1)
    setup["LineMinCF"] = 1
    @test_logs (:warn, r"LineMinCF") GenX.validate_line_power_direction_compatibility!(
        setup, inputs)
end

@testset "hard constraint uses final capacity" begin
    inputs = Dict{Any, Any}(
        "T" => 2,
        "LINE_POWER_LIMIT_LINES" => [2],
        "LinePowerProfileIndexByLine" => [1],
        "pLinePowerProfileDown" => reshape([0.3, -0.4], 2, 1),
        "pLinePowerProfileUp" => reshape([0.8, 0.6], 2, 1),
    )
    setup = base_setup()
    model = Model()
    @variable(model, vFLOW[1:2, 1:2])
    @variable(model, eAvail_Trans_Cap[1:2] >= 0)
    model[:eObj] = AffExpr(0.0)

    GenX.line_power_flow_limits!(model, inputs, setup)

    lower = model[:cLinePowerDown][1, 1]
    upper = model[:cLinePowerUp][1, 1]
    @test normalized_coefficient(lower, model[:vFLOW][2, 1]) == 1.0
    @test normalized_coefficient(lower, model[:eAvail_Trans_Cap][2]) == -0.3
    @test normalized_coefficient(upper, model[:vFLOW][2, 1]) == 1.0
    @test normalized_coefficient(upper, model[:eAvail_Trans_Cap][2]) == -0.8
    @test !haskey(JuMP.object_dictionary(model), :vLinePowerDownViolation)
end

@testset "soft constraints add weighted line-specific penalties" begin
    inputs = Dict{Any, Any}(
        "T" => 2,
        "omega" => [2.0, 3.0],
        "LINE_POWER_LIMIT_LINES" => [2],
        "LinePowerProfileIndexByLine" => [1],
        "pLinePowerProfileDown" => reshape([0.3, -0.4], 2, 1),
        "pLinePowerProfileUp" => reshape([0.8, 0.6], 2, 1),
        "pLinePowerDownPrice" => [100.0],
        "pLinePowerUpPrice" => [200.0],
    )
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, vFLOW[1:2, 1:2])
    @variable(model, eAvail_Trans_Cap[1:2] >= 0)
    model[:eObj] = AffExpr(0.0)

    GenX.line_power_flow_limits!(model, inputs, base_setup())

    down_violation = model[:vLinePowerDownViolation][1, 1]
    up_violation = model[:vLinePowerUpViolation][1, 1]
    @test normalized_coefficient(model[:cLinePowerDown][1, 1], down_violation) == 1.0
    @test normalized_coefficient(model[:cLinePowerUp][1, 1], up_violation) == -1.0
    @test coefficient(model[:eObj], down_violation) == 200.0
    @test coefficient(model[:eObj], up_violation) == 400.0
    fix(down_violation, 1.0; force = true)
    fix(up_violation, 2.0; force = true)
    @objective(model, Min, model[:eObj])
    optimize!(model)
    @test GenX.line_power_flow_limit_penalty_cost(inputs, model) == 1000.0
end

@testset "hard infeasibility and paid violations" begin
    hard_inputs = Dict{Any, Any}(
        "T" => 1,
        "omega" => [1.0],
        "LINE_POWER_LIMIT_LINES" => [1],
        "LinePowerProfileIndexByLine" => [1],
        "pLinePowerProfileDown" => reshape([0.5], 1, 1),
        "pLinePowerProfileUp" => reshape([1.0], 1, 1),
    )
    hard_model = Model(HiGHS.Optimizer)
    set_silent(hard_model)
    @variable(hard_model, vFLOW[1:1, 1:1])
    @variable(hard_model, eAvail_Trans_Cap[1:1] >= 0)
    fix(hard_model[:vFLOW][1, 1], 0.0; force = true)
    fix(hard_model[:eAvail_Trans_Cap][1], 100.0; force = true)
    hard_model[:eObj] = AffExpr(0.0)
    GenX.line_power_flow_limits!(hard_model, hard_inputs, base_setup())
    @objective(hard_model, Min, hard_model[:eObj])
    optimize!(hard_model)
    @test termination_status(hard_model) == JuMP.MOI.INFEASIBLE

    soft_inputs = copy(hard_inputs)
    soft_inputs["pLinePowerDownPrice"] = [100.0]
    soft_inputs["pLinePowerUpPrice"] = [200.0]
    soft_model = Model(HiGHS.Optimizer)
    set_silent(soft_model)
    @variable(soft_model, vFLOW[1:1, 1:1])
    @variable(soft_model, eAvail_Trans_Cap[1:1] >= 0)
    fix(soft_model[:vFLOW][1, 1], 0.0; force = true)
    fix(soft_model[:eAvail_Trans_Cap][1], 100.0; force = true)
    soft_model[:eObj] = AffExpr(0.0)
    GenX.line_power_flow_limits!(soft_model, soft_inputs, base_setup())
    @objective(soft_model, Min, soft_model[:eObj])
    optimize!(soft_model)
    @test termination_status(soft_model) == JuMP.MOI.OPTIMAL
    @test value(soft_model[:vLinePowerDownViolation][1, 1]) ≈ 50.0
    @test value(soft_model[:vLinePowerUpViolation][1, 1]) ≈ 0.0
    @test objective_value(soft_model) ≈ 5000.0
end

@testset "signed intervals, equal bounds, and zero capacity" begin
    inputs = Dict{Any, Any}(
        "T" => 1,
        "LINE_POWER_LIMIT_LINES" => collect(1:5),
        "LinePowerProfileIndexByLine" => collect(1:5),
        "pLinePowerProfileDown" => reshape([0.3, -0.8, -0.5, 0.4, 1.0], 1, 5),
        "pLinePowerProfileUp" => reshape([0.8, -0.3, 0.7, 0.4, 1.0], 1, 5),
    )
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, vFLOW[1:5, 1:1])
    @variable(model, eAvail_Trans_Cap[1:5] >= 0)
    for line in 1:4
        fix(model[:eAvail_Trans_Cap][line], 100.0; force = true)
    end
    fix(model[:eAvail_Trans_Cap][5], 0.0; force = true)
    for (line, flow) in enumerate([50.0, -50.0, 0.0, 40.0, 0.0])
        fix(model[:vFLOW][line, 1], flow; force = true)
    end
    model[:eObj] = AffExpr(0.0)
    GenX.line_power_flow_limits!(model, inputs, base_setup())
    @objective(model, Min, model[:eObj])
    optimize!(model)
    @test termination_status(model) == JuMP.MOI.OPTIMAL
    @test value(model[:vFLOW][4, 1]) == 40.0
    @test value(model[:vFLOW][5, 1]) == 0.0
end

@testset "policy is connected to the generated model" begin
    mktempdir() do temp_dir
        source_case = joinpath(@__DIR__, "DCOPF")
        case_path = joinpath(temp_dir, "DCOPF")
        cp(source_case, case_path)

        network_path = joinpath(case_path, "system", "Network.csv")
        network = CSV.read(network_path, DataFrame)
        network[!, :Line_Power_Profile_ID] = fill("None", nrow(network))
        network[1, :Line_Power_Profile_ID] = "A"
        CSV.write(network_path, network)
        write_profile_file(
            joinpath(case_path, "system", "Line_power_flow_limits.csv"),
            ["A_up" => [1.0], "A_down" => [-1.0]],
        )

        setup = base_setup(
            Trans_Loss_Segments = 0,
            StorageLosses = 0,
            DC_OPF = 1,
        )
        inputs = redirect_stdout(devnull) do
            GenX.load_inputs(setup, case_path)
        end
        model = redirect_stdout(devnull) do
            GenX.generate_model(setup, inputs, optimizer_with_attributes(HiGHS.Optimizer))
        end

        @test haskey(JuMP.object_dictionary(model), :cLinePowerDown)
        @test haskey(JuMP.object_dictionary(model), :cLinePowerUp)
        @test size(model[:cLinePowerDown]) == (1, 1)
    end
end

@testset "TDR extracts the selected raw rows without changing columns" begin
    mktempdir() do temp_dir
        raw_dir = joinpath(temp_dir, "system")
        output_dir = joinpath(temp_dir, "TDR_results")
        mkpath(raw_dir)
        mkpath(output_dir)
        CSV.write(
            joinpath(raw_dir, "Demand_data.csv"),
            DataFrame(Time_Index = 1:6),
        )
        raw_profiles = DataFrame(
            Time_Index = 1:6,
            A_up = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            A_down = [-0.6, -0.5, -0.4, -0.3, -0.2, -0.1],
        )
        CSV.write(joinpath(raw_dir, "Line_power_flow_limits.csv"), raw_profiles)

        output = GenX.write_tdr_line_power_flow_limits_from_raw(
            raw_dir, output_dir, [2], 2, ["A"])

        @test names(output) == names(raw_profiles)
        @test output.Time_Index == [1, 2]
        @test output.A_up == [0.3, 0.4]
        @test output.A_down == [-0.4, -0.3]
        @test isfile(joinpath(output_dir, "Line_power_flow_limits.csv"))

        invalid_unselected = copy(raw_profiles)
        invalid_unselected.A_up[1] = 1.5
        CSV.write(joinpath(raw_dir, "Line_power_flow_limits.csv"), invalid_unselected)
        @test_throws ErrorException GenX.write_tdr_line_power_flow_limits_from_raw(
            raw_dir, output_dir, [2], 2, ["A"])

        open(joinpath(raw_dir, "Line_power_flow_limits.csv"), "w") do io
            write(io,
                "Time_Index,A_up,A_up,A_down\n" *
                "1,0.1,0.1,-0.6\n2,0.2,0.2,-0.5\n3,0.3,0.3,-0.4\n" *
                "4,0.4,0.4,-0.3\n5,0.5,0.5,-0.2\n6,0.6,0.6,-0.1\n")
        end
        @test_throws ErrorException GenX.write_tdr_line_power_flow_limits_from_raw(
            raw_dir, output_dir, [2], 2, ["A"])
    end
end

@testset "balance and dual outputs restore MW and USD per MWh" begin
    inputs = Dict{Any, Any}(
        "T" => 2,
        "omega" => [2.0, 4.0],
        "LINE_POWER_LIMIT_LINES" => [1],
        "LINE_POWER_LIMIT_LINE_IDS" => [34],
        "LINE_POWER_LIMIT_PROFILE_NAMES" => ["A"],
        "LinePowerProfileIndexByLine" => [1],
        "pLinePowerProfileDown" => reshape([0.3, -0.4], 2, 1),
        "pLinePowerProfileUp" => reshape([0.8, 0.6], 2, 1),
        "pTrans_Start_Zone" => [5],
        "pTrans_End_Zone" => [7],
    )
    setup = base_setup(ParameterScale = 1, ObjScale = 2.0)
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, vFLOW[1:1, 1:2])
    @variable(model, eAvail_Trans_Cap[1:1] >= 0)
    fix(model[:eAvail_Trans_Cap][1], 0.1; force = true)
    model[:eObj] = AffExpr(0.0)
    GenX.line_power_flow_limits!(model, inputs, setup)
    @objective(model,
        Min,
        setup["ObjScale"] *
        (inputs["omega"][1] * 0.01 * model[:vFLOW][1, 1] -
         inputs["omega"][2] * 0.02 * model[:vFLOW][1, 2]))
    optimize!(model)

    mktempdir() do output_dir
        GenX.write_line_power_flow_limits(output_dir, inputs, setup, model)
        balance = CSV.read(
            joinpath(output_dir, "line_power_flow_balance.csv"), DataFrame)
        @test balance.Network_Line == [34, 34]
        @test balance.Profile_ID == ["A", "A"]
        @test balance.Final_Capacity_MW == [100.0, 100.0]
        @test balance.Down_Bound_MW ≈ [30.0, -40.0]
        @test balance.Up_Bound_MW ≈ [80.0, 60.0]
        @test balance.Actual_Flow_MW ≈ [30.0, 60.0]
        @test balance.Down_Violation_MW == [0.0, 0.0]
        @test balance.Up_Violation_MW == [0.0, 0.0]

        prices = CSV.read(
            joinpath(output_dir, "line_power_flow_limit_prices.csv"), DataFrame)
        @test prices.Lower_Bound_Price_USD_per_MWh ≈ [10.0, 0.0] atol = 1e-7
        @test prices.Upper_Bound_Price_USD_per_MWh ≈ [0.0, 20.0] atol = 1e-7
    end
end

end
