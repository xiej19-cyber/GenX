function write_reserve_margin_w_multihours(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    NCRM = inputs["NCapacityReserveMargin"]
    selected_hours = inputs["selected_capres_multihours"]
    all_ts = sort(unique(reduce(vcat, values(selected_hours))))
    df = DataFrame(Hour=all_ts)

    for res in 1:NCRM
        w_vals = zeros(length(all_ts))
        ts_list = selected_hours[res]
        for (i, t) in enumerate(all_ts)
            if t in ts_list
                w_vals[i] = capacity_reserve_margin_price_multihours(
                    EP, setup, res, t) / inputs["omega"][t]
            end
        end
        df[!, Symbol("CapResMulti_$res")] = w_vals
    end

    CSV.write(joinpath(path, "ReserveMargin_w_multihours.csv"), df)
end
