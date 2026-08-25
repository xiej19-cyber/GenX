@doc raw"""
	capacity_payment!(EP::Model, inputs::Dict, setup::Dict)

Capacity payment Policy Module. Payment is made only to accredited capacity:
payment = total capacity x regional derating factor x regional capacity price.
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

    if setup["MultiStage"] == 0
        gen = inputs["RESOURCES"]
        for y in inputs["NEW_CAP"]
            marginal_fixed_cost = inv_cost_per_mwyr(gen[y]) +
                                  fixed_om_cost_per_mwyr(gen[y]) +
                                  fixed_amt_cost_per_mwyr(gen[y]) -
                                  fixed_subsidy_per_mwyr(gen[y])
            effective_payment_rate = sum(prices[r] * factors[y, r] for r in 1:N)
            if effective_payment_rate > marginal_fixed_cost && max_cap_mw(gen[y]) <= 0
                @warn "Capacity payment exceeds marginal fixed capacity cost for an expandable resource without a finite Max_Cap_MW; the model may be unbounded." resource = resource_name(gen[y]) capacity_payment = effective_payment_rate marginal_fixed_cost
            end
        end
    end

    for y in 1:G
        EP[:eCapPayment][y] =
            sum(prices[r] * factors[y, r] * eTotalCap[y] for r in 1:N)
    end

    @expression(EP, eTotalCapPayment, sum(EP[:eCapPayment][y] for y in 1:G))
    add_to_expression!(EP[:eObj], -1.0, eTotalCapPayment)
end
