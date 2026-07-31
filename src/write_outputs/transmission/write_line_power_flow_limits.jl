"""
    write_line_power_flow_limits(path, inputs, setup, EP)

Write line power profile bounds, realized flows, violations, and available
dual prices in user-facing MW and USD/MWh units.
"""
function write_line_power_flow_limits(
        path::AbstractString,
        inputs::Dict,
        setup::Dict,
        EP::Model)
    T = inputs["T"]
    lines = inputs["LINE_POWER_LIMIT_LINES"]
    line_ids = inputs["LINE_POWER_LIMIT_LINE_IDS"]
    profile_by_line = inputs["LinePowerProfileIndexByLine"]
    profile_names = inputs["LINE_POWER_LIMIT_PROFILE_NAMES"]
    down_pu = inputs["pLinePowerProfileDown"]
    up_pu = inputs["pLinePowerProfileUp"]
    B = length(lines)
    power_scale = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    has_slack = haskey(inputs, "pLinePowerDownPrice")
    down_violation = has_slack ? value.(EP[:vLinePowerDownViolation]) :
                     zeros(Float64, B, T)
    up_violation = has_slack ? value.(EP[:vLinePowerUpViolation]) :
                   zeros(Float64, B, T)

    network_line = Int[]
    profile_id = String[]
    start_zone = Int[]
    end_zone = Int[]
    time_index = Int[]
    final_capacity_mw = Float64[]
    down_bound_pu = Float64[]
    up_bound_pu = Float64[]
    down_bound_mw = Float64[]
    up_bound_mw = Float64[]
    actual_flow_mw = Float64[]
    margin_above_down_mw = Float64[]
    headroom_to_up_mw = Float64[]
    down_violation_mw = Float64[]
    up_violation_mw = Float64[]

    for b in 1:B
        line = lines[b]
        profile = profile_by_line[b]
        capacity = value(EP[:eAvail_Trans_Cap][line])
        for t in 1:T
            lower = down_pu[t, profile] * capacity
            upper = up_pu[t, profile] * capacity
            flow = value(EP[:vFLOW][line, t])
            push!(network_line, line_ids[b])
            push!(profile_id, profile_names[profile])
            push!(start_zone, inputs["pTrans_Start_Zone"][line])
            push!(end_zone, inputs["pTrans_End_Zone"][line])
            push!(time_index, t)
            push!(final_capacity_mw, capacity * power_scale)
            push!(down_bound_pu, down_pu[t, profile])
            push!(up_bound_pu, up_pu[t, profile])
            push!(down_bound_mw, lower * power_scale)
            push!(up_bound_mw, upper * power_scale)
            push!(actual_flow_mw, flow * power_scale)
            push!(margin_above_down_mw, (flow - lower) * power_scale)
            push!(headroom_to_up_mw, (upper - flow) * power_scale)
            push!(down_violation_mw, down_violation[b, t] * power_scale)
            push!(up_violation_mw, up_violation[b, t] * power_scale)
        end
    end

    balance = DataFrame(
        Network_Line = network_line,
        Profile_ID = profile_id,
        Start_Zone = start_zone,
        End_Zone = end_zone,
        Time_Index = time_index,
        Final_Capacity_MW = final_capacity_mw,
        Down_Bound_pu = down_bound_pu,
        Up_Bound_pu = up_bound_pu,
        Down_Bound_MW = down_bound_mw,
        Up_Bound_MW = up_bound_mw,
        Actual_Flow_MW = actual_flow_mw,
        Margin_Above_Down_MW = margin_above_down_mw,
        Headroom_To_Up_MW = headroom_to_up_mw,
        Down_Violation_MW = down_violation_mw,
        Up_Violation_MW = up_violation_mw,
    )
    CSV.write(joinpath(path, "line_power_flow_balance.csv"), balance)

    if has_duals(EP)
        setup["ObjScale"] > 0 ||
            error("ObjScale must be positive to report line power flow limit prices.")
        lower_price = Float64[]
        upper_price = Float64[]
        price_scale = power_scale / setup["ObjScale"]
        for b in 1:B, t in 1:T
            push!(lower_price,
                dual(EP[:cLinePowerDown][b, t]) / inputs["omega"][t] * price_scale)
            push!(upper_price,
                -dual(EP[:cLinePowerUp][b, t]) / inputs["omega"][t] * price_scale)
        end
        prices = DataFrame(
            Network_Line = network_line,
            Profile_ID = profile_id,
            Start_Zone = start_zone,
            End_Zone = end_zone,
            Time_Index = time_index,
            Lower_Bound_Price_USD_per_MWh = lower_price,
            Upper_Bound_Price_USD_per_MWh = upper_price,
        )
        CSV.write(joinpath(path, "line_power_flow_limit_prices.csv"), prices)
    end
    return balance
end
