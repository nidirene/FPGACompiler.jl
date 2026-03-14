# CoDesign Module
# Hardware-Software Co-Design Environment for FPGACompiler
#
# Provides:
# - Parametric simulation for quick DSE exploration
# - Full pipeline integration with NativeSimulator
# - Observable wrappers for Makie visualization
# - Virtual FPGA device abstractions
# - Workload descriptors for common patterns

module CoDesign

using Observables

# ============================================================================
# Exports
# ============================================================================

# DSE Parameters
export DSEParameters, DSERange, DEFAULT_DSE_RANGE
export validate_dse, estimate_resources

# Workload Descriptors
export WorkloadDescriptor
export total_items, total_ops, total_memory_accesses
export conv2d_workload, matmul_workload, elementwise_workload
export reduction_workload, fir_filter_workload

# Virtual Device
export VirtualPCIe, VirtualFPGAArray, VirtualFPGADevice
export PCIE_GEN3_X16, PCIE_GEN4_X16, PCIE_GEN5_X16, AXI_ZYNQ
export transfer_cycles, allocate!, copyto_device!, copyto_host!
export reset_device!, resource_utilization, print_device_info
export reset_stats!, enable_tracking!
export alveo_u200, alveo_u280, zynq_7020, arty_a7

# Observables
export SimulatorObservables, DSEObservables, ResultObservables
export ParetoPoint, ParetoObservables
export reset!, resize_pipeline!, to_parameters
export sync_from!, sync_to!, update_pareto!
export throttled_update!, batch_update!

# Parametric Simulator
export ParametricSimulator
export tick!, run!, run_async!, reset!
export calculate_throughput, estimate_performance, get_results
export sweep_unroll_factor, sweep_dse_space, find_optimal_config

# Full Pipeline Integration
export CompiledKernel, compile_kernel, compile_kernel_safe
export simulate_compiled, simulate_with_observables
export CoDesignKernel, compile!, simulate!, estimate!
export update_dse!, run_dse_sweep, find_best_config

# Convenience Functions
export quick_sim, compare_configs, create_kernel, print_summary, codesign_help

# ============================================================================
# Includes
# ============================================================================

include("dse.jl")
include("virtual_device.jl")
include("observables.jl")
include("parametric_sim.jl")
include("full_pipeline.jl")

# ============================================================================
# Convenience Functions
# ============================================================================

"""
    quick_sim(workload::WorkloadDescriptor; dse::DSEParameters=DSEParameters())

Quick simulation for DSE exploration. Returns performance estimate.
"""
function quick_sim(workload::WorkloadDescriptor; dse::DSEParameters=DSEParameters())
    sim = ParametricSimulator(workload; dse=dse)
    return estimate_performance(sim)
end

"""
    compare_configs(workload::WorkloadDescriptor, configs::Vector{DSEParameters})

Compare multiple DSE configurations. Returns table of results.
"""
function compare_configs(workload::WorkloadDescriptor, configs::Vector{DSEParameters})
    results = []

    for (i, dse) in enumerate(configs)
        sim = ParametricSimulator(workload; dse=dse)
        est = estimate_performance(sim)

        push!(results, (
            config_id = i,
            unroll = dse.unroll_factor,
            ii = dse.initiation_interval,
            bram_ports = dse.bram_ports,
            cycles = est.estimated_cycles,
            throughput = est.estimated_throughput,
            bottleneck = est.bottleneck
        ))
    end

    return results
end

"""
    create_kernel(name::String; workload=nothing, func=nothing, argtypes=nothing, kwargs...)

Factory function to create a CoDesignKernel with flexible configuration.
"""
function create_kernel(name::String;
                       workload::Union{WorkloadDescriptor, Nothing}=nothing,
                       func::Union{Function, Nothing}=nothing,
                       argtypes::Union{Type, Nothing}=nothing,
                       dse::DSEParameters=DSEParameters(),
                       device::Union{VirtualFPGADevice, Nothing}=nothing,
                       auto_compile::Bool=false)

    kernel = CoDesignKernel(name; workload=workload, dse=dse, device=device)

    if func !== nothing && argtypes !== nothing
        kernel.compiled = CompiledKernel(name)
        kernel.compiled.julia_func = func
        kernel.compiled.argtypes = argtypes

        if auto_compile
            compile!(kernel)
        end
    end

    return kernel
end

"""
    print_summary(kernel::CoDesignKernel)

Print summary of kernel configuration and estimated performance.
"""
function print_summary(kernel::CoDesignKernel)
    println("CoDesign Kernel: $(kernel.name)")
    println("=" ^ 50)

    # DSE Parameters
    println("\nDSE Parameters:")
    println("  Unroll Factor: $(kernel.dse.unroll_factor)")
    println("  Initiation Interval: $(kernel.dse.initiation_interval)")
    println("  Pipeline Depth: $(kernel.dse.pipeline_depth)")
    println("  BRAM Ports: $(kernel.dse.bram_ports)")
    println("  Max DSPs: $(kernel.dse.max_dsps)")

    # Workload
    if kernel.workload !== nothing
        println("\nWorkload: $(kernel.workload.name)")
        println("  NDRange: $(kernel.workload.ndrange)")
        println("  Total Items: $(total_items(kernel.workload))")
        println("  Multiplies/item: $(kernel.workload.multiplies_per_item)")
        println("  Reads/item: $(kernel.workload.reads_per_item)")
    end

    # Compiled kernel
    if kernel.compiled !== nothing && kernel.compiled.is_compiled
        println("\nCompiled Kernel:")
        println("  Total Nodes: $(kernel.compiled.total_nodes)")
        println("  Memory Nodes: $(kernel.compiled.memory_nodes)")
        println("  Critical Path: $(kernel.compiled.critical_path) cycles")
        println("  Compilation Time: $(round(kernel.compiled.compilation_time_ms, digits=2)) ms")
    end

    # Estimate
    try
        est = estimate!(kernel)
        println("\nPerformance Estimate:")
        if haskey(est, :estimated_cycles)
            println("  Estimated Cycles: $(est.estimated_cycles)")
        end
        if haskey(est, :estimated_throughput)
            println("  Estimated Throughput: $(round(est.estimated_throughput, digits=4)) items/cycle")
        end
        if haskey(est, :bottleneck)
            println("  Bottleneck: $(est.bottleneck)")
        end
    catch
        # No estimate available
    end

    # Device
    if kernel.device !== nothing
        println("\nTarget Device: $(kernel.device.name)")
        util = resource_utilization(kernel.device)
        println("  DSP Usage: $(round(util.dsps, digits=1))%")
        println("  BRAM Usage: $(round(util.brams, digits=1))%")
    end
end

# ============================================================================
# REPL Help
# ============================================================================

"""
    codesign_help()

Print help information for CoDesign module.
"""
function codesign_help()
    println("""
    FPGACompiler CoDesign Module
    ============================

    Quick Start:
    ------------
    1. Define workload:
       workload = conv2d_workload(kernel_size=3, img_height=28, img_width=28)

    2. Create kernel with DSE parameters:
       kernel = CoDesignKernel("conv2d"; workload=workload, dse=DSEParameters(unroll_factor=4))

    3. Run simulation:
       result = simulate!(kernel)

    4. Explore DSE space:
       points = run_dse_sweep(kernel; unroll_range=1:8)

    Available Workload Patterns:
    ---------------------------
    - conv2d_workload(; kernel_size, img_height, img_width)
    - matmul_workload(; M, N, K)
    - elementwise_workload(; height, width, ops_per_element)
    - reduction_workload(; length)
    - fir_filter_workload(; taps, samples)

    Virtual Devices:
    ---------------
    - alveo_u200()   - Xilinx Alveo U200
    - alveo_u280()   - Xilinx Alveo U280
    - zynq_7020()    - Zynq-7020
    - arty_a7()      - Arty A7-35T

    Full Pipeline (requires FPGACompiler):
    -------------------------------------
    kernel = compile_kernel(my_func, Tuple{Int32, Int32})
    result = simulate_compiled(kernel, Dict(:a => 5, :b => 3))
    """)
end

end # module CoDesign
