# FPGACompiler.jl API Reference

This document provides a complete reference for all exported functions, types, and macros in FPGACompiler.jl.

## Table of Contents

- [Compilation Functions](#compilation-functions)
- [Types](#types)
- [Macros](#macros)
- [Metadata Functions](#metadata-functions)
- [Utility Functions](#utility-functions)
- [HLS Backend](#hls-backend)
- [RTL Generation](#rtl-generation)
- [Simulation](#simulation)
- [CoDesign Module](#codesign-module)

---

## Compilation Functions

### `fpga_compile`

```julia
fpga_compile(f, types::Type{<:Tuple}; params=FPGACompilerParams()) -> LLVM.Module
```

Compile a Julia function for FPGA synthesis, returning the optimized LLVM module.

**Arguments:**
- `f`: The Julia function to compile
- `types`: Tuple type of argument types (e.g., `Tuple{Float32, Float32}`)
- `params`: Optional `FPGACompilerParams` for compilation settings

**Returns:**
- `LLVM.Module`: The optimized LLVM module ready for HLS tools

**Example:**
```julia
function vadd(A, B, C, n)
    for i in 1:n
        @inbounds C[i] = A[i] + B[i]
    end
end

mod = fpga_compile(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})
```

---

### `fpga_code_llvm`

```julia
fpga_code_llvm(f, types::Type{<:Tuple}; params=FPGACompilerParams()) -> String
```

Return the LLVM IR as a string for inspection.

**Arguments:**
- `f`: The Julia function to compile
- `types`: Tuple type of argument types
- `params`: Optional compilation parameters

**Returns:**
- `String`: The LLVM IR text representation

**Example:**
```julia
ir = fpga_code_llvm(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})
println(ir)
```

---

### `fpga_code_native`

```julia
fpga_code_native(f, types::Type{<:Tuple};
                 format::Symbol=:ll,
                 output::Union{String, Nothing}=nothing,
                 params=FPGACompilerParams()) -> String
```

Write the compiled LLVM IR to a file for use with HLS tools.

**Arguments:**
- `f`: Function to compile
- `types`: Argument types
- `format`: Output format (`:ll` for text IR, `:bc` for bitcode)
- `output`: Output file path (auto-generated if not provided)
- `params`: Compilation parameters

**Returns:**
- `String`: Path to the output file

**Example:**
```julia
# Generate LLVM IR file
path = fpga_code_native(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int}, format=:ll)

# Feed to vendor HLS tool
run(`vitis_hls -f $path`)  # AMD Vitis
run(`aoc $path`)           # Intel oneAPI
```

---

## Types

### `FPGATarget`

```julia
struct FPGATarget <: GPUCompiler.AbstractCompilerTarget
```

Custom compiler target for FPGA High-Level Synthesis. This target configures LLVM to generate IR suitable for vendor HLS tools (Intel aoc, AMD Vitis HLS, or open-source tools like Bambu/CIRCT).

**Example:**
```julia
target = FPGATarget()
```

---

### `FPGACompilerParams`

```julia
Base.@kwdef struct FPGACompilerParams <: GPUCompiler.AbstractCompilerParams
    target_ii::Int = 1
    aggressive_inline::Bool = true
    partition_memory::Bool = true
    emit_llvm_ir::Bool = true
end
```

Parameters for FPGA compilation jobs.

**Fields:**
- `target_ii::Int`: Target initiation interval for loop pipelining (1 = fully pipelined)
- `aggressive_inline::Bool`: Enable aggressive inlining (required for FPGAs)
- `partition_memory::Bool`: Enable memory partitioning analysis
- `emit_llvm_ir::Bool`: Emit human-readable LLVM IR (.ll) instead of bitcode (.bc)

**Example:**
```julia
params = FPGACompilerParams(target_ii=2, aggressive_inline=true)
mod = fpga_compile(my_kernel, Tuple{Vector{Float32}}, params=params)
```

---

### `PartitionedArray`

```julia
struct PartitionedArray{T, N, Factor, Style}
    data::Array{T, N}
end
```

A wrapper around Julia arrays that signals memory partitioning intent to the HLS compiler. The array will be split across `Factor` BRAM banks using the specified `Style`.

**Type Parameters:**
- `T`: Element type
- `N`: Number of dimensions
- `Factor`: Number of memory banks to partition across
- `Style`: Partitioning strategy (`CYCLIC`, `BLOCK`, or `COMPLETE`)

**Constructors:**
```julia
# Full type specification
PartitionedArray{T, N, Factor, Style}(data::Array{T, N})

# Convenience constructor with keyword arguments
PartitionedArray(data::Array; factor::Int=2, style::PartitionStyle=CYCLIC)
```

**Example:**
```julia
# Partition a 1024-element array into 4 BRAM banks using cyclic distribution
A = PartitionedArray{Float32, 1, 4, CYCLIC}(zeros(Float32, 1024))

# Or using the convenience constructor
B = PartitionedArray(zeros(Float32, 1024); factor=4, style=CYCLIC)
```

**Helper Functions:**
```julia
partition_factor(pa::PartitionedArray) -> Int  # Get the partition factor
partition_style(pa::PartitionedArray) -> PartitionStyle  # Get the partition style
```

---

### `PartitionStyle`

```julia
@enum PartitionStyle begin
    CYCLIC    # Round-robin distribution across banks
    BLOCK     # Contiguous chunks per bank
    COMPLETE  # Fully partition into registers (small arrays only)
end
```

Enumeration of memory partitioning strategies for BRAM allocation.

**Values:**
- `CYCLIC`: Elements are distributed round-robin across memory banks. Element `i` goes to bank `i % factor`. Best for sequential access with stride != 1.
- `BLOCK`: Contiguous chunks are assigned to each bank. Elements 0 to N/factor go to bank 0, etc. Best for blocked access patterns.
- `COMPLETE`: Array is fully partitioned into individual registers. Only suitable for small arrays (< 64 elements typically).

---

### `FixedInt`

```julia
struct FixedInt{N, T<:Integer} <: Integer
    value::T
end
```

A fixed-width integer type that signals to the FPGA compiler to use exactly N bits in hardware.

**Type Parameters:**
- `N`: Number of bits (1-64)
- `T`: Storage type (Int8, Int16, Int32, Int64, or unsigned variants)

**Pre-defined Type Aliases:**
```julia
const Int7   = FixedInt{7, Int8}
const Int12  = FixedInt{12, Int16}
const Int14  = FixedInt{14, Int16}
const Int24  = FixedInt{24, Int32}
const UInt7  = FixedInt{7, UInt8}
const UInt12 = FixedInt{12, UInt16}
const UInt14 = FixedInt{14, UInt16}
const UInt24 = FixedInt{24, UInt32}
```

**Example:**
```julia
# 7-bit signed integer (stored in Int8, synthesized as i7)
x = FixedInt{7, Int8}(42)
# Or use the alias
x = Int7(42)

# 12-bit unsigned integer
y = UInt12(1000)

# Get the bit width
@assert bitwidth(x) == 7
```

**Helper Functions:**
```julia
bitwidth(x::FixedInt) -> Int  # Get the bit width N
```

---

## Macros

### `@fpga_kernel`

```julia
@fpga_kernel function_definition
```

Mark a function for FPGA compilation with automatic optimization hints and validation.

**Features:**
- Validates kernel constraints (no dynamic allocation, no exceptions)
- Enables hardware-specific optimizations
- Registers the function for FPGA compilation

**Example:**
```julia
@fpga_kernel function matrix_mul(A, B, C, M, N, K)
    for i in 1:M
        for j in 1:N
            sum = 0.0f0
            for k in 1:K
                @inbounds sum += A[i, k] * B[k, j]
            end
            @inbounds C[i, j] = sum
        end
    end
end
```

---

### `@pipeline`

```julia
@pipeline [II=n] loop
```

Mark a loop for hardware pipelining with target initiation interval.

**Arguments:**
- `II`: Target Initiation Interval (optional, default=1). II=1 means a new iteration starts every clock cycle.

**Hardware Effect:**
The HLS tool will overlap loop iterations, inserting shift registers and FIFOs to achieve the target II.

**Example:**
```julia
@fpga_kernel function pipelined_sum(A, n)
    sum = 0.0f0
    @pipeline II=1 for i in 1:n
        @inbounds sum += A[i]
    end
    return sum
end
```

---

### `@unroll`

```julia
@unroll [factor=n] loop
```

Mark a loop for hardware unrolling.

**Arguments:**
- `factor`: Number of iterations to unroll (optional). If omitted, the loop is fully unrolled.

**Hardware Effect:**
Duplicates loop body hardware `factor` times, allowing parallel execution of multiple iterations. Trades silicon area for throughput.

**Example:**
```julia
@fpga_kernel function unrolled_dot(A, B, n)
    sum = 0.0f0
    @unroll factor=4 for i in 1:n
        @inbounds sum += A[i] * B[i]
    end
    return sum
end
```

---

## Metadata Functions

These functions are used internally to inject HLS-specific metadata into LLVM IR. They can also be used directly for advanced use cases.

### `apply_pipeline_metadata!`

```julia
apply_pipeline_metadata!(loop_block::LLVM.BasicBlock, target_ii::Int) -> LLVM.Metadata
```

Attach loop pipelining metadata to a loop's terminating branch instruction.

**Arguments:**
- `loop_block`: The LLVM BasicBlock containing the loop latch (back-edge)
- `target_ii`: Target Initiation Interval (1 = new iteration every clock cycle)

---

### `apply_partition_metadata!`

```julia
apply_partition_metadata!(alloca_inst::LLVM.Instruction, factor::Int, style::PartitionStyle) -> LLVM.Metadata
```

Attach memory partitioning metadata to an array allocation.

**Arguments:**
- `alloca_inst`: The LLVM AllocaInst for the array
- `factor`: Number of BRAM banks to partition across
- `style`: Partitioning strategy (CYCLIC, BLOCK, or COMPLETE)

---

## Utility Functions

### `validate_kernel`

```julia
validate_kernel(f, types::Type{<:Tuple}) -> Vector{String}
```

Check if a function is valid for FPGA compilation. Returns a list of warnings/errors about potential synthesis issues.

**Checks:**
- Dynamic memory allocation (push!, resize!, Array constructors)
- Recursion (self-referential calls)
- Exception handling (try/catch blocks)
- Type inferrability (no Any types)

**Example:**
```julia
issues = validate_kernel(my_kernel, Tuple{Vector{Float32}, Int})
if !isempty(issues)
    for issue in issues
        @warn issue
    end
end
```

---

### `estimate_resources`

```julia
estimate_resources(f, types::Type{<:Tuple}) -> Dict{String, Int}
```

Estimate FPGA resource usage for a kernel based on IR analysis.

**Returns:**
A dictionary with estimated resource counts:
- `"estimated_luts"`: Look-Up Tables
- `"estimated_ffs"`: Flip-Flops
- `"estimated_dsps"`: DSP blocks
- `"estimated_brams"`: Block RAMs

**Note:** These are rough estimates. Actual resource usage depends on the target FPGA and vendor tool optimizations.

**Example:**
```julia
resources = estimate_resources(my_kernel, Tuple{Vector{Float32}, Int})
println("Estimated DSPs: ", resources["estimated_dsps"])
```

---

## HLS Backend

The HLS backend provides a native Julia implementation for High-Level Synthesis, bypassing vendor tools.

### HLS Types

#### `CDFG`

```julia
mutable struct CDFG
    name::String
    nodes::Vector{DFGNode}
    edges::Vector{DFGEdge}
    states::Vector{FSMState}
    ...
end
```

Combined Control and Data Flow Graph - the central intermediate representation for HLS.

**Constructor:**
```julia
cdfg = CDFG("kernel_name")
```

---

#### `DFGNode`

```julia
mutable struct DFGNode
    id::Int
    op::OperationType
    name::String
    bit_width::Int
    is_signed::Bool
    scheduled_cycle::Int
    latency::Int
    ...
end
```

Represents a single operation in the Data Flow Graph.

**Constructor:**
```julia
node = DFGNode(id, op, name)
```

---

#### `FSMState`

```julia
mutable struct FSMState
    id::Int
    name::String
    operations::Vector{DFGNode}
    successor_ids::Vector{Int}
    ...
end
```

Represents one state in the hardware Finite State Machine.

**Constructor:**
```julia
state = FSMState(id, name)
```

---

#### `HLSOptions`

```julia
struct HLSOptions
    scheduling_algorithm::Symbol  # :asap, :alap, :list, :ilp
    target_ii::Int
    target_clock_mhz::Float64
    constraints::ResourceConstraints
    enable_pipelining::Bool
    enable_resource_sharing::Bool
    ...
end
```

Configuration options for HLS synthesis.

**Constructor:**
```julia
opts = HLSOptions(
    scheduling_algorithm=:ilp,
    target_clock_mhz=100.0,
    enable_pipelining=true
)
```

---

#### `ResourceConstraints`

```julia
struct ResourceConstraints
    max_alus::Int
    max_dsps::Int
    max_fpus::Int
    max_dividers::Int
    max_bram_read_ports::Int
    max_bram_write_ports::Int
    ...
end
```

Hardware resource limits for scheduling.

**Constructor:**
```julia
constraints = ResourceConstraints(max_alus=8, max_dsps=4)
```

---

### Scheduling Functions

#### `schedule_asap!`

```julia
schedule_asap!(cdfg::CDFG) -> Schedule
```

Schedule operations as-soon-as-possible. Minimizes latency but may exceed resource constraints.

---

#### `schedule_alap!`

```julia
schedule_alap!(cdfg::CDFG) -> Schedule
```

Schedule operations as-late-as-possible. Useful for computing scheduling slack.

---

#### `schedule_list!`

```julia
schedule_list!(cdfg::CDFG, constraints::ResourceConstraints) -> Schedule
```

List scheduling with resource constraints. Balances latency with resource limits.

---

#### `schedule_ilp!`

```julia
schedule_ilp!(cdfg::CDFG; options::HLSOptions=HLSOptions()) -> Schedule
```

Optimal scheduling using Integer Linear Programming (JuMP.jl + HiGHS).

---

### Resource Binding

#### `bind_resources!`

```julia
bind_resources!(cdfg::CDFG, schedule::Schedule)
```

Bind operations to physical hardware resources using the left-edge algorithm.

---

#### `get_resource_count`

```julia
get_resource_count(cdfg::CDFG) -> Dict{ResourceType, Int}
```

Get the number of each resource type needed after binding.

---

### Analysis Functions

#### `analyze_critical_path`

```julia
analyze_critical_path(cdfg::CDFG) -> Dict{String, Any}
```

Analyze the critical path and identify bottlenecks.

**Returns:**
- `"length"`: Critical path length in cycles
- `"nodes"`: Node names on critical path
- `"bottlenecks"`: High-latency operations

---

#### `analyze_resource_usage`

```julia
analyze_resource_usage(cdfg::CDFG) -> Dict{String, Any}
```

Analyze resource usage and identify optimization opportunities.

---

#### `analyze_parallelism`

```julia
analyze_parallelism(cdfg::CDFG) -> Dict{String, Any}
```

Analyze available parallelism (ILP) in the CDFG.

---

#### `suggest_optimizations`

```julia
suggest_optimizations(cdfg::CDFG) -> Vector{String}
```

Suggest optimizations based on CDFG analysis.

---

#### `generate_analysis_report`

```julia
generate_analysis_report(cdfg::CDFG) -> String
```

Generate a comprehensive human-readable analysis report.

---

## RTL Generation

The RTL module generates synthesizable Verilog from scheduled CDFGs.

### RTL Types

#### `RTLModule`

```julia
mutable struct RTLModule
    name::String
    ports::Vector{RTLPort}
    signals::Vector{RTLSignal}
    state_names::Vector{String}
    ...
end
```

Represents the complete generated hardware module.

---

#### `RTLPort`

```julia
struct RTLPort
    name::String
    bit_width::Int
    is_input::Bool
    is_signed::Bool
end
```

Represents a port in the RTL module.

---

#### `RTLSignal`

```julia
struct RTLSignal
    name::String
    bit_width::Int
    is_register::Bool
    is_signed::Bool
    initial_value::Union{Int, Nothing}
end
```

Represents an internal signal (wire or register).

---

### Generation Functions

#### `generate_rtl`

```julia
generate_rtl(cdfg::CDFG, schedule::Schedule; options::HLSOptions=HLSOptions()) -> RTLModule
```

Generate RTL module from a scheduled CDFG.

---

#### `generate_verilog`

```julia
generate_verilog(cdfg::CDFG, schedule::Schedule; options::HLSOptions=HLSOptions()) -> String
```

High-level function to generate complete Verilog from CDFG.

---

#### `emit_verilog`

```julia
emit_verilog(rtl::RTLModule) -> String
```

Emit complete Verilog module as a string.

---

#### `write_verilog`

```julia
write_verilog(rtl::RTLModule, filepath::String)
```

Write Verilog module to a file.

---

#### `emit_testbench`

```julia
emit_testbench(rtl::RTLModule; num_test_vectors::Int=10) -> String
```

Generate a Verilog testbench for the module.

---

### Memory Interface Generators

#### `generate_bram_interface`

```julia
generate_bram_interface(name::String, addr_width::Int, data_width::Int,
                        num_read_ports::Int, num_write_ports::Int) -> String
```

Generate BRAM interface module for a specific memory.

---

#### `generate_partitioned_memory`

```julia
generate_partitioned_memory(name::String, partition_type::Symbol, factor::Int,
                            addr_width::Int, data_width::Int) -> String
```

Generate partitioned memory for increased bandwidth.

---

#### `generate_fifo_interface`

```julia
generate_fifo_interface(name::String, data_width::Int, depth::Int) -> String
```

Generate FIFO interface for streaming data.

---

## Simulation

The Sim module provides Verilator integration and verification utilities.

### Simulation Types

#### `VerilatorConfig`

```julia
struct VerilatorConfig
    verilator_path::String
    trace_enabled::Bool
    trace_depth::Int
    optimization_level::Int
    ...
end
```

Configuration for Verilator simulation.

**Constructor:**
```julia
config = VerilatorConfig(trace_enabled=true, optimization_level=3)
```

---

#### `SimulationResult`

```julia
struct SimulationResult
    success::Bool
    output::String
    error_output::String
    exit_code::Int
    cycles::Int
    outputs::Dict{String, Any}
    vcd_file::Union{String, Nothing}
end
```

Result of a Verilator simulation run.

---

#### `VerificationResult`

```julia
struct VerificationResult
    passed::Bool
    total_tests::Int
    passed_tests::Int
    failed_tests::Int
    failures::Vector{Dict{String, Any}}
    coverage::Dict{String, Float64}
end
```

Result of RTL verification against a reference.

---

#### `TestVector`

```julia
struct TestVector
    inputs::Dict{String, Any}
    expected_outputs::Dict{String, Any}
    name::String
    timeout_cycles::Int
end
```

A single test vector with inputs and expected outputs.

---

### Simulation Functions

#### `simulate`

```julia
simulate(rtl::RTLModule, inputs::Dict{String, Any};
         config::VerilatorConfig=VerilatorConfig()) -> SimulationResult
```

High-level simulation: compile and run in one step.

**Example:**
```julia
result = simulate(rtl, Dict("a" => 5, "b" => 10))
if result.success
    println("Output: ", result.outputs["out_1"])
    println("Cycles: ", result.cycles)
end
```

---

#### `compile_verilator`

```julia
compile_verilator(verilog_file::String, output_dir::String;
                  config::VerilatorConfig=VerilatorConfig())
```

Compile Verilog with Verilator.

---

#### `run_verilator`

```julia
run_verilator(executable::String, args::Vector{String}=String[];
              timeout_seconds::Int=60) -> SimulationResult
```

Run a compiled Verilator simulation.

---

### Test Generation

#### `generate_test_vectors`

```julia
generate_test_vectors(rtl::RTLModule; num_random::Int=10, seed::Int=42) -> Vector{TestVector}
```

Generate random test vectors for a module.

---

#### `generate_test_vectors_from_function`

```julia
generate_test_vectors_from_function(rtl::RTLModule, ref_func::Function;
                                    num_random::Int=10) -> Vector{TestVector}
```

Generate test vectors by calling a reference Julia function.

---

#### `generate_directed_tests`

```julia
generate_directed_tests(rtl::RTLModule, scenarios::Vector{Symbol}) -> Vector{TestVector}
```

Generate directed tests for specific scenarios (`:zeros`, `:ones`, `:alternating`, etc.).

---

### Verification Functions

#### `verify_rtl`

```julia
verify_rtl(rtl::RTLModule, ref_func::Function;
           num_tests::Int=100) -> VerificationResult
```

Verify RTL implementation against a Julia reference function.

**Example:**
```julia
function add_ref(a, b)
    return a + b
end

result = verify_rtl(rtl, add_ref; num_tests=100)
println(generate_verification_report(result))
```

---

#### `compare_results`

```julia
compare_results(expected::Dict{String, Any}, actual::Dict{String, Any};
                tolerance::Float64=0.0) -> Tuple{Bool, Vector{String}}
```

Compare expected and actual results with optional tolerance.

---

#### `equivalence_check`

```julia
equivalence_check(rtl1::RTLModule, rtl2::RTLModule;
                  num_tests::Int=100) -> VerificationResult
```

Check if two RTL modules are functionally equivalent.

---

#### `generate_verification_report`

```julia
generate_verification_report(result::VerificationResult) -> String
```

Generate a human-readable verification report.

---

## CoDesign Module

The CoDesign module provides hardware-software co-design capabilities for rapid Design Space Exploration (DSE) without full FPGA compilation.

### DSE Types

#### `DSEParameters`

```julia
Base.@kwdef struct DSEParameters
    unroll_factor::Int = 1
    initiation_interval::Int = 1
    pipeline_depth::Int = 1
    bram_ports::Int = 2
    max_dsps::Int = 64
    clock_freq_mhz::Float64 = 100.0
end
```

Design Space Exploration parameters for hardware configuration.

**Fields:**
- `unroll_factor`: Number of parallel compute units (1-16)
- `initiation_interval`: Cycles between starting new operations (1-8)
- `pipeline_depth`: Number of pipeline stages (1-16)
- `bram_ports`: Number of BRAM read ports (1-8)
- `max_dsps`: Maximum DSP blocks available
- `clock_freq_mhz`: Target clock frequency

**Example:**
```julia
dse = DSEParameters(unroll_factor=4, initiation_interval=1, bram_ports=4)
```

---

#### `WorkloadDescriptor`

```julia
struct WorkloadDescriptor
    name::String
    ndrange::Tuple{Vararg{Int}}
    multiplies_per_item::Int
    adds_per_item::Int
    reads_per_item::Int
    writes_per_item::Int
    has_reduction::Bool
    reduction_size::Int
end
```

Describes kernel computation patterns for performance estimation.

**Helper Functions:**
```julia
total_items(w::WorkloadDescriptor) -> Int
total_ops(w::WorkloadDescriptor) -> Int
total_memory_accesses(w::WorkloadDescriptor) -> Int
```

**Pre-built Workload Constructors:**
```julia
conv2d_workload(; kernel_size=3, img_height=28, img_width=28)
matmul_workload(; M=64, N=64, K=64)
elementwise_workload(; height=32, width=32, ops_per_element=1)
reduction_workload(; length=1024)
fir_filter_workload(; taps=16, samples=1024)
```

**Example:**
```julia
workload = conv2d_workload(kernel_size=5, img_height=224, img_width=224)
println("Total items: ", total_items(workload))
println("Ops per item: ", workload.multiplies_per_item)
```

---

### Virtual Device Types

#### `VirtualFPGADevice`

```julia
mutable struct VirtualFPGADevice
    name::String
    total_luts::Int
    total_ffs::Int
    total_brams::Int
    total_dsps::Int
    clock_freq_mhz::Float64
    # ... resource tracking fields
end
```

Virtual FPGA device for resource-aware DSE.

**Pre-built Device Constructors:**
```julia
alveo_u200()   # Xilinx Alveo U200 (892K LUTs, 6840 DSPs)
alveo_u280()   # Xilinx Alveo U280 (1304K LUTs, 9024 DSPs)
zynq_7020()    # Zynq-7020 (53K LUTs, 220 DSPs)
arty_a7()      # Arty A7-35T (33K LUTs, 90 DSPs)
```

**Example:**
```julia
device = zynq_7020()
println("Available DSPs: ", device.total_dsps)
util = resource_utilization(device)
println("DSP usage: ", util.dsps, "%")
```

---

#### `VirtualFPGAArray`

```julia
mutable struct VirtualFPGAArray{T,N} <: AbstractArray{T,N}
    data::Array{T,N}
    device::VirtualFPGADevice
    read_count::Int
    write_count::Int
    is_device_memory::Bool
end
```

Device memory abstraction with access tracking.

**Functions:**
```julia
allocate!(device, T, dims...) -> VirtualFPGAArray
copyto_device!(device, host_array) -> VirtualFPGAArray
copyto_host!(device_array) -> Array
reset_stats!(arr)
```

---

#### `VirtualPCIe`

```julia
struct VirtualPCIe
    bandwidth_gbps::Float64
    latency_ns::Float64
end
```

PCIe interface simulation for transfer timing.

**Pre-built Configurations:**
```julia
PCIE_GEN3_X16  # 15.75 GB/s, 200ns latency
PCIE_GEN4_X16  # 31.5 GB/s, 150ns latency
PCIE_GEN5_X16  # 63.0 GB/s, 100ns latency
AXI_ZYNQ       # 6.4 GB/s, 50ns latency
```

**Functions:**
```julia
transfer_cycles(pcie, bytes, clock_freq_mhz) -> Int
```

---

### Parametric Simulator

#### `ParametricSimulator`

```julia
mutable struct ParametricSimulator
    workload::WorkloadDescriptor
    dse::DSEParameters
    cycle::Int
    is_done::Bool
    # ... pipeline and timing state
end
```

Lightweight simulator for fast DSE without LLVM compilation.

**Constructor:**
```julia
ParametricSimulator(workload::WorkloadDescriptor; dse::DSEParameters=DSEParameters())
```

**Simulation Functions:**
```julia
tick!(sim::ParametricSimulator)           # Advance one cycle
run!(sim::ParametricSimulator)            # Run to completion
reset!(sim::ParametricSimulator)          # Reset state
calculate_throughput(sim) -> Float64      # Items per cycle
estimate_performance(sim) -> NamedTuple   # Full performance estimate
```

**DSE Sweep Functions:**
```julia
sweep_unroll_factor(workload, range) -> Vector{NamedTuple}
sweep_dse_space(workload; kwargs...) -> Vector{NamedTuple}
find_optimal_config(workload; optimize_for=:throughput) -> DSEParameters
```

**Example:**
```julia
workload = matmul_workload(M=128, N=128, K=128)
sim = ParametricSimulator(workload; dse=DSEParameters(unroll_factor=4))

# Quick estimate
est = estimate_performance(sim)
println("Estimated cycles: ", est.estimated_cycles)
println("Throughput: ", est.estimated_throughput)

# Sweep parameter space
results = sweep_unroll_factor(workload, 1:8)
for r in results
    println("UF=$(r.unroll_factor): $(r.throughput) items/cycle")
end
```

---

### Full Pipeline Integration

#### `CompiledKernel`

```julia
mutable struct CompiledKernel
    name::String
    julia_func::Union{Function, Nothing}
    argtypes::Union{Type, Nothing}
    cdfg::Union{CDFG, Nothing}
    schedule::Union{Schedule, Nothing}
    native_sim::Union{NativeSimulator, Nothing}
    is_compiled::Bool
    # ... metadata fields
end
```

Holds a fully compiled kernel with CDFG, schedule, and simulator.

**Functions:**
```julia
compile_kernel(f::Function, argtypes::Type{<:Tuple}) -> CompiledKernel
compile_kernel_safe(f, argtypes) -> Union{CompiledKernel, Nothing}
simulate_compiled(kernel, inputs::Dict) -> SimulationResult
```

---

#### `CoDesignKernel`

```julia
mutable struct CoDesignKernel
    name::String
    workload::Union{WorkloadDescriptor, Nothing}
    parametric_sim::Union{ParametricSimulator, Nothing}
    compiled::Union{CompiledKernel, Nothing}
    dse::DSEParameters
    device::Union{VirtualFPGADevice, Nothing}
    mode::Symbol  # :parametric or :full
end
```

Unified kernel wrapper supporting both parametric and full simulation.

**Constructor:**
```julia
CoDesignKernel(name::String; workload=nothing, dse=DSEParameters(), device=nothing)
```

**Functions:**
```julia
simulate!(kernel; backend=:auto) -> NamedTuple
estimate!(kernel) -> NamedTuple
compile!(kernel)
update_dse!(kernel, new_dse::DSEParameters)
run_dse_sweep(kernel; unroll_range=1:8) -> Vector
find_best_config(kernel; optimize_for=:throughput) -> DSEParameters
```

**Example:**
```julia
# Create kernel with workload
workload = conv2d_workload(kernel_size=3, img_height=28, img_width=28)
kernel = CoDesignKernel("conv2d"; workload=workload, device=zynq_7020())

# Parametric estimation (fast)
est = estimate!(kernel)
println("Cycles: ", est.estimated_cycles)

# DSE exploration
results = run_dse_sweep(kernel; unroll_range=1:8)
best = find_best_config(kernel; optimize_for=:throughput)
println("Optimal unroll factor: ", best.unroll_factor)
```

---

### Observable Integration

The CoDesign module provides Observable wrappers for integration with Makie.jl:

#### `SimulatorObservables`

```julia
mutable struct SimulatorObservables
    cycle::Observable{Int}
    throughput::Observable{Float64}
    is_done::Observable{Bool}
    pipeline_fill::Observable{Vector{Float64}}
end
```

Reactive wrapper around simulator state for live visualization.

---

#### `DSEObservables`

```julia
mutable struct DSEObservables
    unroll_factor::Observable{Int}
    initiation_interval::Observable{Int}
    bram_ports::Observable{Int}
    pipeline_depth::Observable{Int}
end
```

Observable DSE parameters for interactive control.

**Functions:**
```julia
sync_from!(obs::DSEObservables, dse::DSEParameters)
sync_to!(obs::DSEObservables) -> DSEParameters
to_parameters(obs::DSEObservables) -> DSEParameters
```

---

#### `ParetoObservables`

```julia
mutable struct ParetoObservables
    points::Observable{Vector{ParetoPoint}}
    frontier::Observable{Vector{ParetoPoint}}
end
```

Observable Pareto frontier for design space visualization.

**Functions:**
```julia
update_pareto!(obs, throughput, latency, resources, config)
```

---

### Convenience Functions

#### `quick_sim`

```julia
quick_sim(workload::WorkloadDescriptor; dse::DSEParameters=DSEParameters()) -> NamedTuple
```

One-liner performance estimation without creating simulator objects.

---

#### `compare_configs`

```julia
compare_configs(workload::WorkloadDescriptor, configs::Vector{DSEParameters}) -> Vector
```

Compare multiple DSE configurations side-by-side.

---

#### `create_kernel`

```julia
create_kernel(name::String; workload=nothing, func=nothing, argtypes=nothing,
              dse=DSEParameters(), device=nothing, auto_compile=false) -> CoDesignKernel
```

Factory function for flexible kernel creation.

---

#### `print_summary`

```julia
print_summary(kernel::CoDesignKernel)
```

Print formatted summary of kernel configuration and performance estimates.

---

#### `codesign_help`

```julia
codesign_help()
```

Print REPL help for the CoDesign module.
