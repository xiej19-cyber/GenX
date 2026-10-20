"""Return one resource's selected-hour contribution before delivery limits."""
function multihours_resource_capacity_contribution(EP::Model, inputs::Dict,
        y::Int, res::Int, t::Int)
    gen = inputs["RESOURCES"]
    contribution = derating_factor(gen[y], tag=res) * EP[:eTotalCap][y]
    if y in inputs["THERM_ALL"]
        committed = get(inputs, "THERM_COMMIT", Int[])
        if y in intersect(ids_with_maintenance(gen), committed)
            contribution += thermal_maintenance_capacity_reserve_margin_multihours_adjustment(
                EP, inputs, y, res, t)
        end
        if y in intersect(ids_with(gen, fusion), committed)
            contribution += fusion_capacity_reserve_margin_adjustment(
                EP, inputs, resource_name(gen[y]), y, res, t)
        end
    end
    return contribution
end

"""Cap external dedicated capacity by its signed delivered flow in each selected hour.
Lines with nonzero DerateCapRes retain the separate transmission-flow accounting.
Zero line derating and nonzero participation select dedicated-generation accounting,
matching peakload without crediting the same corridor twice.
"""
function add_multihours_external_resource_flow_limits!(EP::Model, inputs::Dict)
    gen = inputs["RESOURCES"]
    participation = inputs["dfTransCapResMulti_excl"]
    derating = inputs["dfDerateTransCapResMulti"]
    start_zone = inputs["pTrans_Start_Zone"]
    end_zone = inputs["pTrans_End_Zone"]
    resource_sets = ("THERM_ALL", "VRE", "HYDRO_RES", "STOR_ALL", "FLEX", "MUST_RUN")
    eligible = unique(vcat((get(inputs, key, Int[]) for key in resource_sets)...))
    credits = Dict{Tuple{Int, Int, Int}, VariableRef}()
    raw = Dict{Tuple{Int, Int, Int}, Any}()
    flows = Dict{Tuple{Int, Int, Int}, Any}()
    for res in 1:inputs["NCapacityReserveMargin"]
        zones = findall(!iszero, inputs["dfCapRes"][:, res])
        for z in setdiff(1:inputs["Z"], zones)
            resources = [y for y in eligible if zone_id(gen[y]) == z &&
                         !iszero(derating_factor(gen[y], tag=res))]
            isempty(resources) && continue
            lines = [l for l in 1:inputs["L"] if iszero(derating[l, res]) &&
                     !iszero(participation[l, res]) &&
                     ((start_zone[l] == z && end_zone[l] in zones) ||
                      (end_zone[l] == z && start_zone[l] in zones))]
            isempty(lines) && @warn("External resources in zone $z assigned to CapRes_$res have no connecting dedicated CRM line; their selected-hour credit is zero.")
            for t in inputs["selected_capres_multihours"][res]
                key = (res, z, t)
                raw[key] = @expression(EP, sum(multihours_resource_capacity_contribution(
                    EP, inputs, y, res, t) for y in resources))
                flows[key] = @expression(EP, sum(-participation[l, res] *
                    EP[:vFLOW][l, t] for l in lines))
                credits[key] = @variable(EP, lower_bound=0,
                    base_name="vMultiPairedCapCredit_$(res)_$(z)_$(t)")
                @constraint(EP, credits[key] <= raw[key])
                @constraint(EP, credits[key] <= flows[key])
                add_to_expression!(EP[:eCapResMarBalanceMultihour][res, t], -1.0, raw[key])
                add_to_expression!(EP[:eCapResMarBalanceMultihour][res, t], credits[key])
            end
        end
    end
    EP[:vMultiPairedCapCredit] = credits
    EP[:eMultiPairedRawCapacity] = raw
    EP[:eMultiPairedFlow] = flows
    return nothing
end

@doc raw"""
	cap_reserve_margin_multihours!(EP::Model, inputs::Dict, setup::Dict)
This module implements capacity reserve margin constraints only on user-specified selected hours/timesteps. It operates similarly to the peakload-only constraint,
but allows multiple critical timesteps to be defined for each zone and reserve requirement.
Constraints are only applied to the exogenously specified t indices, not all timesteps or a single peak hour.
"""
function cap_reserve_margin_multihours!(EP::Model, inputs::Dict, setup::Dict)

    NCRM = inputs["NCapacityReserveMargin"]
    selected_hours = inputs["selected_capres_multihours"]  
    println("Capacity Reserve Margin - Selected Critical Hours Module")

    if get(inputs, "Z", 1) > 1
        add_multihours_external_resource_flow_limits!(EP, inputs)
    end

    if haskey(inputs, "dfCapRes_slack")
        @variable(EP, vCapResSlack[res=1:NCRM, t in selected_hours[res]] >= 0)
        for res in 1:NCRM
            for t in selected_hours[res]
                add_to_expression!(EP[:eCapResMarBalanceMultihour][res, t], EP[:vCapResSlack][res,t])
            end
        end

        @expression(EP,eCapResSlack_Year[res=1:NCRM],
            sum(EP[:vCapResSlack][res,t] * inputs["omega"][t]
                for t in selected_hours[res]
            ))

        @expression(EP, eCCapResSlack[res=1:NCRM],
            inputs["dfCapRes_slack"][res, :PriceCap] * EP[:eCapResSlack_Year][res])

        @expression(EP, eCTotalCapResSlack, sum(EP[:eCCapResSlack][res] for res in 1:NCRM))
        
        add_to_expression!(EP[:eObj], eCTotalCapResSlack)
    end

    @constraint(EP, cCapacityResMarginMultihour[res=1:NCRM, t in selected_hours[res]],
        EP[:eCapResMarBalanceMultihour][res, t]
        >= sum(
            inputs["pD"][t, z] * (1 + inputs["dfCapRes"][z, res])
            for z in findall(!iszero, inputs["dfCapRes"][:, res])
        )
    )
end