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
GenX.manual_representative_week_full_time_series
GenX.manual_four_week_full_time_series
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

Set `PreserveAnnualCapacityFactors: 0` (the default). TDR extracts every
`Generators_variability.csv` column from the selected raw rows without scaling
or clipping. This preserves CSP inflows above one, thermal `MinVar` profiles,
and relationships between shared profiles. A value of `1` is rejected rather
than silently changing these inputs. The standalone calibration helper is not
used by the TDR output path. Weighted annual availability can therefore differ
from the full-year input and must be validated after selection.

`RandomSeed` optionally fixes the random stream for reproducible clustering.
`MinPeriods` counts both ordinary and extreme periods; it must exceed the
number of distinct selected extremes so an ordinary cluster remains.

Only complete candidate periods are clustered. With 8,760 hours and 168-hour
periods, the final 24 hours are not candidate periods; TDR warns about this.
An explicitly requested extreme in this incomplete period raises an actionable
error. Rescaling `WeightTotal` to 8,760 does not preserve that day's chronology.
