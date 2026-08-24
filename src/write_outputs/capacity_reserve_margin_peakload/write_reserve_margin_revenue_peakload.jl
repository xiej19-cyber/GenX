@doc raw"""
	write_reserve_margin_revenue(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)

Function for reporting the capacity revenue earned by each generator listed in the input file.
    GenX will print this file only when capacity reserve margin is modeled and the shadow price can be obtained form the solver.
    Each row corresponds to a generator, and each column starting from the 6th to the second last is the total revenue from each capacity reserve margin constraint.
    The revenue is calculated as the capacity contribution of each time steps multiplied by the shadow price, and then the sum is taken over all modeled time steps.
    The last column is the total revenue received from all capacity reserve margin constraints.
    As a reminder, GenX models the capacity reserve margin (aka capacity market) at the time-dependent level, and each constraint either stands for an overall market or a locality constraint.

"""
function write_reserve_margin_revenue_peakload(
    path::AbstractString,
    inputs::Dict,
    setup::Dict,
    EP::Model
)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    gen = inputs["RESOURCES"]
    zones = zone_id.(gen)
    regions = region.(gen)
    clusters = cluster.(gen)

    G = inputs["G"]
    THERM_ALL = inputs["THERM_ALL"]
    VRE = inputs["VRE"]
    HYDRO_RES = inputs["HYDRO_RES"]
    STOR_ALL = inputs["STOR_ALL"]
    FLEX = inputs["FLEX"]
    MUST_RUN = inputs["MUST_RUN"]
    VRE_STOR = inputs["VRE_STOR"]

    # resource capacity
    eTotalCap = value.(EP[:eTotalCap])

    dfResRevenue_peakload = DataFrame(
        Region  = regions,
        Resource = inputs["RESOURCE_NAMES"],
        Zone     = zones,
        Cluster  = clusters,
    )

    annual_sum = zeros(G)

    # ========== CRM by reserve slice (single-hour peakload) ==========
    for i in 1:inputs["NCapacityReserveMargin"]

        # --- capacity reserve price in the peak hour ---
        price = capacity_reserve_margin_price_peakload(EP, inputs, setup, i)

        # --- prepare container ---
        rev = zeros(G)

        # --- derating function ---
        crm_derate(y) = derating_factor(gen[y], tag=i)

        # -------- THERMAL --------
        rev[THERM_ALL] =
            [ thermal_plant_effective_capacity_peakload(EP, inputs, y, i)
              for y in THERM_ALL ] .* price

        # -------- VRE ----------
        rev[VRE] = [crm_derate(y) * eTotalCap[y] * price for y in VRE]

        # -------- MUST RUN ----------
        rev[MUST_RUN] = [crm_derate(y) * eTotalCap[y] * price for y in MUST_RUN]

        # -------- HYDRO ----------
        rev[HYDRO_RES] = [crm_derate(y) * eTotalCap[y] * price for y in HYDRO_RES]

        # -------- STORAGE ----------
        if !isempty(STOR_ALL)
            rev[STOR_ALL] = [crm_derate(y) * eTotalCap[y] * price for y in STOR_ALL]
        end

        # -------- FLEX ----------
        if !isempty(FLEX)
            rev[FLEX] = [crm_derate(y) * eTotalCap[y] * price for y in FLEX]
        end

        # -------- VRE-STORAGE ----------
        if !isempty(VRE_STOR)
            rev[VRE_STOR] = [
                vre_stor_effective_capacity_peakload(EP, y, i) * price
                for y in VRE_STOR]
        end

        # accumulate
        rev .*= scale_factor
        annual_sum .+= rev
        dfResRevenue_peakload[!, Symbol("CapRes_$i")] = rev
    end

    dfResRevenue_peakload.AnnualSum = annual_sum

    CSV.write(joinpath(path, "ReserveMarginRevenue_peakload.csv"), dfResRevenue_peakload)
    return dfResRevenue_peakload
    
end
