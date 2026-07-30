"""
    _load_minimum_commitment_profile(filepath, filename, inputs, resources_by_zone)

Load and validate one zonal hourly minimum-commitment profile. The returned
matrix has dimensions `Z × T`; omitted zone columns default to zero.
"""
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

Load optional zonal, hourly minimum commitment fractions for coal and natural
gas from `Minimum_commitment_coal.csv` and `Minimum_commitment_gas.csv`. Both groups
use the `Minimum_Commitment = 1` flag in `Thermal.csv`; the resource `Fuel`
value separates coal (`coal_*`) from gas (`naturalgas_*`).
"""
function load_minimum_commitment!(setup::Dict, path::AbstractString, inputs::Dict)
    TDR_directory = joinpath(path, setup["TimeDomainReductionFolder"])
    input_directory = get_systemfiles_path(setup, TDR_directory, path)

    gen = inputs["RESOURCES"]
    committed = inputs["THERM_COMMIT"]
    eligible = [y for y in committed if get(gen[y], :minimum_commitment, 0) == 1]
    coal = [y for y in eligible if startswith(lowercase(fuel(gen[y])), "coal")]
    gas = [y for y in eligible if startswith(lowercase(fuel(gen[y])), "naturalgas")]

    unclassified = setdiff(eligible, union(coal, gas))
    @assert(isempty(unclassified),
        "Resources marked Minimum_Commitment = 1 must use a Fuel beginning with " *
        "coal or naturalgas. Unclassified resources: " *
        "$(join(resource_name.(gen[unclassified]), ", ")).")

    by_zone(resources) = [
        [y for y in resources if zone_id(gen[y]) == z] for z in 1:inputs["Z"]
    ]
    coal_by_zone = by_zone(coal)
    gas_by_zone = by_zone(gas)

    coal_filename = "Minimum_commitment_coal.csv"
    gas_filename = "Minimum_commitment_gas.csv"
    coal_profile, coal_zones = _load_minimum_commitment_profile(
        joinpath(input_directory, coal_filename), coal_filename, inputs, coal_by_zone)
    gas_profile, gas_zones = _load_minimum_commitment_profile(
        joinpath(input_directory, gas_filename), gas_filename, inputs, gas_by_zone)

    inputs["MINIMUM_COMMITMENT_RESOURCES"] = coal
    inputs["MINIMUM_COMMITMENT_BY_ZONE"] = coal_by_zone
    inputs["pMinimumCommitment"] = coal_profile
    inputs["MINIMUM_COMMITMENT_ZONES"] = coal_zones
    inputs["MINIMUM_COMMITMENT_GAS_RESOURCES"] = gas
    inputs["MINIMUM_COMMITMENT_GAS_BY_ZONE"] = gas_by_zone
    inputs["pMinimumCommitmentGas"] = gas_profile
    inputs["MINIMUM_COMMITMENT_GAS_ZONES"] = gas_zones
    return nothing
end
