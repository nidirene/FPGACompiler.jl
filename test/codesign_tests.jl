# CoDesign Module Tests

using Test
using FPGACompiler
using FPGACompiler.CoDesign

# Explicitly import to avoid conflicts with DataStructures
import FPGACompiler.CoDesign: reset!, run!, tick!

# Import convenience functions not exported from main module
import FPGACompiler.CoDesign: quick_sim, compare_configs, create_kernel

@testset "CoDesign Module" begin

    @testset "DSEParameters" begin
        @testset "Default construction" begin
            dse = DSEParameters()
            @test dse.unroll_factor == 1
            @test dse.initiation_interval == 1
            @test dse.pipeline_depth == 5
            @test dse.bram_ports == 2
            @test dse.max_dsps == 16
            @test dse.target_freq_mhz == 100.0
        end

        @testset "Custom construction" begin
            dse = DSEParameters(
                unroll_factor=4,
                initiation_interval=2,
                pipeline_depth=8,
                bram_ports=4
            )
            @test dse.unroll_factor == 4
            @test dse.initiation_interval == 2
            @test dse.pipeline_depth == 8
            @test dse.bram_ports == 4
        end

        @testset "Validation" begin
            # Valid configuration
            dse = DSEParameters(unroll_factor=4)
            warnings = validate_dse(dse)
            @test isempty(warnings)

            # Invalid configurations
            dse_invalid = DSEParameters()
            dse_invalid.unroll_factor = 0
            warnings = validate_dse(dse_invalid)
            @test !isempty(warnings)
            @test any(w -> occursin("unroll_factor", w), warnings)
        end
    end

    @testset "WorkloadDescriptor" begin
        @testset "Conv2D workload" begin
            workload = conv2d_workload(kernel_size=3, img_height=28, img_width=28)
            @test occursin("Conv2D", workload.name)
            @test workload.ndrange == (28, 28)
            @test workload.multiplies_per_item == 9  # 3x3
            @test workload.reads_per_item == 9
            @test workload.writes_per_item == 1
            @test total_items(workload) == 784  # 28x28
        end

        @testset "MatMul workload" begin
            workload = matmul_workload(M=64, N=64, K=64)
            @test occursin("MatMul", workload.name)
            @test workload.ndrange == (64, 64)
            @test workload.multiplies_per_item == 64  # K
            @test workload.adds_per_item == 63  # K-1
            @test total_items(workload) == 4096  # 64x64
        end

        @testset "FIR filter workload" begin
            workload = fir_filter_workload(taps=16, samples=1024)
            @test occursin("FIR", workload.name)
            @test workload.ndrange == (1024,)
            @test workload.multiplies_per_item == 16
            @test workload.reads_per_item == 17  # taps + 1
            @test total_items(workload) == 1024
        end

        @testset "Elementwise workload" begin
            workload = elementwise_workload(height=1000, ops_per_element=2)
            @test total_items(workload) == 1000
            @test workload.multiplies_per_item == 2
        end

        @testset "Reduction workload" begin
            workload = reduction_workload(length=1024)
            @test total_items(workload) == 1024
            @test workload.adds_per_item == 1
        end

        @testset "Total operations" begin
            workload = conv2d_workload(kernel_size=3, img_height=10, img_width=10)
            @test total_items(workload) == 100
            @test total_ops(workload) > 0  # multiplies + adds
            @test total_memory_accesses(workload) == 100 * (9 + 1)  # reads + writes
        end
    end

    @testset "VirtualPCIe" begin
        @testset "Predefined configurations" begin
            @test PCIE_GEN3_X16.bandwidth_GBps == 16.0
            @test PCIE_GEN4_X16.bandwidth_GBps == 32.0
            @test PCIE_GEN5_X16.bandwidth_GBps == 64.0
            @test AXI_ZYNQ.bandwidth_GBps == 4.0
        end

        @testset "Transfer cycles" begin
            pcie = PCIE_GEN3_X16
            # 1MB transfer
            cycles = transfer_cycles(pcie, 1024 * 1024)
            @test cycles > 0
            @test isa(cycles, Int)

            # Larger transfer should take more cycles
            cycles_2mb = transfer_cycles(pcie, 2 * 1024 * 1024)
            @test cycles_2mb > cycles
        end
    end

    @testset "VirtualFPGAArray" begin
        @testset "Construction" begin
            arr = VirtualFPGAArray{Float32, 2}(undef, (10, 10))
            @test size(arr) == (10, 10)
            @test length(arr) == 100
            @test eltype(arr) == Float32
        end

        @testset "From existing array" begin
            data = rand(Float32, 5, 5)
            arr = VirtualFPGAArray(data)
            @test size(arr) == (5, 5)
            @test arr.data == data
        end

        @testset "Access tracking" begin
            arr = VirtualFPGAArray{Int, 1}(undef, (10,))
            arr.data .= 1:10

            @test arr.total_reads == 0
            @test arr.total_writes == 0

            # Read
            _ = arr[1]
            @test arr.total_reads == 1

            # Write
            arr[1] = 100
            @test arr.total_writes == 1

            # Reset
            reset_stats!(arr)
            @test arr.total_reads == 0
            @test arr.total_writes == 0
        end

        @testset "Memory type and partitioning" begin
            arr = VirtualFPGAArray{Int, 1}(undef, (100,);
                memory_type=:uram,
                partition_factor=4,
                partition_style=:block
            )
            @test arr.memory_type == :uram
            @test arr.partition_factor == 4
            @test arr.partition_style == :block
        end
    end

    @testset "VirtualFPGADevice" begin
        @testset "Preset devices" begin
            u200 = alveo_u200()
            @test u200.name == "Alveo U200 (XCU200)"
            @test u200.total_dsps == 6840
            @test u200.clock_freq_mhz == 300.0

            u280 = alveo_u280()
            @test u280.total_dsps == 9024

            zynq = zynq_7020()
            @test zynq.total_dsps == 220

            arty = arty_a7()
            @test arty.total_dsps == 90
        end

        @testset "Memory allocation" begin
            device = VirtualFPGADevice("Test")
            arr = allocate!(device, :input_data, Float32, (100,))

            @test haskey(device.memories, :input_data)
            @test size(arr) == (100,)
            @test device.used_brams > 0
        end

        @testset "Resource utilization" begin
            device = alveo_u200()
            util = resource_utilization(device)

            @test haskey(util, :luts)
            @test haskey(util, :dsps)
            @test haskey(util, :brams)
            @test util.dsps == 0.0  # No usage yet
        end

        @testset "Device reset" begin
            device = VirtualFPGADevice("Test")
            allocate!(device, :test, Float32, (100,))
            @test !isempty(device.memories)

            reset_device!(device)
            @test isempty(device.memories)
            @test device.used_brams == 0
        end
    end

    @testset "SimulatorObservables" begin
        @testset "Construction" begin
            obs = SimulatorObservables()
            @test obs.clock[] == 0
            @test obs.progress[] == 0.0
            @test obs.fsm_state[] == "IDLE"
            @test obs.is_done[] == false
        end

        @testset "Pipeline depth" begin
            obs = SimulatorObservables(10)
            @test length(obs.pipeline[]) == 10
            @test length(obs.pipeline_valid[]) == 10
        end

        @testset "Reset" begin
            obs = SimulatorObservables()
            obs.clock[] = 100
            obs.progress[] = 50.0
            obs.fsm_state[] = "RUNNING"

            reset!(obs)
            @test obs.clock[] == 0
            @test obs.progress[] == 0.0
            @test obs.fsm_state[] == "IDLE"
        end

        @testset "Resize pipeline" begin
            obs = SimulatorObservables(5)
            @test length(obs.pipeline[]) == 5

            resize_pipeline!(obs, 10)
            @test length(obs.pipeline[]) == 10
        end
    end

    @testset "DSEObservables" begin
        dse = DSEParameters(unroll_factor=4, bram_ports=2)
        obs = DSEObservables(dse)

        @test obs.unroll_factor[] == 4
        @test obs.bram_ports[] == 2

        # Convert back to parameters
        dse2 = to_parameters(obs)
        @test dse2.unroll_factor == 4
        @test dse2.bram_ports == 2
    end

    @testset "ParametricSimulator" begin
        @testset "Construction" begin
            workload = conv2d_workload(kernel_size=3, img_height=28, img_width=28)
            dse = DSEParameters(unroll_factor=4)
            sim = ParametricSimulator(workload; dse=dse)

            @test sim.total_items == 784
            @test sim.clock_cycle == 0
            @test sim.items_processed == 0
        end

        @testset "Throughput calculation" begin
            workload = conv2d_workload(kernel_size=3)
            dse = DSEParameters(unroll_factor=4, bram_ports=4, max_dsps=64)

            throughput, mem_bound, comp_bound = calculate_throughput(workload, dse)
            @test throughput > 0
            @test isa(mem_bound, Bool)
            @test isa(comp_bound, Bool)
        end

        @testset "Tick simulation" begin
            workload = elementwise_workload(height=100, ops_per_element=1)
            sim = ParametricSimulator(workload)

            # Initial state
            @test sim.clock_cycle == 0
            @test sim.running == false

            # Tick
            continuing = tick!(sim)
            @test continuing == true
            @test sim.clock_cycle == 1
            @test sim.running == true

            # More ticks
            for _ in 1:10
                tick!(sim)
            end
            @test sim.clock_cycle == 11
        end

        @testset "Full run" begin
            workload = elementwise_workload(height=50, ops_per_element=1)
            dse = DSEParameters(unroll_factor=2)
            sim = ParametricSimulator(workload; dse=dse)

            result = run!(sim; max_cycles=1000)

            @test result.completed == true
            @test result.items_processed == 50
            @test result.total_cycles > 0
            @test result.throughput > 0
        end

        @testset "Reset" begin
            workload = elementwise_workload(height=50)
            sim = ParametricSimulator(workload)

            # Run some cycles
            for _ in 1:10
                tick!(sim)
            end
            @test sim.clock_cycle > 0

            # Reset
            reset!(sim)
            @test sim.clock_cycle == 0
            @test sim.items_processed == 0
            @test sim.running == false
        end

        @testset "Performance estimation" begin
            workload = conv2d_workload(kernel_size=3, img_height=28, img_width=28)
            dse = DSEParameters(unroll_factor=4)
            sim = ParametricSimulator(workload; dse=dse)

            est = estimate_performance(sim)
            @test est.estimated_cycles > 0
            @test est.estimated_throughput > 0
            @test haskey(est, :bottleneck)
        end

        @testset "Observable updates" begin
            workload = elementwise_workload(height=100)
            sim = ParametricSimulator(workload)

            # Check observables update
            @test sim.observables.clock[] == 0

            tick!(sim)
            @test sim.observables.clock[] == 1

            tick!(sim)
            @test sim.observables.clock[] == 2
        end
    end

    @testset "DSE Sweep Functions" begin
        @testset "Unroll factor sweep" begin
            workload = conv2d_workload(kernel_size=3, img_height=10, img_width=10)
            results = sweep_unroll_factor(workload, 1:4)

            @test length(results) == 4
            @test results[1].unroll_factor == 1
            @test results[4].unroll_factor == 4

            # Higher unroll should generally improve throughput (up to limits)
            @test results[2].throughput >= results[1].throughput
        end

        @testset "DSE space sweep" begin
            workload = elementwise_workload(height=100)
            points = sweep_dse_space(workload;
                unroll_range=1:2,
                ii_range=1:2,
                bram_range=1:2
            )

            @test length(points) == 8  # 2 * 2 * 2
            @test all(p -> p.cycles > 0, points)
            @test all(p -> p.throughput > 0, points)
        end

        @testset "Find optimal config" begin
            workload = conv2d_workload(kernel_size=3, img_height=10, img_width=10)
            best = find_optimal_config(workload;
                optimize_for=:throughput,
                max_dsps=32,
                max_brams=16
            )

            @test best !== nothing
            @test best.unroll_factor >= 1
        end
    end

    @testset "ParetoObservables" begin
        pareto = ParetoObservables()
        @test isempty(pareto.points[])
        @test isempty(pareto.frontier[])

        # Create test points
        dse1 = DSEParameters(unroll_factor=1)
        dse2 = DSEParameters(unroll_factor=2)
        dse3 = DSEParameters(unroll_factor=4)

        points = [
            ParetoPoint(dse1, 100, 0.5, 4, 2, false, false),
            ParetoPoint(dse2, 60, 0.8, 8, 4, false, false),
            ParetoPoint(dse3, 40, 1.0, 16, 8, true, false)
        ]

        update_pareto!(pareto, points)
        @test length(pareto.points[]) == 3
        @test length(pareto.frontier[]) > 0
    end

    @testset "CoDesignKernel" begin
        @testset "Parametric mode" begin
            workload = conv2d_workload(kernel_size=3)
            dse = DSEParameters(unroll_factor=2)
            kernel = CoDesignKernel("test_conv"; workload=workload, dse=dse)

            @test kernel.name == "test_conv"
            @test kernel.mode == :parametric
            @test kernel.parametric_sim !== nothing
            @test kernel.compiled === nothing
        end

        @testset "Simulation" begin
            workload = elementwise_workload(height=50)
            kernel = CoDesignKernel("test"; workload=workload)

            result = simulate!(kernel; backend=:parametric)
            @test result.completed == true
            @test result.total_cycles > 0
        end

        @testset "DSE update" begin
            workload = elementwise_workload(height=50)
            kernel = CoDesignKernel("test"; workload=workload)

            new_dse = DSEParameters(unroll_factor=4, pipeline_depth=8)
            update_dse!(kernel, new_dse)

            @test kernel.dse.unroll_factor == 4
            @test kernel.dse.pipeline_depth == 8
            @test length(kernel.observables.pipeline[]) == 8
        end

        @testset "DSE sweep" begin
            workload = elementwise_workload(height=100)
            kernel = CoDesignKernel("test"; workload=workload)

            points = run_dse_sweep(kernel;
                unroll_range=1:2,
                ii_range=1:2,
                bram_range=1:2
            )

            @test length(points) == 8
        end

        @testset "Find best config" begin
            workload = elementwise_workload(height=100)
            kernel = CoDesignKernel("test"; workload=workload)

            best = find_best_config(kernel; max_dsps=32)
            @test best !== nothing
            @test kernel.dse == best  # Should be applied
        end

        @testset "With device" begin
            workload = conv2d_workload(kernel_size=3)
            device = zynq_7020()
            kernel = CoDesignKernel("test";
                workload=workload,
                device=device
            )

            @test kernel.device !== nothing
            @test kernel.device.name == "Zynq-7020 (XC7Z020)"
        end
    end

    @testset "Resource Estimation" begin
        workload = conv2d_workload(kernel_size=5, img_height=32, img_width=32)
        dse = DSEParameters(unroll_factor=4, bram_ports=4)

        # Use qualified name to avoid conflict with FPGACompiler.estimate_resources
        resources = FPGACompiler.CoDesign.estimate_resources(dse, workload)
        @test haskey(resources, :dsps)
        @test haskey(resources, :feasible)
        @test resources.dsps > 0
    end

    @testset "Convenience Functions" begin
        @testset "quick_sim" begin
            workload = elementwise_workload(height=100)
            result = quick_sim(workload)

            @test result.estimated_cycles > 0
            @test result.estimated_throughput > 0
        end

        @testset "compare_configs" begin
            workload = elementwise_workload(height=100)
            configs = [
                DSEParameters(unroll_factor=1),
                DSEParameters(unroll_factor=2),
                DSEParameters(unroll_factor=4)
            ]

            results = compare_configs(workload, configs)
            @test length(results) == 3
            @test all(r -> haskey(r, :throughput), results)
        end

        @testset "create_kernel factory" begin
            workload = conv2d_workload()
            kernel = create_kernel("factory_test"; workload=workload)

            @test kernel.name == "factory_test"
            @test kernel.workload !== nothing
        end
    end

    @testset "Integration" begin
        @testset "End-to-end parametric workflow" begin
            # 1. Define workload
            workload = matmul_workload(M=32, N=32, K=32)

            # 2. Create kernel
            kernel = CoDesignKernel("matmul"; workload=workload)

            # 3. Estimate initial performance
            est1 = estimate!(kernel)
            @test est1.estimated_cycles > 0

            # 4. Find better configuration
            best = find_best_config(kernel; max_dsps=64)

            # 5. Run simulation with new config
            result = simulate!(kernel)
            @test result.completed == true

            # 6. Compare performance
            est2 = estimate!(kernel)
            @test est2.estimated_throughput >= est1.estimated_throughput
        end

        @testset "Device-aware simulation" begin
            # Target specific device
            device = zynq_7020()

            # Workload that fits device
            workload = conv2d_workload(kernel_size=3, img_height=16, img_width=16)

            # Constrain DSE to device resources
            dse = DSEParameters(
                max_dsps=device.total_dsps,
                max_brams=device.total_brams
            )

            kernel = CoDesignKernel("constrained";
                workload=workload,
                dse=dse,
                device=device
            )

            # Find optimal within constraints
            best = find_best_config(kernel;
                max_dsps=device.total_dsps,
                max_brams=device.total_brams
            )

            @test best !== nothing
        end
    end

end

println("CoDesign tests completed!")
