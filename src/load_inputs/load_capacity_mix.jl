"""Load exact end-of-stage capacity shares and many-to-many resource assignments."""
function load_capacity_mix!(setup::Dict, case_path::AbstractString, inputs::Dict)
    target_path = joinpath(case_path, setup["PoliciesFolder"], "Capacity_mix.csv")
    assignment_path = joinpath(case_path, setup["ResourcesFolder"],
        setup["ResourcePoliciesFolder"], "Resource_capacity_mix.csv")
    isfile(target_path) || error("CapacityMix=1 requires $target_path.")
    isfile(assignment_path) || error("CapacityMix=1 requires $assignment_path.")

    targets = load_dataframe(target_path)
    assignments = load_dataframe(assignment_path)
    target_columns = Set(["Group", "Resource_Type", "Share"])
    assignment_columns = Set(["Resource", "Group", "Resource_Type"])
    Set(names(targets)) == target_columns ||
        error("Capacity_mix.csv must contain exactly Group, Resource_Type, Share.")
    Set(names(assignments)) == assignment_columns ||
        error("Resource_capacity_mix.csv must contain exactly Resource, Group, Resource_Type.")
    nrow(targets) > 0 || error("Capacity_mix.csv must contain at least one row.")
    nrow(assignments) > 0 || error("Resource_capacity_mix.csv must contain at least one row.")

    function names_in(df, column, filename)
        values = df[!, column]
        all(v -> !ismissing(v) && !isempty(strip(string(v))), values) ||
            error("$column in $filename cannot be empty.")
        return strip.(string.(values))
    end

    group_names = names_in(targets, :Group, "Capacity_mix.csv")
    type_names = names_in(targets, :Resource_Type, "Capacity_mix.csv")
    raw_shares = targets[!, :Share]
    all(v -> v isa Real && isfinite(v) && 0 <= v <= 1, raw_shares) ||
        error("Share in Capacity_mix.csv must be a finite number between 0 and 1.")
    shares = Float64.(raw_shares)
    target_keys = collect(zip(group_names, type_names))
    allunique(target_keys) || error("Capacity_mix.csv contains a duplicate Group/Resource_Type.")

    groups = unique(group_names)
    rows_by_group = [findall(==(group), group_names) for group in groups]
    for (group, rows) in zip(groups, rows_by_group)
        length(rows) >= 2 || error("Capacity mix group $group must contain at least two types.")
        isapprox(sum(shares[rows]), 1.0; atol = 1e-8, rtol = 0) ||
            error("Shares in capacity mix group $group must sum to 1.")
    end

    assigned_names = names_in(assignments, :Resource, "Resource_capacity_mix.csv")
    assigned_groups = names_in(assignments, :Group, "Resource_capacity_mix.csv")
    assigned_types = names_in(assignments, :Resource_Type, "Resource_capacity_mix.csv")
    assignment_keys = collect(zip(assigned_names, assigned_groups))
    allunique(assignment_keys) ||
        error("Resource_capacity_mix.csv assigns a resource more than once in one group.")
    valid_targets = Set(target_keys)
    all(key -> key in valid_targets, zip(assigned_groups, assigned_types)) ||
        error("Resource_capacity_mix.csv contains a Group/Resource_Type absent from Capacity_mix.csv.")

    resources = inputs["RESOURCES"]
    resource_names = resource_name.(resources)
    resource_ids = Vector{Int}(undef, nrow(assignments))
    for (row, name) in enumerate(assigned_names)
        matches = findall(==(name), resource_names)
        length(matches) == 1 ||
            error("Resource $name in Resource_capacity_mix.csv must match exactly one resource.")
        id = only(matches)
        supported = resources[id] isa Union{Vre, Thermal, Storage} ||
            (resources[id] isa Hydro && occursin("_csp_", lowercase(name)))
        supported ||
            error("Capacity mix does not support resource $name of type $(typeof(resources[id])).")
        resource_ids[row] = id
    end

    ids_by_target = [resource_ids[findall(==((group, category)),
        collect(zip(assigned_groups, assigned_types)))]
                     for (group, category) in target_keys]
    all(!isempty, ids_by_target) ||
        error("Every Group/Resource_Type in Capacity_mix.csv needs at least one assigned resource.")
    ids_by_group = [unique(vcat(ids_by_target[rows]...)) for rows in rows_by_group]
    constrained_rows = vcat([rows[1:(end - 1)] for rows in rows_by_group]...)
    group_index = [findfirst(==(group), groups) for group in group_names]

    inputs["CapacityMixGroups"] = groups
    inputs["CapacityMixTypes"] = type_names
    inputs["CapacityMixShares"] = shares
    inputs["CapacityMixGroupIndex"] = group_index
    inputs["CapacityMixIdsByGroup"] = ids_by_group
    inputs["CapacityMixIdsByTarget"] = ids_by_target
    inputs["CapacityMixConstrainedRows"] = constrained_rows
    return nothing
end
