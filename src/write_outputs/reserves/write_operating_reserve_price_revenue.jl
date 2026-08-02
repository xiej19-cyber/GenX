@doc raw"""
	write_operating_reserve_regulation_revenue(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)

Function for reporting the operating reserve and regulation revenue earned by generators listed in the input file.
    GenX will print this file only when operating reserve and regulation are modeled and the shadow price can be obtained from the solver.
    The revenues are calculated as the operating reserve and regulation contributions in each time step multiplied by the corresponding shadow price, and then the sum is taken over all modeled time steps.
    The last column is the total revenue received from all operating reserve and regulation constraints.
    As a reminder, GenX models the operating reserve and regulation at the time-dependent level, and each constraint either stands for an overall market or a locality constraint.
"""
function write_operating_reserve_regulation_revenue(path::AbstractString,
        inputs::Dict,
        setup::Dict,
        EP::Model)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    gen = inputs["RESOURCES"]
    RSV = inputs["RSV"]
    REG = inputs["REG"]

    regions = region.(gen)
    clusters = cluster.(gen)
    zones = zone_id.(gen)
    names = inputs["RESOURCE_NAMES"]

    dfOpRsvRevenue = DataFrame(Region = regions[RSV],
        Resource = names[RSV],
        Zone = zones[RSV],
        Cluster = clusters[RSV],
        AnnualSum = Array{Float64}(undef, length(RSV)))
    dfOpRegRevenue = DataFrame(Region = regions[REG],
        Resource = names[REG],
        Zone = zones[REG],
        Cluster = clusters[REG],
        AnnualSum = Array{Float64}(undef, length(REG)))

    weighted_reg_price = operating_regulation_price(EP, inputs, setup)
    weighted_rsv_price = operating_reserve_price(EP, inputs, setup)

    if setup["OperationalReserves"] == 2
        if inputs["OPERATIONAL_RESERVE_CUSTOM_REGIONS"]
            resource_region = inputs["OPERATIONAL_RESERVE_RESOURCE_REGION"]
            region_zones = inputs["OPERATIONAL_RESERVE_REGION_ZONES"]
            rsv_resource_price = copy(weighted_rsv_price[resource_region[RSV], :])
            reg_resource_price = copy(weighted_reg_price[resource_region[REG], :])
            if !isempty(inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"])
                keys = inputs["OPERATIONAL_RESERVE_SUPPLY_KEYS"]
                rsv_supply_price = -Array(dual.(EP[:cRsvTransferSupply])) ./
                                   transpose(inputs["omega"]) .* scale_factor
                reg_supply_price = -Array(dual.(EP[:cRegTransferSupply])) ./
                                   transpose(inputs["omega"]) .* scale_factor
                for (row, y) in enumerate(RSV)
                    r = resource_region[y]
                    if zone_id(gen[y]) ∉ region_zones[r]
                        key_row = findfirst(==((zone_id(gen[y]), r)), keys)
                        rsv_resource_price[row, :] .= rsv_supply_price[key_row, :]
                    end
                end
                for (row, y) in enumerate(REG)
                    r = resource_region[y]
                    if zone_id(gen[y]) ∉ region_zones[r]
                        key_row = findfirst(==((zone_id(gen[y]), r)), keys)
                        reg_resource_price[row, :] .= reg_supply_price[key_row, :]
                    end
                end
            end
            rsvrevenue = value.(EP[:vRSV][RSV, :].data) .* rsv_resource_price
            regrevenue = value.(EP[:vREG][REG, :].data) .* reg_resource_price
        else
            rsvrevenue = value.(EP[:vRSV][RSV, :].data) .*
                         weighted_rsv_price[zones[RSV], :]
            regrevenue = value.(EP[:vREG][REG, :].data) .*
                         weighted_reg_price[zones[REG], :]
        end
    else
        rsvrevenue = value.(EP[:vRSV][RSV, :].data) .* transpose(weighted_rsv_price)
        regrevenue = value.(EP[:vREG][REG, :].data) .* transpose(weighted_reg_price)
    end

    rsvrevenue *= scale_factor
    regrevenue *= scale_factor

    dfOpRsvRevenue.AnnualSum .= rsvrevenue * inputs["omega"]
    dfOpRegRevenue.AnnualSum .= regrevenue * inputs["omega"]

    write_simple_csv(joinpath(path, "OperatingReserveRevenue.csv"), dfOpRsvRevenue)
    write_simple_csv(joinpath(path, "OperatingRegulationRevenue.csv"), dfOpRegRevenue)
    return dfOpRegRevenue, dfOpRsvRevenue
end

@doc raw"""
    operating_regulation_price(EP::Model,
                                  inputs::Dict,
                                  setup::Dict)::Vector{Float64}

Operating regulation price for each time step.
This is equal to the dual variable of the regulation requirement constraint.

    Returns a time vector in system-wide mode or a zone-by-time matrix in zonal mode,
    with units of USD/MW.
"""

function operating_regulation_price(EP::Model, inputs::Dict, setup::Dict)
    ω = inputs["omega"]
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    requirement_constraint = haskey(EP, :cRegVreStor) ? EP[:cRegVreStor] : EP[:cReg]
    prices = Array(dual.(requirement_constraint))
    if setup["OperationalReserves"] == 2
        if inputs["OPERATIONAL_RESERVE_CUSTOM_REGIONS"]
            return prices ./ transpose(ω) .* scale_factor
        end
        zonal_prices = zeros(inputs["Z"], length(ω))
        zonal_prices[inputs["OPERATIONAL_RESERVE_REGIONS"], :] .=
            prices ./ transpose(ω) .* scale_factor
        if !isempty(inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"])
            supply_zones = unique(inputs["pTrans_Start_Zone"][
                inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"]])
            zonal_prices[supply_zones, :] .=
                -Array(dual.(EP[:cRegTransferSupply])) ./ transpose(ω) .* scale_factor
        end
        return zonal_prices
    end
    return prices ./ ω .* scale_factor
end

@doc raw"""
    operating_reserve_price(EP::Model,
                                  inputs::Dict,
                                  setup::Dict)::Vector{Float64}

Operating reserve price for each time step.
This is equal to the dual variable of the reserve requirement constraint.

    Returns a time vector in system-wide mode or a zone-by-time matrix in zonal mode,
    with units of USD/MW.
"""

function operating_reserve_price(EP::Model, inputs::Dict, setup::Dict)
    ω = inputs["omega"]
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    requirement_constraint = haskey(EP, :cRsvReqVreStor) ? EP[:cRsvReqVreStor] :
                             EP[:cRsvReq]
    prices = Array(dual.(requirement_constraint))
    if setup["OperationalReserves"] == 2
        if inputs["OPERATIONAL_RESERVE_CUSTOM_REGIONS"]
            return prices ./ transpose(ω) .* scale_factor
        end
        zonal_prices = zeros(inputs["Z"], length(ω))
        zonal_prices[inputs["OPERATIONAL_RESERVE_REGIONS"], :] .=
            prices ./ transpose(ω) .* scale_factor
        if !isempty(inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"])
            supply_zones = unique(inputs["pTrans_Start_Zone"][
                inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"]])
            zonal_prices[supply_zones, :] .=
                -Array(dual.(EP[:cRsvTransferSupply])) ./ transpose(ω) .* scale_factor
        end
        return zonal_prices
    end
    return prices ./ ω .* scale_factor
end
