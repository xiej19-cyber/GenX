function write_rsv(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    T = inputs["T"]     # Number of time steps (hours)
    RSV = inputs["RSV"]
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    resources = inputs["RESOURCE_NAMES"][RSV]
    zones = inputs["R_ZONES"][RSV]
    rsv = value.(EP[:vRSV][RSV, :].data) * scale_factor

    dfRsv = DataFrame(Resource = resources, Zone = zones)

    dfRsv.AnnualSum = rsv * inputs["omega"]

    if setup["WriteOutputs"] == "annual"
        write_annual(joinpath(path, "reserves.csv"), dfRsv)
    else # setup["WriteOutputs"] == "full"
        unmet_values = Array(value.(EP[:vUNMET_RSV])) * scale_factor
        if setup["OperationalReserves"] == 2
            unmet_matrix = unmet_values
            unmet_zones = inputs["OPERATIONAL_RESERVE_REGIONS"]
            label = inputs["OPERATIONAL_RESERVE_CUSTOM_REGIONS"] ? "region" : "z"
            unmet_names = ["unmet_$(label)$z" for z in unmet_zones]
        else
            unmet_matrix = reshape(unmet_values, 1, :)
            unmet_zones = [0]
            unmet_names = ["unmet"]
        end
        dfRsv = hcat(dfRsv, DataFrame(rsv, :auto))
        auxNew_Names = [Symbol("Resource");
                        Symbol("Zone");
                        Symbol("AnnualSum");
                        [Symbol("t$t") for t in 1:T]]
        rename!(dfRsv, auxNew_Names)

        total = DataFrame(["Total" 0 sum(dfRsv.AnnualSum) zeros(1, T)], :auto)
        unmet = DataFrame(Resource = unmet_names,
            Zone = unmet_zones,
            AnnualSum = unmet_matrix * inputs["omega"])
        unmet = hcat(unmet, DataFrame(unmet_matrix, :auto))
        total[!, 4:(T + 3)] .= sum(rsv, dims = 1)
        rename!(total, auxNew_Names)
        rename!(unmet, auxNew_Names)
        dfRsv = vcat(dfRsv, unmet, total)
        CSV.write(joinpath(path, "reserves.csv"),
            dftranspose(dfRsv, false),
            writeheader = false)
    end
end
