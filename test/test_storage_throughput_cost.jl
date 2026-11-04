using Test, JuMP, HiGHS, CSV, DataFrames

function throughput_resource(name="Storage"; inverter=0.8, charge=0.0, discharge=0.0)
    constructor = name=="Co-located" ? GenX.VreStorage : GenX.Storage
    constructor(Dict{Symbol,Any}(:resource=>name, :zone=>1, :etainverter=>inverter, :charge_cost_per_mwh=>charge, :discharge_cost_per_mwh=>discharge))
end

@testset "Resource-table throughput prices" begin
    setup=GenX.default_settings()
    for scale in [1.0,1000.0]
        data=DataFrame(charge_cost_per_mwh=[0.1,0.3],discharge_cost_per_mwh=[0.2,0.4])
        GenX.validate_storage_throughput_columns(data,GenX.Storage)
        GenX.scale_resources_data!(data,scale)
        @test data.charge_cost_per_mwh≈[0.1,0.3]/scale
        @test data.discharge_cost_per_mwh≈[0.2,0.4]/scale
    end
    x=Dict{String,Any}("G"=>2,"STOR_ALL"=>[1,2],"RESOURCES"=>[
        throughput_resource("A";charge=0.1,discharge=0.2),throughput_resource("B";charge=0.3,discharge=0.4)])
    @test GenX.storage_throughput_rates(x,setup)==([0.1,0.3],[0.2,0.4])
    for bad in [-1,Inf,NaN,missing,true,"0.1"]
        df=DataFrame(charge_cost_per_mwh=[bad],discharge_cost_per_mwh=[0.0])
        @test_throws ErrorException GenX.validate_storage_throughput_columns(df,GenX.Storage)
    end
    x["RESOURCES"][1].charge_cost_per_mwh=0.0
    x["RESOURCES"][1].discharge_cost_per_mwh=0.0
    @test first(GenX.storage_throughput_rates(x,setup))[1]==0.0
    delete!(parent(x["RESOURCES"][1]),:charge_cost_per_mwh)
    @test_throws ErrorException GenX.load_storage_throughput_cost!(setup,"",x)
    @test GenX.storage_throughput_rates(Dict{String,Any}(),setup)==(Float64[],Float64[])
end

@testset "Actual storage throughput fee" begin
    @test !haskey(GenX.default_settings(), "StorageThroughputCost")
    for bad in [-1, Inf, NaN, "1", true]
        @test_throws ErrorException GenX.validated_storage_throughput_price(bad, "test")
    end
    for scaled in [0,1]
        f=scaled==1 ? GenX.ModelScalingFactor : 1.0
        s=GenX.default_settings();s["ParameterScale"]=scaled
        x=Dict{String,Any}("G"=>3,"T"=>1,"omega"=>[3.0],
            "RESOURCES"=>[throughput_resource("Standalone";charge=1/f,discharge=2/f),throughput_resource("Co-located";charge=1/f,discharge=2/f),throughput_resource("Not storage")],
            "STOR_ALL"=>[1],"VS_STOR"=>[2],"VS_STOR_DC_CHARGE"=>[2],
            "VS_STOR_DC_DISCHARGE"=>[2],"VS_STOR_AC_CHARGE"=>[2],"VS_STOR_AC_DISCHARGE"=>[2])
        m=Model(HiGHS.Optimizer);set_silent(m);m[:eObj]=AffExpr(0.0)
        @variable(m,vP[1:3,1:1]>=0);@variable(m,vCHARGE[1:1,1:1]>=0)
        @variable(m,vP_DC_CHARGE[2:2,1:1]>=0);@variable(m,vP_DC_DISCHARGE[2:2,1:1]>=0)
        @variable(m,vP_AC_CHARGE[2:2,1:1]>=0);@variable(m,vP_AC_DISCHARGE[2:2,1:1]>=0)
        fix(vCHARGE[1,1],10/f;force=true);fix(vP[1,1],8/f;force=true)
        fix(vP[2,1],100/f;force=true);fix(vP[3,1],100/f;force=true)
        for (variable,amount) in [(vP_DC_CHARGE,8),(vP_DC_DISCHARGE,2),(vP_AC_CHARGE,4),(vP_AC_DISCHARGE,3)]
            fix(variable[2,1],amount/f;force=true)
        end
        GenX.storage_throughput_cost!(m,x,s)
        @objective(m,Min,m[:eObj]);optimize!(m)
        @test termination_status(m)==MOI.OPTIMAL
        @test value(m[:eStorageThroughputCost][1])*f^2 ≈ 78
        @test value(m[:eStorageThroughputCost][2])*f^2 ≈ 69.6
        @test value(m[:eStorageThroughputCost][3]) == 0
        @test objective_value(m)*f^2 ≈ 147.6
        mktempdir() do dir
            GenX.write_storage_throughput(dir,x,s,m)
            df=CSV.read(joinpath(dir,"storage_throughput.csv"),DataFrame)
            @test df.Resource==["Standalone","Co-located"]
            @test df.Charge_MWh ≈ [30,42]
            @test df.Discharge_MWh ≈ [24,13.8]
            @test df.Overlap_MWh ≈ [24,13.8]
            @test sum(df.ThroughputCost) ≈ 147.6
        end
    end
end

function cycle_toy(rate; arbitrage=false)
    s=GenX.default_settings()
    n=arbitrage ? 2 : 1
    x=Dict{String,Any}("G"=>1,"T"=>n,"omega"=>ones(n),
        "RESOURCES"=>[throughput_resource(;charge=rate,discharge=rate)],"STOR_ALL"=>[1],"STOR_SYMMETRIC"=>[1])
    m=Model(HiGHS.Optimizer);set_silent(m);m[:eObj]=AffExpr(0.0)
    @variable(m,vP[1:1,1:n]>=0);@variable(m,vCHARGE[1:1,1:n]>=0)
    @variable(m,soc[1:n]>=0);@variable(m,renewable[1:n]>=0);@variable(m,peaker[1:n]>=0)
    m[:eTotalCap]=[2000.0];GenX.storage_symmetric!(m,x,s)
    for t in 1:n
        @constraint(m,soc[t]==soc[mod1(t-1,n)]+0.9*vCHARGE[1,t]-vP[1,t]/0.9)
        @constraint(m,soc[t]<=2000)
        @constraint(m,renewable[t]<= (t==1 ? 200.0 : 0.0))
        @constraint(m,renewable[t]+peaker[t]+vP[1,t]-vCHARGE[1,t]==(arbitrage && t==2 ? 100.0 : 0.0))
    end
    # A tiny generation preference exposes the otherwise arbitrary zero-cost cycle.
    add_to_expression!(m[:eObj],-0.01,sum(renewable))
    add_to_expression!(m[:eObj],1000.0,sum(peaker))
    GenX.storage_throughput_cost!(m,x,s)
    @objective(m,Min,m[:eObj]);optimize!(m)
    @test termination_status(m)==MOI.OPTIMAL
    return (charge=sum(value.(vCHARGE)),discharge=sum(value.(vP)),peaker=sum(value.(peaker)),
        overlap=sum(min(value(vCHARGE[1,t]),value(vP[1,t])) for t in 1:n))
end

@testset "Fee removes wasteful cycling but retains useful shifting" begin
    free=cycle_toy(0.0);paid=cycle_toy(1.0)
    @test free.overlap>100
    @test paid.charge≈0 atol=1e-6
    @test paid.discharge≈0 atol=1e-6
    low=cycle_toy(0.1)
    @test low.charge≈0 atol=1e-6
    @test low.discharge≈0 atol=1e-6
    useful=cycle_toy(1.0;arbitrage=true)
    @test useful.discharge≈100 atol=1e-6
    @test useful.charge≈100/0.81 atol=1e-6
    @test useful.overlap≈0 atol=1e-6
    @test useful.peaker≈0 atol=1e-6
end

@testset "Generation model and cost reports include throughput once" begin
    setup=GenX.default_settings()
    setup["ParameterScale"]=1
    setup["NetworkExpansion"]=1;setup["UCommit"]=2
    inputs=GenX.load_inputs(setup,joinpath(@__DIR__,"VRE_storage","solar"))
    for y in union(inputs["STOR_ALL"],inputs["VS_STOR"])
        inputs["RESOURCES"][y].charge_cost_per_mwh=1/GenX.ModelScalingFactor
        inputs["RESOURCES"][y].discharge_cost_per_mwh=1/GenX.ModelScalingFactor
    end
    model=GenX.generate_model(setup,inputs,optimizer_with_attributes(HiGHS.Optimizer,"output_flag"=>false))
    optimize!(model)
    @test termination_status(model)==MOI.OPTIMAL
    @test haskey(model,:eTotalCStorageThroughput)
    mktempdir() do dir
        GenX.write_costs(dir,inputs,setup,model)
        df=CSV.read(joinpath(dir,"costs.csv"),DataFrame)
        diagnostics=CSV.read(joinpath(dir,"storage_throughput.csv"),DataFrame)
        fee=value(model[:eTotalCStorageThroughput])*GenX.ModelScalingFactor^2
        @test sum(diagnostics.ThroughputCost) ≈ fee atol=1e-5
        @test sum(diagnostics.Charge_MWh+diagnostics.Discharge_MWh) ≈ fee atol=1e-5
        # Isolate the new fee from pre-existing zonal VOM reporting conventions.
        per_resource=model[:eStorageThroughputCost];total=model[:eTotalCStorageThroughput]
        unregister(model,:eStorageThroughputCost);unregister(model,:eTotalCStorageThroughput)
        baseline_dir=joinpath(dir,"without_fee");mkdir(baseline_dir)
        GenX.write_costs(baseline_dir,inputs,setup,model)
        baseline=CSV.read(joinpath(baseline_dir,"costs.csv"),DataFrame)
        model[:eStorageThroughputCost]=per_resource;model[:eTotalCStorageThroughput]=total
        @test only(df.Total[df.Costs.=="cVar"])-only(baseline.Total[baseline.Costs.=="cVar"]) ≈ fee atol=1e-5
        for z in 1:inputs["Z"]
            zone=Symbol("Zone$z")
            delta=parse(Float64,string(only(df[df.Costs.=="cVar",zone])))-
                  parse(Float64,string(only(baseline[baseline.Costs.=="cVar",zone])))
            expected_zone=sum(value(per_resource[y])*GenX.ModelScalingFactor^2 for y in 1:inputs["G"] if GenX.zone_id(inputs["RESOURCES"][y])==z;init=0.0)
            @test delta ≈ expected_zone atol=1e-5
        end
        expected=value(model[:eTotalCVarOut])+value(model[:eTotalCVarIn])+value(model[:eTotalCVarFlexIn])+
                 value(model[:eTotalCVarOutSolar])+value(model[:eTotalCVarStor])+value(model[:eTotalCStorageThroughput])
        @test only(df.Total[df.Costs.=="cVar"]) ≈ expected*GenX.ModelScalingFactor^2
    end
end
