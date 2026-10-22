@doc raw"""
	capacity_payment!(EP::Model, inputs::Dict, setup::Dict)

Capacity payment Policy Module. Payment is made only to accredited capacity:
Local payment = total capacity x regional derating factor x regional capacity price.
External dedicated payment is additionally capped by deliverable critical-hour flow.
Objective: minimize total cost - total payment revenue

The payment applies to final discharge/generation capacity after additions and retirements.
For storage and co-located resources, it does not apply to energy or charging capacity.
"""
function capacity_payment!(EP::Model, inputs::Dict, setup::Dict)
    println("Capacity payment Module")

    G = inputs["G"]
    prices = inputs["capacity_payment_price"]
    factors = inputs["CAPACITY_PAYMENT_DERATING_FACTOR"]
    N = inputs["NCapacityPaymentRegions"]
    eTotalCap = EP[:eTotalCap]

    add_capacity_payment_delivery_limits!(EP, inputs)

    if setup["MultiStage"] == 0
        gen = inputs["RESOURCES"]
        for y in inputs["NEW_CAP"]
            marginal_fixed_cost = inv_cost_per_mwyr(gen[y]) +
                                  fixed_om_cost_per_mwyr(gen[y]) +
                                  fixed_amt_cost_per_mwyr(gen[y]) -
                                  fixed_subsidy_per_mwyr(gen[y])
            effective_payment_rate = sum((prices[r] * factors[y, r] for r in 1:N
                if !haskey(EP[:vCapacityPaymentExternalPaid], (r, y))); init=0.0)
            if effective_payment_rate > marginal_fixed_cost && max_cap_mw(gen[y]) <= 0
                @warn "Capacity payment exceeds marginal fixed capacity cost for an expandable resource without a finite Max_Cap_MW; the model may be unbounded." resource = resource_name(gen[y]) capacity_payment = effective_payment_rate marginal_fixed_cost
            end
        end
    end

    for y in 1:G
        EP[:eCapPayment][y] =
            sum(prices[r] * EP[:eCapacityPaymentCredited][y, r] for r in 1:N)
    end

    @expression(EP, eTotalCapPayment, sum(EP[:eCapPayment][y] for y in 1:G))
    add_to_expression!(EP[:eObj], -1.0, eTotalCapPayment)
end

"""Accreditation before delivery limits, including committed thermal adjustments."""
function capacity_payment_raw_capacity(EP::Model, inputs::Dict, y::Int, r::Int)
    factor = inputs["CAPACITY_PAYMENT_DERATING_FACTOR"][y,r]
    raw = factor * EP[:eTotalCap][y]
    get(inputs, "capacity_payment_delivery_enabled", false) || return raw
    # Local resources retain the existing fixed-factor payment rule. Adjust the
    # external thermal contribution in the same hour as peakload/multihours.
    gen = inputs["RESOURCES"]
    zone_id(gen[y]) in inputs["capacity_payment_crm_zones"][r] && return raw
    if y in get(inputs, "THERM_COMMIT", Int[]) && !iszero(factor)
        t = inputs["capacity_payment_critical_hours"][r]
        if y in ids_with_maintenance(gen)
            down = EP[Symbol(maintenance_down_name(resource_name(gen[y])))]
            raw -= factor * down[t] * cap_size(gen[y])
        end
        if y in ids_with(gen, fusion)
            payment_inputs = copy(inputs)
            payment_inputs["DERATING_FACTOR"] = inputs["CAPACITY_PAYMENT_DERATING_FACTOR"]
            raw += fusion_capacity_reserve_margin_adjustment(
                EP, payment_inputs, resource_name(gen[y]), y, r, t)
        end
    end
    return raw
end

"""Limit external payments by eligible connecting lines' signed critical-hour flow.
The per-resource LP allocation is immaterial at a common regional price. Reports
allocate each source zone's solved aggregate credit proportionally to raw capacity.
"""
function add_capacity_payment_delivery_limits!(EP::Model, inputs::Dict)
    G = inputs["G"]
    N = inputs["NCapacityPaymentRegions"]
    factors = inputs["CAPACITY_PAYMENT_DERATING_FACTOR"]
    @expression(EP, eCapacityPaymentRaw[y=1:G,r=1:N],
        capacity_payment_raw_capacity(EP, inputs, y, r))
    @expression(EP, eCapacityPaymentCredited[y=1:G,r=1:N], eCapacityPaymentRaw[y,r])
    paid = Dict{Tuple{Int,Int},VariableRef}()
    groups = Dict{Tuple{Int,Int},Vector{Int}}()
    flows = Dict{Tuple{Int,Int},Any}()
    EP[:vCapacityPaymentExternalPaid] = paid
    EP[:capacityPaymentDeliveryGroups] = groups
    EP[:eCapacityPaymentExternalFlow] = flows
    get(inputs, "capacity_payment_delivery_enabled", false) || return nothing
    gen = inputs["RESOURCES"]
    derating = inputs["capacity_payment_line_derating"]
    participation = inputs["capacity_payment_line_participation"]
    start_zone = inputs["pTrans_Start_Zone"]
    end_zone = inputs["pTrans_End_Zone"]
    for r in 1:N
        zones = inputs["capacity_payment_crm_zones"][r]
        t = inputs["capacity_payment_critical_hours"][r]
        for z in setdiff(1:inputs["Z"], zones)
            ys = [y for y in 1:G if zone_id(gen[y]) == z && !iszero(factors[y,r])]
            isempty(ys) && continue
            any(y -> y in get(inputs,"VRE_STOR",Int[]), ys) && error("External VRE_STOR payment delivery is not supported by the dedicated-generation accounting used by peakload/multihours.")
            lines = [l for l in 1:inputs["L"] if iszero(derating[l,r]) &&
                !iszero(participation[l,r]) &&
                ((start_zone[l] == z && end_zone[l] in zones) ||
                 (end_zone[l] == z && start_zone[l] in zones))]
            isempty(lines) && @warn("External resources in zone $z assigned to CapPayment_$r have no connecting dedicated CRM line; their paid capacity is zero.")
            groups[(r,z)] = ys
            flows[(r,z)] = @expression(EP,
                sum(-participation[l,r] * EP[:vFLOW][l,t] for l in lines))
            for y in ys
                paid[(r,y)] = @variable(EP, lower_bound=0,
                    base_name="vCapacityPaymentExternalPaid_$(r)_$(y)")
                @constraint(EP, paid[(r,y)] <= eCapacityPaymentRaw[y,r])
                EP[:eCapacityPaymentCredited][y,r] = 1.0 * paid[(r,y)]
            end
            @constraint(EP, sum(paid[(r,y)] for y in ys) <= flows[(r,z)])
        end
    end
    return nothing
end

"""Solved credited capacity, with proportional allocation within each external zone."""
function capacity_payment_reported_capacity(EP::Model, inputs::Dict)
    G = inputs["G"]
    N = inputs["NCapacityPaymentRegions"]
    if !haskey(EP, :eCapacityPaymentRaw)
        return inputs["CAPACITY_PAYMENT_DERATING_FACTOR"] .* value.(EP[:eTotalCap][1:G])
    end
    raw = Array(value.(EP[:eCapacityPaymentRaw]))
    result = copy(raw)
    for ((r,z),ys) in EP[:capacityPaymentDeliveryGroups]
        total = sum(raw[y,r] for y in ys)
        credit = sum(value(EP[:vCapacityPaymentExternalPaid][(r,y)]) for y in ys)
        fraction = total > 0 ? clamp(credit/total,0.0,1.0) : 0.0
        for y in ys
            result[y,r] = raw[y,r] * fraction
        end
    end
    return result
end

"""Resource revenue allocation shared by payment, cost and net-revenue reports."""
function capacity_payment_reported_revenue(EP::Model, inputs::Dict)
    return capacity_payment_reported_capacity(EP, inputs) * inputs["capacity_payment_price"]
end
