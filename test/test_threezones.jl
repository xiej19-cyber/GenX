module TestThreeZones

using Test

include(joinpath(@__DIR__, "utilities.jl"))

obj_true = 6960.20855
test_path = "three_zones"

# Define test inputs
genx_setup = Dict("NetworkExpansion" => 1,
    "Trans_Loss_Segments" => 1,
    "CO2Cap" => 2,
    "StorageLosses" => 1,
    "MinCapReq" => 1,
    "ParameterScale" => 1,
    "UCommit" => 2)

# Run the case and get the objective value and tolerance
EP, inputs, optimizer = redirect_stdout(devnull) do
    run_genx_case_testing(test_path, genx_setup)
end
obj_test = objective_value(EP)
optimal_tol_rel = get_attribute(EP, "ipm_optimality_tolerance")
optimal_tol = optimal_tol_rel * obj_test  # Convert to absolute tolerance

# Test the objective value
test_result = @test obj_test≈obj_true atol=optimal_tol

# Round objective value and tolerance. Write to test log.
obj_test = round_from_tol!(obj_test, optimal_tol)
optimal_tol = round_from_tol!(optimal_tol, optimal_tol)
write_testlog(test_path, obj_test, optimal_tol, test_result)

# OperationalReserves = 2 creates an independent reserve balance for every zone.
zonal_setup = GenX.default_settings()
merge!(zonal_setup, genx_setup, Dict("OperationalReserves" => 2))
EP_zonal, zonal_inputs = redirect_stdout(devnull) do
    case_inputs = load_inputs(zonal_setup, test_path)
    generate_model(zonal_setup, case_inputs, optimizer), case_inputs
end
reserve_zones = zonal_inputs["OPERATIONAL_RESERVE_ZONES"]
@test reserve_zones == [2, 3]
@test zonal_inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"] == [1, 2]
@test size(EP_zonal[:eRegReq]) == (length(reserve_zones), zonal_inputs["T"])
@test size(EP_zonal[:eRsvReq]) == (length(reserve_zones), zonal_inputs["T"])
@test size(EP_zonal[:vUNMET_RSV]) == (length(reserve_zones), zonal_inputs["T"])
@test size(EP_zonal[:cReg]) == (length(reserve_zones), zonal_inputs["T"])
@test size(EP_zonal[:cRsvReq]) == (length(reserve_zones), zonal_inputs["T"])
for y in zonal_inputs["RSV"], z in reserve_zones
    expected = GenX.zone_id(zonal_inputs["RESOURCES"][y]) == z ? 1.0 : 0.0
    @test normalized_coefficient(EP_zonal[:cRsvReq][z, 1], EP_zonal[:vRSV][y, 1]) == expected
end
@test size(EP_zonal[:vRSV_TRANSFER]) == (2, zonal_inputs["T"])
@test size(EP_zonal[:cReserveTransferHeadroom]) == (2, zonal_inputs["T"])
@test normalized_coefficient(EP_zonal[:cRsvReq][2, 1], EP_zonal[:vRSV_TRANSFER][1, 1]) ==
      1 - zonal_inputs["pPercent_Loss"][1]
@test normalized_coefficient(EP_zonal[:cRsvReq][3, 1], EP_zonal[:vRSV_TRANSFER][2, 1]) ==
      1 - zonal_inputs["pPercent_Loss"][2]
for y in zonal_inputs["REG"], z in reserve_zones
    expected = GenX.zone_id(zonal_inputs["RESOURCES"][y]) == z ? 1.0 : 0.0
    @test normalized_coefficient(EP_zonal[:cReg][z, 1], EP_zonal[:vREG][y, 1]) == expected
end

# Custom reserve regions may aggregate physical zones and assign resources independently
# of their model zone.
mktempdir() do temp_dir
    custom_case = joinpath(temp_dir, "three_zones")
    cp(joinpath(@__DIR__, "three_zones"), custom_case)
    fixture = joinpath(@__DIR__, "custom_operational_reserve")
    cp(joinpath(fixture, "Operational_reserves.csv"),
        joinpath(custom_case, "system", "Operational_reserves.csv"); force = true)
    cp(joinpath(fixture, "Resource_operational_reserve.csv"),
        joinpath(custom_case, "resources", "policy_assignments",
            "Resource_operational_reserve.csv"); force = true)
    custom_inputs = redirect_stdout(devnull) do
        load_inputs(zonal_setup, custom_case)
    end
    custom_EP = redirect_stdout(devnull) do
        generate_model(zonal_setup, custom_inputs, optimizer)
    end
    @test custom_inputs["OPERATIONAL_RESERVE_REGIONS"] == [1, 2]
    @test custom_inputs["OPERATIONAL_RESERVE_REGION_ZONES"] == Dict(1 => [1, 2], 2 => [3])
    @test custom_inputs["pReg_Req_Demand_By_Zone"] == [0.01, 0.02, 0.03]
    @test custom_inputs["pRsv_Req_Demand_By_Zone"] == [0.033, 0.043, 0.053]
    @test custom_inputs["OPERATIONAL_RESERVE_TRANSFER_LINES"] == [2]
    ma_gas = findfirst(==("MA_natural_gas_combined_cycle"),
        custom_inputs["RESOURCE_NAMES"])
    @test custom_inputs["OPERATIONAL_RESERVE_RESOURCE_REGION"][ma_gas] == 2
    @test normalized_coefficient(custom_EP[:cRsvReq][2, 1],
        custom_EP[:vRSV][ma_gas, 1]) == 0
    @test normalized_coefficient(custom_EP[:cRsvReq][2, 1],
        custom_EP[:vRSV_TRANSFER][2, 1]) == 1 - custom_inputs["pPercent_Loss"][2]
    @test normalized_coefficient(custom_EP[:cRsvTransferSupply][(1, 2), 1],
        custom_EP[:vRSV][ma_gas, 1]) == -1
end

end # module TestThreeZones
