@doc raw"""
	load_period_map!(setup::Dict, path::AbstractString, inputs::Dict)

Read input parameters related to mapping of representative time periods to full chronological time series
"""
function load_period_map!(setup::Dict, path::AbstractString, inputs::Dict)
    file_path = period_map_path(setup, path)
    isnothing(file_path) && error(
        "Period_map.csv was not found in the active system input directory.")
    inputs["Period_Map"] = load_dataframe(file_path)
    validate_period_map!(inputs["Period_Map"], inputs)
    inputs["Period_Map_Source"] = file_path

    println("Period_map.csv Successfully Read!")
end

"""Validate the chronological mapping used by inter-period storage constraints."""
function validate_period_map!(period_map::DataFrame, inputs::Dict)
    required_columns = [:Period_Index, :Rep_Period, :Rep_Period_Index]
    missing_columns = setdiff(required_columns, propertynames(period_map))
    isempty(missing_columns) || error(
        "Period_map.csv is missing required columns: $(join(string.(missing_columns), ", ")).")

    nrow(period_map) > 0 || error("Period_map.csv must contain at least one period.")
    for column in required_columns
        values = period_map[!, column]
        all(value -> !ismissing(value) && value isa Real && isfinite(value) &&
                     isinteger(value), values) || error(
            "Period_map.csv column $column must contain finite integer values.")
        period_map[!, column] = Int.(values)
    end

    period_index = period_map.Period_Index
    period_index == collect(1:nrow(period_map)) || error(
        "Period_map.csv Period_Index must be consecutive and ordered from 1 to " *
        "$(nrow(period_map)).")

    n_representative_periods = inputs["REP_PERIOD"]
    representative_index = period_map.Rep_Period_Index
    all(1 .<= representative_index .<= n_representative_periods) || error(
        "Period_map.csv Rep_Period_Index values must be between 1 and " *
        "$n_representative_periods.")
    Set(representative_index) == Set(1:n_representative_periods) || error(
        "Period_map.csv must assign at least one chronological period to every " *
        "representative period from 1 to $n_representative_periods.")

    representative_period = period_map.Rep_Period
    all(1 .<= representative_period .<= nrow(period_map)) || error(
        "Period_map.csv Rep_Period values must refer to valid Period_Index rows.")
    for representative in 1:n_representative_periods
        anchors = unique(representative_period[representative_index .== representative])
        length(anchors) == 1 || error(
            "Representative period $representative must have exactly one Rep_Period anchor.")
    end
    anchors = [only(unique(representative_period[representative_index .== representative]))
               for representative in 1:n_representative_periods]
    allunique(anchors) || error(
        "Period_map.csv must use a distinct Rep_Period anchor for every representative period.")
    return nothing
end

"""
    build_manual_representative_week_period_map!(inputs)

Construct the chronological mapping needed by independent long-duration storage for
manually selected representative weeks. Four input weeks are interpreted in the order
spring, summer, autumn, winter. Twelve input weeks are interpreted in January-to-December
order. This is deliberately independent of the `TimeDomainReduction` setting.

For four seasonal weeks, the 52 complete seven-day periods are divided into the same
four 13-week seasons used by the manual seasonal workflow. For twelve monthly weeks,
each complete week is assigned according to its midpoint month. The final 24 hours
are accounted for by the representative-period weights but do not form a separate
chronological period in this weekly LDS mapping.
"""
function build_manual_representative_week_period_map!(inputs::Dict)
    n_representative_periods = inputs["REP_PERIOD"]
    hours_per_period = inputs["hours_per_subperiod"]
    n_representative_periods in (4, 12) && hours_per_period == 168 || error(
        "Independent LDS with multiple manually supplied representative periods " *
        "requires either four seasonal 168-hour weeks, twelve monthly 168-hour weeks, " *
        "or an explicit system/Period_map.csv file. Found $n_representative_periods " *
        "periods of $hours_per_period hours.")

    weights = Float64.(inputs["Weights"])
    length(weights) == n_representative_periods || error(
        "Expected one Sub_Weights value for each representative week.")
    isapprox(sum(weights), 8760.0; atol = 1e-6) || error(
        "Automatic calendar mapping for manual representative weeks requires " *
        "Sub_Weights to sum to 8760 hours; found $(sum(weights)).")
    expected_weights = if n_representative_periods == 4
        Float64.([92, 92, 91, 90] .* 24)
    else
        Float64.([31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] .* 24)
    end
    all(isapprox.(weights, expected_weights; atol = 1e-6)) || error(
        "Automatic calendar mapping expected Sub_Weights $(expected_weights) for " *
        "$n_representative_periods manual representative weeks, but found $weights. " *
        "Use an explicit system/Period_map.csv for another weighting convention.")

    year_start = DateTime(2021, 1, 1) # fixed non-leap reference calendar
    n_periods = div(8760, hours_per_period)
    representative_index = if n_representative_periods == 4
        # Match the established manual/TDR seasonal convention: 13 complete
        # weeks per season, ordered spring, summer, autumn, winter.
        [fill(4, 8); fill(1, 13); fill(2, 13); fill(3, 13); fill(4, 5)]
    else
        monthly_index = Vector{Int}(undef, n_periods)
        for period in 1:n_periods
            midpoint_hour = (period - 1) * hours_per_period + div(hours_per_period, 2)
            monthly_index[period] = month(year_start + Hour(midpoint_hour))
        end
        monthly_index
    end

    # Anchor each modeled representative profile at the complete calendar week
    # containing the second week of its source month. The anchor fixes the absolute
    # SOC profile once; all other occurrences may have their own inter-period SOC.
    source_months = n_representative_periods == 4 ? [4, 7, 10, 1] : collect(1:12)
    anchors = Vector{Int}(undef, n_representative_periods)
    for representative in 1:n_representative_periods
        source_date = Date(2021, source_months[representative], 8)
        source_hour = 24 * (dayofyear(source_date) - 1)
        proposed_anchor = div(source_hour, hours_per_period) + 1
        candidates = findall(==(representative), representative_index)
        anchors[representative] = candidates[argmin(abs.(candidates .- proposed_anchor))]
    end

    period_map = DataFrame(
        Period_Index = 1:n_periods,
        Rep_Period = [anchors[r] for r in representative_index],
        Rep_Period_Index = representative_index,
    )
    validate_period_map!(period_map, inputs)
    inputs["Period_Map"] = period_map
    inputs["Period_Map_Source"] = "automatic manual representative-week calendar"
    println("Period map automatically constructed for " *
            "$n_representative_periods manual representative weeks")
    return nothing
end
