@doc raw"""
	load_cap_reserve_margin_multihours!(setup::Dict, path::AbstractString, inputs::Dict)

Read input parameters related to planning reserve margin constraints for exogenously selected hours
"""
function load_cap_reserve_margin_multihours!(setup::Dict, path::AbstractString, inputs::Dict)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    # Slack variables
    filename = "CRM_multihours_slack.csv"
    if isfile(joinpath(path, filename))
        df = load_dataframe(joinpath(path, filename))
        :PriceCap in propertynames(df) ||
            error("$(filename) must contain a PriceCap column.")
        all(x -> x isa Real && isfinite(x) && x >= 0, df.PriceCap) ||
            error("PriceCap values in $(filename) must be finite, nonnegative numbers.")
        inputs["dfCapRes_slack"] = df
        inputs["dfCapRes_slack"][!, :PriceCap] ./= scale_factor
    end

    # Core reserve margin requirements
    filename = "CRM_multihours.csv"
    df = load_dataframe(joinpath(path, filename))

    mat = extract_matrix_from_dataframe(df, "CapRes")
    size(mat, 2) > 0 || error("$(filename) must contain at least one CapRes column.")
    size(mat, 1) == inputs["Z"] ||
        error("$(filename) must have one row per model zone ($(inputs["Z"]) rows).")
    all(x -> x isa Real && isfinite(x) && x >= 0, mat) ||
        error("CapRes values in $(filename) must be finite, nonnegative numbers.")
    inputs["dfCapRes"] = mat

    NCRM = size(mat, 2)
    inputs["NCapacityReserveMargin"] = NCRM
    if haskey(inputs, "dfCapRes_slack") && nrow(inputs["dfCapRes_slack"]) != NCRM
        error("CRM_multihours_slack.csv must have one row per CRM constraint ($(NCRM) rows).")
    end
    for res in 1:NCRM
        all(iszero, mat[:, res]) &&
            error("CapRes_$(res) does not include any zone with a positive reserve margin.")
    end

    # #####################################
    # load t for each region
    # #####################################
    filename = "CRM_multihours_selected.csv"
    df_selected = load_dataframe(joinpath(path, filename))
    all(column -> column in propertynames(df_selected), [:CapRes, :t]) ||
        error("$(filename) must contain CapRes and t columns.")
    all(x -> x isa Real && isfinite(x) && isinteger(x), df_selected.CapRes) ||
        error("CapRes values in $(filename) must be integer CRM identifiers.")
    all(x -> x isa Real && isfinite(x) && isinteger(x), df_selected.t) ||
        error("t values in $(filename) must be integer timestep identifiers.")

    selected_hours = Dict{Int, Vector{Int}}()
    for res in 1:NCRM
        hours = Int.(df_selected[df_selected.CapRes .== res, :t])
        isempty(hours) && error("CRM constraint $(res) has no selected timestep in $(filename).")
        all(t -> 1 <= t <= inputs["T"], hours) ||
            error("Selected timesteps for CRM constraint $(res) must be between 1 and $(inputs["T"]).")
        length(hours) == length(unique(hours)) ||
            error("CRM constraint $(res) contains duplicate selected timesteps.")
        selected_hours[res] = sort(hours)
    end
    all(res -> 1 <= res <= NCRM, Int.(df_selected.CapRes)) ||
        error("$(filename) contains a CapRes identifier outside 1:$(NCRM).")
    inputs["selected_capres_multihours"] = selected_hours

    println(filename * " Successfully Read!")
end

@doc raw"""
	load_cap_reserve_margin_multihours_trans!(setup::Dict, inputs::Dict, network_var::DataFrame)

Read input parameters related to participation of transmission imports/exports in multihours capacity reserve margin constraint
"""
function load_cap_reserve_margin_multihours_trans!(setup::Dict, inputs::Dict, network_var::DataFrame)
    mat = extract_matrix_from_dataframe(network_var, "DerateCapRes")
    inputs["dfDerateTransCapResMulti"] = mat

    mat = extract_matrix_from_dataframe(network_var, "CapRes_Excl")
    inputs["dfTransCapResMulti_excl"] = mat
end
