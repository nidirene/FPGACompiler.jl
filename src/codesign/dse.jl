# Design Space Exploration Parameters
# Defines DSE parameters that affect hardware generation and simulation

# ============================================================================
# DSE Parameters
# ============================================================================

"""
    DSEParameters

Design Space Exploration parameters that affect hardware generation.
These control the tradeoffs between throughput, latency, and resource usage.
"""
Base.@kwdef mutable struct DSEParameters
    # Pipeline configuration
    unroll_factor::Int = 1          # Parallel computation units (1-16)
    initiation_interval::Int = 1    # Cycles between new inputs (1-4)
    pipeline_depth::Int = 5         # Number of pipeline stages

    # Memory configuration
    bram_ports::Int = 2             # Max simultaneous memory accesses (1-8)
    bram_partition::Int = 1         # Memory partitioning factor
    bram_latency::Int = 2           # BRAM read latency in cycles

    # Resource allocation
    max_dsps::Int = 16              # DSP blocks available
    max_alus::Int = 32              # ALU units available
    max_brams::Int = 64             # BRAM blocks available

    # Clock configuration
    target_freq_mhz::Float64 = 100.0
end

"""
    DSERange

Defines valid ranges for DSE parameter sweeps.
"""
struct DSERange
    unroll_factor::UnitRange{Int}
    initiation_interval::UnitRange{Int}
    bram_ports::UnitRange{Int}
    bram_partition::UnitRange{Int}
    max_dsps::UnitRange{Int}
end

const DEFAULT_DSE_RANGE = DSERange(
    1:16,   # unroll_factor
    1:4,    # initiation_interval
    1:8,    # bram_ports
    1:8,    # bram_partition
    1:64    # max_dsps
)

"""
    validate_dse(dse::DSEParameters)

Validate DSE parameters are within reasonable bounds.
Returns list of warnings.
"""
function validate_dse(dse::DSEParameters)::Vector{String}
    warnings = String[]

    if dse.unroll_factor < 1
        push!(warnings, "unroll_factor must be >= 1")
    end
    if dse.unroll_factor > 64
        push!(warnings, "unroll_factor > 64 is unusually high")
    end
    if dse.initiation_interval < 1
        push!(warnings, "initiation_interval must be >= 1")
    end
    if dse.bram_ports < 1
        push!(warnings, "bram_ports must be >= 1")
    end
    if dse.pipeline_depth < 1
        push!(warnings, "pipeline_depth must be >= 1")
    end

    return warnings
end

"""
    estimate_resources(dse::DSEParameters, workload::WorkloadDescriptor)

Estimate FPGA resource usage for given DSE configuration.
"""
function estimate_resources(dse::DSEParameters, workload)
    # DSP usage: multipliers needed per cycle
    dsps_needed = dse.unroll_factor * workload.multiplies_per_item

    # BRAM usage: ports needed for memory access
    bram_ports_needed = dse.unroll_factor * workload.reads_per_item

    # LUT estimate (rough)
    luts_per_alu = 50
    luts_per_mux = 20
    luts_needed = dse.unroll_factor * (workload.adds_per_item * luts_per_alu +
                                        workload.multiplies_per_item * luts_per_mux)

    # FF estimate (registers for pipeline)
    ffs_per_stage = dse.unroll_factor * 32  # Assuming 32-bit data
    ffs_needed = dse.pipeline_depth * ffs_per_stage

    return (
        dsps = dsps_needed,
        bram_ports = bram_ports_needed,
        luts = luts_needed,
        ffs = ffs_needed,
        dsp_utilization = dsps_needed / dse.max_dsps * 100,
        feasible = dsps_needed <= dse.max_dsps && bram_ports_needed <= dse.bram_ports * dse.bram_partition
    )
end

# ============================================================================
# Workload Descriptor
# ============================================================================

"""
    WorkloadDescriptor

Describes kernel computation characteristics for parametric simulation.
Used for quick DSE exploration without full compilation.
"""
struct WorkloadDescriptor
    name::String

    # Workload dimensions (what KA @kernel would produce)
    ndrange::Tuple{Vararg{Int}}         # e.g., (28, 28) for MNIST
    workgroup_size::Tuple{Vararg{Int}}  # e.g., (1, 1) for sequential

    # Per-item computation profile
    multiplies_per_item::Int            # Multiply operations per work item
    adds_per_item::Int                  # Add operations per work item
    compares_per_item::Int              # Compare operations per work item

    # Memory access profile
    reads_per_item::Int                 # Memory reads per work item
    writes_per_item::Int                # Memory writes per work item

    # Data types
    data_width_bits::Int                # Data width (e.g., 32 for Float32)

    # Optional: reference Julia function for validation
    reference_func::Union{Function, Nothing}
end

# Default constructor
function WorkloadDescriptor(name::String, ndrange::Tuple{Vararg{Int}};
                            workgroup_size::Tuple{Vararg{Int}}=(1,),
                            multiplies::Int=1, adds::Int=0, compares::Int=0,
                            reads::Int=1, writes::Int=1,
                            data_width::Int=32,
                            reference::Union{Function, Nothing}=nothing)
    WorkloadDescriptor(name, ndrange, workgroup_size,
                       multiplies, adds, compares, reads, writes,
                       data_width, reference)
end

"""
    total_items(workload::WorkloadDescriptor)

Get total number of work items.
"""
total_items(workload::WorkloadDescriptor) = prod(workload.ndrange)

"""
    total_ops(workload::WorkloadDescriptor)

Get total operations across all work items.
"""
function total_ops(workload::WorkloadDescriptor)
    items = total_items(workload)
    ops_per_item = workload.multiplies_per_item + workload.adds_per_item + workload.compares_per_item
    return items * ops_per_item
end

"""
    total_memory_accesses(workload::WorkloadDescriptor)

Get total memory accesses across all work items.
"""
function total_memory_accesses(workload::WorkloadDescriptor)
    items = total_items(workload)
    return items * (workload.reads_per_item + workload.writes_per_item)
end

# ============================================================================
# Common Workload Patterns
# ============================================================================

"""
    conv2d_workload(; kernel_size, img_height, img_width, name)

Create workload descriptor for 2D convolution.
"""
function conv2d_workload(; kernel_size::Int=3, img_height::Int=28, img_width::Int=28,
                          name::String="Conv2D")
    ks2 = kernel_size^2
    WorkloadDescriptor(
        "$name $(kernel_size)x$(kernel_size)",
        (img_height, img_width),
        workgroup_size=(1, 1),
        multiplies=ks2,           # One multiply per kernel element
        adds=ks2 - 1,             # Reduction tree
        compares=0,
        reads=ks2,                # Read kernel window
        writes=1,                 # Write one output pixel
        data_width=32
    )
end

"""
    matmul_workload(; M, N, K, name)

Create workload descriptor for matrix multiplication C[M,N] = A[M,K] * B[K,N].
"""
function matmul_workload(; M::Int=64, N::Int=64, K::Int=64,
                          name::String="MatMul")
    WorkloadDescriptor(
        "$name $(M)x$(K) × $(K)x$(N)",
        (M, N),
        workgroup_size=(1, 1),
        multiplies=K,             # K multiplies per output element
        adds=K - 1,               # K-1 adds for reduction
        compares=0,
        reads=2 * K,              # Read row of A and column of B
        writes=1,                 # Write one output element
        data_width=32
    )
end

"""
    elementwise_workload(; height, width, ops_per_element, name)

Create workload descriptor for elementwise operations.
"""
function elementwise_workload(; height::Int=1024, width::Int=1,
                               ops_per_element::Int=1,
                               name::String="Elementwise")
    WorkloadDescriptor(
        "$name $(height)x$(width)",
        width == 1 ? (height,) : (height, width),
        workgroup_size=(1,),
        multiplies=ops_per_element,
        adds=0,
        compares=0,
        reads=1,
        writes=1,
        data_width=32
    )
end

"""
    reduction_workload(; length, name)

Create workload descriptor for reduction (sum, max, etc.).
"""
function reduction_workload(; length::Int=1024, name::String="Reduction")
    # Reduction tree: log2(length) stages
    stages = ceil(Int, log2(length))
    WorkloadDescriptor(
        "$name length=$length",
        (length,),
        workgroup_size=(1,),
        multiplies=0,
        adds=1,                   # One add per element
        compares=0,
        reads=1,                  # Read element
        writes=0,                 # Only final write
        data_width=32
    )
end

"""
    fir_filter_workload(; taps, samples, name)

Create workload descriptor for FIR filter.
"""
function fir_filter_workload(; taps::Int=16, samples::Int=1024,
                              name::String="FIR Filter")
    WorkloadDescriptor(
        "$name taps=$taps samples=$samples",
        (samples,),
        workgroup_size=(1,),
        multiplies=taps,          # One multiply per tap
        adds=taps - 1,            # Accumulation
        compares=0,
        reads=taps + 1,           # Read taps + current sample
        writes=1,                 # Write filtered output
        data_width=32
    )
end
