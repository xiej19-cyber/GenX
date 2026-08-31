@doc raw"""
	load_cap_reserve_margin_peakload!(setup::Dict, path::AbstractString, inputs::Dict)

Read input parameters related to planning reserve margin constraints
"""
function load_cap_reserve_margin_peakload!(setup::Dict, path::AbstractString, inputs::Dict)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    filename = "CRM_peakload_slack.csv"
    if isfile(joinpath(path, filename))
        df = load_dataframe(joinpath(path, filename))
        :PriceCap in propertynames(df) ||
            error("$(filename) must contain a PriceCap column.")
        all(x -> x isa Real && isfinite(x) && x >= 0, df.PriceCap) ||
            error("PriceCap values in $(filename) must be finite, nonnegative numbers.")
        inputs["dfCapRes_slack"] = df
        inputs["dfCapRes_slack"][!, :PriceCap] ./= scale_factor # Million $/GW if scaled, $/MW if not scaled
    end

    filename = "CRM_peakload.csv"
    df = load_dataframe(joinpath(path, filename))

    mat = extract_matrix_from_dataframe(df, "CapRes")
    size(mat, 2) > 0 || error("$(filename) must contain at least one CapRes column.")
    all(x -> x isa Real && isfinite(x) && x >= 0, mat) ||
        error("CapRes values in $(filename) must be finite, nonnegative numbers.")
    inputs["dfCapRes"] = mat
    
    NCRM = size(mat,2)
    inputs["NCapacityReserveMargin"] = NCRM
    if haskey(inputs, "dfCapRes_slack") && nrow(inputs["dfCapRes_slack"]) != NCRM
        error("CRM_peakload_slack.csv must have one row per CRM constraint ($(NCRM) rows).")
    end

    T = inputs["T"]
    pD=inputs["pD"]

    peak_hour_idx = Vector{Int}(undef, NCRM)
    for res in 1:NCRM
        zones = findall(!iszero, inputs["dfCapRes"][:, res])
        isempty(zones) && error("CapRes_$(res) does not include any zone with a positive reserve margin.")
        total_load = [sum(pD[t, z] for z in zones) for t in 1:T]
        peak_hour_idx[res] = argmax(total_load)
    end

    inputs["peak_hour_idx"] = peak_hour_idx

    println(filename * " Successfully Read!")
end

@doc raw"""
	load_cap_reserve_margin_trans!(setup::Dict, inputs::Dict, network_var::DataFrame)

Read input parameters related to participation of transmission imports/exports in capacity reserve margin constraint.
"""
function load_cap_reserve_margin_peakload_trans!(setup::Dict, inputs::Dict, network_var::DataFrame)
    mat = extract_matrix_from_dataframe(network_var, "DerateCapRes")
    all(x -> x isa Real && isfinite(x) && 0 <= x <= 1, mat) ||
        error("Network DerateCapRes values for CRM_peakload must be finite values between 0 and 1.")
    inputs["dfDerateTransCapResPeak"] = mat

    mat = extract_matrix_from_dataframe(network_var, "CapRes_Excl")
    all(x -> x isa Real && isfinite(x) && abs(x) <= 1, mat) ||
        error("Network CapRes_Excl values for CRM_peakload must be finite values between -1 and 1.")
    inputs["dfTransCapRes_exclPeak"] = mat
end
