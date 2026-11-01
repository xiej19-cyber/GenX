using GenX
using Gurobi

length(ARGS) == 1 || error("Usage: julia --project=/path/to/GenX run_one.jl CASE_DIR")
case = abspath(ARGS[1])
settings = joinpath(case, "settings")
setup = GenX.configure_settings(
    joinpath(settings, "genx_settings.yml"),
    joinpath(settings, "output_settings.yml"),
)

# Force Gurobi without modifying a case's own settings or Run.jl.
setup["Solver"] = "gurobi"
if setup["MultiStage"] == 0
    GenX.run_genx_case_simple!(case, setup, Gurobi.Optimizer)
else
    GenX.run_genx_case_multistage!(case, setup, Gurobi.Optimizer)
end
