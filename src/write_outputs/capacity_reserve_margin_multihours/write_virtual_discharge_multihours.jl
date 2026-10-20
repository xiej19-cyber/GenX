function write_virtual_discharge_multihours(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    STOR_ALL = inputs["STOR_ALL"]
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    NCRM = inputs["NCapacityReserveMargin"]
    resources = inputs["RESOURCE_NAMES"][STOR_ALL]
    zones = inputs["R_ZONES"][STOR_ALL]
    gen = inputs["RESOURCES"]

    df = DataFrame(Resource = resources, Zone = zones)

    for res in 1:NCRM
        hours = inputs["selected_capres_multihours"][res]
        for t in hours
            virt = [derating_factor(gen[y], tag=res) * value(EP[:eTotalCap][y]) *
                    multihours_external_delivery_fraction(EP, res, zone_id(gen[y]), t) *
                    scale_factor for y in STOR_ALL]
            column = length(hours) == 1 ? Symbol("CapResMulti_$res") :
                     Symbol("CapResMulti_$(res)_t$(t)")
            df[!, column] = virt
        end
    end

    CSV.write(joinpath(path, "virtual_discharge_multihours.csv"), df)
    return nothing
end