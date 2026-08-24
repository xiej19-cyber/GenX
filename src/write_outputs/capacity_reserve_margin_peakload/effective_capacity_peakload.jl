@doc raw"""
    thermal_plant_effective_capacity(EP::Model,
                                     inputs::Dict,
                                     resources::Vector{Int},
                                     capres_zone::Int,
                                     timesteps::Vector{Int})::Matrix{Float64})

Effective capacity in a capacity reserve margin zone for certain resources in the given timesteps.
"""
function thermal_plant_effective_capacity_peakload(
        EP::Model, inputs::Dict, y::Int, capres_zone::Int)::Float64
    t_peak = inputs["peak_hour_idx"][capres_zone]
    return _thermal_effective_capacity_peakload(
            EP, inputs, y, capres_zone, t_peak)
end

function _thermal_effective_capacity_peakload(
        EP::Model,
        inputs::Dict,
        y::Int,
        capres_zone::Int,
        t_peak::Int)::Float64

    gen          = inputs["RESOURCES"]
    capresfactor = derating_factor(gen[y], tag = capres_zone)
    eTotalCap    = value(EP[:eTotalCap][y])

    effective_capacity = capresfactor * eTotalCap

    if has_maintenance(inputs) && y in ids_with_maintenance(gen)
            effective_capacity += value(thermal_maintenance_capacity_reserve_margin_peakload_adjustment(
                         EP, inputs, y, capres_zone, t_peak))
    end

    if y in ids_with(gen, :fusion)
        resource_component = resource_name(gen[y])
            effective_capacity += value(thermal_fusion_capacity_reserve_margin_adjustment(
                         EP, inputs, resource_component, y, capres_zone, t_peak))
    end

    return effective_capacity
end

function vre_stor_effective_capacity_peakload(
        EP::Model, y::Int, capres_zone::Int)::Float64
    return value(EP[:eCapResMarBalancePeakVreStorByResource][y, capres_zone])
end
