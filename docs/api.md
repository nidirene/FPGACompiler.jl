# FPGACompiler.jl API Reference

This document provides a complete reference for all exported functions, types, and macros in FPGACompiler.jl.

## Table of Contents

- [Compilation Functions](#compilation-functions)
- [Types](#types)
- [Macros](#macros)
- [Metadata Functions](#metadata-functions)
- [Utility Functions](#utility-functions)

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
