module TestTDR

import GenX
import Test
import JLD2, Clustering, DataFrames

include(joinpath(@__DIR__, "utilities.jl"))

# suppress printing
console_out = stdout
redirect_stdout(devnull)

test_folder = settings_path = "TDR"
TDR_Results_test = joinpath(test_folder, "TDR_results_test")

# Folder with true clustering results for LTS and non-LTS versions
TDR_Results_true = if VERSION == v"1.6.7"
    joinpath(test_folder, "TDR_results_true_LTS")
else
    joinpath(test_folder, "TDR_results_true")
end

# Remove test folder if it exists
if isdir(TDR_Results_test)
    rm(TDR_Results_test, recursive = true)
end

# Inputs for cluster_inputs function
genx_setup = Dict("TimeDomainReduction" => 1,
    "TimeDomainReductionFolder" => "TDR_results_test",
    "UCommit" => 2,
    "CapacityReserveMargin" => 1,
    "MinCapReq" => 1,
    "MaxCapReq" => 1,
    "EnergyShareRequirement" => 1,
    "CO2Cap" => 2)

settings = GenX.default_settings()
merge!(settings, genx_setup)

clustering_test = with_logger(ConsoleLogger(stderr, Logging.Warn)) do
    GenX.cluster_inputs(test_folder, settings_path, settings, random = false)["ClusterObject"]
end

# Load true clustering
clustering_true = JLD2.load(joinpath(TDR_Results_true, "clusters_true.jld2"))["ClusterObject"]

# Clustering validation
R = Clustering.randindex(clustering_test, clustering_true)
I = Clustering.mutualinfo(clustering_test, clustering_true)

# restore printing
redirect_stdout(console_out)

# test clusters
Test.@test round(R[1], digits = 1) == 1   # Adjusted Rand index should be equal to 1
Test.@test round(R[2], digits = 1) == 1   # Rand index should be equal to 1
Test.@test round(I, digits = 1) == 1      # Mutual information should be equal to 1

# test if output files are correct
for file in filter(f -> endswith(f, ".csv") && f != "Demand_data.csv",
    readdir(TDR_Results_true))
    Test.@test cmp_csv(joinpath(TDR_Results_test, file), joinpath(TDR_Results_true, file))
end

# Demand extremes intentionally change demand output relative to the legacy
# golden file. Validate the required invariant instead: weighted annual zonal
# demand must equal the full-resolution input.
raw_demand = GenX.get_demand_dataframe(joinpath(test_folder, "system"))
tdr_demand = GenX.get_demand_dataframe(TDR_Results_test)
num_reps = Int(tdr_demand.Rep_Periods[1])
hours_per_rep = Int(tdr_demand.Timesteps_per_Rep_Period[1])
weights = collect(skipmissing(tdr_demand.Sub_Weights))[1:num_reps]
demand_columns = filter(n -> startswith(n, "Demand_MW_"), names(raw_demand))
for column in demand_columns
    represented_total = sum(
        sum(tdr_demand[(rep - 1) * hours_per_rep + 1:rep * hours_per_rep, column]) *
        weights[rep] / hours_per_rep for rep in 1:num_reps)
    Test.@test represented_total ≈ sum(raw_demand[!, column]) rtol = 1e-10
end

# Constant demand profiles are removed before clustering and must not be used
# when calculating multipliers for the remaining profiles.
cluster_output = DataFrames.DataFrame(Symbol("1") => [1.0, 2.0, 1.0, 1.0])
input_data = DataFrames.DataFrame(Demand_MW_z1 = [1.0, 2.0, 1.0, 2.0])
demand_mults = GenX.get_demand_multipliers(cluster_output,
    input_data,
    [1],
    [2.0],
    [:Demand_MW_z1, :Demand_MW_z2],
    2,
    [:Demand_MW_z1, :GrpWeight],
    1,
    2)
Test.@test demand_mults == Dict(:Demand_MW_z1 => 2.0)

# A demand extreme remains unscaled while non-extreme periods are calibrated
# to preserve the original annual energy exactly.
extreme_cluster_output = DataFrames.DataFrame(
    Symbol("1") => [1.0, 1.0],
    Symbol("2") => [4.0, 4.0],
)
extreme_input = DataFrames.DataFrame(Demand_MW_z1 = fill(2.0, 8))
extreme_mults = GenX.get_demand_multipliers_preserving_extremes(
    extreme_cluster_output,
    extreme_input,
    [1, 2],
    [6.0, 2.0],
    [:Demand_MW_z1],
    2,
    [:Demand_MW_z1, :GrpWeight],
    2,
    1,
    [2],
)
Test.@test extreme_mults[:Demand_MW_z1][2] == 1.0
Test.@test extreme_mults[:Demand_MW_z1][1] ≈ 4 / 3
weighted_demand = 6 / 2 * sum([1.0, 1.0] .* extreme_mults[:Demand_MW_z1][1]) +
                  2 / 2 * sum([4.0, 4.0] .* extreme_mults[:Demand_MW_z1][2])
Test.@test weighted_demand ≈ sum(extreme_input.Demand_MW_z1)

# Four-week seasonal clustering always retains one representative from each
# meteorological season and maps every source week to its own season.
seasonal_input = DataFrames.DataFrame(
    Dict(Symbol(i) => [Float64(i), Float64(i % 7)] for i in 1:52),
)
_, seasonal_assignments, seasonal_weights, seasonal_reps, _ =
    GenX.cluster_four_seasons(seasonal_input, "kmeans", 2, false, false)
season_ranges = [Set(9:21), Set(22:34), Set(35:47), Set([48:52; 1:8])]
Test.@test length(seasonal_reps) == 4
Test.@test all(seasonal_reps[s] in season_ranges[s] for s in 1:4)
Test.@test seasonal_weights == [13, 13, 13, 13]
Test.@test all(seasonal_assignments[p] == s
    for s in 1:4 for p in season_ranges[s])

_, seasonal12_assignments, seasonal12_weights, seasonal12_reps, _ =
    GenX.cluster_four_seasons(
        seasonal_input, "kmeans", 2, false, false; periods_per_season = 3)
Test.@test length(seasonal12_reps) == 12
Test.@test sum(seasonal12_weights) == 52
Test.@test all(count(r -> r in season_ranges[s], seasonal12_reps) == 3 for s in 1:4)
Test.@test all(seasonal12_assignments[p] in (3 * (s - 1) + 1):(3 * s)
    for s in 1:4 for p in season_ranges[s])

normalized_profiles = DataFrames.DataFrame(
    Demand_MW_z1 = [0.0, 1.0],
    wind_a = [0.0, 1.0],
    wind_b = [1.0, 0.0],
    solar_a = [0.2, 0.8],
)
aggregated_profiles = GenX.aggregate_profiles_for_clustering(
    normalized_profiles,
    ["Demand_MW_z1"],
    ["wind_a", "wind_b", "solar_a"],
    ["solar_a"],
    ["wind_a", "wind_b"],
    String[],
    Dict("wind_a" => 1, "wind_b" => 1, "solar_a" => 1),
)
Test.@test Set(names(aggregated_profiles)) ==
           Set(["Demand_MW_z1", "TDR_Wind_z1", "TDR_Solar_z1"])
Test.@test aggregated_profiles.TDR_Wind_z1 == [0.5, 0.5]

# Selected variability profiles are bounded and reproduce full-resolution
# annual available hours after applying representative-period weights.
raw_variability = DataFrames.DataFrame(
    Wind = [0.1, 0.2, 0.7, 0.8, 0.4, 0.5, 0.9, 1.0],
    Solar = [0.0, 0.2, 0.8, 0.0, 0.1, 0.3, 0.9, 0.1],
)
selected_variability = raw_variability[[1, 2, 5, 6], :]
variability_diagnostics = GenX.calibrate_tdr_variability!(
    selected_variability, raw_variability, [4.0, 4.0], 2)
variability_omega = repeat([2.0, 2.0]; inner = 2)
for column in names(raw_variability)
    Test.@test sum(selected_variability[!, column] .* variability_omega) ≈
               sum(raw_variability[!, column]) atol = 1e-8
    Test.@test all(x -> 0 <= x <= 1, selected_variability[!, column])
end
Test.@test nrow(variability_diagnostics) == 2

end # module TestTDR
