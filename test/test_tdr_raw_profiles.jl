using GenX, Test, CSV, DataFrames, Random

@testset "TDR preserves raw shared profiles" begin
    mktempdir() do dir
        raw = DataFrame(Time_Index=1:8,
            CSP=[0.0,1.8,0.0,0.5,0.0,2.1,0.0,0.4],
            MinVar=[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8])
        source=joinpath(dir,"Generators_variability.csv")
        CSV.write(source,raw)
        result=GenX.write_tdr_generators_variability_from_raw(
            source,joinpath(dir,"selected.csv"),[2,4],2;weights=[4.0,4.0])
        @test result.Time_Index == 1:4
        @test result.CSP == raw.CSP[[3,4,7,8]]
        @test result.MinVar == raw.MinVar[[3,4,7,8]]
        result=GenX.write_tdr_generators_variability_from_raw(
            source,joinpath(dir,"above_one.csv"),[1,3],2)
        @test result.CSP == [0.0,1.8,0.0,2.1]
        @test !isfile(joinpath(dir,"Generators_variability_diagnostics.csv"))
        for stage in 1:2
            dest=joinpath(dir,"inputs","inputs_p$stage","system")
            mkpath(dest)
            CSV.write(joinpath(dest,"Generators_variability.csv"),raw)
        end
        result=GenX.write_tdr_generators_variability_from_raw_multistage_concat(
            dir,Dict{Any,Any}("SystemFolder"=>"system"),2,
            joinpath(dir,"concat.csv"),[1,5],2;weights=[8.0,8.0])
        @test result.CSP == [0.0,1.8,0.0,1.8]
        @test result.MinVar == [0.1,0.2,0.1,0.2]
    end
end

@testset "TDR deterministic real representatives" begin
    profiles=DataFrame(Dict(Symbol(i)=>[sin(i),cos(i),Float64(i%4)] for i in 1:16))
    for method in ["kmeans","kmedoids"]
        Random.seed!(7)
        a=GenX.cluster(method,profiles,4,5,false,false)
        Random.seed!(99)
        b=GenX.cluster(method,profiles,4,5,false,false)
        @test a[2] == b[2]
        @test a[4] == b[4]
        @test length(unique(a[4])) == 4
        @test all(a[2][a[4][i]] == i for i in 1:4)
    end
end

@testset "TDR rejects unsafe settings before loading inputs" begin
    fixture=joinpath(@__DIR__,"TDR","time_domain_reduction_settings.yml")
    config=GenX.YAML.load_file(fixture)
    setup=GenX.default_settings()
    for (key,value) in [("PreserveAnnualCapacityFactors",1),
                        ("TimestepsPerRepPeriod",0),
                        ("MinPeriods",0),
                        ("nReps",0),
                        ("ClusterMethod","typo"),
                        ("RandomSeed",-1)]
        mktempdir() do dir
            settings=deepcopy(config)
            settings[key]=value
            GenX.YAML.write_file(joinpath(dir,"time_domain_reduction_settings.yml"),settings)
            @test_throws ErrorException GenX.cluster_inputs(
                joinpath(dir,"no_inputs"),dir,setup)
        end
    end
end

@testset "TDR cache includes aligned auxiliary profiles" begin
    mktempdir() do dir
        raw=joinpath(dir,"system");tdr=joinpath(dir,"TDR_results")
        mkpath(raw);mkpath(tdr)
        for f in ["Demand_data.csv","Generators_variability.csv","Fuels_data.csv"]
            write(joinpath(tdr,f),"placeholder")
        end
        @test !GenX.time_domain_reduced_files_exist(tdr)
        write(joinpath(tdr,"Period_map.csv"),"placeholder")
        @test GenX.time_domain_reduced_files_exist(tdr)
        write(joinpath(raw,"Minimum_commitment.csv"),"placeholder")
        @test !GenX.time_domain_reduced_files_exist(tdr;system_path=raw)
        write(joinpath(tdr,"Minimum_commitment.csv"),"placeholder")
        @test GenX.time_domain_reduced_files_exist(tdr;system_path=raw)
        @test !GenX.time_domain_reduced_files_exist(tdr;
            system_path=raw,line_power_limits=true)
        write(joinpath(tdr,"Line_power_flow_limits.csv"),"placeholder")
        @test GenX.time_domain_reduced_files_exist(tdr;
            system_path=raw,line_power_limits=true)
    end
end

@testset "TDR re-runs read the original full-resolution inputs" begin
    mktempdir() do dir
        source=joinpath(@__DIR__,"TDR")
        for folder in ["system","resources","policies"]
            cp(joinpath(source,folder),joinpath(dir,folder))
        end
        config=GenX.YAML.load_file(joinpath(source,"time_domain_reduction_settings.yml"))
        config["MinPeriods"]=8;config["MaxPeriods"]=8
        config["nReps"]=2;config["IterativelyAddPeriods"]=0
        config["ClusterMethod"]="kmedoids";config["RandomSeed"]=1234
        config["ClusterFuelPrices"]=0
        GenX.YAML.write_file(joinpath(dir,"time_domain_reduction_settings.yml"),config)
        setup=GenX.default_settings()
        merge!(setup,Dict("TimeDomainReduction"=>1,
            "TimeDomainReductionFolder"=>"TDR_results","UCommit"=>2,
            "CapacityReserveMargin"=>1,"MinCapReq"=>1,"MaxCapReq"=>1,
            "EnergyShareRequirement"=>1,"CO2Cap"=>2))
        first=GenX.cluster_inputs(dir,dir,setup)
        demand1=CSV.read(joinpath(dir,"TDR_results","Demand_data.csv"),DataFrame)
        second=GenX.cluster_inputs(dir,dir,setup)
        demand2=CSV.read(joinpath(dir,"TDR_results","Demand_data.csv"),DataFrame)
        periods=CSV.read(joinpath(dir,"TDR_results","Period_map.csv"),DataFrame)
        @test first["Centers"] == second["Centers"]
        @test first["Weights"] == second["Weights"]
        @test isequal(demand1,demand2)
        @test nrow(periods) == 52
        @test sum(skipmissing(demand2.Sub_Weights)) ≈ 8760
        # Variable fuel prices remain aligned even when excluded from clustering.
        rawfuel=CSV.read(joinpath(dir,"system","Fuels_data.csv"),DataFrame)
        selectedfuel=CSV.read(joinpath(dir,"TDR_results","Fuels_data.csv"),DataFrame)
        indices=GenX.representative_time_indices(second["Centers"],168)
        for column in setdiff(names(rawfuel),["Time_Index"])
            @test selectedfuel[1,column] == rawfuel[1,column]
            @test selectedfuel[2:end,column] ≈ rawfuel[indices .+ 1,column]
        end
    end
end
