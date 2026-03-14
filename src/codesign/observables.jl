# Observable Wrappers for Makie Integration
# Provides reactive state management for live visualization

using Observables

# ============================================================================
# Simulator Observables
# ============================================================================

"""
    SimulatorObservables

Observable wrappers for simulation state, enabling live Makie updates.
All fields are Observables that automatically trigger UI redraws when modified.
"""
mutable struct SimulatorObservables
    # Time
    clock::Observable{Int}
    progress::Observable{Float64}       # 0-100%

    # Pipeline state
    pipeline::Observable{Vector{Int}}   # Items per stage
    pipeline_valid::Observable{Vector{Bool}}

    # Throughput
    throughput::Observable{Float64}     # Current items/cycle
    throughput_history::Observable{Vector{Float64}}

    # Resource utilization (0-100%)
    dsp_util::Observable{Float64}
    bram_util::Observable{Float64}
    lut_util::Observable{Float64}

    # Memory
    memory_bw::Observable{Float64}      # Memory bandwidth utilization
    pending_reads::Observable{Int}
    pending_writes::Observable{Int}

    # FSM state
    fsm_state::Observable{String}
    fsm_state_id::Observable{Int}

    # Completion
    is_done::Observable{Bool}
    is_running::Observable{Bool}
end

"""
    SimulatorObservables(pipeline_depth::Int=5)

Create a new SimulatorObservables instance with default values.
"""
function SimulatorObservables(pipeline_depth::Int=5)
    SimulatorObservables(
        Observable(0),
        Observable(0.0),
        Observable(zeros(Int, pipeline_depth)),
        Observable(fill(false, pipeline_depth)),
        Observable(0.0),
        Observable(Float64[]),
        Observable(0.0),
        Observable(0.0),
        Observable(0.0),
        Observable(0.0),
        Observable(0),
        Observable(0),
        Observable("IDLE"),
        Observable(0),
        Observable(false),
        Observable(false)
    )
end

"""
    reset!(obs::SimulatorObservables)

Reset all observables to initial state.
"""
function reset!(obs::SimulatorObservables)
    obs.clock[] = 0
    obs.progress[] = 0.0
    fill!(obs.pipeline[], 0)
    notify(obs.pipeline)
    fill!(obs.pipeline_valid[], false)
    notify(obs.pipeline_valid)
    obs.throughput[] = 0.0
    empty!(obs.throughput_history[])
    notify(obs.throughput_history)
    obs.dsp_util[] = 0.0
    obs.bram_util[] = 0.0
    obs.lut_util[] = 0.0
    obs.memory_bw[] = 0.0
    obs.pending_reads[] = 0
    obs.pending_writes[] = 0
    obs.fsm_state[] = "IDLE"
    obs.fsm_state_id[] = 0
    obs.is_done[] = false
    obs.is_running[] = false
end

"""
    resize_pipeline!(obs::SimulatorObservables, depth::Int)

Resize pipeline observables for different pipeline depths.
"""
function resize_pipeline!(obs::SimulatorObservables, depth::Int)
    obs.pipeline[] = zeros(Int, depth)
    obs.pipeline_valid[] = fill(false, depth)
end

# ============================================================================
# DSE Observables
# ============================================================================

"""
    DSEObservables

Observable wrappers for DSE parameters, enabling reactive UI updates.
"""
mutable struct DSEObservables
    unroll_factor::Observable{Int}
    initiation_interval::Observable{Int}
    pipeline_depth::Observable{Int}
    bram_ports::Observable{Int}
    bram_partition::Observable{Int}
    max_dsps::Observable{Int}
    target_freq_mhz::Observable{Float64}
end

"""
    DSEObservables(dse::DSEParameters)

Create DSEObservables from DSEParameters.
"""
function DSEObservables(dse::DSEParameters)
    DSEObservables(
        Observable(dse.unroll_factor),
        Observable(dse.initiation_interval),
        Observable(dse.pipeline_depth),
        Observable(dse.bram_ports),
        Observable(dse.bram_partition),
        Observable(dse.max_dsps),
        Observable(dse.target_freq_mhz)
    )
end

"""
    to_parameters(obs::DSEObservables)

Convert DSEObservables to DSEParameters.
"""
function to_parameters(obs::DSEObservables)::DSEParameters
    DSEParameters(
        unroll_factor=obs.unroll_factor[],
        initiation_interval=obs.initiation_interval[],
        pipeline_depth=obs.pipeline_depth[],
        bram_ports=obs.bram_ports[],
        bram_partition=obs.bram_partition[],
        max_dsps=obs.max_dsps[]
    )
end

"""
    sync_from!(obs::DSEObservables, dse::DSEParameters)

Sync observable values from DSEParameters.
"""
function sync_from!(obs::DSEObservables, dse::DSEParameters)
    obs.unroll_factor[] = dse.unroll_factor
    obs.initiation_interval[] = dse.initiation_interval
    obs.pipeline_depth[] = dse.pipeline_depth
    obs.bram_ports[] = dse.bram_ports
    obs.bram_partition[] = dse.bram_partition
    obs.max_dsps[] = dse.max_dsps
    obs.target_freq_mhz[] = dse.target_freq_mhz
end

"""
    sync_to!(dse::DSEParameters, obs::DSEObservables)

Sync DSEParameters from observable values.
"""
function sync_to!(dse::DSEParameters, obs::DSEObservables)
    dse.unroll_factor = obs.unroll_factor[]
    dse.initiation_interval = obs.initiation_interval[]
    dse.pipeline_depth = obs.pipeline_depth[]
    dse.bram_ports = obs.bram_ports[]
    dse.bram_partition = obs.bram_partition[]
    dse.max_dsps = obs.max_dsps[]
    dse.target_freq_mhz = obs.target_freq_mhz[]
end

# ============================================================================
# Performance Result Observables
# ============================================================================

"""
    ResultObservables

Observable wrappers for simulation results.
"""
mutable struct ResultObservables
    total_cycles::Observable{Int}
    achieved_throughput::Observable{Float64}
    achieved_latency_ns::Observable{Float64}
    memory_bound::Observable{Bool}
    compute_bound::Observable{Bool}
    estimated_power_w::Observable{Float64}
end

function ResultObservables()
    ResultObservables(
        Observable(0),
        Observable(0.0),
        Observable(0.0),
        Observable(false),
        Observable(false),
        Observable(0.0)
    )
end

# ============================================================================
# Pareto Data Observable
# ============================================================================

"""
    ParetoPoint

A single point in the Pareto analysis.
"""
struct ParetoPoint
    dse::DSEParameters
    cycles::Int
    throughput::Float64
    dsp_usage::Int
    bram_usage::Int
    memory_bound::Bool
    on_frontier::Bool
end

"""
    ParetoObservables

Observable wrapper for Pareto analysis data.
"""
mutable struct ParetoObservables
    points::Observable{Vector{ParetoPoint}}
    frontier::Observable{Vector{ParetoPoint}}
    selected_point::Observable{Union{ParetoPoint, Nothing}}
end

function ParetoObservables()
    ParetoObservables(
        Observable(ParetoPoint[]),
        Observable(ParetoPoint[]),
        Observable(nothing)
    )
end

"""
    update_pareto!(pareto::ParetoObservables, points::Vector{ParetoPoint})

Update Pareto data and compute frontier.
"""
function update_pareto!(pareto::ParetoObservables, points::Vector{ParetoPoint})
    pareto.points[] = points

    # Compute Pareto frontier (maximize throughput, minimize DSP)
    frontier = ParetoPoint[]
    sorted = sort(points, by=p -> (p.dsp_usage, -p.throughput))

    max_throughput = 0.0
    for pt in sorted
        if pt.throughput > max_throughput
            push!(frontier, pt)
            max_throughput = pt.throughput
        end
    end

    pareto.frontier[] = frontier
end

# ============================================================================
# Observable Helpers
# ============================================================================

"""
    throttled_update!(obs::Observable, value; min_interval_ms::Int=16)

Update observable with throttling to prevent excessive UI updates.
"""
const _last_update_times = Dict{UInt, Float64}()

function throttled_update!(obs::Observable{T}, value::T;
                           min_interval_ms::Int=16) where T
    key = objectid(obs)
    current_time = time() * 1000  # ms

    if !haskey(_last_update_times, key) ||
       (current_time - _last_update_times[key]) >= min_interval_ms
        obs[] = value
        _last_update_times[key] = current_time
    end
end

"""
    batch_update!(f::Function)

Execute multiple observable updates in a single batch.
Useful for reducing UI update overhead.
"""
function batch_update!(f::Function)
    # Note: This is a placeholder. Real implementation would
    # need to integrate with Makie's update scheduler
    f()
end
