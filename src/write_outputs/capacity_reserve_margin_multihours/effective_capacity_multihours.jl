@doc raw"""
    thermal_plant_effective_capacity_multihours(EP::Model, inputs::Dict, y::Int, capres_zone::Int, t::Int)

Effective capacity for multihours CRM (same logic as peakload).
"""
function thermal_plant_effective_capacity_multihours(
    EP::Model, inputs::Dict, y::Int, capres_zone::Int, t::Int
)
    return _thermal_effective_capacity_multihours(EP, inputs, y, capres_zone, t)
end

function _thermal_effective_capacity_multihours(
    EP::Model, inputs::Dict, y::Int, capres_zone::Int, t::Int
)
    gen = inputs["RESOURCES"]
    capresfactor = derating_factor(gen[y], tag=capres_zone)
    eTotalCap = value(EP[:eTotalCap][y])

    effective_capacity = capresfactor * eTotalCap

    if has_maintenance(inputs) && y in ids_with_maintenance(gen)
        effective_capacity += value(
            thermal_maintenance_capacity_reserve_margin_multihours_adjustment(
                EP, inputs, y, capres_zone, t
            )
        )
    end

    if y in ids_with(gen, :fusion)
        resource_component = resource_name(gen[y])
        effective_capacity += value(thermal_fusion_capacity_reserve_margin_adjustment(
            EP, inputs, resource_component, y, capres_zone, t))
    end

    return effective_capacity
end

function vre_stor_effective_capacity_multihours(
        EP::Model, y::Int, capres_zone::Int, t::Int)::Float64
    return value(
        EP[:eCapResMarBalanceMultihourVreStorByResource][y, capres_zone, t])
end

function capacity_reserve_margin_price_multihours(
        EP::Model, setup::Dict, capres_zone::Int, t::Int)::Float64
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1.0
    return max(0.0, dual(EP[:cCapacityResMarginMultihour][capres_zone, t])) *
           scale_factor
end
