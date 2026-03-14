# FPGACompiler.jl

A Julia package that extends `GPUCompiler.jl` to generate LLVM IR suitable for FPGA High-Level Synthesis (HLS) tools.

## Overview

FPGACompiler.jl enables writing FPGA kernels in pure Julia by:

1. Leveraging Julia's powerful type system to express hardware constraints
2. Using `GPUCompiler.jl` to intercept the compilation pipeline
3. Running FPGA-specific LLVM optimization passes
4. Injecting HLS metadata for pipelining, memory partitioning, and bit-width optimization
5. Outputting clean LLVM IR for vendor HLS tools (Intel oneAPI, AMD Vitis, Bambu)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/yourusername/FPGACompiler.jl")
```

Or for development:

```julia
Pkg.develop(path="path/to/FPGACompiler.jl")
```

## Quick Start

```julia
using FPGACompiler

# Define a kernel
function vector_add(A, B, C, n)
    for i in 1:n
        @inbounds C[i] = A[i] + B[i]
    end
end

# Compile to LLVM IR
ir = fpga_code_llvm(vector_add, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})
println(ir)

# Write to file for HLS tools
fpga_code_native(vector_add, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int},
                 format=:ll, output="vector_add.ll")
```

Then feed the output to your HLS tool:

```bash
# AMD Vitis HLS
v++ -c vector_add.ll -o vector_add.xo

# Intel oneAPI FPGA
aoc vector_add.ll -o vector_add.aocx

# Open-source (Bambu)
bambu vector_add.ll
```

## Architecture

The compilation pipeline follows three phases:

### Phase 1: Canonicalization

Cleans the LLVM IR for hardware synthesis:

- `mem2reg` - Promotes memory to SSA registers (becomes physical wires)
- `always-inline` - Flattens call graph (FPGAs have no stack)
- `loop-simplify` - Normalizes loops for hardware counters
- `indvars` - Simplifies loop induction variables
- Strips Julia GC and exception handling

### Phase 2: Dependency Analysis

Analyzes data dependencies to enable hardware pipelining:

- **Alias Analysis** - Proves arrays don't overlap, enabling parallel BRAM ports
- **Scalar Evolution** - Models loop variables for hardware schedulers
- **Dependence Analysis** - Detects loop-carried dependencies for pipeline II calculation
- **LICM** - Moves invariant code outside loops to save logic gates

### Phase 3: Hardware Metadata

Injects HLS-specific metadata into the LLVM IR:

- Loop pipelining hints (`llvm.loop.pipeline.enable`)
- Memory partitioning directives
- Interface specifications (AXI, BRAM, Stream)
- Bit-width annotations

## Features

### Custom Bit-Width Types

FPGAs can compute with arbitrary bit widths. Use custom integer types to minimize silicon area:

```julia
using FPGACompiler

# Use 7-bit integers instead of 32-bit
function efficient_kernel(A::Vector{Int7}, B::Vector{Int7})
    @inbounds A[1] = A[1] + B[1]  # Generates `add i7` in LLVM IR
end
```

Available types: `Int3`, `Int5`, `Int7`, `Int12`, `Int14`, `Int24` (and unsigned variants)

### Memory Partitioning

Partition arrays across multiple BRAM banks for parallel access:

```julia
using FPGACompiler

# Partition into 4 BRAM banks with cyclic distribution
A = PartitionedArray{Float32, 1, 4, CYCLIC}(zeros(Float32, 1024))

# Or use convenience constructor
B = PartitionedArray(zeros(Float32, 1024); factor=8, style=BLOCK)
```

Partition styles:
- `CYCLIC` - Round-robin distribution (good for stride-1 access)
- `BLOCK` - Contiguous chunks per bank
- `COMPLETE` - Fully partition into registers (small arrays only)

### HLS Macros

```julia
@fpga_kernel function matrix_mul(A, B, C, M, N, K)
    for i in 1:M
        for j in 1:N
            sum = 0.0f0
            @pipeline II=1 for k in 1:K
                sum += A[i, k] * B[k, j]
            end
            C[i, j] = sum
        end
    end
end
```

### Compiler Parameters

```julia
params = FPGACompilerParams(
    target_ii = 1,           # Target initiation interval
    aggressive_inline = true, # Inline all functions
    partition_memory = true,  # Enable memory analysis
    emit_llvm_ir = true       # Output .ll instead of .bc
)

fpga_compile(my_kernel, types; params=params)
```

## API Reference

### Compilation Functions

| Function | Description |
|----------|-------------|
| `fpga_compile(f, types)` | Compile function, return LLVM.Module |
| `fpga_code_llvm(f, types)` | Return LLVM IR as string |
| `fpga_code_native(f, types; format, output)` | Write IR to file |

### Metadata Functions

| Function | Description |
|----------|-------------|
| `apply_pipeline_metadata!(block, ii)` | Add pipelining hints to loop |
| `apply_unroll_metadata!(block, factor)` | Add unrolling hints |
| `apply_partition_metadata!(inst, factor, style)` | Add memory partitioning |
| `apply_noalias_metadata!(mod)` | Mark arrays as non-overlapping |

### Types

| Type | Description |
|------|-------------|
| `FPGATarget` | Compiler target for FPGA synthesis |
| `FPGACompilerParams` | Compilation configuration |
| `PartitionedArray{T,N,Factor,Style}` | Array with partitioning hints |
| `Int7`, `Int12`, etc. | Arbitrary bit-width integers |

## Limitations

- **No dynamic memory allocation** - All arrays must be fixed-size
- **No exceptions** - Use `@inbounds` to disable bounds checking
- **No recursion** - All functions must be inlineable
- **No runtime dispatch** - All types must be inferrable

## Supported HLS Tools

| Vendor | Tool | Command |
|--------|------|---------|
| AMD/Xilinx | Vitis HLS | `v++ -c kernel.ll` |
| Intel | oneAPI FPGA | `aoc kernel.ll` |
| Open Source | Bambu | `bambu kernel.ll` |
| Open Source | CIRCT | Via MLIR pipeline |

## Dependencies

- [GPUCompiler.jl](https://github.com/JuliaGPU/GPUCompiler.jl) - Julia GPU compilation framework
- [LLVM.jl](https://github.com/maleadt/LLVM.jl) - Julia wrapper for LLVM C API

## Documentation

- [API Reference](docs/api.md) - Complete function and type documentation
- [Architecture](docs/architecture.md) - Internal design and extension points
- [Tutorial](docs/tutorial.md) - Step-by-step usage guide
- [Vendor Integration](docs/vendor-integration.md) - Intel/AMD/Bambu workflows

## Examples

See the `examples/` directory for complete working examples:

- [`vector_add.jl`](examples/vector_add.jl) - Basic kernel compilation
- [`matrix_mul.jl`](examples/matrix_mul.jl) - Pipelined matrix multiplication
- [`memory_partition.jl`](examples/memory_partition.jl) - PartitionedArray usage
- [`custom_bitwidth.jl`](examples/custom_bitwidth.jl) - FixedInt for resource efficiency

Run an example:
```bash
julia --project=. examples/vector_add.jl
```

## Contributing

Contributions are welcome! Areas of interest:

- Additional LLVM optimization passes
- Vendor-specific metadata formats
- Verilog simulation integration (inspired by [Verilog.jl](https://github.com/interplanetary-robot/Verilog.jl))
- Resource estimation improvements

## License

MIT License - see [LICENSE](LICENSE) for details.
