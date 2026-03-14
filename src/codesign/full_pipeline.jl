# Full Pipeline Integration
# Connects CoDesign environment to FPGACompiler infrastructure

# ============================================================================
# Compiled Kernel Representation
# ============================================================================

"""
    CompiledKernel

Holds compiled kernel with CDFG, schedule, and native simulator.
This is the result of full FPGACompiler pipeline compilation.
"""
mutable struct CompiledKernel
    name::String

    # Source
    julia_func::Union{Function, Nothing}
    argtypes::Union{Type, Nothing}

    # Compiled artifacts
    llvm_module::Union{Any, Nothing}      # LLVM.Module (type erased for optional dep)
    cdfg::Union{Any, Nothing}             # HLS.CDFG
    schedule::Union{Any, Nothing}         # HLS.Schedule
    native_sim::Union{Any, Nothing}       # Sim.NativeSimulator

    # Extracted metadata
    critical_path::Int
    total_nodes::Int
    memory_nodes::Int
    input_ports::Vector{Symbol}
    output_ports::Vector{Symbol}

    # Compilation status
    is_compiled::Bool
    compilation_time_ms::Float64
    errors::Vector{String}
end

function CompiledKernel(name::String="kernel")
    CompiledKernel(
        name,
        nothing, nothing,
        nothing, nothing, nothing, nothing,
        0, 0, 0,
        Symbol[], Symbol[],
        false, 0.0,
        String[]
    )
end

# ============================================================================
# Full Pipeline Compilation
# ============================================================================

"""
    compile_kernel(f::Function, argtypes::Type{<:Tuple}; kwargs...)

Compile a Julia function through the full FPGACompiler pipeline.
Returns a CompiledKernel with CDFG, schedule, and simulator.

# Arguments
- `f`: Julia function to compile
- `argtypes`: Tuple type of argument types

# Keyword Arguments
- `scheduling`: Scheduling algorithm (:asap, :alap, :list, :ilp)
- `target_ii`: Target initiation interval for modulo scheduling
- `constraints`: Resource constraints

# Example
```julia
function my_add(a::Int32, b::Int32)::Int32
    return a + b
end

kernel = compile_kernel(my_add, Tuple{Int32, Int32})
```
"""
function compile_kernel(f::Function, argtypes::Type{<:Tuple};
                        scheduling::Symbol=:list,
                        target_ii::Int=1,
                        constraints=nothing)

    kernel = CompiledKernel(string(nameof(f)))
    kernel.julia_func = f
    kernel.argtypes = argtypes

    start_time = time()

    try
        # Step 1: Compile to LLVM via FPGACompiler
        kernel.llvm_module = Main.FPGACompiler.fpga_compile(f, argtypes)

        # Step 2: Build CDFG from LLVM module
        func_name = string(nameof(f))
        kernel.cdfg = Main.FPGACompiler.HLS.build_cdfg_from_module(
            kernel.llvm_module, func_name
        )

        # Step 3: Schedule the CDFG
        if constraints === nothing
            constraints = Main.FPGACompiler.HLS.ResourceConstraints()
        end

        kernel.schedule = if scheduling == :asap
            Main.FPGACompiler.HLS.schedule_asap!(kernel.cdfg)
        elseif scheduling == :alap
            Main.FPGACompiler.HLS.schedule_alap!(kernel.cdfg)
        elseif scheduling == :ilp
            Main.FPGACompiler.HLS.schedule_ilp!(kernel.cdfg; constraints=constraints)
        elseif scheduling == :modulo
            Main.FPGACompiler.HLS.schedule_modulo!(kernel.cdfg;
                target_ii=target_ii, constraints=constraints)
        else  # :list
            Main.FPGACompiler.HLS.schedule_list!(kernel.cdfg, constraints)
        end

        # Step 4: Build native simulator
        kernel.native_sim = Main.FPGACompiler.Sim.build_simulator(
            kernel.cdfg, kernel.schedule
        )

        # Extract metadata
        kernel.critical_path = kernel.cdfg.critical_path_length
        kernel.total_nodes = length(kernel.cdfg.nodes)
        kernel.memory_nodes = length(kernel.cdfg.memory_nodes)
        kernel.input_ports = [Symbol(n.name) for n in kernel.cdfg.input_nodes]
        kernel.output_ports = [Symbol(n.name) for n in kernel.cdfg.output_nodes]

        kernel.is_compiled = true

    catch e
        push!(kernel.errors, string(e))
        kernel.is_compiled = false
    end

    kernel.compilation_time_ms = (time() - start_time) * 1000

    return kernel
end

"""
    compile_kernel_safe(f::Function, argtypes::Type{<:Tuple}; kwargs...)

Safe version that returns (kernel, success) tuple.
"""
function compile_kernel_safe(f::Function, argtypes::Type{<:Tuple}; kwargs...)
    try
        kernel = compile_kernel(f, argtypes; kwargs...)
        return (kernel, kernel.is_compiled)
    catch e
        kernel = CompiledKernel(string(nameof(f)))
        kernel.julia_func = f
        kernel.argtypes = argtypes
        push!(kernel.errors, string(e))
        return (kernel, false)
    end
end

# ============================================================================
# Simulation Interface
# ============================================================================

"""
    simulate_compiled(kernel::CompiledKernel, inputs::Dict{Symbol, <:Integer};
                      max_cycles::Int=10000, verbose::Bool=false)

Run cycle-accurate simulation using the compiled NativeSimulator.
"""
function simulate_compiled(kernel::CompiledKernel, inputs::Dict{Symbol, <:Integer};
                           max_cycles::Int=10000, verbose::Bool=false)

    if !kernel.is_compiled || kernel.native_sim === nothing
        error("Kernel not compiled. Call compile_kernel first.")
    end

    sim = kernel.native_sim

    # Reset simulator
    Main.FPGACompiler.Sim.reset!(sim)

    # Set inputs
    Main.FPGACompiler.Sim.set_inputs!(sim, inputs)

    # Start
    Main.FPGACompiler.Sim.start!(sim)

    # Run
    result = Main.FPGACompiler.Sim.run!(sim; max_cycles=max_cycles, verbose=verbose)

    return result
end

"""
    simulate_with_observables(kernel::CompiledKernel, inputs::Dict{Symbol, <:Integer},
                              obs::SimulatorObservables; kwargs...)

Run simulation with observable updates for live visualization.
"""
function simulate_with_observables(kernel::CompiledKernel,
                                   inputs::Dict{Symbol, <:Integer},
                                   obs::SimulatorObservables;
                                   max_cycles::Int=10000,
                                   yield_interval::Int=10)

    if !kernel.is_compiled || kernel.native_sim === nothing
        error("Kernel not compiled. Call compile_kernel first.")
    end

    sim = kernel.native_sim

    # Reset
    Main.FPGACompiler.Sim.reset!(sim)
    Main.FPGACompiler.Sim.set_inputs!(sim, inputs)
    Main.FPGACompiler.Sim.start!(sim)

    obs.is_running[] = true
    obs.is_done[] = false
    obs.fsm_state[] = "RUNNING"

    cycle = 0
    while Main.FPGACompiler.Sim.tick!(sim) && cycle < max_cycles
        cycle += 1

        # Update observables
        obs.clock[] = cycle

        # Get FSM state
        state = Main.FPGACompiler.Sim.get_state(sim)
        obs.fsm_state[] = String(state)

        # Progress estimate
        if kernel.schedule !== nothing
            total_cycles = kernel.schedule.total_cycles
            progress = cycle / max(1, total_cycles) * 100
            obs.progress[] = min(100.0, progress)
        end

        # Yield for UI updates
        if cycle % yield_interval == 0
            yield()
        end
    end

    obs.is_running[] = false
    obs.is_done[] = Main.FPGACompiler.Sim.is_done(sim)
    obs.fsm_state[] = obs.is_done[] ? "DONE" : "TIMEOUT"

    # Collect outputs
    outputs = Main.FPGACompiler.Sim.get_outputs(sim)

    return (
        total_cycles = cycle,
        is_done = obs.is_done[],
        outputs = outputs
    )
end

# ============================================================================
# CoDesign Kernel Wrapper
# ============================================================================

"""
    CoDesignKernel

Unified kernel wrapper supporting both parametric and full-pipeline simulation.
"""
mutable struct CoDesignKernel
    name::String

    # Parametric mode (lightweight)
    workload::Union{WorkloadDescriptor, Nothing}
    parametric_sim::Union{ParametricSimulator, Nothing}

    # Full pipeline mode (cycle-accurate)
    compiled::Union{CompiledKernel, Nothing}

    # DSE parameters
    dse::DSEParameters

    # Virtual device
    device::Union{VirtualFPGADevice, Nothing}

    # Observable state
    observables::SimulatorObservables

    # Active simulation mode
    mode::Symbol  # :parametric or :full
end

function CoDesignKernel(name::String="kernel";
                        workload::Union{WorkloadDescriptor, Nothing}=nothing,
                        dse::DSEParameters=DSEParameters(),
                        device::Union{VirtualFPGADevice, Nothing}=nothing)

    # Create parametric simulator if workload provided
    param_sim = workload !== nothing ? ParametricSimulator(workload; dse=dse) : nothing

    CoDesignKernel(
        name,
        workload,
        param_sim,
        nothing,
        dse,
        device,
        SimulatorObservables(dse.pipeline_depth),
        :parametric
    )
end

"""
    CoDesignKernel(f::Function, argtypes::Type{<:Tuple}; kwargs...)

Create CoDesignKernel from a Julia function (compiles through full pipeline).
"""
function CoDesignKernel(f::Function, argtypes::Type{<:Tuple};
                        dse::DSEParameters=DSEParameters(),
                        device::Union{VirtualFPGADevice, Nothing}=nothing,
                        compile::Bool=true)

    kernel = CoDesignKernel(string(nameof(f));
        dse=dse,
        device=device
    )

    kernel.julia_func = f
    kernel.argtypes = argtypes

    if compile
        compile!(kernel)
    end

    return kernel
end

"""
    compile!(kernel::CoDesignKernel)

Compile kernel through full FPGACompiler pipeline.
"""
function compile!(kernel::CoDesignKernel)
    if kernel.compiled !== nothing && kernel.compiled.julia_func !== nothing
        kernel.compiled = compile_kernel(
            kernel.compiled.julia_func,
            kernel.compiled.argtypes
        )
        kernel.mode = :full
    end
end

"""
    simulate!(kernel::CoDesignKernel, inputs::Dict=Dict();
              backend::Symbol=:auto)

Run simulation using specified backend.

# Arguments
- `backend`: :parametric, :full, or :auto (uses :full if compiled)
"""
function simulate!(kernel::CoDesignKernel, inputs::Dict=Dict();
                   backend::Symbol=:auto,
                   max_cycles::Int=10000,
                   callback::Union{Function, Nothing}=nothing)

    # Auto-select backend
    actual_backend = if backend == :auto
        kernel.compiled !== nothing && kernel.compiled.is_compiled ? :full : :parametric
    else
        backend
    end

    if actual_backend == :full
        if kernel.compiled === nothing || !kernel.compiled.is_compiled
            error("Full pipeline backend requires compiled kernel")
        end

        # Convert inputs to Symbol keys with Integer values
        int_inputs = Dict{Symbol, Int}()
        for (k, v) in inputs
            int_inputs[Symbol(k)] = Int(v)
        end

        return simulate_with_observables(
            kernel.compiled, int_inputs, kernel.observables;
            max_cycles=max_cycles
        )

    else  # :parametric
        if kernel.parametric_sim === nothing
            error("Parametric backend requires WorkloadDescriptor")
        end

        # Sync DSE parameters
        kernel.parametric_sim.dse = kernel.dse
        reset!(kernel.parametric_sim)

        return run!(kernel.parametric_sim;
            max_cycles=max_cycles,
            callback=callback
        )
    end
end

"""
    estimate!(kernel::CoDesignKernel)

Get quick performance estimate without running full simulation.
"""
function estimate!(kernel::CoDesignKernel)
    if kernel.parametric_sim !== nothing
        return estimate_performance(kernel.parametric_sim)
    elseif kernel.compiled !== nothing && kernel.compiled.is_compiled
        return (
            estimated_cycles = kernel.compiled.schedule.total_cycles,
            critical_path = kernel.compiled.critical_path,
            total_nodes = kernel.compiled.total_nodes,
            memory_ops = kernel.compiled.memory_nodes
        )
    else
        error("No simulation backend available")
    end
end

"""
    update_dse!(kernel::CoDesignKernel, dse::DSEParameters)

Update DSE parameters and reconfigure simulator.
"""
function update_dse!(kernel::CoDesignKernel, dse::DSEParameters)
    kernel.dse = dse

    if kernel.parametric_sim !== nothing
        kernel.parametric_sim.dse = dse
        reset!(kernel.parametric_sim)
    end

    # Resize observables if needed
    if length(kernel.observables.pipeline[]) != dse.pipeline_depth
        resize_pipeline!(kernel.observables, dse.pipeline_depth)
    end
end

# ============================================================================
# DSE Helper Functions
# ============================================================================

"""
    run_dse_sweep(kernel::CoDesignKernel;
                  unroll_range::UnitRange{Int}=1:8,
                  ii_range::UnitRange{Int}=1:2,
                  bram_range::UnitRange{Int}=1:4)

Run DSE sweep and return Pareto points.
"""
function run_dse_sweep(kernel::CoDesignKernel;
                       unroll_range::UnitRange{Int}=1:8,
                       ii_range::UnitRange{Int}=1:2,
                       bram_range::UnitRange{Int}=1:4)

    if kernel.workload === nothing
        error("DSE sweep requires WorkloadDescriptor")
    end

    return sweep_dse_space(kernel.workload;
        unroll_range=unroll_range,
        ii_range=ii_range,
        bram_range=bram_range,
        base_dse=kernel.dse
    )
end

"""
    find_best_config(kernel::CoDesignKernel;
                     optimize_for::Symbol=:throughput,
                     max_dsps::Int=64,
                     max_brams::Int=32)

Find optimal DSE configuration.
"""
function find_best_config(kernel::CoDesignKernel;
                          optimize_for::Symbol=:throughput,
                          max_dsps::Int=64,
                          max_brams::Int=32)

    if kernel.workload === nothing
        error("Finding best config requires WorkloadDescriptor")
    end

    best_dse = find_optimal_config(kernel.workload;
        optimize_for=optimize_for,
        max_dsps=max_dsps,
        max_brams=max_brams
    )

    if best_dse !== nothing
        update_dse!(kernel, best_dse)
    end

    return best_dse
end

# ============================================================================
# Pretty Printing
# ============================================================================

function Base.show(io::IO, kernel::CompiledKernel)
    status = kernel.is_compiled ? "compiled" : "not compiled"
    print(io, "CompiledKernel(\"$(kernel.name)\", $status")
    if kernel.is_compiled
        print(io, ", $(kernel.total_nodes) nodes, $(kernel.critical_path) cycle critical path")
    end
    if !isempty(kernel.errors)
        print(io, ", $(length(kernel.errors)) errors")
    end
    print(io, ")")
end

function Base.show(io::IO, kernel::CoDesignKernel)
    modes = String[]
    if kernel.workload !== nothing
        push!(modes, "parametric")
    end
    if kernel.compiled !== nothing && kernel.compiled.is_compiled
        push!(modes, "full")
    end
    mode_str = isempty(modes) ? "unconfigured" : join(modes, "+")
    print(io, "CoDesignKernel(\"$(kernel.name)\", $mode_str, active=$(kernel.mode))")
end
