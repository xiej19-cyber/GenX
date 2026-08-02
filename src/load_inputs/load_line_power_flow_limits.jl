const LINE_POWER_PROFILE_COLUMN = "Line_Power_Profile_ID"
const LINE_POWER_PROFILE_NONE = "None"
const LINE_POWER_PROFILE_FILENAME = "Line_power_flow_limits.csv"
const LINE_POWER_PROFILE_SLACK_FILENAME = "Line_power_flow_limits_slack.csv"

function validate_line_power_profile_name(profile_id::AbstractString)
    isempty(profile_id) && error("Line power profile IDs cannot be empty.")
    strip(profile_id) == profile_id ||
        error("Line power profile ID '$profile_id' has leading or trailing whitespace.")
    any(iscntrl, profile_id) &&
        error("Line power profile ID '$profile_id' contains a control character.")
    return nothing
end

function network_line_rows_and_ids(network_var::DataFrame)
    "Network_Lines" in names(network_var) ||
        error("Network.csv must contain the Network_Lines column.")
    line_rows = findall(!ismissing, network_var[!, :Network_Lines])
    line_ids = Int[]
    for row in line_rows
        value = network_var[row, :Network_Lines]
        value isa Real && isfinite(value) && isinteger(value) ||
            error("Network_Lines must contain finite integer values; found '$value' on row $row.")
        push!(line_ids, Int(value))
    end
    allunique(line_ids) || error("Network_Lines values must be unique.")
    return line_rows, line_ids
end

function validated_profile_values(df::DataFrame, column::String)
    values = df[!, column]
    any(ismissing, values) &&
        error("Line power profile column '$column' contains missing values.")
    all(x -> x isa Real && isfinite(x), values) ||
        error("Line power profile column '$column' must contain only finite numeric values.")
    return Float64.(values)
end

function validate_line_power_time_index(df::DataFrame, expected_length::Int)
    "Time_Index" in names(df) ||
        error("$LINE_POWER_PROFILE_FILENAME must contain a Time_Index column.")
    values = df[!, :Time_Index]
    any(ismissing, values) &&
        error("Time_Index in $LINE_POWER_PROFILE_FILENAME contains missing values.")
    length(values) == expected_length ||
        error("$LINE_POWER_PROFILE_FILENAME has $(length(values)) rows, but the active demand time basis has $expected_length rows.")
    all(x -> x isa Real && isfinite(x) && isinteger(x), values) ||
        error("Time_Index in $LINE_POWER_PROFILE_FILENAME must contain finite integers.")
    Int.(values) == collect(1:expected_length) ||
        error("Time_Index in $LINE_POWER_PROFILE_FILENAME must be unique and exactly equal to 1:$expected_length.")
    return nothing
end

function validate_line_power_profile_dataframe(
        df::DataFrame,
        profile_names::Vector{String},
        expected_length::Int)
    validate_line_power_time_index(df, expected_length)

    expected_columns = Set(["Time_Index"])
    for profile in profile_names
        push!(expected_columns, string(profile, "_up"))
        push!(expected_columns, string(profile, "_down"))
    end
    actual_columns = Set(names(df))
    missing_columns = sort(collect(setdiff(expected_columns, actual_columns)))
    isempty(missing_columns) ||
        error("$LINE_POWER_PROFILE_FILENAME is missing required columns $missing_columns.")
    extra_columns = sort(collect(setdiff(actual_columns, expected_columns)))
    isempty(extra_columns) ||
        error("$LINE_POWER_PROFILE_FILENAME contains columns not referenced by Network.csv: $extra_columns.")

    P = length(profile_names)
    down = Matrix{Float64}(undef, expected_length, P)
    up = Matrix{Float64}(undef, expected_length, P)
    for (p, profile) in enumerate(profile_names)
        down[:, p] = validated_profile_values(df, string(profile, "_down"))
        up[:, p] = validated_profile_values(df, string(profile, "_up"))
    end
    all(down .>= -1) && all(up .<= 1) && all(down .<= up) ||
        error("Line power profile values must satisfy -1 <= down <= up <= 1 at every time step.")
    return down, up
end

function load_line_power_flow_limit_slack!(
        setup::Dict,
        policies_path::AbstractString,
        inputs::Dict)
    slack_path = joinpath(policies_path, LINE_POWER_PROFILE_SLACK_FILENAME)
    isfile(slack_path) || return nothing

    ensure_unique_csv_columns(slack_path)
    df = load_dataframe(slack_path)
    required_columns = [
        "Network_Lines",
        "LowerBound_PriceCap",
        "UpperBound_PriceCap",
    ]
    Set(names(df)) == Set(required_columns) ||
        error("$LINE_POWER_PROFILE_SLACK_FILENAME must contain exactly $(required_columns).")

    line_values = df[!, :Network_Lines]
    any(ismissing, line_values) &&
        error("$LINE_POWER_PROFILE_SLACK_FILENAME contains a missing Network_Lines value.")
    all(x -> x isa Real && isfinite(x) && isinteger(x), line_values) ||
        error("Network_Lines in $LINE_POWER_PROFILE_SLACK_FILENAME must be finite integers.")
    slack_line_ids = Int.(line_values)
    allunique(slack_line_ids) ||
        error("Network_Lines in $LINE_POWER_PROFILE_SLACK_FILENAME must be unique.")

    expected_line_ids = inputs["LINE_POWER_LIMIT_LINE_IDS"]
    Set(slack_line_ids) == Set(expected_line_ids) ||
        error("$LINE_POWER_PROFILE_SLACK_FILENAME must cover exactly the constrained Network_Lines $(sort(expected_line_ids)).")

    down_prices = validated_profile_values(df, "LowerBound_PriceCap")
    up_prices = validated_profile_values(df, "UpperBound_PriceCap")
    all(>(0), down_prices) ||
        error("LowerBound_PriceCap values must be positive.")
    all(>(0), up_prices) ||
        error("UpperBound_PriceCap values must be positive.")

    row_by_line_id = Dict(line_id => row for (row, line_id) in enumerate(slack_line_ids))
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    inputs["pLinePowerDownPrice"] =
        [down_prices[row_by_line_id[line_id]] / scale_factor for line_id in expected_line_ids]
    inputs["pLinePowerUpPrice"] =
        [up_prices[row_by_line_id[line_id]] / scale_factor for line_id in expected_line_ids]
    return nothing
end

function validate_line_power_direction_compatibility!(
        setup::Dict,
        inputs::Dict)
    setup["PowerFlowDirectionRequirement"] == 1 || return nothing
    directions = inputs["Direction_Multiplier"]
    lines = inputs["LINE_POWER_LIMIT_LINES"]
    profile_by_line = inputs["LinePowerProfileIndexByLine"]
    down = inputs["pLinePowerProfileDown"]
    up = inputs["pLinePowerProfileUp"]
    line_ids = inputs["LINE_POWER_LIMIT_LINE_IDS"]

    for b in eachindex(lines)
        line = lines[b]
        profile = profile_by_line[b]
        if directions[line] == 1 && any(<(0), up[:, profile])
            error("Line power profile for Network_Lines=$(line_ids[b]) requires negative flow while DirectionReq=1.")
        elseif directions[line] == -1 && any(>(0), down[:, profile])
            error("Line power profile for Network_Lines=$(line_ids[b]) requires positive flow while DirectionReq=-1.")
        end
    end

    if setup["LineMinCF"] == 1
        affected = [
            line_ids[b] for b in eachindex(lines)
            if inputs["LineMinCF"][lines[b]] != 0
        ]
        isempty(affected) ||
            @warn "LineMinCF and LinePowerFlowLimits both apply to Network_Lines=$(affected); both constraints will be enforced."
    end
    return nothing
end

"""
    load_line_power_flow_limits!(setup, case_path, inputs, network_var)

Load reusable per-unit line-flow profiles, line-to-profile mappings, and
optional line-specific violation prices.
"""
function load_line_power_flow_limits!(
        setup::Dict,
        case_path::AbstractString,
        inputs::Dict,
        network_var::DataFrame)
    LINE_POWER_PROFILE_COLUMN in names(network_var) ||
        error("LinePowerFlowLimits=1 requires column '$LINE_POWER_PROFILE_COLUMN' in Network.csv.")

    line_rows, line_ids = network_line_rows_and_ids(network_var)
    length(line_rows) == inputs["L"] ||
        error("The number of non-missing Network_Lines rows does not match the model line count.")

    constrained_lines = Int[]
    constrained_line_ids = Int[]
    constrained_network_rows = Int[]
    profile_for_constrained_line = String[]

    for (line, row) in enumerate(line_rows)
        raw_profile = network_var[row, LINE_POWER_PROFILE_COLUMN]
        ismissing(raw_profile) &&
            error("Line_Power_Profile_ID is missing for Network_Lines=$(line_ids[line]); use None for an unconstrained line.")
        raw_profile isa AbstractString ||
            error("Line_Power_Profile_ID for Network_Lines=$(line_ids[line]) must be text.")
        profile_id = String(raw_profile)
        validate_line_power_profile_name(profile_id)
        if profile_id != LINE_POWER_PROFILE_NONE
            push!(constrained_lines, line)
            push!(constrained_line_ids, line_ids[line])
            push!(constrained_network_rows, row)
            push!(profile_for_constrained_line, profile_id)
        end
    end

    profile_names = sort(unique(profile_for_constrained_line))
    isempty(profile_names) &&
        error("LinePowerFlowLimits=1 requires at least one line with a profile other than None.")
    profile_index_by_name =
        Dict(profile => index for (index, profile) in enumerate(profile_names))

    tdr_path = joinpath(case_path, setup["TimeDomainReductionFolder"])
    profile_dir = get_systemfiles_path(setup, tdr_path, case_path)
    profile_path = joinpath(profile_dir, LINE_POWER_PROFILE_FILENAME)
    ensure_unique_csv_columns(profile_path)
    df = load_dataframe(profile_path)
    down, up =
        validate_line_power_profile_dataframe(df, profile_names, inputs["T"])

    inputs["LINE_POWER_LIMIT_LINES"] = constrained_lines
    inputs["LINE_POWER_LIMIT_LINE_IDS"] = constrained_line_ids
    inputs["LINE_POWER_LIMIT_NETWORK_ROWS"] = constrained_network_rows
    inputs["LINE_POWER_LIMIT_PROFILE_NAMES"] = profile_names
    inputs["LinePowerProfileIndexByName"] = profile_index_by_name
    inputs["LinePowerProfileIndexByLine"] =
        [profile_index_by_name[profile] for profile in profile_for_constrained_line]
    inputs["pLinePowerProfileDown"] = down
    inputs["pLinePowerProfileUp"] = up

    load_line_power_flow_limit_slack!(
        setup,
        joinpath(case_path, setup["PoliciesFolder"]),
        inputs,
    )
    validate_line_power_direction_compatibility!(setup, inputs)
    println("$LINE_POWER_PROFILE_FILENAME Successfully Read!")
    return nothing
end
