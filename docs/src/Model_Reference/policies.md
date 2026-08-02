# Emission mitigation policies
## Capacity Reserve Margin
```@docs
GenX.cap_reserve_margin!
```

## CO$_2$ Constraint Policy
```@docs
GenX.co2_cap!
```

## Energy Share Requirement
```@docs
GenX.load_energy_share_requirement!
GenX.energy_share_requirement!
```

## Minimum Capacity Requirement
```@docs
GenX.minimum_capacity_requirement!
```

## Maximum Capacity Requirement
```@autodocs
Modules = [GenX]
Pages = ["maximum_capacity_requirement.jl"]
```

## Hydrogen Production Demand Requirement (Electrolyzer)
```@docs
GenX.hydrogen_demand!
```

## Additional Policy Constraints
```@docs
GenX.minimum_generation_fraction!
GenX.capacity_payment!
GenX.minimum_capacity_factor_requirement!
GenX.minimum_utilizationrate!
GenX.cap_reserve_margin_multihours!
GenX.minimum_capacity_requirement_simple!
GenX.maximum_capacity_requirement_simple!
```

## Hourly clean supply matching constraint
```@autodocs
Modules = [GenX]
Pages = ["hourly_matching.jl"]
```
