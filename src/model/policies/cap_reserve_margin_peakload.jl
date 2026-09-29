
"""Return the peak-load CRM contribution currently credited to one resource."""
function peakload_resource_capacity_contribution(
        EP::Model, inputs::Dict, y::Int, capres::Int)
    gen = inputs["RESOURCES"]
    contribution = derating_factor(gen[y], tag = capres) * EP[:eTotalCap][y]

    if y in inputs["THERM_ALL"]
        t_peak = inputs["peak_hour_idx"][capres]
        if y in intersect(ids_with_maintenance(gen), inputs["THERM_COMMIT"])
            contribution += thermal_maintenance_capacity_reserve_margin_peakload_adjustment(
                EP, inputs, y, capres, t_peak)
        end
        if y in intersect(ids_with(gen, fusion), inputs["THERM_COMMIT"])
            contribution += fusion_capacity_reserve_margin_adjustment(
                EP, inputs, resource_name(gen[y]), y, capres, t_peak)
        end
    end
    return contribution
end

"""
    add_peakload_external_resource_flow_limits!(EP, inputs)

Replace the unconstrained peak-load CRM contribution of resources located outside a CRM
region with a deliverable contribution. For each external source zone, accredited
capacity is limited by both the resources' derated installed capacity and the signed
flow on connecting CRM lines in the CRM peak hour.

Lines with a nonzero transmission `DerateCapRes` continue to use the transmission-flow
method and are excluded from the dedicated-generation flow cap. The existing input
convention therefore still selects the accounting method by setting either the line or
resource derating factor to zero, without a separate mode setting.
"""
function add_peakload_external_resource_flow_limits!(EP::Model, inputs::Dict)
    NCRM = inputs["NCapacityReserveMargin"]
    Z = inputs["Z"]
    gen = inputs["RESOURCES"]
    participation = inputs["dfTransCapRes_exclPeak"]
    line_derating = inputs["dfDerateTransCapResPeak"]
    start_zone = inputs["pTrans_Start_Zone"]
    end_zone = inputs["pTrans_End_Zone"]
    peak_idx = inputs["peak_hour_idx"]

    resource_sets = ("THERM_ALL", "VRE", "HYDRO_RES", "STOR_ALL", "FLEX", "MUST_RUN")
    eligible_resources = unique(vcat((get(inputs, key, Int[]) for key in resource_sets)...))

    credits = Dict{Tuple{Int, Int}, VariableRef}()
    raw_capacity = Dict{Tuple{Int, Int}, Any}()
    peak_flow = Dict{Tuple{Int, Int}, Any}()

    for res in 1:NCRM
        crm_zones = findall(!iszero, inputs["dfCapRes"][:, res])
        for z in setdiff(1:Z, crm_zones)
            resources = [y for y in eligible_resources
                         if zone_id(gen[y]) == z &&
                            !iszero(derating_factor(gen[y], tag = res))]
            isempty(resources) && continue

            paired_lines = [l for l in 1:inputs["L"]
                            if iszero(line_derating[l, res]) &&
                               !iszero(participation[l, res]) &&
                               ((start_zone[l] == z && end_zone[l] in crm_zones) ||
                                (end_zone[l] == z && start_zone[l] in crm_zones))]
            isempty(paired_lines) && @warn(
                "External resources in zone $z are assigned to CapRes_$res, but no " *
                "connecting line with zero DerateCapRes_$res and nonzero " *
                "CapRes_Excl_$res was found; their peak-load CRM contribution is zero.")

            key = (res, z)
            raw_capacity[key] = @expression(EP,
                sum(peakload_resource_capacity_contribution(EP, inputs, y, res)
                    for y in resources))
            peak_flow[key] = @expression(EP,
                sum(-participation[l, res] * EP[:vFLOW][l, peak_idx[res]]
                    for l in paired_lines))
            credits[key] = @variable(EP, lower_bound = 0,
                base_name = "vPeakPairedCapCredit_$(res)_$(z)")

            @constraint(EP, credits[key] <= raw_capacity[key])
            @constraint(EP, credits[key] <= peak_flow[key])

            # Resource modules already added the full external resource contribution.
            # Replace it with the deliverable (minimum) contribution.
            add_to_expression!(EP[:eCapResMarBalancePeak][res], -1.0, raw_capacity[key])
            add_to_expression!(EP[:eCapResMarBalancePeak][res], credits[key])
        end
    end

    EP[:vPeakPairedCapCredit] = credits
    EP[:ePeakPairedRawCapacity] = raw_capacity
    EP[:ePeakPairedFlow] = peak_flow
    return nothing
end

function cap_reserve_margin_peakload!(EP::Model, inputs::Dict, setup::Dict)
    # capacity reserve margin constraint with peakload only
    NCRM = inputs["NCapacityReserveMargin"]
    peak_idx = inputs["peak_hour_idx"]
    println("Capacity Reserve Margin Policies with peakload only Module")

    if get(inputs, "Z", 1) > 1
        add_peakload_external_resource_flow_limits!(EP, inputs)
    end

    # if input files are present, add capacity reserve margin slack variables
    if haskey(inputs, "dfCapRes_slack")
        @variable(EP, vCapResSlack[res=1:NCRM] >= 0)
        for res in 1:NCRM
            add_to_expression!(EP[:eCapResMarBalancePeak][res], EP[:vCapResSlack][res])
        end 

        @expression(EP, 
        eCapResSlack_Year[res = 1:NCRM],
        EP[:vCapResSlack][res])

        @expression(EP,
            eCCapResSlack[res = 1:NCRM],
            inputs["dfCapRes_slack"][res, :PriceCap]*EP[:eCapResSlack_Year][res])

        @expression(EP, eCTotalCapResSlack,sum(EP[:eCCapResSlack][res] for res in 1:NCRM))
        add_to_expression!(EP[:eObj], eCTotalCapResSlack)
    end

        @constraint(EP,
                cCapacityResMargin[res = 1:NCRM],
                EP[:eCapResMarBalancePeak][res]
                >= sum(
                    inputs["pD"][peak_idx[res], z] * 
                    (1 + inputs["dfCapRes"][z, res])
                    for z in findall(!iszero, inputs["dfCapRes"][:, res])))
end
