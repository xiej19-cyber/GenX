# Reusable Line Power Flow Limits

`LinePowerFlowLimits` applies time-dependent signed flow bounds to selected
transmission lines. A line references a reusable profile \(p(l)\) through
`Line_Power_Profile_ID` in `Network.csv`. The profile file supplies constant
per-unit lower and upper curves.

For each constrained line \(l\) and time step \(t\),

```math
\alpha^{down}_{p(l),t} C_l^{Final}
\leq \Phi_{l,t} \leq
\alpha^{up}_{p(l),t} C_l^{Final},
```

where \(\Phi_{l,t}\) is `vFLOW[l,t]` and \(C_l^{Final}\) is
`eAvail_Trans_Cap[l]`. The final capacity equals existing capacity plus any
optimized reinforcement, so the formulation remains linear: each
\(\alpha\) is input data. Positive flow follows `Start_Zone` to `End_Zone`.

The ordinary physical limits
\(-C_l^{Final}\leq\Phi_{l,t}\leq C_l^{Final}\) remain active. A zero-capacity
line therefore has zero absolute profile bounds, and the profile does not
force construction. `LineMinCF` also remains active when configured.

## Optional violations

If `Line_power_flow_limits_slack.csv` is present, the constraints become

```math
\Phi_{l,t}+s^{down}_{l,t}
\geq\alpha^{down}_{p(l),t}C_l^{Final},
```

```math
\Phi_{l,t}-s^{up}_{l,t}
\leq\alpha^{up}_{p(l),t}C_l^{Final},
```

with nonnegative violations. The objective adds

```math
\sum_{l,t}\omega_t
\left(\pi^{down}_l s^{down}_{l,t}
+\pi^{up}_l s^{up}_{l,t}\right).
```

Profile curves are reusable, but violation prices are assigned by
`Network_Lines`.

## Scope

The first implementation supports single-stage models. Enabling this policy
with `MultiStage = 1` is rejected. With TDR, profiles use the selected
representative rows but do not affect clustering.

```@docs
GenX.load_line_power_flow_limits!
GenX.line_power_flow_limits!
GenX.write_line_power_flow_limits
```
