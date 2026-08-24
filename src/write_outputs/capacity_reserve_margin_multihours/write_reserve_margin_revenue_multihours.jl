function write_reserve_margin_revenue_multihours(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    gen = inputs["RESOURCES"]
    G = inputs["G"]
    selected_hours = inputs["selected_capres_multihours"]
    NCRM = inputs["NCapacityReserveMargin"]
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    THERM_ALL = inputs["THERM_ALL"]
    STATIC_CAPACITY_RESOURCES = union(inputs["VRE"],
        inputs["HYDRO_RES"], inputs["STOR_ALL"], inputs["MUST_RUN"], inputs["FLEX"])
    VRE_STOR = inputs["VRE_STOR"]

    eTotalCap = value.(EP[:eTotalCap])
    df = DataFrame(
        Region=region.(gen),
        Resource=inputs["RESOURCE_NAMES"],
        Zone=zone_id.(gen),
        Cluster=cluster.(gen)
    )
    annual_sum = zeros(G)

    for res in 1:NCRM
        ts_list = selected_hours[res]
        isempty(ts_list) && continue
        revenue = zeros(G)

        for t in ts_list
            price = capacity_reserve_margin_price_multihours(EP, setup, res, t)
            for y in 1:G
                if y in THERM_ALL
                    cap = thermal_plant_effective_capacity_multihours(EP, inputs, y, res, t)
                elseif y in STATIC_CAPACITY_RESOURCES
                    cap = derating_factor(gen[y], tag=res) * eTotalCap[y]
                elseif y in VRE_STOR
                    cap = vre_stor_effective_capacity_multihours(EP, y, res, t)
                else
                    cap = 0.0
                end
                revenue[y] += cap * price * scale_factor
            end
        end

        df[!, Symbol("CapResMulti_$res")] = revenue
        annual_sum .+= revenue
    end

    df[!, :AnnualSum] = annual_sum
    CSV.write(joinpath(path, "ReserveMarginRevenue_multihours.csv"), df)
    return df
end
