@doc raw"""
	load_operational_reserves!(setup::Dict,path::AbstractString, inputs::Dict)

Read input parameters related to frequency regulation and operating reserve requirements
"""
function load_operational_reserves!(setup::Dict, path::AbstractString, inputs::Dict)
    filename = "Operational_reserves.csv"
    deprecated_synonym = "Reserves.csv"
    res_in = load_dataframe(path, [filename, deprecated_synonym])

    gen = inputs["RESOURCES"]

    function load_field_with_deprecated_symbol(df::DataFrame,
            columns::Vector{Symbol},
            row::Int = 1)
        best = popfirst!(columns)
        all_columns = Symbol.(names(df))
        if best in all_columns
            return float(df[row, best])
        end
        for col in columns
            if col in all_columns
                Base.depwarn(
                    "The column name $col in file $filename is deprecated; prefer $best",
                    :load_operational_reserves,
                    force = true)
                return float(df[row, col])
            end
        end
        error("None of the columns $columns were found in the file $filename")
    end

    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    if setup["OperationalReserves"] == 2
        Z = inputs["Z"]
        columns = Symbol.(names(res_in))
        custom_regions = :Reserve_Region in columns || :Zones in columns

        if custom_regions
            (:Reserve_Region in columns && :Zones in columns) || error(
                "Custom operational reserve regions require both Reserve_Region and Zones columns")
            row_regions = Int.(res_in[!, :Reserve_Region])
            reserve_regions = sort(unique(row_regions))
            reserve_regions == collect(1:length(reserve_regions)) || error(
                "Reserve_Region values must be consecutive integers 1:$(length(reserve_regions))")
            parse_zones(value) = begin
                # Use String-to-String replacements for Julia 1.6 compatibility.
                normalized = String(strip(string(value)))
                normalized = replace(normalized, "“" => "\"")
                normalized = replace(normalized, "”" => "\"")
                normalized = replace(normalized, "；" => ";")
                normalized = replace(normalized, "\"" => "")
                tokens = split(normalized, r"[;|[:space:]]+")
                isempty(tokens) || all(x -> !isempty(x), tokens) ||
                    error("Invalid Zones value: $value")
                zones = tryparse.(Int, tokens)
                all(x -> !isnothing(x), zones) || error(
                    "Invalid Zones value '$value'. Use zone numbers separated by semicolons, " *
                    "for example \"1;2;3\". ASCII or Chinese quotation marks are accepted.")
                Int[something(z) for z in zones]
            end
            region_zones = Dict(r => Int[] for r in reserve_regions)
            inputs["pReg_Req_Demand_By_Zone"] = zeros(Z)
            inputs["pReg_Req_VRE_By_Zone"] = zeros(Z)
            inputs["pRsv_Req_Demand_By_Zone"] = zeros(Z)
            inputs["pRsv_Req_VRE_By_Zone"] = zeros(Z)
            for (row, r) in enumerate(row_regions)
                zones = parse_zones(res_in[row, :Zones])
                append!(region_zones[r], zones)
                for z in zones
                    1 <= z <= Z || error(
                        "Operational_reserves.csv contains zone $z outside 1:$Z")
                    inputs["pReg_Req_Demand_By_Zone"][z] =
                        load_field_with_deprecated_symbol(res_in,
                            [:Reg_Req_Percent_Demand, :Reg_Req_Percent_Load], row)
                    inputs["pReg_Req_VRE_By_Zone"][z] = float(res_in[row, :Reg_Req_Percent_VRE])
                    inputs["pRsv_Req_Demand_By_Zone"][z] =
                        load_field_with_deprecated_symbol(res_in,
                            [:Rsv_Req_Percent_Demand, :Rsv_Req_Percent_Load], row)
                    inputs["pRsv_Req_VRE_By_Zone"][z] = float(res_in[row, :Rsv_Req_Percent_VRE])
                end
            end
            all(z -> 1 <= z <= Z, Iterators.flatten(values(region_zones))) ||
                error("Operational_reserves.csv contains a zone outside 1:$Z")
            all(!isempty, values(region_zones)) ||
                error("Every operational reserve region must contain at least one zone")
            listed_zones = collect(Iterators.flatten(values(region_zones)))
            length(unique(listed_zones)) == length(listed_zones) || error(
                "A physical zone may belong to only one operational reserve region")

            assignment_file = joinpath(dirname(path), setup["ResourcesFolder"],
                setup["ResourcePoliciesFolder"], OPERATIONAL_RESERVE_ASSIGNMENT_FILE)
            isfile(assignment_file) || error(
                "$OPERATIONAL_RESERVE_ASSIGNMENT_FILE is required when custom reserve regions are used")
            assignment_df = load_dataframe(assignment_file)
            assignment_columns = lowercase.(names(assignment_df))
            expected_columns = ["resource"; ["reserve_region_$r" for r in reserve_regions]]
            assignment_columns == expected_columns || error(
                "$OPERATIONAL_RESERVE_ASSIGNMENT_FILE must contain exactly these columns: " *
                join(expected_columns, ", "))
            length(unique(assignment_df[!, 1])) == nrow(assignment_df) || error(
                "$OPERATIONAL_RESERVE_ASSIGNMENT_FILE contains duplicate Resource rows")
            gen = inputs["RESOURCES"]
            resource_region = zeros(Int, length(gen))
            for y in eachindex(gen)
                memberships = Int[]
                for r in reserve_regions
                    attribute = Symbol("reserve_region_$r")
                    value = get(gen[y], attribute, 0)
                    value in (0, 1) || error(
                        "$(resource_name(gen[y])) has non-binary $attribute=$value")
                    value == 1 && push!(memberships, r)
                end
                length(memberships) <= 1 || error(
                    "$(resource_name(gen[y])) belongs to more than one operational reserve region")
                !isempty(memberships) && (resource_region[y] = only(memberships))
            end
            unassigned = [resource_name(gen[y]) for y in union(inputs["REG"], inputs["RSV"])
                          if resource_region[y] == 0]
            isempty(unassigned) || error(
                "Reserve-capable resources missing an operational reserve region assignment: " *
                join(unassigned, ", "))
            inputs["OPERATIONAL_RESERVE_REGIONS"] = reserve_regions
            inputs["OPERATIONAL_RESERVE_REGION_ZONES"] = region_zones
            inputs["OPERATIONAL_RESERVE_RESOURCE_REGION"] = resource_region
            inputs["OPERATIONAL_RESERVE_CUSTOM_REGIONS"] = true
            transfer_region = Dict{Int, Int}()
            for y in union(inputs["REG"], inputs["RSV"])
                r = resource_region[y]
                source_zone = zone_id(gen[y])
                source_zone in region_zones[r] && continue
                candidate_lines = [l for l in 1:inputs["L"]
                                   if inputs["pTrans_Start_Zone"][l] == source_zone &&
                                      inputs["pTrans_End_Zone"][l] in region_zones[r]]
                isempty(candidate_lines) && error(
                    "$(resource_name(gen[y])) is assigned to reserve region $r but no direct " *
                    "Network.csv line connects its physical zone $source_zone to that region")
                for l in candidate_lines
                    haskey(transfer_region, l) && transfer_region[l] != r && error(
                        "Network line $l cannot deliver reserves to multiple regions")
                    transfer_region[l] = r
                end
            end
            inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"] = sort(collect(keys(transfer_region)))
            inputs["OPERATIONAL_RESERVE_TRANSFER_REGION"] = transfer_region
        else
            :Zone in columns || error(
                "Operational_reserves.csv must include Zone, or Reserve_Region and Zones, when OperationalReserves = 2")
            reserve_regions = Int.(res_in[!, :Zone])
            isempty(reserve_regions) &&
                error("Operational_reserves.csv must list at least one Zone when OperationalReserves = 2")
            length(unique(reserve_regions)) == length(reserve_regions) ||
                error("Each Zone in Operational_reserves.csv must appear only once")
            all(z -> 1 <= z <= Z, reserve_regions) ||
                error("Operational_reserves.csv contains a Zone outside 1:$Z")
            inputs["OPERATIONAL_RESERVE_REGIONS"] = reserve_regions
            inputs["OPERATIONAL_RESERVE_REGION_ZONES"] = Dict(z => [z] for z in reserve_regions)
            inputs["OPERATIONAL_RESERVE_RESOURCE_REGION"] = zone_id.(inputs["RESOURCES"])
            inputs["OPERATIONAL_RESERVE_CUSTOM_REGIONS"] = false
            inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"] = Z > 1 ? [
                    l for l in 1:inputs["L"]
                    if inputs["pTrans_Start_Zone"][l] ∉ reserve_regions &&
                       inputs["pTrans_End_Zone"][l] ∈ reserve_regions] : Int[]
            inputs["OPERATIONAL_RESERVE_TRANSFER_REGION"] = Dict(
                l => inputs["pTrans_End_Zone"][l]
                for l in inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"])
        end
        # Deprecated compatibility alias: entries are region IDs in custom-region mode.
        inputs["OPERATIONAL_RESERVE_ZONES"] = reserve_regions

        N = length(reserve_regions)
        if custom_regions
            inputs["pC_Rsv_Penalty"] = zeros(N)
            inputs["pStatic_Contingency"] = zeros(N)
            for r in reserve_regions
                rows = findall(==(r), row_regions)
                penalties = unique(float.(res_in[rows, :Unmet_Rsv_Penalty_Dollar_per_MW]))
                length(penalties) == 1 || error(
                    "Unmet_Rsv_Penalty_Dollar_per_MW must be identical within reserve region $r")
                contingencies = unique(float.(res_in[rows, :Static_Contingency_MW]))
                length(contingencies) == 1 || error(
                    "Static_Contingency_MW must be identical within reserve region $r")
                inputs["pC_Rsv_Penalty"][r] = only(penalties) / scale_factor
                inputs["pStatic_Contingency"][r] = only(contingencies) / scale_factor
            end
        else
            inputs["pReg_Req_Demand"] = zeros(Z)
            inputs["pReg_Req_VRE"] = zeros(Z)
            inputs["pRsv_Req_Demand"] = zeros(Z)
            inputs["pRsv_Req_VRE"] = zeros(Z)
            inputs["pC_Rsv_Penalty"] = zeros(Z)
            inputs["pStatic_Contingency"] = zeros(Z)
            for (row, r) in enumerate(reserve_regions)
                inputs["pReg_Req_Demand"][r] = load_field_with_deprecated_symbol(res_in,
                    [:Reg_Req_Percent_Demand, :Reg_Req_Percent_Load], row)
                inputs["pReg_Req_VRE"][r] = float(res_in[row, :Reg_Req_Percent_VRE])
                inputs["pRsv_Req_Demand"][r] = load_field_with_deprecated_symbol(res_in,
                    [:Rsv_Req_Percent_Demand, :Rsv_Req_Percent_Load], row)
                inputs["pRsv_Req_VRE"][r] = float(res_in[row, :Rsv_Req_Percent_VRE])
                inputs["pC_Rsv_Penalty"][r] =
                    float(res_in[row, :Unmet_Rsv_Penalty_Dollar_per_MW]) / scale_factor
                inputs["pStatic_Contingency"][r] =
                    float(res_in[row, :Static_Contingency_MW]) / scale_factor
            end
        end
    else
        inputs["OPERATIONAL_RESERVE_ZONES"] = collect(1:inputs["Z"])
        inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"] = Int[]
        inputs["pReg_Req_Demand"] = load_field_with_deprecated_symbol(res_in,
            [:Reg_Req_Percent_Demand, :Reg_Req_Percent_Load])
        inputs["pReg_Req_VRE"] = float(res_in[1, :Reg_Req_Percent_VRE])
        inputs["pRsv_Req_Demand"] = load_field_with_deprecated_symbol(res_in,
            [:Rsv_Req_Percent_Demand, :Rsv_Req_Percent_Load])
        inputs["pRsv_Req_VRE"] = float(res_in[1, :Rsv_Req_Percent_VRE])
        inputs["pC_Rsv_Penalty"] =
            float(res_in[1, :Unmet_Rsv_Penalty_Dollar_per_MW]) / scale_factor
        inputs["pStatic_Contingency"] =
            float(res_in[1, :Static_Contingency_MW]) / scale_factor
    end

    if setup["UCommit"] >= 1
        if setup["OperationalReserves"] == 2
            dynamic_values = unique(Int8.(res_in[!, :Dynamic_Contingency]))
            length(dynamic_values) == 1 ||
                error("Dynamic_Contingency must have the same value for all operational reserve zones")
            inputs["pDynamic_Contingency"] = only(dynamic_values)
        else
            inputs["pDynamic_Contingency"] = Int8(res_in[1, :Dynamic_Contingency])
        end
        # Set BigM value used for dynamic contingencies cases to be largest possible cluster size
        # Note: this BigM value is only relevant for units in the COMMIT set. See operational_reserves.jl for details on implementation of dynamic contingencies
        if inputs["pDynamic_Contingency"] > 0
            inputs["pContingency_BigM"] = zeros(Float64, inputs["G"])
            for y in inputs["COMMIT"]
                inputs["pContingency_BigM"][y] = max_cap_mw(gen[y])
                # When Max_Cap_MW == -1, there is no limit on capacity size
                if inputs["pContingency_BigM"][y] < 0
                    # NOTE: this effectively acts as a maximum cluster size when not otherwise specified, adjust accordingly
                    inputs["pContingency_BigM"][y] = 5000 * cap_size(gen[y])
                end
            end
        end
    end

    println(filename * " Successfully Read!")
end
