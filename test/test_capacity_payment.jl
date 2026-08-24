using CSV
using DataFrames
using HiGHS
using JuMP

function capacity_payment_resource(; name = "Test resource", price = 50.0,
        include_price = true, max_cap = 10.0)
    attributes = Dict{Symbol, Any}(
        :resource => name,
        :zone => 1,
        :cluster => 1,
        :max_cap_mw => max_cap,
        :inv_cost_per_mwyr => 100.0,
        :fixed_om_cost_per_mwyr => 0.0,
        :fixed_amt_cost_per_mwyr => 0.0,
        :fixed_subsidy_per_mwyr => 0.0,
    )
    include_price && (attributes[:capacity_sub_price] = price)
    return GenX.Thermal(attributes)
end

@testset "input validation and scaling" begin
    setup = GenX.default_settings()
    setup["CapacityPayment"] = 1
    inputs = Dict("RESOURCES" => [capacity_payment_resource()], "G" => 1)

    GenX.load_capacity_payment!(setup, "resources", inputs)
    @test inputs["cap_sub_price"] == [50.0]

    setup["ParameterScale"] = 1
    GenX.load_capacity_payment!(setup, "resources", inputs)
    @test inputs["cap_sub_price"] == [0.05]

    missing_column_inputs = Dict(
        "RESOURCES" => [capacity_payment_resource(include_price = false)],
        "G" => 1,
    )
    @test_throws ErrorException GenX.load_capacity_payment!(
        setup, "resources", missing_column_inputs)

    invalid_inputs = Dict(
        "RESOURCES" => [capacity_payment_resource(price = NaN)],
        "G" => 1,
    )
    @test_throws ErrorException GenX.load_capacity_payment!(setup, "resources", invalid_inputs)
end

@testset "objective and monetary output scaling" begin
    setup = GenX.default_settings()
    setup["CapacityPayment"] = 1
    setup["ParameterScale"] = 1

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, capacity >= 0)
    model[:eTotalCap] = [capacity]
    model[:eObj] = AffExpr(0.0)
    GenX.create_empty_expression!(model, :eCapPayment, 1)

    resource = capacity_payment_resource()
    inputs = Dict(
        "G" => 1,
        "NEW_CAP" => [1],
        "RESOURCES" => [resource],
        "R_ZONES" => [1],
        "cap_sub_price" => [0.05],
    )
    GenX.capacity_payment!(model, inputs, setup)
    @constraint(model, capacity == 2.0)
    @objective(model, Min, model[:eObj])
    optimize!(model)

    @test objective_value(model) ≈ -0.1
    @test value(model[:eTotalCapPayment]) ≈ 0.1

    mktempdir() do output_path
        GenX.write_capacity_payment(model, inputs, output_path, setup)
        per_resource = CSV.read(
            joinpath(output_path, "capacity_payment_per_unit.csv"), DataFrame)
        total = CSV.read(joinpath(output_path, "capacity_payment_total.csv"), DataFrame)
        @test per_resource.CapacityPaymentTotal == [100_000.0]
        @test total.TotalCapacityPayment == [100_000.0]
        @test sum(per_resource.CapacityPaymentTotal) == only(total.TotalCapacityPayment)
    end
end

@testset "unboundedness warning" begin
    setup = GenX.default_settings()
    setup["CapacityPayment"] = 1
    model = Model()
    @variable(model, capacity >= 0)
    model[:eTotalCap] = [capacity]
    model[:eObj] = AffExpr(0.0)
    GenX.create_empty_expression!(model, :eCapPayment, 1)
    inputs = Dict(
        "G" => 1,
        "NEW_CAP" => [1],
        "RESOURCES" => [capacity_payment_resource(price = 150.0, max_cap = -1.0)],
        "cap_sub_price" => [150.0],
    )

    @test_logs (:warn, r"model may be unbounded") GenX.capacity_payment!(model, inputs, setup)
end
