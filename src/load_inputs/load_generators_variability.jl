@doc raw"""
	load_generators_variability!(setup::Dict, path::AbstractString, inputs::Dict)

Read input parameters related to hourly maximum capacity factors for generators, storage, and flexible demand resources
"""
function load_generators_variability!(setup::Dict, path::AbstractString, inputs::Dict)

    # Hourly capacity factors
    TDR_directory = joinpath(path, setup["TimeDomainReductionFolder"])
    # if TDR is used, my_dir = TDR_directory, else my_dir = "system"
    my_dir = get_systemfiles_path(setup, TDR_directory, path)

    filename = "Generators_variability.csv"
    gen_var = load_dataframe(joinpath(my_dir, filename))


    if setup["NarrowVariability"] == 0
        all_resources = inputs["RESOURCE_NAMES"]        
        existing_variability = names(gen_var)
        for r in all_resources
            if r ∉ existing_variability
                @info "assuming availability of 1.0 for resource $r."
                ensure_column!(gen_var, r, 1.0)
            end
        end

        # Reorder DataFrame to R_ID order
        select!(gen_var, [:Time_Index; Symbol.(all_resources)])
        # Maximum power output and variability of each energy resource
        inputs["pP_Max"] = transpose(Matrix{Float64}(gen_var[1:inputs["T"],
            2:(inputs["G"] + 1)]))
    else
        inputs["pP_Max"] = ones(inputs["G"],inputs["T"])
        for nonvar in ("None",)
            ensure_column!(gen_var, nonvar, 1.0)
        end
        for i in 1:inputs["G"]
            r = inputs["RESOURCES"][i]
            inputs["pP_Max"][i,:] = transpose(Matrix{Float64}(select(gen_var,Symbol.(maxvar(r)))))
        end
    end

    # Hourly minimum power fractions for thermal resources with unit commitment.
    # MinVar is a shared profile tag under NarrowVariability; when it is absent
    # or set to None, retain the resource's static Min_Power value.
    inputs["pP_Min"] = zeros(inputs["G"], inputs["T"])
    active_minvar = [y for y in inputs["THERM_COMMIT"]
                     if !isempty(string(minvar(inputs["RESOURCES"][y]))) &&
                        lowercase(string(minvar(inputs["RESOURCES"][y]))) != "none"]
    @assert(setup["NarrowVariability"] == 1 || isempty(active_minvar),
        "Thermal MinVar profiles require NarrowVariability = 1.")
    for y in inputs["THERM_COMMIT"]
        inputs["pP_Min"][y, :] .= min_power(inputs["RESOURCES"][y])
    end
    for y in inputs["THERM_COMMIT"]
        tag = string(minvar(inputs["RESOURCES"][y]))
        if !isempty(tag) && lowercase(tag) != "none"
            column = Symbol(tag)
            @assert(column in propertynames(gen_var),
                "MinVar tag '$tag' for resource $(inputs["RESOURCE_NAMES"][y]) " *
                "is not a column in $filename.")
            values = Float64.(gen_var[1:inputs["T"], column])
            @assert(all(isfinite, values),
                "$filename contains non-finite MinVar values in column $tag.")
            @assert(all(x -> 0 <= x <= 1, values),
                "MinVar values in $filename column $tag must be between 0 and 1.")
            inputs["pP_Min"][y, :] .= values
        end
    end
    for y in inputs["THERM_COMMIT"], t in 1:inputs["T"]
        @assert(inputs["pP_Min"][y, t] <= inputs["pP_Max"][y, t],
            "Minimum power exceeds maximum availability for resource " *
            "$(inputs["RESOURCE_NAMES"][y]) at time step $t: " *
            "$(inputs["pP_Min"][y, t]) > $(inputs["pP_Max"][y, t]).")
    end

    println(filename * " Successfully Read!")
end
