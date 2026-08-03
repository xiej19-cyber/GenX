# Time Domain Reduction (TDR)

```@autodocs
Modules = [GenX]
Pages = ["time_domain_reduction.jl"]
Order = [:type, :function]
```

```@docs
GenX.run_timedomainreduction!
```

```@docs
GenX.full_time_series_reconstruction
```

## Four-season representative weeks

Set `SeasonalClustering: 1` to allocate the same number of representative weeks
to each meteorological season. This mode requires a single input year with 52
complete 168-hour periods, equal `MinPeriods` and `MaxPeriods`, a total period
count divisible by four, and `UseExtremePeriods: 0`. Set `PeriodsPerSeason: 1`
for four weeks, `2` for eight weeks, or `3` for twelve weeks. Spring uses weeks
9–21, summer 22–34, autumn 35–47, and winter weeks 48–52 plus 1–8.
Clustering is performed independently within each season.

Set `AggregateProfilesForClustering: 1` (the default) to average project-level
generator profiles by zone and technology class before selecting periods.
Demand and fuel profiles remain individual clustering features. This prevents
zones with many candidate projects from receiving unintended extra weight.
The aggregation is used only for clustering; all original project-level GV
columns are retained in the generated TDR input.

Set `PreserveAnnualCapacityFactors: 1` (the default) to calibrate every
selected generator-variability profile so its weighted annual available hours
equal the full-resolution input. Calibration uses a bounded multiplicative
factor and clips values at one, preserving the selected weeks' shape without
creating invalid capacity factors. TDR writes
`Generators_variability_diagnostics.csv` with the original, pre-calibration,
and post-calibration available hours and the applied multiplier for every
profile. Set the option to zero only when the unadjusted selected weeks are
explicitly desired.

## Demand extreme periods

When a demand extreme period is enabled, GenX preserves its original hourly
peak values. The remaining representative periods are scaled independently by
zone so that their weighted demand plus the unchanged extreme period exactly
reproduces full-resolution annual zonal demand. Thus peak preservation no
longer disables annual-energy conservation.
