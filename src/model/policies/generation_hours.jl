@doc raw"""
    maximum_generation_hours!(EP::Model, inputs::Dict)

Limit the capacity-weighted average annual generation hours of each tagged resource
group. For every policy group ``p``, this imposes
```math
\sum_{y \in \mathcal{G}_p}\sum_t \omega_t P_{y,t}
\leq H_p^{max}\sum_{y \in \mathcal{G}_p} Cap_y.
```
"""
function maximum_generation_hours!(EP::Model, inputs::Dict)
    println("Maximum Generation Hours Policy Module")
    n_reqs = inputs["NumberOfMaxGenHoursReqs"]
    resources_by_req = inputs["MaxGenHoursResources"]
    T = inputs["T"]

    @expression(EP, eMaxGenHoursAnnualGeneration[p = 1:n_reqs],
        sum(inputs["omega"][t] * EP[:vP][y, t]
        for y in resources_by_req[p], t in 1:T))
    @expression(EP, eMaxGenHoursTotalCapacity[p = 1:n_reqs],
        sum(EP[:eTotalCap][y] for y in resources_by_req[p]))
    @constraint(EP, cMaxGenHours[p = 1:n_reqs],
        eMaxGenHoursAnnualGeneration[p] <=
        inputs["MaxGenHoursValues"][p] * eMaxGenHoursTotalCapacity[p])
    return nothing
end

@doc raw"""
    minimum_generation_hours!(EP::Model, inputs::Dict)

Set a floor on the capacity-weighted average annual generation hours of each tagged
resource group. For every policy group ``p``, this imposes
```math
\sum_{y \in \mathcal{G}_p}\sum_t \omega_t P_{y,t}
\geq H_p^{min}\sum_{y \in \mathcal{G}_p} Cap_y.
```
"""
function minimum_generation_hours!(EP::Model, inputs::Dict)
    println("Minimum Generation Hours Policy Module")
    n_reqs = inputs["NumberOfMinGenHoursReqs"]
    resources_by_req = inputs["MinGenHoursResources"]
    T = inputs["T"]

    @expression(EP, eMinGenHoursAnnualGeneration[p = 1:n_reqs],
        sum(inputs["omega"][t] * EP[:vP][y, t]
        for y in resources_by_req[p], t in 1:T))
    @expression(EP, eMinGenHoursTotalCapacity[p = 1:n_reqs],
        sum(EP[:eTotalCap][y] for y in resources_by_req[p]))
    @constraint(EP, cMinGenHours[p = 1:n_reqs],
        eMinGenHoursAnnualGeneration[p] >=
        inputs["MinGenHoursValues"][p] * eMinGenHoursTotalCapacity[p])
    return nothing
end
