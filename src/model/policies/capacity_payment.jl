@doc raw"""
	capacity_payment!(EP::Model, inputs::Dict, setup::Dict)

Capacity payment Policy Module
This module adds exogenous capacity payment revenue to the objective function (as negative cost).
payment = (Existing Capacity + New Built Capacity) x payment Price
Objective: minimize total cost - total payment revenue

The payment applies to final discharge/generation capacity after additions and retirements.
For storage and co-located resources, it does not apply to energy or charging capacity.
"""
function capacity_payment!(EP::Model, inputs::Dict, setup::Dict)
    println("Capacity payment Module")

    G = inputs["G"]
    cap_sub_price = inputs["cap_sub_price"]
    eTotalCap = EP[:eTotalCap]

    if setup["MultiStage"] == 0
        gen = inputs["RESOURCES"]
        for y in inputs["NEW_CAP"]
            marginal_fixed_cost = inv_cost_per_mwyr(gen[y]) +
                                  fixed_om_cost_per_mwyr(gen[y]) +
                                  fixed_amt_cost_per_mwyr(gen[y]) -
                                  fixed_subsidy_per_mwyr(gen[y])
            if cap_sub_price[y] > marginal_fixed_cost && max_cap_mw(gen[y]) <= 0
                @warn "Capacity payment exceeds marginal fixed capacity cost for an expandable resource without a finite Max_Cap_MW; the model may be unbounded." resource = resource_name(gen[y]) capacity_payment = cap_sub_price[y] marginal_fixed_cost
            end
        end
    end

    for y in 1:G
        EP[:eCapPayment][y] = cap_sub_price[y] * eTotalCap[y]
    end

    @expression(EP, eTotalCapPayment, sum(EP[:eCapPayment][y] for y in 1:G))
    add_to_expression!(EP[:eObj], -1.0, eTotalCapPayment)
end
