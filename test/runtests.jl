using GenX
using Test
using Logging

include("utilities.jl")

@testset "Expr manipulation" begin
    include("expression_manipulation_test.jl")
end

@testset "Minimum commitment" begin
    include("test_minimum_commitment.jl")
end

@testset "Minimum power variability" begin
    include("test_minimum_power_variability.jl")
end

@testset "Line power flow limits" begin
    include("test_line_power_flow_limits.jl")
end

@testset "Capacity payment" begin
    include("test_capacity_payment.jl")
end

@testset "Peak-load capacity reserve margin" begin
    include("test_peakload_capacity_reserve_margin.jl")
end

@testset "Multihour capacity reserve margin" begin
include("test_multihour_capacity_reserve_margin.jl")
include("test_policy_parameter_scaling.jl")
end

if VERSION ≥ v"1.7"
    @testset "Resource loading" begin
        include("test_load_resource_data.jl")
    end
end

# Test GenX modules
@testset verbose=true "GenX modules" begin
    @testset "Three zones" begin
        include("test_threezones.jl")
    end

    @testset "TDR" begin
        include("test_time_domain_reduction.jl")
    end

    @testset "Piecewise Fuel" begin
        include("test_piecewisefuel.jl")
    end

    @testset "VRE_STOR" begin
        include("test_VRE_storage.jl")
    end

    @testset "Electrolyzer" begin
        include("test_electrolyzer.jl")
    end

    @testset "Fusion" begin
        include("test_fusion.jl")
    end

    @testset "Multi Stage" begin
        include("test_multistage.jl")
    end

    @testset "DCOPF" begin
        include("test_DCOPF.jl")
    end

    @testset "Multi Fuels" begin
        include("test_multifuels.jl")
    end

    @testset "Compute Conflicts" begin
        include("test_compute_conflicts.jl")
    end

    @testset "Retrofit" begin
        include("test_retrofit.jl")
    end
end

# Test writing outputs
@testset "Writing outputs " begin
    for test_file in filter!(x -> endswith(x, ".jl"), readdir("writing_outputs"))
        include("writing_outputs/$test_file")
    end
end

# Remove temporary files
isdir(results_path) && rm(results_path, force = true, recursive = true)
