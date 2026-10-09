using CSV
using DataFrames
using HiGHS
using JuMP
using Test

@testset "CO2 capture cap input" begin
    mktempdir() do path
        setup = Dict("CO2Cap" => 1, "ParameterScale" => 0)
        base = DataFrame(CO_2_Cap_Zone_1 = [1, 1],
            CO_2_Max_Mtons_1 = [100.0, 0.0])

        function load_cap(df, parameter_scale=0)
            CSV.write(joinpath(path, "CO2_cap.csv"), df)
            setup["ParameterScale"] = parameter_scale
            inputs = Dict{String, Any}()
            GenX.load_co2_cap!(setup, path, inputs)
            return inputs
        end

        legacy = load_cap(base)
        @test !haskey(legacy, "dfMaxCO2Capture")

        with_capture = copy(base)
        with_capture.CO_2_Capture_Max_Mtons_1 = [1.25, 0.75]
        @test load_cap(with_capture, 0)["dfMaxCO2Capture"] == reshape([1.25e6, 0.75e6], 2, 1)
        @test load_cap(with_capture, 1)["dfMaxCO2Capture"] == reshape([1250.0, 750.0], 2, 1)

        gap = copy(base)
        gap.CO_2_Capture_Max_Mtons_2 = [1.0, 0.0]
        err = try load_cap(gap) catch e e end
        @test err isa ErrorException
        @test occursin("CO_2_Capture_Max_Mtons", sprint(showerror, err))

        mismatch = copy(with_capture)
        mismatch.CO_2_Capture_Max_Mtons_2 = [1.0, 0.0]
        err = try load_cap(mismatch) catch e e end
        @test err isa ErrorException
        @test occursin("CO_2_Cap_Zone", sprint(showerror, err))

        negative = copy(with_capture)
        negative.CO_2_Capture_Max_Mtons_1 = [-1.0, 0.0]
        err = try load_cap(negative) catch e e end
        @test err isa ErrorException
        @test occursin("nonnegative", sprint(showerror, err))

        incomplete = copy(with_capture)
        incomplete.CO_2_Capture_Max_Mtons_1 = Union{Missing, Float64}[1.0, missing]
        err = try load_cap(incomplete) catch e e end
        @test err isa ErrorException
        @test occursin("missing", sprint(showerror, err))
    end
end

@testset "CO2 capture cap constraints" begin
    resources = [GenX.Thermal(Dict{Symbol, Any}(
        :resource => "Resource $id", :id => id, :zone => zone, :cluster => 1))
        for (id, zone) in enumerate([1, 2, 3, 1])]
    inputs = Dict{String, Any}(
        "SEG" => 1, "T" => 2, "NCO2Cap" => 2,
        "omega" => [2.0, 3.0],
        "dfCO2CapZones" => [1 0; 1 0; 0 1],
        "dfMaxCO2" => zeros(3, 2),
        "dfMaxCO2Capture" => [25.0 0.0; 0.0 0.0; 0.0 12.0],
        "CCS" => [1, 2, 3], "RESOURCES" => resources,
    )
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, 0 <= captured[1:3, 1:2] <= 10)
    @variable(model, 0 <= uncaptured <= 10)
    @expression(model, eEmissionsCaptureByPlantYear[y in 1:3],
        2 * captured[y, 1] + 3 * captured[y, 2])
    model[:eEmissionsByZone] = [AffExpr(0.0) for _ in 1:3, _ in 1:2]
    model[:eObj] = AffExpr(0.0)
    GenX.co2_cap!(model, inputs, Dict("CO2Cap" => 1))

    @test haskey(object_dictionary(model), :cCO2Capture_systemwide)
    cap_1 = model[:cCO2Capture_systemwide][1]
    cap_2 = model[:cCO2Capture_systemwide][2]
    @test normalized_coefficient(cap_1, captured[1, 1]) == 2.0
    @test normalized_coefficient(cap_1, captured[2, 2]) == 3.0
    @test normalized_coefficient(cap_1, captured[3, 1]) == 0.0
    @test normalized_coefficient(cap_2, captured[3, 2]) == 3.0
    @test normalized_coefficient(cap_2, captured[1, 1]) == 0.0
    @test normalized_coefficient(cap_1, uncaptured) == 0.0

    @objective(model, Max, sum(captured) + uncaptured)
    optimize!(model)
    @test termination_status(model) == MOI.OPTIMAL
    @test sum(value(eEmissionsCaptureByPlantYear[y]) for y in 1:2) ≈ 25.0
    @test value(eEmissionsCaptureByPlantYear[3]) ≈ 12.0
    @test value(uncaptured) ≈ 10.0

    legacy_inputs = copy(inputs)
    delete!(legacy_inputs, "dfMaxCO2Capture")
    legacy_model = Model()
    legacy_model[:eObj] = AffExpr(0.0)
    legacy_model[:eEmissionsByZone] = [AffExpr(0.0) for _ in 1:3, _ in 1:2]
    GenX.co2_cap!(legacy_model, legacy_inputs, Dict("CO2Cap" => 1))
    @test !haskey(object_dictionary(legacy_model), :cCO2Capture_systemwide)

    empty_inputs = copy(inputs)
    empty_inputs["CCS"] = Int[]
    empty_model = Model()
    empty_model[:eObj] = AffExpr(0.0)
    empty_model[:eEmissionsByZone] = [AffExpr(0.0) for _ in 1:3, _ in 1:2]
    err = try GenX.co2_cap!(empty_model, empty_inputs, Dict("CO2Cap" => 1)) catch e e end
    @test err isa ErrorException
    @test occursin("CCS", sprint(showerror, err))
end
