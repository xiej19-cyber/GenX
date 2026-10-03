function _realized_generation_hours(annual_generation::AbstractVector{<:Real},
        total_capacity::AbstractVector{<:Real})
    return Union{Missing, Float64}[
        capacity > 0 ? generation / capacity : missing
        for (generation, capacity) in zip(annual_generation, total_capacity)
    ]
end

function write_maximum_generation_hours(path::AbstractString,
        inputs::Dict,
        setup::Dict,
        EP::Model)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1.0
    annual_generation = value.(EP[:eMaxGenHoursAnnualGeneration])
    total_capacity = value.(EP[:eMaxGenHoursTotalCapacity])
    result = DataFrame(
        ConstraintDescription = inputs["MaxGenHoursNames"],
        Max_Hours = inputs["MaxGenHoursValues"],
        Annual_Generation_MWh = annual_generation .* scale_factor,
        Total_Capacity_MW = total_capacity .* scale_factor,
        Realized_Hours = _realized_generation_hours(annual_generation, total_capacity),
        Shadow_Price_USD_per_MWh = -dual.(EP[:cMaxGenHours]) .* scale_factor,
    )
    CSV.write(joinpath(path, "Maximum_generation_hours_results.csv"), result)
    return result
end

function write_minimum_generation_hours(path::AbstractString,
        inputs::Dict,
        setup::Dict,
        EP::Model)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1.0
    annual_generation = value.(EP[:eMinGenHoursAnnualGeneration])
    total_capacity = value.(EP[:eMinGenHoursTotalCapacity])
    result = DataFrame(
        ConstraintDescription = inputs["MinGenHoursNames"],
        Min_Hours = inputs["MinGenHoursValues"],
        Annual_Generation_MWh = annual_generation .* scale_factor,
        Total_Capacity_MW = total_capacity .* scale_factor,
        Realized_Hours = _realized_generation_hours(annual_generation, total_capacity),
        Shadow_Price_USD_per_MWh = dual.(EP[:cMinGenHours]) .* scale_factor,
    )
    CSV.write(joinpath(path, "Minimum_generation_hours_results.csv"), result)
    return result
end
