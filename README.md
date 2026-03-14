# FPGACompiler.jl

A Julia package that extends `GPUCompiler.jl` to generate LLVM IR suitable for FPGA High-Level Synthesis (HLS) tools.

## Overview

FPGACompiler.jl enables writing FPGA kernels in pure Julia by:

1. Leveraging Julia's powerful type system to express hardware constraints
2. Using `GPUCompiler.jl` to intercept the compilation pipeline
3. Running FPGA-specific LLVM optimization passes
4. Injecting HLS metadata for pipelining, memory partitioning, and bit-width optimization
5. **Native HLS backend** with ASAP/ALAP/list/ILP scheduling and resource binding
6. **RTL generation** producing synthesizable Verilog
7. **Simulation** via Verilator integration
8. Outputting clean LLVM IR for vendor HLS tools (Intel oneAPI, AMD Vitis, Bambu)

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

### Phase 4: Native HLS Backend

A pure Julia HLS implementation that bypasses vendor tools:

- **CDFG Construction** - Combined Control and Data Flow Graph from IR
- **Scheduling** - ASAP, ALAP, list scheduling, and ILP-based optimal scheduling
- **Resource Binding** - Maps operations to functional units with sharing
- **FSM Generation** - Synthesizes control state machines

### Phase 5: RTL Generation

Produces synthesizable Verilog from the scheduled CDFG:

- **Datapath** - Functional units, multiplexers, registers
- **FSM** - State machine with one-hot or binary encoding
- **Memory Interfaces** - BRAM controllers with banking support
- **Top Module** - Integrates datapath, FSM, and memories

### Phase 6: Simulation

Verifies generated RTL with Verilator:

- **Testbench Generation** - Automatic C++ testbenches
- **Verilator Integration** - Compile and run simulations
- **Waveform Output** - VCD traces for debugging

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

### Native HLS Flow

Generate Verilog directly without vendor tools:

```julia
using FPGACompiler
using FPGACompiler.HLS
using FPGACompiler.RTL

# Build CDFG from operations
cdfg = CDFG("my_kernel")
add_operation!(cdfg, :add, :a, :b, :sum)
add_operation!(cdfg, :mul, :sum, :c, :result)

# Schedule with resource constraints
schedule = schedule_list!(cdfg, ResourceConstraints(adders=1, multipliers=1))

# Bind resources
bind_resources!(cdfg, schedule)

# Generate Verilog
rtl_module = generate_rtl(cdfg)
verilog = emit_verilog(rtl_module)
write("my_kernel.v", verilog)
```

### Simulation

Verify RTL with Verilator:

```julia
using FPGACompiler.Sim

# Generate testbench
tb = generate_testbench(rtl_module, [
    (a=1.0f0, b=2.0f0, c=3.0f0),  # Test vector 1
    (a=4.0f0, b=5.0f0, c=6.0f0),  # Test vector 2
])

# Run simulation
result = run_verilator(rtl_module, tb)
@assert result.passed
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

### HLS Module (`FPGACompiler.HLS`)

| Function | Description |
|----------|-------------|
| `CDFG(name)` | Create Control/Data Flow Graph |
| `schedule_asap!(cdfg)` | As-soon-as-possible scheduling |
| `schedule_alap!(cdfg)` | As-late-as-possible scheduling |
| `schedule_list!(cdfg, constraints)` | List scheduling with resource limits |
| `schedule_ilp!(cdfg)` | Optimal ILP-based scheduling |
| `bind_resources!(cdfg, schedule)` | Map operations to functional units |

### RTL Module (`FPGACompiler.RTL`)

| Function | Description |
|----------|-------------|
| `generate_rtl(cdfg)` | Generate RTL module from scheduled CDFG |
| `emit_verilog(module)` | Emit Verilog source code |
| `generate_fsm(cdfg)` | Generate FSM controller |
| `generate_datapath(cdfg)` | Generate datapath logic |

### Simulation Module (`FPGACompiler.Sim`)

| Function | Description |
|----------|-------------|
| `generate_testbench(module, vectors)` | Create C++ testbench |
| `run_verilator(module, testbench)` | Compile and simulate with Verilator |
| `verify_output(expected, actual)` | Compare simulation results |

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
- [Graphs.jl](https://github.com/JuliaGraphs/Graphs.jl) - Graph data structures for CFG/DFG
- [JuMP.jl](https://github.com/jump-dev/JuMP.jl) - Mathematical optimization for ILP scheduling
- [HiGHS.jl](https://github.com/jump-dev/HiGHS.jl) - High-performance LP/MIP solver

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
- Additional scheduling algorithms (force-directed, modulo scheduling)
- FPGA vendor backend integration (Vivado, Quartus)
- Resource estimation improvements

## License

MIT License - see [LICENSE](LICENSE) for details.
