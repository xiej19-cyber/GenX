# Load and validate one zonal hourly minimum-commitment profile. The returned
# matrix has dimensions Z × T; omitted zone columns default to zero.
function _load_minimum_commitment_profile(filepath::AbstractString,
        filename::AbstractString, inputs::Dict, resources_by_zone)
    Z, T = inputs["Z"], inputs["T"]
    if !isfile(filepath)
        return zeros(Z, T), Int[]
    end

    data = load_dataframe(filepath)
    @assert(:Time_Index in propertynames(data),
        "$filename must contain a Time_Index column.")
    @assert(nrow(data) == T,
        "$filename must have exactly $T rows, matching the time steps in the " *
        "current model, but has $(nrow(data)) rows.")

    expected_columns = [Symbol("Zone_$z") for z in 1:Z]
    supplied_columns = filter(!=(:Time_Index), propertynames(data))
    unknown_columns = setdiff(supplied_columns, expected_columns)
    @assert(isempty(unknown_columns),
        "$filename contains unknown zone columns: $(join(unknown_columns, ", ")). " *
        "Use Zone_1 through Zone_$Z.")

    profile = zeros(Z, T)
    for z in 1:Z
        column = Symbol("Zone_$z")
        if column in propertynames(data)
            values = Float64.(data[:, column])
            @assert(all(isfinite, values),
                "$filename contains non-finite values for $column.")
            @assert(all(x -> 0 <= x <= 1, values),
                "$filename values for $column must be between 0 and 1.")
            profile[z, :] .= values
        end
    end

    constrained_zones = [z for z in 1:Z if any(x -> x > 0, profile[z, :])]
    missing_resources = [z for z in constrained_zones if isempty(resources_by_zone[z])]
    @assert(isempty(missing_resources),
        "$filename specifies a positive fraction for zones without any eligible " *
        "committed thermal resources: $(join(missing_resources, ", ")).")

    println(filename * " Successfully Read!")
    return profile, constrained_zones
end

@doc raw"""
	load_minimum_commitment!(setup::Dict, path::AbstractString, inputs::Dict)

Load optional zonal, hourly minimum commitment fractions for one combined pool
of coal and natural-gas resources from `Minimum_commitment.csv`. The
`Minimum_Commitment` value in `Thermal.csv` is the fraction of each resource's
capacity included in the policy capacity total.
"""
function load_minimum_commitment!(setup::Dict, path::AbstractString, inputs::Dict)
    TDR_directory = joinpath(path, setup["TimeDomainReductionFolder"])
    input_directory = get_systemfiles_path(setup, TDR_directory, path)

    gen = inputs["RESOURCES"]
    committed = inputs["THERM_COMMIT"]
    invalid = [y for y in committed if
               !(minimum_commitment_fraction(gen[y]) isa Real &&
                 isfinite(minimum_commitment_fraction(gen[y])) &&
                 0 <= minimum_commitment_fraction(gen[y]) <= 1)]
    @assert(isempty(invalid),
        "Minimum_Commitment must be a finite fraction between 0 and 1. " *
        "Invalid resources: $(join(resource_name.(gen[invalid]), ", ")).")

    eligible = [y for y in committed if minimum_commitment_fraction(gen[y]) > 0]
    coal_or_gas = [y for y in eligible if
                   startswith(lowercase(fuel(gen[y])), "coal") ||
                   startswith(lowercase(fuel(gen[y])), "naturalgas")]

    unclassified = setdiff(eligible, coal_or_gas)
    @assert(isempty(unclassified),
        "Resources with Minimum_Commitment > 0 must use a Fuel beginning with " *
        "coal or naturalgas. Unclassified resources: " *
        "$(join(resource_name.(gen[unclassified]), ", ")).")

    resources_by_zone = [
        [y for y in coal_or_gas if zone_id(gen[y]) == z] for z in 1:inputs["Z"]
    ]

    filename = "Minimum_commitment.csv"
    profile, zones = _load_minimum_commitment_profile(
        joinpath(input_directory, filename), filename, inputs, resources_by_zone)

    inputs["MINIMUM_COMMITMENT_RESOURCES"] = coal_or_gas
    inputs["MINIMUM_COMMITMENT_BY_ZONE"] = resources_by_zone
    inputs["pMinimumCommitment"] = profile
    inputs["MINIMUM_COMMITMENT_ZONES"] = zones
    return nothing
end
