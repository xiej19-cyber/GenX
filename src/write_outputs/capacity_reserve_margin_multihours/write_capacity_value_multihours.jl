function write_capacity_value_multihours(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    gen = inputs["RESOURCES"]
    G = inputs["G"]
    zones = zone_id.(gen)
    selected_hours = inputs["selected_capres_multihours"]
    NCRM = inputs["NCapacityReserveMargin"]

    THERM_ALL = inputs["THERM_ALL"]
    VRE = inputs["VRE"]
    HYDRO_RES = inputs["HYDRO_RES"]
    STOR_ALL = inputs["STOR_ALL"]
    FLEX = inputs["FLEX"]
    MUST_RUN = inputs["MUST_RUN"]
    VRE_STOR = inputs["VRE_STOR"]

    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    eTotalCap = value.(EP[:eTotalCap])

    df = DataFrame()
    all_times = sort(unique(reduce(vcat, [selected_hours[res] for res in 1:NCRM])))

    for res in 1:NCRM
        ts_list = selected_hours[res]
        capvalue = zeros(G, length(all_times))

        for (col_idx, t) in enumerate(all_times)
            if t in ts_list
                for y in THERM_ALL
                    capvalue[y, col_idx] = thermal_plant_effective_capacity_multihours(EP, inputs, y, res, t)
                end
                for y in VRE
                    capvalue[y, col_idx] = derating_factor(gen[y], tag=res) * eTotalCap[y]
                end
                for y in HYDRO_RES
                    capvalue[y, col_idx] = derating_factor(gen[y], tag=res) * eTotalCap[y]
                end
                for y in STOR_ALL
                    capvalue[y, col_idx] = derating_factor(gen[y], tag=res) * eTotalCap[y]
                end
                for y in MUST_RUN
                    capvalue[y, col_idx] = derating_factor(gen[y], tag=res) * eTotalCap[y]
                end
                for y in FLEX
                    capvalue[y, col_idx] = derating_factor(gen[y], tag=res) * eTotalCap[y]
                end
                for y in VRE_STOR
                    capvalue[y, col_idx] =
                        vre_stor_effective_capacity_multihours(EP, y, res, t)
                end
            end
        end

        capvalue .*= scale_factor

        temp_df = DataFrame(capvalue, :auto)
        rename!(temp_df, [Symbol("t$t") for t in all_times])

        temp_df = hcat(
            DataFrame(Resource=inputs["RESOURCE_NAMES"], Zone=zones, Reserve=fill("CapResMulti_$res", G)),
            temp_df
        )
        append!(df, temp_df) 
    end
    
    write_simple_csv(joinpath(path, "CapacityValue_multihours.csv"), df)
end
