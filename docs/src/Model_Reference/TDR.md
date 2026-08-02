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

Set `SeasonalClustering: 1` to select exactly one representative week from
each meteorological season. This mode requires a single input year containing
52 complete 168-hour periods, `MinPeriods: 4`, `MaxPeriods: 4`, and
`UseExtremePeriods: 0`. Spring uses weeks 9–21, summer 22–34, autumn 35–47,
and winter weeks 48–52 plus 1–8. Clustering is performed independently within
each season, so four-week studies cannot omit a season.

## Demand extreme periods

When a demand extreme period is enabled, GenX preserves its original hourly
peak values. The remaining representative periods are scaled independently by
zone so that their weighted demand plus the unchanged extreme period exactly
reproduces full-resolution annual zonal demand. Thus peak preservation no
longer disables annual-energy conservation.
