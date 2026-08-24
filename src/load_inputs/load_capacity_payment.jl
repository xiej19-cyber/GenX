@doc raw"""
    load_capacity_payment!(setup::Dict, path::AbstractString, inputs::Dict)

Read the `capacity_sub_price` parameter from the resource CSV files. Values are annual
capacity payments in \$/MW-year. When `ParameterScale` is enabled, prices are converted
to \$M/GW-year for use in the model. The column must be present in at least one resource
file, and every supplied value must be finite; resources without the column receive zero.
"""
function load_capacity_payment!(setup::Dict, path::AbstractString, inputs::Dict)
    gen = inputs["RESOURCES"]
    G = inputs["G"]
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    if all(!haskey(resource, :capacity_sub_price) for resource in gen)
        error("CapacityPayment is enabled, but no capacity_sub_price column was found in the resource CSV files under $(path).")
    end

    cap_sub_price = Vector{Float64}(undef, G)
    for g in 1:G
        price = capacity_payment(gen[g])
        if ismissing(price) || !(price isa Real) || !isfinite(price)
            error("capacity_sub_price for resource $(resource_name(gen[g])) must be a finite number; found $(repr(price)).")
        end
        cap_sub_price[g] = Float64(price) / scale_factor
    end
    inputs["cap_sub_price"] = cap_sub_price

    println("Capacity payment Successfully Read from resources CSV!")
end
