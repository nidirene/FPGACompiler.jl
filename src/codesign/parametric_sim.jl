# Parametric RTL Simulator
# Lightweight simulator for DSE exploration without full compilation

# ============================================================================
# Parametric Simulator
# ============================================================================

"""
    ParametricSimulator

Lightweight parametric simulator for quick DSE exploration.
Estimates throughput and resource usage based on workload and DSE parameters.
Does NOT require LLVM compilation - uses workload descriptors directly.
"""
mutable struct ParametricSimulator
    # Workload description
    workload::WorkloadDescriptor

    # DSE parameters
    dse::DSEParameters

    # Simulation state
    clock_cycle::Int
    items_processed::Int
    total_items::Int

    # Pipeline state
    pipeline_stages::Vector{Int}        # Items per stage
    pipeline_valid::Vector{Bool}        # Valid flag per stage

    # Computed metrics
    effective_throughput::Int           # Items per cycle (considering limits)
    memory_bound::Bool                  # True if memory is bottleneck
    compute_bound::Bool                 # True if compute is bottleneck

    # Statistics
    total_active_cycles::Int
    total_stall_cycles::Int

    # Observable wrappers
    observables::SimulatorObservables

    # Simulation control
    running::Bool
    speed_factor::Float64               # Simulation speed (1.0 = realtime viz)
end

"""
    ParametricSimulator(workload::WorkloadDescriptor, dse::DSEParameters)

Create a new ParametricSimulator.
"""
function ParametricSimulator(workload::WorkloadDescriptor;
                              dse::DSEParameters=DSEParameters())
    total = total_items(workload)

    # Calculate effective throughput
    throughput, mem_bound, comp_bound = calculate_throughput(workload, dse)

    sim = ParametricSimulator(
        workload,
        dse,
        0,                              # clock_cycle
        0,                              # items_processed
        total,                          # total_items
        zeros(Int, dse.pipeline_depth),
        fill(false, dse.pipeline_depth),
        throughput,
        mem_bound,
        comp_bound,
        0, 0,                           # statistics
        SimulatorObservables(dse.pipeline_depth),
        false,
        1.0
    )

    return sim
end

"""
    calculate_throughput(workload::WorkloadDescriptor, dse::DSEParameters)

Calculate effective throughput based on workload and DSE parameters.
Returns (throughput, memory_bound, compute_bound).
"""
function calculate_throughput(workload::WorkloadDescriptor, dse::DSEParameters)
    # Memory-bound: limited by BRAM ports
    # Each item needs `reads_per_item` reads
    reads_per_cycle = workload.reads_per_item * dse.unroll_factor
    available_read_bw = dse.bram_ports * dse.bram_partition
    memory_throughput = if reads_per_cycle <= available_read_bw
        dse.unroll_factor
    else
        available_read_bw ÷ workload.reads_per_item
    end

    # Compute-bound: limited by DSPs (for multiplies)
    dsps_per_item = workload.multiplies_per_item
    dsps_per_cycle = dsps_per_item * dse.unroll_factor
    compute_throughput = if dsps_per_cycle <= dse.max_dsps
        dse.unroll_factor
    else
        dse.max_dsps ÷ max(1, dsps_per_item)
    end

    # Effective throughput is the minimum
    effective = max(1, min(memory_throughput, compute_throughput))

    memory_bound = memory_throughput < compute_throughput
    compute_bound = compute_throughput <= memory_throughput

    return (effective, memory_bound, compute_bound)
end

"""
    reset!(sim::ParametricSimulator)

Reset simulator to initial state.
"""
function reset!(sim::ParametricSimulator)
    sim.clock_cycle = 0
    sim.items_processed = 0
    sim.total_active_cycles = 0
    sim.total_stall_cycles = 0

    fill!(sim.pipeline_stages, 0)
    fill!(sim.pipeline_valid, false)

    # Recalculate throughput (DSE params may have changed)
    throughput, mem_bound, comp_bound = calculate_throughput(sim.workload, sim.dse)
    sim.effective_throughput = throughput
    sim.memory_bound = mem_bound
    sim.compute_bound = comp_bound

    # Resize pipeline if needed
    if length(sim.pipeline_stages) != sim.dse.pipeline_depth
        sim.pipeline_stages = zeros(Int, sim.dse.pipeline_depth)
        sim.pipeline_valid = fill(false, sim.dse.pipeline_depth)
        resize_pipeline!(sim.observables, sim.dse.pipeline_depth)
    end

    # Reset observables
    reset!(sim.observables)
    sim.running = false
end

"""
    tick!(sim::ParametricSimulator)

Execute one clock cycle with DSE-aware behavior.
Returns true if simulation should continue.
"""
function tick!(sim::ParametricSimulator)::Bool
    if sim.items_processed >= sim.total_items
        sim.running = false
        return false
    end

    sim.clock_cycle += 1
    sim.running = true

    # Shift pipeline stages (simulate hardware registers)
    for i in length(sim.pipeline_stages):-1:2
        sim.pipeline_stages[i] = sim.pipeline_stages[i-1]
        sim.pipeline_valid[i] = sim.pipeline_valid[i-1]
    end

    # Determine if we can start new work this cycle
    can_start = (sim.clock_cycle % sim.dse.initiation_interval == 0)

    if can_start && sim.items_processed < sim.total_items
        # Calculate how many items we can process
        remaining = sim.total_items - sim.items_processed
        items = min(sim.effective_throughput, remaining)

        sim.pipeline_stages[1] = items
        sim.pipeline_valid[1] = items > 0
        sim.items_processed += items
        sim.total_active_cycles += 1
    else
        sim.pipeline_stages[1] = 0
        sim.pipeline_valid[1] = false
        if !can_start
            sim.total_stall_cycles += 1
        end
    end

    # Update observables
    update_observables!(sim)

    return sim.items_processed < sim.total_items
end

"""
    update_observables!(sim::ParametricSimulator)

Push current state to observables for UI update.
"""
function update_observables!(sim::ParametricSimulator)
    obs = sim.observables

    # Time and progress
    obs.clock[] = sim.clock_cycle
    obs.progress[] = sim.items_processed / sim.total_items * 100.0

    # Pipeline state
    obs.pipeline[] = copy(sim.pipeline_stages)
    obs.pipeline_valid[] = copy(sim.pipeline_valid)

    # Throughput
    if sim.clock_cycle > 0
        current_throughput = sim.items_processed / sim.clock_cycle
        obs.throughput[] = current_throughput
        push!(obs.throughput_history[], current_throughput)
        notify(obs.throughput_history)
    end

    # Resource utilization
    total_active = sum(sim.pipeline_stages)
    max_possible = sim.dse.unroll_factor * sim.dse.pipeline_depth

    # DSP utilization based on active multipliers
    active_dsps = total_active * sim.workload.multiplies_per_item
    obs.dsp_util[] = active_dsps / sim.dse.max_dsps * 100.0

    # BRAM utilization based on memory bandwidth
    active_reads = sim.pipeline_stages[1] * sim.workload.reads_per_item
    max_reads = sim.dse.bram_ports * sim.dse.bram_partition
    obs.memory_bw[] = active_reads / max_reads * 100.0

    # FSM state
    if sim.items_processed >= sim.total_items
        obs.fsm_state[] = "DONE"
        obs.is_done[] = true
    elseif sim.items_processed == 0
        obs.fsm_state[] = "IDLE"
    else
        obs.fsm_state[] = "RUNNING"
    end

    obs.is_running[] = sim.running
end

"""
    run!(sim::ParametricSimulator; max_cycles::Int=100000, callback=nothing)

Run simulation until completion or max cycles.
Optional callback is called each cycle for UI updates.
"""
function run!(sim::ParametricSimulator;
              max_cycles::Int=100000,
              callback::Union{Function, Nothing}=nothing,
              yield_interval::Int=10)

    reset!(sim)
    cycle = 0

    while tick!(sim) && cycle < max_cycles
        cycle += 1

        if callback !== nothing
            callback(sim)
        end

        # Yield to allow UI updates
        if cycle % yield_interval == 0
            yield()
        end
    end

    return get_results(sim)
end

"""
    run_async!(sim::ParametricSimulator; kwargs...)

Run simulation asynchronously, returning immediately.
Use sim.observables to monitor progress.
"""
function run_async!(sim::ParametricSimulator; kwargs...)
    @async run!(sim; kwargs...)
end

"""
    get_results(sim::ParametricSimulator)

Get simulation results as a NamedTuple.
"""
function get_results(sim::ParametricSimulator)
    return (
        total_cycles = sim.clock_cycle,
        items_processed = sim.items_processed,
        total_items = sim.total_items,
        throughput = sim.items_processed / max(1, sim.clock_cycle),
        effective_throughput = sim.effective_throughput,
        memory_bound = sim.memory_bound,
        compute_bound = sim.compute_bound,
        active_cycles = sim.total_active_cycles,
        stall_cycles = sim.total_stall_cycles,
        utilization = sim.total_active_cycles / max(1, sim.clock_cycle) * 100,
        completed = sim.items_processed >= sim.total_items
    )
end

"""
    estimate_performance(sim::ParametricSimulator)

Estimate final performance without running full simulation.
"""
function estimate_performance(sim::ParametricSimulator)
    items = sim.total_items

    # Items per initiation interval
    items_per_ii = sim.effective_throughput

    # Total IIs needed
    total_iis = ceil(Int, items / items_per_ii)

    # Total cycles = IIs * II + pipeline depth
    total_cycles = total_iis * sim.dse.initiation_interval + sim.dse.pipeline_depth

    return (
        estimated_cycles = total_cycles,
        estimated_throughput = items / total_cycles,
        memory_bound = sim.memory_bound,
        compute_bound = sim.compute_bound,
        bottleneck = sim.memory_bound ? "Memory" : "Compute"
    )
end

# ============================================================================
# DSE Sweep Functions
# ============================================================================

"""
    sweep_unroll_factor(workload::WorkloadDescriptor, range::UnitRange{Int};
                        base_dse::DSEParameters=DSEParameters())

Sweep unroll factor and collect performance metrics.
"""
function sweep_unroll_factor(workload::WorkloadDescriptor, range::UnitRange{Int};
                             base_dse::DSEParameters=DSEParameters())
    results = []

    for uf in range
        dse = deepcopy(base_dse)
        dse.unroll_factor = uf

        sim = ParametricSimulator(workload; dse=dse)
        est = estimate_performance(sim)

        push!(results, (
            unroll_factor = uf,
            cycles = est.estimated_cycles,
            throughput = est.estimated_throughput,
            memory_bound = est.memory_bound
        ))
    end

    return results
end

"""
    sweep_dse_space(workload::WorkloadDescriptor;
                    unroll_range::UnitRange{Int}=1:8,
                    ii_range::UnitRange{Int}=1:2,
                    bram_range::UnitRange{Int}=1:4)

Sweep multiple DSE parameters and return Pareto points.
"""
function sweep_dse_space(workload::WorkloadDescriptor;
                         unroll_range::UnitRange{Int}=1:8,
                         ii_range::UnitRange{Int}=1:2,
                         bram_range::UnitRange{Int}=1:4,
                         base_dse::DSEParameters=DSEParameters())

    points = ParetoPoint[]

    for uf in unroll_range
        for ii in ii_range
            for bp in bram_range
                dse = deepcopy(base_dse)
                dse.unroll_factor = uf
                dse.initiation_interval = ii
                dse.bram_ports = bp

                sim = ParametricSimulator(workload; dse=dse)
                est = estimate_performance(sim)

                # Estimate resource usage
                dsp_usage = uf * workload.multiplies_per_item
                bram_usage = bp

                push!(points, ParetoPoint(
                    dse,
                    est.estimated_cycles,
                    est.estimated_throughput,
                    dsp_usage,
                    bram_usage,
                    est.memory_bound,
                    false  # on_frontier computed later
                ))
            end
        end
    end

    return points
end

"""
    find_optimal_config(workload::WorkloadDescriptor;
                        optimize_for::Symbol=:throughput,
                        constraints::DSEParameters=DSEParameters())

Find optimal DSE configuration for the given workload.
"""
function find_optimal_config(workload::WorkloadDescriptor;
                             optimize_for::Symbol=:throughput,
                             max_dsps::Int=64,
                             max_brams::Int=32)

    best_config = nothing
    best_score = optimize_for == :throughput ? 0.0 : Inf

    for uf in 1:16
        for ii in 1:3
            for bp in 1:8
                dse = DSEParameters(
                    unroll_factor=uf,
                    initiation_interval=ii,
                    bram_ports=bp,
                    max_dsps=max_dsps
                )

                # Check resource constraints
                dsp_needed = uf * workload.multiplies_per_item
                if dsp_needed > max_dsps
                    continue
                end
                if bp > max_brams
                    continue
                end

                sim = ParametricSimulator(workload; dse=dse)
                est = estimate_performance(sim)

                score = if optimize_for == :throughput
                    est.estimated_throughput
                elseif optimize_for == :latency
                    -est.estimated_cycles  # Negative because we're maximizing
                elseif optimize_for == :efficiency
                    est.estimated_throughput / dsp_needed
                else
                    est.estimated_throughput
                end

                if (optimize_for == :latency && score > best_score) ||
                   (optimize_for != :latency && score > best_score)
                    best_score = score
                    best_config = dse
                end
            end
        end
    end

    return best_config
end
