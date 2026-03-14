# FPGACompiler.jl Tutorial

This tutorial walks you through using FPGACompiler.jl to compile Julia code for FPGA synthesis.

## Prerequisites

- Julia 1.10 or later
- GPUCompiler.jl v1.x
- LLVM.jl v9.x
- (Optional) An HLS tool: Intel oneAPI, AMD Vitis HLS, or Bambu

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/youruser/FPGACompiler.jl")
```

Or add to your project:

```julia
] add FPGACompiler
```

## Quick Start

### Step 1: Write a Kernel

FPGA kernels must follow hardware synthesis constraints:

```julia
using FPGACompiler

# Simple vector addition kernel
function vadd(A, B, C, n)
    for i in 1:n
        @inbounds C[i] = A[i] + B[i]
    end
end
```

**Constraints:**
- No dynamic memory allocation (`push!`, `resize!`, `Array()`)
- No exceptions - use `@inbounds` for bounds checking
- No recursion - all functions must inline
- All types must be statically inferrable

### Step 2: Compile to LLVM IR

```julia
# Get the LLVM module
mod = fpga_compile(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})

# View the IR
println(fpga_code_llvm(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int}))
```

### Step 3: Export for HLS Tools

```julia
# Write LLVM IR to file
path = fpga_code_native(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})
println("Generated: $path")

# Or generate bitcode for some tools
bc_path = fpga_code_native(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int}, format=:bc)
```

## Using Macros

### The `@fpga_kernel` Macro

Mark functions intended for FPGA synthesis:

```julia
@fpga_kernel function matrix_mul(A, B, C, M, N, K)
    for i in 1:M
        for j in 1:N
            sum = 0.0f0
            for k in 1:K
                @inbounds sum += A[(i-1)*K + k] * B[(k-1)*N + j]
            end
            @inbounds C[(i-1)*N + j] = sum
        end
    end
end
```

### Loop Pipelining with `@pipeline`

Pipelining overlaps loop iterations to increase throughput:

```julia
@fpga_kernel function pipelined_accumulator(A, n)
    sum = 0.0f0

    # Pipeline with initiation interval of 1
    # (new iteration every clock cycle)
    @pipeline II=1 for i in 1:n
        @inbounds sum += A[i]
    end

    return sum
end
```

**Initiation Interval (II):**
- `II=1`: New iteration starts every clock cycle (maximum throughput)
- `II=2`: New iteration starts every 2 cycles (half throughput)
- Higher II reduces resource usage but decreases performance

### Loop Unrolling with `@unroll`

Unrolling duplicates hardware for parallel execution:

```julia
@fpga_kernel function unrolled_dot_product(A, B, n)
    sum = 0.0f0

    # Unroll by factor of 4 - processes 4 elements in parallel
    @unroll factor=4 for i in 1:n
        @inbounds sum += A[i] * B[i]
    end

    return sum
end
```

**When to Unroll:**
- Short loops with known bounds
- When you have sufficient FPGA resources
- When memory bandwidth supports parallel access

## Memory Partitioning

### Using PartitionedArray

Standard arrays map to a single BRAM (2 read/write ports). Partitioning splits arrays across multiple BRAMs for parallel access:

```julia
# Create a partitioned array with 4 BRAM banks
data = zeros(Float32, 1024)
pa = PartitionedArray{Float32, 1, 4, CYCLIC}(data)

# Or use the convenience constructor
pa = PartitionedArray(data; factor=4, style=CYCLIC)
```

### Partitioning Styles

**CYCLIC:**
```
Bank 0: elements 0, 4, 8, 12, ...
Bank 1: elements 1, 5, 9, 13, ...
Bank 2: elements 2, 6, 10, 14, ...
Bank 3: elements 3, 7, 11, 15, ...
```
Best for: Sequential access with stride other than 1

**BLOCK:**
```
Bank 0: elements 0-255
Bank 1: elements 256-511
Bank 2: elements 512-767
Bank 3: elements 768-1023
```
Best for: Blocked/tiled access patterns

**COMPLETE:**
```
Every element gets its own register
```
Best for: Small arrays (< 64 elements) needing full parallel access

### Example: Parallel Array Access

```julia
@fpga_kernel function parallel_sum(A::PartitionedArray{Float32, 1, 4, CYCLIC}, n)
    sum = 0.0f0

    # With 4 partitions, we can access 4 elements per cycle
    @unroll factor=4 for i in 1:4:n
        @inbounds sum += A[i] + A[i+1] + A[i+2] + A[i+3]
    end

    return sum
end
```

## Custom Bit-Width Integers

FPGAs can compute with any bit width, not just 8/16/32/64:

```julia
# 7-bit counter (saves resources vs 8-bit)
counter = Int7(0)

# 12-bit ADC value
adc_reading = UInt12(2048)

# Custom bit widths
x = FixedInt{10, Int16}(500)  # 10-bit signed integer

# Check bit width
@assert bitwidth(counter) == 7
```

### Arithmetic Operations

FixedInt types support standard arithmetic:

```julia
a = Int7(10)
b = Int7(20)

c = a + b    # Result is Int7
d = a * b    # Result is Int7 (with wrapping)

# Comparisons
@assert a < b
@assert a == Int7(10)
```

## Validation

Check kernels for synthesis issues before compilation:

```julia
issues = validate_kernel(my_kernel, Tuple{Vector{Float32}, Int})

if !isempty(issues)
    println("Potential synthesis issues:")
    for issue in issues
        println("  - $issue")
    end
end
```

## Resource Estimation

Get a rough estimate of FPGA resource usage:

```julia
resources = estimate_resources(matrix_mul, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int, Int, Int})

println("Estimated resources:")
println("  LUTs:  $(resources["estimated_luts"])")
println("  FFs:   $(resources["estimated_ffs"])")
println("  DSPs:  $(resources["estimated_dsps"])")
println("  BRAMs: $(resources["estimated_brams"])")
```

## Complete Example: FIR Filter

Here's a complete example implementing a pipelined FIR filter:

```julia
using FPGACompiler

# FIR filter with pipelined multiply-accumulate
@fpga_kernel function fir_filter(
    input::Vector{Float32},
    coeffs::Vector{Float32},
    output::Vector{Float32},
    n_samples::Int,
    n_taps::Int
)
    for i in 1:n_samples
        acc = 0.0f0

        # Pipeline the inner loop for maximum throughput
        @pipeline II=1 for j in 1:n_taps
            idx = i - j + 1
            if idx >= 1
                @inbounds acc += input[idx] * coeffs[j]
            end
        end

        @inbounds output[i] = acc
    end
end

# Compile and export
path = fpga_code_native(
    fir_filter,
    Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int, Int},
    format=:ll
)

println("FIR filter compiled to: $path")
```

## Best Practices

### 1. Always Use `@inbounds`

Bounds checking generates exception-handling code that can't synthesize:

```julia
# Good
@inbounds A[i] = B[i] + C[i]

# Bad - generates unsynthesizable bounds checks
A[i] = B[i] + C[i]
```

### 2. Prefer Fixed Loop Bounds

Hardware counters work best with compile-time known bounds:

```julia
# Good - loop bound is a type parameter
function process_block(data::NTuple{16, Float32})
    for i in 1:16  # Known at compile time
        # ...
    end
end

# Acceptable - runtime bound, but HLS tools can handle it
function process_array(data, n::Int)
    for i in 1:n  # Runtime bound
        # ...
    end
end
```

### 3. Avoid Julia Runtime Features

```julia
# Bad - dynamic allocation
result = Float32[]
push!(result, x)

# Good - fixed-size output
result = zeros(Float32, MAX_SIZE)
result[idx] = x
```

### 4. Use Type Annotations

Help type inference by annotating function arguments:

```julia
@fpga_kernel function kernel(
    A::Vector{Float32},
    B::Vector{Float32},
    n::Int64
)
    # ...
end
```

### 5. Test Locally First

Verify correctness in Julia before FPGA compilation:

```julia
# Create test data
A = rand(Float32, 1024)
B = rand(Float32, 1024)
C = zeros(Float32, 1024)

# Run in Julia
vadd(A, B, C, 1024)

# Verify
@assert all(C .≈ A .+ B)

# Then compile for FPGA
fpga_code_native(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})
```

## Next Steps

- See [API Reference](api.md) for complete function documentation
- See [Architecture](architecture.md) for internal details
- See [Vendor Integration](vendor-integration.md) for HLS tool workflows
