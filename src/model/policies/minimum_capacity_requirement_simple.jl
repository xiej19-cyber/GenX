@doc raw"""
	minimum_capacity_requirement_simple!(EP::Model, inputs::Dict, setup::Dict)
The minimum capacity requirement constraint allows for modeling minimum deployment of a certain technology or set of eligible technologies across the eligible model zones and can be used to mimic policies supporting specific technology build out (i.e. capacity deployment targets/mandates for storage, offshore wind, solar etc.). The default unit of the constraint is in MW. For each requirement $p \in \mathcal{P}^{MaxCapReq}$, we model the policy with the following constraint.
```math
\begin{aligned}
\sum_{y \in \mathcal{G} } \sum_{z \in \mathcal{Z} } \left( \epsilon_{y,z,p}^{MaxCapReq} \times \Delta^{\text{total}}_{y,z} \right) \leq REQ_{p}^{MaxCapReq} \hspace{1 cm}  \forall p \in \mathcal{P}^{MaxCapReq}
\end{aligned}
```
Note that $\epsilon_{y,z,p}^{MaxCapReq}$ is the eligiblity of a generator of technology $y$ in zone $z$ of requirement $p$ and will be equal to $1$ for eligible generators and will be zero for ineligible resources. The dual value of each maximum capacity constraint can be interpreted as the required payment (e.g. subsidy) per MW per year required to ensure adequate revenue for the qualifying resources.
"""
function minimum_capacity_requirement_simple!(EP::Model, inputs::Dict, setup::Dict)
    println("Minimum Capacity Requirement Module Simple Version")
    NumberOfMinCapSpReqs = inputs["NumberOfSimpleMinCapReqs"]

    # if input files are present, add maximum capacity requirement slack variables
    if haskey(inputs, "MinCapSpPriceCap")
        @variable(EP, vMinCapSp_slack[mincap = 1:NumberOfMinCapSpReqs]>=0)
        add_similar_to_expression!(EP[:eMinCapResSp], 1.0, vMinCapSp_slack)

        @expression(EP,
            eCMinCapSp_slack[mincap = 1:NumberOfMinCapSpReqs],
            inputs["MinCapSpPriceCap"][mincap]*EP[:vMinCapSp_slack][mincap])
        @expression(EP,
            eTotalCMinCapSpSlack,
            sum(EP[:eCMinCapSp_slack][mincap] for mincap in 1:NumberOfMinCapSpReqs))

        add_to_expression!(EP[:eObj], eTotalCMinCapSpSlack)
    end

    @constraint(EP,
        cZoneMinCapReqSp[mincap = 1:NumberOfMinCapSpReqs],
        EP[:eMinCapResSp][mincap]>=inputs["MinCapReqSp"][mincap])
end
