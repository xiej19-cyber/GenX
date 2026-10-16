"""Write target and realized capacity shares without requiring model duals."""
function write_capacity_mix(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    scale = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1.0
    group_capacity = value.(EP[:eCapacityMixGroup])
    type_capacity = value.(EP[:eCapacityMixType])
    group_index = inputs["CapacityMixGroupIndex"]
    totals = group_capacity[group_index]
    shares = inputs["CapacityMixShares"]
    realized = Union{Missing, Float64}[
        total * scale > 1e-6 ? type_capacity[r] / total : missing
        for (r, total) in enumerate(totals)
    ]
    result = DataFrame(
        Group = inputs["CapacityMixGroups"][group_index],
        Resource_Type = inputs["CapacityMixTypes"],
        Target_Share = shares,
        Type_Capacity_MW = type_capacity .* scale,
        Group_Capacity_MW = totals .* scale,
        Realized_Share = realized,
        Share_Gap = realized .- shares,
    )
    CSV.write(joinpath(path, "Capacity_mix_results.csv"), result)
    return result
end
