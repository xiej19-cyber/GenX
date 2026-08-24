@doc raw"""
	must_run!(EP::Model, inputs::Dict, setup::Dict)

This function defines the constraints for operation of `must-run' or non-dispatchable resources, such as rooftop solar systems that do not receive dispatch signals, run-of-river hydroelectric facilities without the ability to spill water, or cogeneration systems that must produce a fixed quantity of heat in each time step. This resource type can also be used to model baseloaded or self-committed thermal generators that do not respond to economic dispatch.

For must-run resources ($y\in \mathcal{MR}$) output in each time period $t$ must exactly equal the available capacity factor times the installed capacity, not allowing for curtailment. These resources are also not eligible for contributing to frequency regulation or operating reserve requirements.

```math
\begin{aligned}
\Theta_{y,z,t} = \rho^{max}_{y,z,t}\times \Delta^{total}_{y,z}
\hspace{4 cm}  \forall y \in \mathcal{MR}, z \in \mathcal{Z},t \in \mathcal{T}
\end{aligned}
```
"""
function must_run!(EP::Model, inputs::Dict, setup::Dict)
    println("Must-Run Resources Module")

    gen = inputs["RESOURCES"]

    T = inputs["T"]     # Number of time steps (hours)
    Z = inputs["Z"]     # Number of zones
    G = inputs["G"] # Number of generators

    MUST_RUN = inputs["MUST_RUN"]
    CapacityReserveMargin = setup["CapacityReserveMargin"]

    ### Expressions ###

    ## Power Balance Expressions ##
    MUST_RUN_BY_ZONE = map(1:Z) do z
        return intersect(MUST_RUN, resources_in_zone_by_rid(gen, z))
    end
    @expression(EP, ePowerBalanceNdisp[t = 1:T, z = 1:Z],
        sum(EP[:vP][y, t] for y in MUST_RUN_BY_ZONE[z]))
    add_similar_to_expression!(EP[:ePowerBalance], ePowerBalanceNdisp)

    # Capacity Reserves Margin policy
    if CapacityReserveMargin > 0
        nCRMZones = inputs["NCapacityReserveMargin"]
        capresfactor = inputs["DERATING_FACTOR"]
        @expression(EP,
            eCapResMarBalanceMustRun[res = 1:nCRMZones, t = 1:T],
            sum(capresfactor[y, res] * EP[:eTotalCap][y] *
                inputs["pP_Max"][y, t] for y in MUST_RUN))
        add_similar_to_expression!(EP[:eCapResMarBalance], eCapResMarBalanceMustRun)
    end

  # Capacity Reserves Margin peakload policy
    if setup["CRM_peakload"] > 0
        NCRM     = inputs["NCapacityReserveMargin"]
        @expression(EP,
            eCapResMarBalancePeakMustRun[res = 1:NCRM],
            sum(derating_factor(gen[y], tag = res) * EP[:eTotalCap][y] for y in MUST_RUN))
        for res in 1:NCRM
            add_to_expression!(EP[:eCapResMarBalancePeak][res], eCapResMarBalancePeakMustRun[res])
        end
    end

    # Capacity Reserves Margin multihours policy
    if setup["CRM_multihours"] > 0
        NCRM_multi = inputs["NCapacityReserveMargin"]
        selected_hours = inputs["selected_capres_multihours"]

        @expression(EP,
            eCapResMarBalanceMultiMustRun[res = 1:NCRM_multi, t in selected_hours[res]],
            sum(derating_factor(gen[y], tag = res) * EP[:eTotalCap][y]
                for y in MUST_RUN)
        )

        for res in 1:NCRM_multi
            for t in selected_hours[res]
                add_to_expression!(
                    EP[:eCapResMarBalanceMultihour][res, t],
                    eCapResMarBalanceMultiMustRun[res, t]
                )
            end
        end
    end

    ### Constratints ###

    @constraint(EP,
        [y in MUST_RUN, t = 1:T],
        EP[:vP][y, t]==inputs["pP_Max"][y, t] * EP[:eTotalCap][y])
    ##CO2 Polcy Module Must Run Generation by zone
    @expression(EP, eGenerationByMustRun[z = 1:Z, t = 1:T], # the unit is GW
        sum(EP[:vP][y, t] for y in MUST_RUN_BY_ZONE[z]))
    add_similar_to_expression!(EP[:eGenerationByZone], eGenerationByMustRun)
end
