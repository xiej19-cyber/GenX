function _generation_hours_tag(resource::AbstractResource, attribute::Symbol)
    return strip(string(get(resource, attribute, "none")))
end

function _load_generation_hours!(path::AbstractString,
        inputs::Dict,
        filename::String,
        hours_column::Symbol,
        resource_attribute::Symbol,
        input_prefix::String)
    df = load_dataframe(joinpath(path, filename))
    required_columns = ["ConstraintDescription", string(hours_column)]
    missing_columns = setdiff(required_columns, names(df))
    isempty(missing_columns) ||
        error("$filename is missing required columns: $(join(missing_columns, ", ")).")
    nrow(df) > 0 || error("$filename must contain at least one constraint.")

    constraint_names = strip.(string.(df[!, :ConstraintDescription]))
    all(name -> !isempty(name), constraint_names) ||
        error("ConstraintDescription values in $filename cannot be empty.")
    all(name -> lowercase(name) != "none", constraint_names) ||
        error("ConstraintDescription in $filename cannot be 'none'; that value is reserved for resources outside the policy.")
    allunique(constraint_names) ||
        error("ConstraintDescription values in $filename must be unique.")

    hours = Float64.(df[!, hours_column])
    all(isfinite, hours) || error("$hours_column values in $filename must be finite.")
    all(>=(0), hours) || error("$hours_column values in $filename must be nonnegative.")

    resources = inputs["RESOURCES"]
    resource_tags = [_generation_hours_tag(resource, resource_attribute)
                     for resource in resources]
    active_tags = filter(tag -> lowercase(tag) != "none", resource_tags)
    unknown_tags = setdiff(unique(active_tags), constraint_names)
    isempty(unknown_tags) ||
        error("Resource column $(string(resource_attribute)) contains constraint names not found in $filename: $(join(unknown_tags, ", ")).")

    resource_ids = [findall(==(name), resource_tags) for name in constraint_names]
    empty_constraints = constraint_names[isempty.(resource_ids)]
    isempty(empty_constraints) ||
        error("The following constraints in $filename do not match any resources: $(join(empty_constraints, ", ")).")

    tagged_ids = unique(vcat(resource_ids...))
    unsupported = [resource_name(resources[y]) for y in tagged_ids
                   if resources[y] isa VreStorage || resources[y] isa AllamCycleLOX]
    isempty(unsupported) ||
        error("Generation-hours policies do not currently support VreStorage or AllamCycleLOX resources: $(join(unsupported, ", ")).")

    inputs["NumberOf$(input_prefix)Reqs"] = nrow(df)
    inputs["$(input_prefix)Names"] = constraint_names
    inputs["$(input_prefix)Values"] = hours
    inputs["$(input_prefix)Resources"] = resource_ids
    println(filename * " Successfully Read!")
    return nothing
end

function load_maximum_generation_hours!(path::AbstractString, inputs::Dict, setup::Dict)
    _load_generation_hours!(path,
        inputs,
        "Maximum_generation_hours.csv",
        :Max_Hours,
        :maxgenhours,
        "MaxGenHours")
end

function load_minimum_generation_hours!(path::AbstractString, inputs::Dict, setup::Dict)
    _load_generation_hours!(path,
        inputs,
        "Minimum_generation_hours.csv",
        :Min_Hours,
        :mingenhours,
        "MinGenHours")
end
