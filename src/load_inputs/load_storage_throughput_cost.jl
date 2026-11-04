"""Validate an explicit storage price; zero disables that side of the surcharge."""
function validated_storage_throughput_price(value, label)
    (value isa Real && !(value isa Bool) && isfinite(value) && value >= 0) ||
        error("$label must be a finite, nonnegative number (currency/MWh).")
    return Float64(value)
end

"""Validate optional price columns before the normal resource scaling step."""
function validate_storage_throughput_columns(data::DataFrame, resource_type::Type)
    resource_type in (Storage, VreStorage) || return nothing
    for column in (:charge_cost_per_mwh, :discharge_cost_per_mwh)
        if column in propertynames(data)
            for (i, price) in enumerate(data[!, column])
                validated_storage_throughput_price(price, "$column on resource row $i")
            end
        end
    end
    return nothing
end

"""Validate resource-table prices. No setting or separate price file controls these fees."""
function load_storage_throughput_cost!(setup::Dict, path::AbstractString, inputs::Dict)
    storage = union(get(inputs, "STOR_ALL", Int[]), get(inputs, "VS_STOR", Int[]))
    isempty(storage) && return nothing
    storage_throughput_rates(inputs, setup)
    if haskey(setup, "StorageThroughputCost")
        @warn "The legacy StorageThroughputCost setting is ignored; use Charge_Cost_per_MWh and Discharge_Cost_per_MWh in resource tables."
    end
    if isfile(joinpath(path, setup["SystemFolder"], "Storage_throughput_cost.csv"))
        @warn "Storage_throughput_cost.csv is obsolete and ignored; prices now come from Storage.csv / Vre_stor.csv."
    end
    return nothing
end

"""Per-resource prices already scaled by the standard resource data loader."""
function storage_throughput_rates(inputs::AbstractDict, setup::AbstractDict)
    G = get(inputs, "G", 0)
    charge, discharge = zeros(G), zeros(G)
    storage = union(get(inputs, "STOR_ALL", Int[]), get(inputs, "VS_STOR", Int[]))
    for y in storage
        resource = inputs["RESOURCES"][y]
        for (column, target) in ((:charge_cost_per_mwh, charge), (:discharge_cost_per_mwh, discharge))
            haskey(resource, column) || error("Storage resource $(resource_name(resource)) requires column $column in Storage.csv / Vre_stor.csv. Set it to 0 to disable this side of the throughput fee.")
            target[y] = validated_storage_throughput_price(get(resource, column, missing), "$(resource_name(resource)): $column")
        end
    end
    return charge, discharge
end
