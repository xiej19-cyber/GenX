using CSV
using DataFrames
using HiGHS
using JuMP

function capacity_payment_resource(; name = "Test resource", max_cap = 10.0)
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
    return GenX.Thermal(attributes)
end

@testset "input validation and scaling" begin
    mktempdir() do case_path
        policies = joinpath(case_path, "policies")
        assignments = joinpath(case_path, "resources", "policy_assignments")
        mkpath(policies)
        mkpath(assignments)
        CSV.write(joinpath(policies, "Capacity_payment.csv"), DataFrame(
            CapPayment_Region=["CapPayment_1"], CapacityPrice=[50.0]))
        CSV.write(joinpath(assignments, "Resource_capacity_payment.csv"), DataFrame(
            Resource=["Test resource"], Derating_Factor_1=[0.8]))

        setup = GenX.default_settings()
        setup["CapacityPayment"] = 1
        inputs = Dict("RESOURCES" => [capacity_payment_resource()], "G" => 1)
        GenX.load_capacity_payment!(setup, case_path, inputs)
        @test inputs["capacity_payment_price"] == [50.0]
        @test inputs["CAPACITY_PAYMENT_DERATING_FACTOR"] == reshape([0.8], 1, 1)

        setup["ParameterScale"] = 1
        GenX.load_capacity_payment!(setup, case_path, inputs)
        @test inputs["capacity_payment_price"] == [0.05]

        CSV.write(joinpath(policies, "Capacity_payment.csv"), DataFrame(
            CapPayment_Region=["CapPayment_1"], CapacityPrice=[NaN]))
        @test_throws ErrorException GenX.load_capacity_payment!(setup, case_path, inputs)
    end
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
        "NCapacityPaymentRegions" => 1,
        "capacity_payment_price" => [0.05],
        "CAPACITY_PAYMENT_DERATING_FACTOR" => reshape([0.8], 1, 1),
    )
    GenX.capacity_payment!(model, inputs, setup)
    @constraint(model, capacity == 2.0)
    @objective(model, Min, model[:eObj])
    optimize!(model)

    @test objective_value(model) ≈ -0.08
    @test value(model[:eTotalCapPayment]) ≈ 0.08

    mktempdir() do output_path
        GenX.write_capacity_payment(model, inputs, output_path, setup)
        per_resource = CSV.read(
            joinpath(output_path, "capacity_payment_per_unit.csv"), DataFrame)
        total = CSV.read(joinpath(output_path, "capacity_payment_total.csv"), DataFrame)
        @test per_resource.NameplateCapacityMW == [2_000.0]
        @test per_resource.AccreditedCapacityMW == [1_600.0]
        @test per_resource.CapPayment_1 ≈ [80_000.0]
        @test per_resource.CapacityPaymentTotal ≈ [80_000.0]
        @test total.TotalCapacityPayment ≈ [80_000.0]
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
        "RESOURCES" => [capacity_payment_resource(max_cap = -1.0)],
        "NCapacityPaymentRegions" => 1,
        "capacity_payment_price" => [150.0],
        "CAPACITY_PAYMENT_DERATING_FACTOR" => reshape([1.0], 1, 1),
    )

    @test_logs (:warn, r"model may be unbounded") GenX.capacity_payment!(model, inputs, setup)
end

@testset "net revenue totals include every reported component" begin
    revenue_columns = [
        :EnergyRevenue,
        :SubsidyRevenue,
        :OperatingReserveRevenue,
        :OperatingRegulationRevenue,
        :ReserveMarginRevenue,
        :ReserveMarginRevenue_peakload,
        :ReserveMarginRevenue_multihours,
        :ESRRevenue,
        :RegSubsidyRevenue,
        :CapacityPaymentRevenue,
    ]
    cost_columns = [
        :Inv_cost_MW,
        :Inv_cost_MWh,
        :Inv_cost_charge_MW,
        :Fixed_OM_cost_MW,
        :Fixed_AMT_cost_MW,
        :Fixed_OM_cost_MWh,
        :Fixed_AMT_cost_MWh,
        :Fixed_OM_cost_charge_MW,
        :Fixed_AMT_cost_charge_MW,
        :Var_OM_cost_out,
        :Fuel_cost,
        :Var_OM_cost_in,
        :StartCost,
        :Charge_cost,
        :CO2SequestrationCost,
        :EmissionsCost,
    ]
    fixed_subsidy_columns = [
        :Fixed_Subsidy_MW,
        :Fixed_Subsidy_MWh,
        :Fixed_Subsidy_charge_MW,
    ]
    df = DataFrame()
    for column in revenue_columns
        df[!, column] = [1.0, 2.0]
    end
    for column in cost_columns
        df[!, column] = [3.0, 4.0]
    end
    for column in fixed_subsidy_columns
        df[!, column] = [0.5, 1.0]
    end

    GenX._add_net_revenue_totals!(df)

    @test df.Revenue == [10.0, 20.0]
    @test df.Cost == [46.5, 61.0]
    @test df.Profit == [-36.5, -41.0]
end
