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
    credited = capacity_payment_reported_capacity(EP, inputs)
    revenues = credited * prices

    cap_payment_per_unit = DataFrame(
        Resource = [resource_name(gen[y]) for y in 1:G],
        Zone = [zones[y] for y in 1:G],
        NameplateCapacityMW = capacities .* capacity_scale_factor,
        AccreditedCapacityMW =
            [sum(credited[y, r] for r in 1:N) * capacity_scale_factor
             for y in 1:G],
        CapacityPaymentTotal = revenues .* monetary_scale_factor
    )
    for r in 1:N
        cap_payment_per_unit[!, Symbol("CapPayment_$r")] =
            credited[:, r] .* prices[r] .* monetary_scale_factor
    end
    CSV.write(joinpath(path, "capacity_payment_per_unit.csv"), cap_payment_per_unit)

    total_payment = DataFrame(
        TotalCapacityPayment = [value(EP[:eTotalCapPayment]) * monetary_scale_factor]
    )
    CSV.write(joinpath(path, "capacity_payment_total.csv"), total_payment)
    if get(inputs, "capacity_payment_delivery_enabled", false)
        delivery = DataFrame(Region=Int[], SourceZone=Int[], Hour=Int[],
            RawCapacityMW=Float64[], PaidCapacityMW=Float64[],
            NetExportMW=Float64[], DeliveryFraction=Float64[], Payment=Float64[])
        raw = value.(EP[:eCapacityPaymentRaw])
        for ((r,z),ys) in sort(collect(EP[:capacityPaymentDeliveryGroups]); by=first)
            total_raw = sum(raw[y,r] for y in ys)
            paid = sum(credited[y,r] for y in ys)
            push!(delivery, (r,z,inputs["capacity_payment_critical_hours"][r],
                total_raw*capacity_scale_factor,paid*capacity_scale_factor,
                value(EP[:eCapacityPaymentExternalFlow][(r,z)])*capacity_scale_factor,
                total_raw > 0 ? paid/total_raw : 0.0,
                paid*prices[r]*monetary_scale_factor))
        end
        CSV.write(joinpath(path, "capacity_payment_delivery.csv"), delivery)
    end
end
