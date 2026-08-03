"""
    full_time_series_reconstruction(path::AbstractString, setup::Dict, DF::DataFrame)

Internal function for performing the reconstruction. This function returns a DataFrame with the full series reconstruction. 

# Arguments
- `path` (AbstractString): Path input to the results folder
- `setup` (Dict): Case setup
- `DF` (DataFrame): DataFrame to be reconstructed

# Returns
- `reconDF` (DataFrame): DataFrame with the full series reconstruction
"""
function full_time_series_reconstruction(
        path::AbstractString, setup::Dict, DF::DataFrame)
    if setup["MultiStage"] == 1
        dirs = splitpath(path)
        case = joinpath(dirs[.!occursin.("result", dirs)])  # Get the case folder without the "results" folder(s)
        cur_stage = setup["MultiStageSettingsDict"]["CurStage"]
        TDRpath = joinpath(case, "inputs", string("inputs_p", cur_stage),
            setup["TimeDomainReductionFolder"])
    elseif setup["TimeDomainReduction"] == 1
        case = dirname(path)
        TDRpath = joinpath(case, setup["TimeDomainReductionFolder"])
    else
        case = dirname(path)
        return manual_four_week_full_time_series(case, setup, DF)
    end
    # Read Period map file Period_map.csv
    Period_map = CSV.read(joinpath(TDRpath, "Period_map.csv"), DataFrame)

    # Read time domain reduction settings file time_domain_reduction_settings.yml
    myTDRsetup = YAML.load(open(joinpath(
        case, "settings/time_domain_reduction_settings.yml")))

    # Define Timesteps per Representative Period and Weight Total
    TimestepsPerRepPeriod = myTDRsetup["TimestepsPerRepPeriod"]
    WeightTotal = myTDRsetup["WeightTotal"]
    # Calculate the number of total periods the original time series was split into (will usually be 52)
    numPeriods = floor(Int, WeightTotal / TimestepsPerRepPeriod)

    # Find the index of the row with the first time step
    t1 = findfirst(x -> x == "t1", DF[!, 1])
    isnothing(t1) && error("Unable to reconstruct full time series: input has no t1 row.")

    if nrow(Period_map) < numPeriods
        error("Period_map.csv contains $(nrow(Period_map)) periods, but $numPeriods are required.")
    end

    # Build the source-hour lookup once, then reconstruct every output column in
    # one indexed copy. The previous column-by-column hcat repeatedly copied the
    # full accumulated matrix and scaled quadratically with the resource count.
    source_hours = Vector{Int}(undef, TimestepsPerRepPeriod * numPeriods)
    for period in 1:numPeriods
        rep_period = Period_map[period, "Rep_Period_Index"]
        source_start = (rep_period - 1) * TimestepsPerRepPeriod + 1
        output_start = (period - 1) * TimestepsPerRepPeriod + 1
        source_hours[output_start:(output_start + TimestepsPerRepPeriod - 1)] .=
            source_start:(source_start + TimestepsPerRepPeriod - 1)
    end

    # Weekly TDR covers 8,736 hours. Repeat the final reconstructed hours to fill
    # the remaining 24 hours of a non-leap year, matching the documented behavior.
    remaining_hours = WeightTotal - length(source_hours)
    remaining_hours < 0 && error("WeightTotal is shorter than the reconstructed periods.")
    remaining_hours > length(source_hours) &&
        error("Cannot fill $remaining_hours trailing hours from the reconstructed series.")
    if remaining_hours > 0
        append!(source_hours, source_hours[(end - remaining_hours + 1):end])
    end

    metadata_rows = t1 - 1
    reconstructed = Matrix{Any}(undef, metadata_rows + WeightTotal, ncol(DF))
    if metadata_rows > 0
        reconstructed[1:metadata_rows, :] .= Matrix(DF[1:metadata_rows, :])
    end
    reconstructed[(metadata_rows + 1):end, 1] .= ["t$t" for t in 1:WeightTotal]
    reconstructed[(metadata_rows + 1):end, 2:end] .=
        Matrix(DF[t1 .+ source_hours .- 1, 2:end])

    return DataFrame(reconstructed, :auto)
end

"""
    manual_four_week_full_time_series(case, setup, DF)

Reconstruct a non-leap calendar year from four user-provided representative
weeks when GenX's TDR preprocessing is disabled. The representative weeks are
interpreted in input order as spring (March-May), summer (June-August), autumn
(September-November), and winter (January, February, and December). Each week
is repeated within its calendar block and truncated at the block boundary.

This function only expands output rows. It does not modify `Sub_Weights`, model
weights, annual sums, or any optimization result.
"""
function manual_four_week_full_time_series(
        case::AbstractString, setup::Dict, DF::DataFrame)
    demand_path = joinpath(case, setup["SystemFolder"], "Demand_data.csv")
    isfile(demand_path) || error(
        "Cannot reconstruct a manual four-week time series: $demand_path was not found.")
    demand = CSV.read(demand_path, DataFrame;
        select = ["Rep_Periods", "Timesteps_per_Rep_Period", "Time_Index"])
    representative_periods = only(collect(skipmissing(demand.Rep_Periods)))
    hours_per_period = only(collect(skipmissing(demand.Timesteps_per_Rep_Period)))

    t1 = findfirst(==("t1"), DF[!, 1])
    isnothing(t1) && error("Unable to reconstruct full time series: input has no t1 row.")
    available_hours = nrow(DF) - t1 + 1
    # A non-TDR case may already contain a full year. In that case the regular
    # output is already chronological, so place an unchanged copy in the
    # Full_TimeSeries folder.
    available_hours == 8760 && return copy(DF)

    representative_periods == 4 && hours_per_period == 168 || error(
        "Automatic full-year reconstruction with TimeDomainReduction=0 requires " *
        "either 8760 modeled hours or exactly four 168-hour representative weeks " *
        "in Demand_data.csv; found $representative_periods periods of " *
        "$hours_per_period hours and $available_hours output hours.")
    expected_hours = representative_periods * hours_per_period
    available_hours == expected_hours || error(
        "Manual four-week reconstruction expected $expected_hours modeled hours, " *
        "but the output contains $available_hours.")

    # Non-leap-year calendar blocks. Winter is split at the year boundary, so
    # January-February and December each restart at hour 1 of representative week 4.
    block_days = [31 + 28, 31 + 30 + 31, 30 + 31 + 31, 30 + 31 + 30, 31]
    block_representatives = [4, 1, 2, 3, 4]
    source_hours = Int[]
    sizehint!(source_hours, 8760)
    for (days, representative_period) in zip(block_days, block_representatives)
        block_hours = 24 * days
        representative_start = (representative_period - 1) * hours_per_period
        append!(source_hours,
            representative_start .+ mod.(0:(block_hours - 1), hours_per_period) .+ 1)
    end
    length(source_hours) == 8760 || error(
        "Internal error constructing the manual four-week calendar mapping.")

    metadata_rows = t1 - 1
    reconstructed = Matrix{Any}(undef, metadata_rows + 8760, ncol(DF))
    if metadata_rows > 0
        reconstructed[1:metadata_rows, :] .= Matrix(DF[1:metadata_rows, :])
    end
    reconstructed[(metadata_rows + 1):end, 1] .= ["t$t" for t in 1:8760]
    reconstructed[(metadata_rows + 1):end, 2:end] .=
        Matrix(DF[t1 .+ source_hours .- 1, 2:end])
    return DataFrame(reconstructed, :auto)
end
