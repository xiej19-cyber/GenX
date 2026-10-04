@doc raw"""
	write_virtual_discharge(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)

Function for writing the "virtual" discharge of each storage technology. Virtual discharge is used to
	allow storage resources to contribute to the capacity reserve margin without actually discharging.
"""
function write_virtual_discharge_peakload(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    STOR_ALL = inputs["STOR_ALL"]
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    NCRM = inputs["NCapacityReserveMargin"]
    resources = inputs["RESOURCE_NAMES"][STOR_ALL]
    zones = inputs["R_ZONES"][STOR_ALL]
    gen = inputs["RESOURCES"]
    df = DataFrame(Resource = resources, Zone = zones)

    for res in 1:NCRM
        peak_hour = inputs["peak_hour_idx"][res]

        vdis = [
            derating_factor(gen[y], tag=res) * value(EP[:eTotalCap][y]) *
            peakload_external_delivery_fraction(EP, res, zone_id(gen[y])) * scale_factor
            for y in STOR_ALL
        ]

        df[!, Symbol("CRM_$res")] = vdis
        df[!, Symbol("PeakHour_$res")] = fill(peak_hour, length(STOR_ALL))
    end

    CSV.write(joinpath(path, "virtual_discharge_peakload.csv"), df)
    return nothing
end
