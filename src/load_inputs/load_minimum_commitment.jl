@doc raw"""
	load_minimum_commitment!(setup::Dict, path::AbstractString, inputs::Dict)

Load an optional zonal, hourly minimum commitment fraction from
`Minimum_commitment.csv`. Columns are named `Zone_1`, ..., `Zone_Z`, and values
are fractions in `[0, 1]`. Thermal unit-commitment resources participate when
their `Minimum_Commitment` resource attribute equals 1.
"""
function load_minimum_commitment!(setup::Dict, path::AbstractString, inputs::Dict)
    TDR_directory = joinpath(path, setup["TimeDomainReductionFolder"])
    input_directory = get_systemfiles_path(setup, TDR_directory, path)
    filename = "Minimum_commitment.csv"
    filepath = joinpath(input_directory, filename)

    gen = inputs["RESOURCES"]
    committed = inputs["THERM_COMMIT"]
    eligible = [y for y in committed if get(gen[y], :minimum_commitment, 0) == 1]
    inputs["MINIMUM_COMMITMENT_RESOURCES"] = eligible
    inputs["MINIMUM_COMMITMENT_BY_ZONE"] = [
        [y for y in eligible if zone_id(gen[y]) == z] for z in 1:inputs["Z"]
    ]

    # The feature is opt-in through the presence of the input file.
    if !isfile(filepath)
        inputs["pMinimumCommitment"] = zeros(inputs["Z"], inputs["T"])
        inputs["MINIMUM_COMMITMENT_ZONES"] = Int[]
        return nothing
    end

    min_commitment = load_dataframe(filepath)
    @assert(:Time_Index in propertynames(min_commitment),
        "$filename must contain a Time_Index column.")
    @assert(nrow(min_commitment) == inputs["T"],
        "$filename must have exactly $(inputs["T"]) rows, matching the time " *
        "steps in the current model, but has $(nrow(min_commitment)) rows.")

    expected_columns = [Symbol("Zone_$z") for z in 1:inputs["Z"]]
    supplied_columns = filter(!=(:Time_Index), propertynames(min_commitment))
    unknown_columns = setdiff(supplied_columns, expected_columns)
    @assert(isempty(unknown_columns),
        "$filename contains unknown zone columns: $(join(unknown_columns, ", ")). " *
        "Use Zone_1 through Zone_$(inputs["Z"]).")

    profile = zeros(inputs["Z"], inputs["T"])
    for z in 1:inputs["Z"]
        column = Symbol("Zone_$z")
        if column in propertynames(min_commitment)
            values = Float64.(min_commitment[:, column])
            @assert(all(isfinite, values),
                "$filename contains non-finite values for $column.")
            @assert(all(x -> 0 <= x <= 1, values),
                "$filename values for $column must be between 0 and 1.")
            profile[z, :] .= values
        end
    end

    constrained_zones = [z for z in 1:inputs["Z"] if any(x -> x > 0, profile[z, :])]
    missing_resources = [z for z in constrained_zones
                         if isempty(inputs["MINIMUM_COMMITMENT_BY_ZONE"][z])]
    @assert(isempty(missing_resources),
        "$filename specifies a positive fraction for zones without any committed " *
        "thermal resource marked Minimum_Commitment = 1: " *
        "$(join(missing_resources, ", ")).")

    inputs["pMinimumCommitment"] = profile
    inputs["MINIMUM_COMMITMENT_ZONES"] = constrained_zones
    println(filename * " Successfully Read!")
    return nothing
end
