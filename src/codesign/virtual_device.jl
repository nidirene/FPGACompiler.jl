# Virtual FPGA Device Abstraction
# Provides memory and PCIe simulation for co-design environment

# ============================================================================
# Virtual PCIe Interface
# ============================================================================

"""
    VirtualPCIe

Simulates PCIe transfer characteristics between host and FPGA.
"""
struct VirtualPCIe
    bandwidth_GBps::Float64     # PCIe bandwidth (e.g., 16 GB/s for Gen4 x16)
    latency_ns::Float64         # Round-trip latency in nanoseconds
    clock_freq_mhz::Float64     # FPGA clock frequency for cycle conversion
end

# Common PCIe configurations
const PCIE_GEN3_X16 = VirtualPCIe(16.0, 1000.0, 250.0)
const PCIE_GEN4_X16 = VirtualPCIe(32.0, 800.0, 300.0)
const PCIE_GEN5_X16 = VirtualPCIe(64.0, 600.0, 400.0)
const AXI_ZYNQ = VirtualPCIe(4.0, 200.0, 100.0)  # AXI for embedded

"""
    transfer_cycles(pcie::VirtualPCIe, bytes::Int)

Calculate number of FPGA clock cycles for a PCIe transfer.
"""
function transfer_cycles(pcie::VirtualPCIe, bytes::Int)::Int
    # Transfer time = data/bandwidth + latency
    transfer_time_ns = (bytes / pcie.bandwidth_GBps) * 1e9
    total_time_ns = transfer_time_ns + pcie.latency_ns

    # Convert to FPGA clock cycles
    cycles_per_ns = pcie.clock_freq_mhz / 1000.0
    return ceil(Int, total_time_ns * cycles_per_ns)
end

# ============================================================================
# Virtual FPGA Array
# ============================================================================

"""
    VirtualFPGAArray{T,N}

Array type that mimics FPGA device memory with transfer simulation.
Behaves like a regular array but tracks memory access statistics.
"""
mutable struct VirtualFPGAArray{T,N} <: AbstractArray{T,N}
    data::Array{T,N}

    # Memory configuration
    memory_type::Symbol          # :bram, :uram, :hbm, :ddr
    partition_factor::Int        # BRAM partitioning factor
    partition_style::Symbol      # :cyclic, :block, :complete

    # Access statistics
    total_reads::Int
    total_writes::Int
    bytes_transferred::Int

    # Access history for visualization (cycle, address, is_write)
    access_history::Vector{Tuple{Int, Int, Bool}}
    track_accesses::Bool
end

# Constructors
function VirtualFPGAArray{T,N}(::UndefInitializer, dims::NTuple{N,Int};
                                memory_type::Symbol=:bram,
                                partition_factor::Int=1,
                                partition_style::Symbol=:cyclic) where {T,N}
    VirtualFPGAArray{T,N}(
        Array{T,N}(undef, dims),
        memory_type, partition_factor, partition_style,
        0, 0, 0,
        Tuple{Int, Int, Bool}[],
        false
    )
end

function VirtualFPGAArray(data::Array{T,N};
                          memory_type::Symbol=:bram,
                          partition_factor::Int=1,
                          partition_style::Symbol=:cyclic) where {T,N}
    VirtualFPGAArray{T,N}(
        copy(data),
        memory_type, partition_factor, partition_style,
        0, 0, 0,
        Tuple{Int, Int, Bool}[],
        false
    )
end

# Array interface
Base.size(a::VirtualFPGAArray) = size(a.data)
Base.length(a::VirtualFPGAArray) = length(a.data)
Base.eltype(::Type{VirtualFPGAArray{T,N}}) where {T,N} = T
Base.ndims(::Type{VirtualFPGAArray{T,N}}) where {T,N} = N

function Base.getindex(a::VirtualFPGAArray, I...)
    a.total_reads += 1
    if a.track_accesses
        idx = LinearIndices(a.data)[I...]
        push!(a.access_history, (0, idx, false))
    end
    return getindex(a.data, I...)
end

function Base.setindex!(a::VirtualFPGAArray, v, I...)
    a.total_writes += 1
    if a.track_accesses
        idx = LinearIndices(a.data)[I...]
        push!(a.access_history, (0, idx, true))
    end
    return setindex!(a.data, v, I...)
end

Base.similar(a::VirtualFPGAArray{T,N}, ::Type{S}, dims::Dims{M}) where {T,N,S,M} =
    VirtualFPGAArray{S,M}(undef, dims;
                          memory_type=a.memory_type,
                          partition_factor=a.partition_factor,
                          partition_style=a.partition_style)

Base.IndexStyle(::Type{<:VirtualFPGAArray}) = IndexLinear()

"""
    reset_stats!(a::VirtualFPGAArray)

Reset access statistics.
"""
function reset_stats!(a::VirtualFPGAArray)
    a.total_reads = 0
    a.total_writes = 0
    a.bytes_transferred = 0
    empty!(a.access_history)
end

"""
    enable_tracking!(a::VirtualFPGAArray, enable::Bool=true)

Enable or disable access tracking for visualization.
"""
function enable_tracking!(a::VirtualFPGAArray, enable::Bool=true)
    a.track_accesses = enable
    if !enable
        empty!(a.access_history)
    end
end

# ============================================================================
# Virtual FPGA Device
# ============================================================================

"""
    VirtualFPGADevice

Complete virtual FPGA device with resources and interfaces.
"""
mutable struct VirtualFPGADevice
    name::String

    # Resource configuration
    total_luts::Int
    total_ffs::Int
    total_brams::Int           # In 18Kb blocks
    total_dsps::Int
    total_uram::Int            # UltraRAM blocks (if available)

    # Clock
    clock_freq_mhz::Float64

    # Current resource usage
    used_luts::Int
    used_ffs::Int
    used_brams::Int
    used_dsps::Int

    # Interface
    pcie::VirtualPCIe

    # Allocated memories
    memories::Dict{Symbol, VirtualFPGAArray}

    # Statistics
    total_compute_cycles::Int
    total_transfer_cycles::Int
    total_idle_cycles::Int
end

# Default constructor
function VirtualFPGADevice(name::String="Virtual FPGA";
                           luts::Int=100000,
                           ffs::Int=200000,
                           brams::Int=200,
                           dsps::Int=200,
                           uram::Int=0,
                           clock_mhz::Float64=100.0,
                           pcie::VirtualPCIe=PCIE_GEN3_X16)
    VirtualFPGADevice(
        name,
        luts, ffs, brams, dsps, uram,
        clock_mhz,
        0, 0, 0, 0,
        pcie,
        Dict{Symbol, VirtualFPGAArray}(),
        0, 0, 0
    )
end

# Preset device configurations
function alveo_u200()
    VirtualFPGADevice(
        "Alveo U200 (XCU200)",
        luts=1182240,
        ffs=2364480,
        brams=2160,
        dsps=6840,
        uram=960,
        clock_mhz=300.0,
        pcie=PCIE_GEN3_X16
    )
end

function alveo_u280()
    VirtualFPGADevice(
        "Alveo U280 (XCU280)",
        luts=1304000,
        ffs=2607360,
        brams=2016,
        dsps=9024,
        uram=960,
        clock_mhz=300.0,
        pcie=PCIE_GEN4_X16
    )
end

function zynq_7020()
    VirtualFPGADevice(
        "Zynq-7020 (XC7Z020)",
        luts=53200,
        ffs=106400,
        brams=140,
        dsps=220,
        uram=0,
        clock_mhz=100.0,
        pcie=AXI_ZYNQ
    )
end

function arty_a7()
    VirtualFPGADevice(
        "Arty A7-35T",
        luts=20800,
        ffs=41600,
        brams=50,
        dsps=90,
        uram=0,
        clock_mhz=100.0,
        pcie=AXI_ZYNQ
    )
end

"""
    allocate!(device::VirtualFPGADevice, name::Symbol, ::Type{T}, dims::Tuple;
              memory_type::Symbol=:bram) where T

Allocate memory on the virtual FPGA device.
"""
function allocate!(device::VirtualFPGADevice, name::Symbol, ::Type{T}, dims::Tuple;
                   memory_type::Symbol=:bram,
                   partition_factor::Int=1) where T
    arr = VirtualFPGAArray{T, length(dims)}(undef, dims;
                                             memory_type=memory_type,
                                             partition_factor=partition_factor)
    device.memories[name] = arr

    # Update BRAM usage estimate
    bytes = prod(dims) * sizeof(T)
    bram_18kb = ceil(Int, bytes / (18 * 1024))
    device.used_brams += bram_18kb * partition_factor

    return arr
end

"""
    copyto_device!(device::VirtualFPGADevice, dst::VirtualFPGAArray, src::Array)

Simulate PCIe DMA transfer to device memory.
Returns number of cycles for the transfer.
"""
function copyto_device!(device::VirtualFPGADevice,
                        dst::VirtualFPGAArray{T}, src::Array{T}) where T
    bytes = sizeof(T) * length(src)
    cycles = transfer_cycles(device.pcie, bytes)

    # Update statistics
    device.total_transfer_cycles += cycles
    dst.bytes_transferred += bytes

    # Copy data
    copyto!(dst.data, src)

    return cycles
end

"""
    copyto_host!(device::VirtualFPGADevice, dst::Array, src::VirtualFPGAArray)

Simulate PCIe DMA transfer from device to host.
Returns number of cycles for the transfer.
"""
function copyto_host!(device::VirtualFPGADevice,
                      dst::Array{T}, src::VirtualFPGAArray{T}) where T
    bytes = sizeof(T) * length(src)
    cycles = transfer_cycles(device.pcie, bytes)

    # Update statistics
    device.total_transfer_cycles += cycles
    src.bytes_transferred += bytes

    # Copy data
    copyto!(dst, src.data)

    return cycles
end

"""
    reset_device!(device::VirtualFPGADevice)

Reset device statistics and allocated memories.
"""
function reset_device!(device::VirtualFPGADevice)
    device.used_luts = 0
    device.used_ffs = 0
    device.used_brams = 0
    device.used_dsps = 0
    device.total_compute_cycles = 0
    device.total_transfer_cycles = 0
    device.total_idle_cycles = 0

    for (_, mem) in device.memories
        reset_stats!(mem)
    end

    empty!(device.memories)
end

"""
    resource_utilization(device::VirtualFPGADevice)

Get current resource utilization as percentages.
"""
function resource_utilization(device::VirtualFPGADevice)
    return (
        luts = device.used_luts / device.total_luts * 100,
        ffs = device.used_ffs / device.total_ffs * 100,
        brams = device.used_brams / device.total_brams * 100,
        dsps = device.used_dsps / device.total_dsps * 100
    )
end

"""
    print_device_info(device::VirtualFPGADevice)

Print device information and current utilization.
"""
function print_device_info(device::VirtualFPGADevice)
    util = resource_utilization(device)

    println("Device: $(device.name)")
    println("=" ^ 40)
    println("Resources:")
    println("  LUTs:  $(device.used_luts) / $(device.total_luts) ($(round(util.luts, digits=1))%)")
    println("  FFs:   $(device.used_ffs) / $(device.total_ffs) ($(round(util.ffs, digits=1))%)")
    println("  BRAMs: $(device.used_brams) / $(device.total_brams) ($(round(util.brams, digits=1))%)")
    println("  DSPs:  $(device.used_dsps) / $(device.total_dsps) ($(round(util.dsps, digits=1))%)")
    println()
    println("Clock: $(device.clock_freq_mhz) MHz")
    println("PCIe:  $(device.pcie.bandwidth_GBps) GB/s")
    println()
    println("Statistics:")
    println("  Compute cycles:  $(device.total_compute_cycles)")
    println("  Transfer cycles: $(device.total_transfer_cycles)")
    println("  Idle cycles:     $(device.total_idle_cycles)")
end
