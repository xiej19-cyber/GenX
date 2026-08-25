function write_capacity_payment(EP::Model, inputs::Dict, path::AbstractString, setup::Dict)
    println("Writing Capacity Payment Outputs")
    monetary_scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor^2 : 1

    gen = inputs["RESOURCES"]
    G = inputs["G"]
    zones = inputs["R_ZONES"]
    N = inputs["NCapacityPaymentRegions"]
    factors = inputs["CAPACITY_PAYMENT_DERATING_FACTOR"]
    prices = inputs["capacity_payment_price"]
    capacity_scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    capacities = value.(EP[:eTotalCap][1:G])

    cap_payment_per_unit = DataFrame(
        Resource = [resource_name(gen[y]) for y in 1:G],
        Zone = [zones[y] for y in 1:G],
        NameplateCapacityMW = capacities .* capacity_scale_factor,
        AccreditedCapacityMW =
            [sum(factors[y, r] * capacities[y] for r in 1:N) * capacity_scale_factor
             for y in 1:G],
        CapacityPaymentTotal = value.(EP[:eCapPayment][1:G]) .* monetary_scale_factor
    )
    for r in 1:N
        cap_payment_per_unit[!, Symbol("CapPayment_$r")] =
            factors[:, r] .* capacities .* prices[r] .* monetary_scale_factor
    end
    CSV.write(joinpath(path, "capacity_payment_per_unit.csv"), cap_payment_per_unit)

    total_payment = DataFrame(
        TotalCapacityPayment = [value(EP[:eTotalCapPayment]) * monetary_scale_factor]
    )
    CSV.write(joinpath(path, "capacity_payment_total.csv"), total_payment)
end
