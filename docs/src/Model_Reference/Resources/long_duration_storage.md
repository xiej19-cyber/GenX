# Long Duration Storage

Independent long-duration storage uses the ordinary `Storage.csv` formulation. Set
`LDS=1` only for resources that may transfer energy between representative periods;
ordinary batteries that wrap within each representative period should retain `LDS=0`.
Duration is not hard-coded: it is controlled by `Min_Duration`, `Max_Duration`, and the
MW/MWh capacity limits and costs.

When `TimeDomainReduction=0`, GenX automatically constructs the chronological mapping
for either of these manual 168-hour input conventions:

- four weeks ordered spring, summer, autumn, winter; or
- twelve weeks ordered January through December.

The four-week convention assigns 13 complete calendar weeks to each season. The
twelve-week convention assigns each complete week according to its midpoint month.
Both use the standard non-leap-year convention of 52 complete weeks plus the final 24
hours. Other representative-period arrangements require an explicit
`system/Period_map.csv`.

The inter-period LDS approximation links the 52 complete weeks. The remaining 24 hours
are included in annual operating weights and full-time-series output but do not form a
separate partial-week SOC transition. This is the same weekly-horizon convention used
by GenX's existing weekly TDR workflow. Use full chronological inputs when exact SOC
tracking through all 8,760 hours is required.

When the mapping is generated automatically, the resolved mapping is written to
`results/Period_map_used.csv` with the LDS outputs so the assumed chronology can be
audited.

For peak-load capacity reserve margin, independent LDS uses the same exogenous capacity
accreditation as ordinary storage:

```text
accredited MW = final discharge MW × Derating_Factor
```

Set the factor in `resources/policy_assignments/Resource_crm_peakload.csv`. If capacity
payments are enabled, set the independent payment factor separately in
`resources/policy_assignments/Resource_capacity_payment.csv`; payments apply to
accredited discharge MW, not to MWh energy capacity. Example input fragments are in
`example_systems/independent_lds_input_examples`.

```@autodocs
Modules = [GenX]
Pages = ["long_duration_storage.jl"]
```
