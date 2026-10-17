"""Constrain each resource type to its share of its group's final power capacity."""
function capacity_mix!(EP::Model, inputs::Dict)
    ids_by_group = inputs["CapacityMixIdsByGroup"]
    ids_by_target = inputs["CapacityMixIdsByTarget"]
    group_index = inputs["CapacityMixGroupIndex"]
    shares = inputs["CapacityMixShares"]
    @expression(EP, eCapacityMixGroup[g = eachindex(ids_by_group)],
        sum(EP[:eTotalCap][y] for y in ids_by_group[g]))
    @expression(EP, eCapacityMixType[r = eachindex(ids_by_target)],
        sum(EP[:eTotalCap][y] for y in ids_by_target[r]))
    @constraint(EP, cCapacityMix[r in inputs["CapacityMixConstrainedRows"]],
        eCapacityMixType[r] == shares[r] * eCapacityMixGroup[group_index[r]])
    return nothing
end
