"""
    line_power_flow_limits!(EP, inputs, setup)

Constrain selected signed transmission flows to reusable per-unit lower and
upper profiles multiplied by each line's final planned capacity.
"""
function line_power_flow_limits!(EP::Model, inputs::Dict, setup::Dict)
    println("Line Power Flow Limits Policy Module")
    T = inputs["T"]
    lines = inputs["LINE_POWER_LIMIT_LINES"]
    profile_by_line = inputs["LinePowerProfileIndexByLine"]
    down = inputs["pLinePowerProfileDown"]
    up = inputs["pLinePowerProfileUp"]
    B = length(lines)

    if haskey(inputs, "pLinePowerDownPrice")
        @variable(EP, vLinePowerDownViolation[b = 1:B, t = 1:T]>=0)
        @variable(EP, vLinePowerUpViolation[b = 1:B, t = 1:T]>=0)
        @constraint(EP,
            cLinePowerDown[b = 1:B, t = 1:T],
            EP[:vFLOW][lines[b], t] + vLinePowerDownViolation[b, t] >=
            down[t, profile_by_line[b]] * EP[:eAvail_Trans_Cap][lines[b]])
        @constraint(EP,
            cLinePowerUp[b = 1:B, t = 1:T],
            EP[:vFLOW][lines[b], t] - vLinePowerUpViolation[b, t] <=
            up[t, profile_by_line[b]] * EP[:eAvail_Trans_Cap][lines[b]])
        @expression(EP,
            eCLinePowerFlowLimitViolation[b = 1:B, t = 1:T],
            inputs["omega"][t] *
            (inputs["pLinePowerDownPrice"][b] * vLinePowerDownViolation[b, t] +
             inputs["pLinePowerUpPrice"][b] * vLinePowerUpViolation[b, t]))
        @expression(EP,
            eCTotalLinePowerFlowLimitViolation,
            sum(eCLinePowerFlowLimitViolation[b, t] for b in 1:B, t in 1:T))
        add_to_expression!(EP[:eObj], eCTotalLinePowerFlowLimitViolation)
    else
        @constraint(EP,
            cLinePowerDown[b = 1:B, t = 1:T],
            EP[:vFLOW][lines[b], t] >=
            down[t, profile_by_line[b]] * EP[:eAvail_Trans_Cap][lines[b]])
        @constraint(EP,
            cLinePowerUp[b = 1:B, t = 1:T],
            EP[:vFLOW][lines[b], t] <=
            up[t, profile_by_line[b]] * EP[:eAvail_Trans_Cap][lines[b]])
    end
    return nothing
end

function line_power_flow_limit_penalty_cost(inputs::Dict, EP::Model)
    haskey(inputs, "pLinePowerDownPrice") ||
        return 0.0
    return value(EP[:eCTotalLinePowerFlowLimitViolation])
end
