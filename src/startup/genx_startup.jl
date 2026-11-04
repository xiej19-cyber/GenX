function print_genx_version()
    v = pkgversion(GenX)
    ascii_art = raw"""
     ____           __  __   _ _
    / ___| ___ _ __ \ \/ /  (_) |
   | |  _ / _ \ '_ \ \  /   | | |
   | |_| |  __/ | | |/  \ _ | | |
    \____|\___|_| |_/_/\_(_)/ |_|
                          |__/
    """
    ascii_art *= "Version: $(v)"
    println(ascii_art)
    return nothing
end

# This function is a workaround for Julia versions < 1.9.
function pkgversion(m::Module)
    if VERSION >= v"1.9"
        return Base.pkgversion(m)
    else
        _pkgdir = pkgdir(m)
        _pkgdir === nothing && return nothing
        project_file = joinpath(_pkgdir, "Project.toml")
        isa(project_file, String) && return get_project_version(project_file)
        return nothing
    end
end

function get_project_version(project_file::String)
    d = Base.parsed_toml(project_file)
    v = get(d, "version", nothing)
    isnothing(v) && return nothing
    return VersionNumber(v::AbstractString)
end

"""
    precompile()

Precompiles the functions `run_genx_case!` and `cluster_inputs` with specific 
arguments. This function is intended to speed up the first use of GenX in a 
new Julia session by precompiling it. 

The function redirects standard output to `devnull` to suppress any output 
generated during the precompilation process, and sets up a logger to capture 
any warnings or errors.

# Output
Returns `nothing`.

"""
function _precompile()
    @info "Running precompile script for GenX. This may take a few minutes."
    @info "If you want to skip this step, please set the environment variable " *
        "`GENX_PRECOMPILE` to `false` before running `using GenX`. \n" *
        "Example: `ENV[\"GENX_PRECOMPILE\"] = \"false\"`."
    redirect_stdout(devnull) do
        warnerror_logger = ConsoleLogger(stderr, Logging.Warn)
        with_logger(warnerror_logger) do
            @compile_workload begin
                mktempdir() do workdir
                    case = joinpath(workdir, "case")
                    cp(joinpath(pkgdir(GenX), "precompile/case"), case)
                    # Older bundled fixtures predate explicit throughput prices.
                    for filename in ("Storage.csv", "Vre_stor.csv")
                        file = joinpath(case, "resources", filename)
                        isfile(file) || continue
                        data = CSV.read(file, DataFrame)
                        for column in (:Charge_Cost_per_MWh, :Discharge_Cost_per_MWh)
                            column in propertynames(data) ||
                                (data[!, column] = zeros(nrow(data)))
                        end
                        CSV.write(file, data)
                    end
                    # TDR is optional and is not part of the import-time workload.
                    run_genx_case!(case, HiGHS.Optimizer)
                end
            end
        end
    end
    return nothing
end

# Precompile `run_genx_case!` and `TDR` unless the environment variable `GENX_PRECOMPILE` is set to `false`
if get(ENV, "GENX_PRECOMPILE", "false") != "false"
    _precompile()
end
