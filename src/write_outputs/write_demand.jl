@doc raw"""
	write_demand(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)

Function for writing the zonal and total demand.
"""
function write_demand(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)
    T = inputs["T"]     # Number of time steps (hours)
    Z = inputs["Z"]     # Number of zones

    dfDemandconsumption = DataFrame(Zone = 1:Z,
        AnnualSum = zeros(Z))
    demand = zeros(Z,T)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    demand = transpose(inputs["pD"] .- value.(EP[:ePowerBalanceNse])) * scale_factor

    dfDemandconsumption.AnnualSum .= demand * inputs["omega"]

    if setup["WriteOutputs"] == "annual"
        total = DataFrame(["Total" sum(dfDemandconsumption[!, :AnnualSum])],
            [:Zone, :AnnualSum])
        dfDemandconsumption = vcat(dfDemandconsumption, total)
        CSV.write(joinpath(path, "zonaldemand.csv"), dfDemandconsumption)
    else # setup["WriteOutputs"] == "full"
        dfDemandconsumption = hcat(dfDemandconsumption, DataFrame(demand, :auto))
        auxNew_Names = [Symbol("Zone");
                        Symbol("AnnualSum");
                        [Symbol("t$t") for t in 1:T]]
        rename!(dfDemandconsumption, auxNew_Names)

        total = DataFrame(["Total" sum(dfDemandconsumption[!, :AnnualSum]) fill(0.0, (1, T))], :auto)
        total[:, 3:(T + 2)] .= sum(demand, dims = 1)
        rename!(total, auxNew_Names)
        dfDemandconsumption = vcat(dfDemandconsumption, total)

        CSV.write(joinpath(path, "zonaldemand.csv"), dftranspose(dfDemandconsumption, false), writeheader = false)

        if setup["OutputFullTimeSeries"] == 1
            write_full_time_series_reconstruction(path, setup, dfDemandconsumption, "demand")
            @info("Writing Full Time Series for Demand")
        end
    end
    return nothing
end
