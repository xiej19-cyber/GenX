@doc raw"""
    load_co2_cap!(setup::Dict, path::AbstractString, inputs::Dict)

Read input parameters related to CO$_2$ emissions cap constraints
"""
function load_co2_cap!(setup::Dict, path::AbstractString, inputs::Dict)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    filename = "CO2_cap_slack.csv"
    if isfile(joinpath(path, filename))
        df = load_dataframe(joinpath(path, filename))
        inputs["dfCO2Cap_slack"] = df
        inputs["dfCO2Cap_slack"][!, :PriceCap] ./= scale_factor # Million $/kton if scaled, $/ton if not scaled
    end

    filename = "CO2_cap.csv"
    df = load_dataframe(joinpath(path, filename))

    inputs["dfCO2Cap"] = df
    mat = extract_matrix_from_dataframe(df, "CO_2_Cap_Zone")
    inputs["dfCO2CapZones"] = mat
    inputs["NCO2Cap"] = size(mat, 2)

    capture_prefix = "CO_2_Capture_Max_Mtons"
    capture_columns = find_matrix_columns_in_dataframe(df, capture_prefix)
    if !isempty(capture_columns)
        expected_columns = collect(1:inputs["NCO2Cap"])
        capture_columns == collect(1:length(capture_columns)) ||
            error("$capture_prefix columns must be numbered continuously from 1.")
        capture_columns == expected_columns ||
            error("$capture_prefix columns must match the CO_2_Cap_Zone columns.")

        column_names = capture_prefix .* "_" .* string.(capture_columns)
        for column_name in column_names, (row, value) in enumerate(df[!, column_name])
            ismissing(value) && error("$column_name row $row has a missing capture limit.")
            (value isa Real && isfinite(value) && value >= 0) ||
                error("$column_name row $row must have a finite, nonnegative capture limit.")
        end
        inputs["dfMaxCO2Capture"] = Matrix{Float64}(df[:, column_names]) *
                                     1e6 / scale_factor
    end

    # Emission limits
    if setup["CO2Cap"] == 1
        #  CO2 emissions cap in mass
        # note the default inputs is in million tons
        # when scaled, the constraint unit is kton
        # when not scaled, the constraint unit is ton
        mat = extract_matrix_from_dataframe(df, "CO_2_Max_Mtons")
        inputs["dfMaxCO2"] = mat * 1e6 / scale_factor

    elseif setup["CO2Cap"] == 2 || setup["CO2Cap"] == 3
        #  CO2 emissions rate applied per MWh
        mat = extract_matrix_from_dataframe(df, "CO_2_Max_tons_MWh")
        # no scale_factor is needed since this is a ratio
        inputs["dfMaxCO2Rate"] = mat
    end

    println(filename * " Successfully Read!")
end
