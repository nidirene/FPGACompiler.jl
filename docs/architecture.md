# FPGACompiler.jl Architecture

This document describes the internal architecture of FPGACompiler.jl, including the compilation pipeline, LLVM integration, and extension points.

## Overview

FPGACompiler.jl extends [GPUCompiler.jl](https://github.com/JuliaGPU/GPUCompiler.jl) to generate LLVM IR suitable for FPGA High-Level Synthesis (HLS) tools. The compiler transforms Julia source code into hardware-ready IR through a three-phase pipeline.

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Julia     │───▶│   Type      │───▶│   LLVM      │───▶│   HLS-Ready │
│   Source    │    │   Inference │    │   Passes    │    │   LLVM IR   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                         │                  │
                    GPUCompiler.jl    FPGACompiler.jl
```

## Source Files

### Core Modules

| File | Purpose |
|------|---------|
| `src/target.jl` | `FPGATarget` and `FPGACompilerParams` - extends `GPUCompiler.AbstractCompilerTarget` |
| `src/types.jl` | `PartitionedArray` for BRAM partitioning, `FixedInt{N,T}` for arbitrary bit-width integers |
| `src/optimize.jl` | Overrides `GPUCompiler.optimize!` with Phase 1 (canonicalization) and Phase 2 (dependency analysis) LLVM passes |
| `src/metadata.jl` | Phase 3 functions to inject HLS metadata (`apply_pipeline_metadata!`, `apply_partition_metadata!`) |
| `src/compiler.jl` | User-facing API (`fpga_compile`, `fpga_code_llvm`, `fpga_code_native`) and macros (`@fpga_kernel`, `@pipeline`, `@unroll`) |

### HLS Backend (`src/hls/`)

| File | Purpose |
|------|---------|
| `src/hls/types.jl` | Core HLS data structures: `CDFG`, `DFGNode`, `FSMState`, `Schedule`, `HLSOptions` |
| `src/hls/cfg.jl` | CFG extraction from LLVM IR, creating FSM states from basic blocks |
| `src/hls/dfg.jl` | DFG extraction from LLVM instructions, building operation nodes and edges |
| `src/hls/cdfg.jl` | Combined CDFG construction, validation, and critical path analysis |
| `src/hls/schedule.jl` | Scheduling algorithms: ASAP, ALAP, List Scheduling, ILP (JuMP.jl), Modulo |
| `src/hls/binding.jl` | Resource binding with left-edge algorithm, register allocation |
| `src/hls/analysis.jl` | Analysis utilities: resource usage, parallelism, memory patterns, optimization suggestions |

### RTL Generation (`src/rtl/`)

| File | Purpose |
|------|---------|
| `src/rtl/module.jl` | RTL module structure generation, port/signal declarations |
| `src/rtl/fsm.jl` | FSM Verilog generation with state transitions and cycle counting |
| `src/rtl/datapath.jl` | Datapath generation: ALU operations, pipeline registers, muxes |
| `src/rtl/memory.jl` | Memory interface generation: BRAM, partitioned memory, FIFO |
| `src/rtl/emit.jl` | Verilog emission, testbench generation, Verilator integration |

### Simulation (`src/sim/`)

| File | Purpose |
|------|---------|
| `src/sim/verilator.jl` | Verilator compilation and execution, VCD parsing |
| `src/sim/testbench.jl` | Test vector generation, directed tests, coverage points |
| `src/sim/verify.jl` | RTL verification against Julia references, equivalence checking |

## Compilation Pipeline

### Pre-Phase: Julia Runtime Cleanup

Before the main optimization phases, GPUCompiler's `optimize_module!` strips Julia-specific constructs that have no hardware equivalent:

- **Garbage Collection**: FPGA hardware has no heap or GC. All memory must be statically allocated.
- **Exception Handling**: No try/catch/throw - hardware can't dynamically change control flow on errors.
- **Thread-Local Storage**: FPGAs don't have OS threads.

```julia
GPUCompiler.optimize_module!(job, mod)
```

### Phase 1: Canonicalization

Phase 1 prepares the IR for hardware synthesis by normalizing control flow and promoting memory to SSA form.

**Passes:**
```
always-inline    → Flatten call graph (no hardware stack)
mem2reg          → Promote memory to SSA registers (physical wires)
instcombine      → Clean up redundant instructions
simplifycfg      → Remove dead branches (dead logic gates)
loop-simplify    → Normalize loops for hardware counters
indvars          → Simplify loop induction variables
gvn              → Global Value Numbering (remove redundant calculations)
dce              → Dead Code Elimination
```

**Why These Passes Matter:**

| Pass | Software Purpose | Hardware Effect |
|------|-----------------|-----------------|
| `always-inline` | Reduce function call overhead | Eliminate need for call stack hardware |
| `mem2reg` | Optimize memory access | Convert memory to wires/registers |
| `loop-simplify` | Canonicalize loop structure | Enable trip count extraction for counters |
| `indvars` | Simplify induction variables | Reduce counter hardware complexity |

### Phase 2: Dependency Analysis

Phase 2 analyzes memory dependencies and prepares loops for pipelining.

**Passes:**
```
require<opt-remark-emit>  → Enable HLS warnings
loop(licm)                → Loop Invariant Code Motion (save logic gates)
loop-idiom                → Recognize memory patterns for BRAM bursting
loop-deletion             → Delete proven-empty loops
loop-unroll               → Duplicate hardware for spatial parallelism
```

**Analysis Results:**
- **Scalar Evolution (SCEV)**: Computes loop trip counts for hardware counter sizing
- **Alias Analysis (AA)**: Determines memory access independence for parallel scheduling
- **Dependence Analysis**: Identifies loop-carried dependencies that limit pipelining

### Phase 3: Hardware Metadata Injection

Phase 3 attaches vendor-specific metadata to the IR that HLS tools interpret:

#### Loop Pipelining Metadata

```llvm
br i1 %cond, label %body, label %exit, !llvm.loop !0
!0 = distinct !{!0, !1, !2}
!1 = !{!"llvm.loop.pipeline.enable"}
!2 = !{!"llvm.loop.pipeline.initiationinterval", i32 1}
```

#### Memory Partitioning Metadata

```llvm
%arr = alloca [1024 x float], !fpga.memory !3
!3 = !{!"fpga.memory.partition", !"CYCLIC", i32 4}
```

#### Interface Metadata

```llvm
define void @kernel(float* %A) !fpga.interfaces !4 {
!4 = !{!"fpga.interface", i32 1, !"m_axi"}
```

## GPUCompiler.jl Integration

FPGACompiler.jl integrates with GPUCompiler through method overloading:

### Target Definition

```julia
struct FPGATarget <: GPUCompiler.AbstractCompilerTarget end

# Configure LLVM triple (SPIR-V for HLS compatibility)
GPUCompiler.llvm_triple(::FPGATarget) = "spir64-unknown-unknown"

# Configure data layout
GPUCompiler.llvm_datalayout(::FPGATarget) = "e-i64:64-v16:16-v24:32-..."

# Disable Julia runtime features
GPUCompiler.runtime_module(::CompilerJob{FPGATarget}) = nothing
GPUCompiler.uses_julia_runtime(::CompilerJob{FPGATarget}) = false
GPUCompiler.can_throw(::CompilerJob{FPGATarget}) = false
```

### Optimization Hook

The key extension point is `GPUCompiler.optimize!`:

```julia
function GPUCompiler.optimize!(job::CompilerJob{FPGATarget}, mod::LLVM.Module)
    # Phase 1: Canonicalization
    # Phase 2: Dependency Analysis
    # Phase 3: Verification
    verify_fpga_compatible!(mod)
    return mod
end
```

This intercepts Julia's compilation after type inference but before machine code generation.

## LLVM.jl Usage

FPGACompiler uses LLVM.jl's new pass manager API:

```julia
LLVM.@dispose pb=LLVM.PassBuilder() begin
    LLVM.@dispose mpm=LLVM.NewPMModulePassManager(pb) begin
        pipeline = "always-inline,mem2reg,instcombine,..."
        LLVM.add!(mpm, pb, pipeline)
        LLVM.run!(mpm, mod)
    end
end
```

### Metadata Manipulation

```julia
# Create metadata nodes
ctx = LLVM.context(loop_block)
md_pipeline = LLVM.MDString("llvm.loop.pipeline.enable"; ctx)
md_ii = LLVM.ConstantInt(Int32(target_ii); ctx)

# Build metadata tuple
loop_md = LLVM.MDNode([md_pipeline, md_ii]; ctx)

# Attach to instruction
LLVM.metadata!(terminator, LLVM.MD_loop, loop_md)
```

## Type System Integration

### PartitionedArray

The `PartitionedArray{T, N, Factor, Style}` type encodes partitioning information in Julia's type system:

```julia
struct PartitionedArray{T, N, Factor, Style}
    data::Array{T, N}
end
```

During compilation, the type parameters are extracted and converted to LLVM metadata:

```julia
factor = partition_factor(typeof(arr))  # Extract from type
style = partition_style(typeof(arr))
apply_partition_metadata!(alloca_inst, factor, style)
```

### FixedInt

The `FixedInt{N, T}` type represents arbitrary bit-width integers:

```julia
struct FixedInt{N, T<:Integer} <: Integer
    value::T
end
```

At runtime, values are stored in standard Julia integers. During compilation, the `N` parameter is used to generate appropriately-sized LLVM integer types (`iN`).

## Macro System

The macro system uses a registry pattern to pass compile-time hints to the optimization passes:

```julia
# Global registry for loop hints
const LOOP_HINTS = Dict{UInt, NamedTuple}()

macro pipeline(ii_expr, loop_expr)
    # Generate unique ID for this loop
    loop_id = hash(loop_expr)

    # Parse II parameter
    ii = extract_ii_value(ii_expr)

    # Store hint in registry
    LOOP_HINTS[loop_id] = (type=:pipeline, ii=ii)

    # Return instrumented loop
    return esc(instrument_loop(loop_expr, loop_id))
end
```

During compilation, the optimizer queries the registry to apply appropriate metadata.

## Extension Points

### Adding New Targets

Create a new target by subtyping `AbstractCompilerTarget`:

```julia
struct MyFPGATarget <: GPUCompiler.AbstractCompilerTarget
    device::String
end

GPUCompiler.llvm_triple(t::MyFPGATarget) = "..."
```

### Adding New Metadata

Add new HLS metadata by creating functions that manipulate LLVM IR:

```julia
function apply_my_metadata!(inst::LLVM.Instruction, ...)
    ctx = LLVM.context(inst)
    md = LLVM.MDNode([...]; ctx)
    LLVM.metadata!(inst, "my.metadata", md)
end
```

### Custom Optimization Passes

Add custom passes by extending the pipeline string:

```julia
# In optimize.jl
custom_passes = ["my-custom-pass"]
all_passes = vcat(phase1_passes, custom_passes, phase2_passes)
```

## Compilation Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                        fpga_compile(f, types)                        │
└───────────────────────────────────┬──────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│              GPUCompiler.CompilerJob(FPGATarget(), f, types)         │
└───────────────────────────────────┬──────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  GPUCompiler.compile(:llvm, job)                     │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  1. Type Inference (Julia)                                      │ │
│  │  2. LLVM IR Generation                                          │ │
│  │  3. GPUCompiler.optimize!(job, mod) ─────────────────────────── │ │
│  │     │                                                           │ │
│  │     ├─▶ Pre-Phase: Strip GC/Exceptions                          │ │
│  │     ├─▶ Phase 1: Canonicalization                               │ │
│  │     ├─▶ Phase 2: Dependency Analysis                            │ │
│  │     └─▶ Phase 3: verify_fpga_compatible!()                      │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────┬──────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                        LLVM.Module (HLS-Ready)                       │
│  • No GC calls                                                       │
│  • No exceptions                                                     │
│  • Loops normalized with trip counts                                 │
│  • Pipeline/unroll metadata attached                                 │
│  • Memory partition metadata attached                                │
└──────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│              fpga_code_native(..., format=:ll)                       │
│                              │                                       │
│                              ▼                                       │
│                    kernel_fpga.ll / kernel_fpga.bc                   │
└───────────────────────────────────┬──────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         Vendor HLS Tool                              │
│  • Intel aoc / oneAPI                                                │
│  • AMD Vitis HLS                                                     │
│  • Bambu / LegUp / CIRCT                                             │
└──────────────────────────────────────────────────────────────────────┘
```

## HLS Backend Architecture

The HLS backend provides a complete native Julia implementation for High-Level Synthesis, bypassing proprietary vendor tools.

### HLS Pipeline Overview

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   LLVM IR   │───▶│    CDFG     │───▶│  Scheduled  │───▶│   Verilog   │
│   Module    │    │  Extraction │    │    CDFG     │    │    RTL      │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
      │                  │                  │                  │
      │                  │                  │                  │
  LLVM.jl            cfg.jl            schedule.jl         emit.jl
                     dfg.jl            binding.jl
                     cdfg.jl
```

### CDFG Construction

The Combined Control and Data Flow Graph (CDFG) captures both control flow (FSM) and data flow (datapath):

1. **CFG Extraction** (`cfg.jl`):
   - Each LLVM BasicBlock becomes an FSM state
   - Branch instructions determine state transitions
   - Back-edges identify loops for pipelining

2. **DFG Extraction** (`dfg.jl`):
   - Each LLVM instruction becomes a DFGNode
   - Use-def chains become DFGEdges
   - Operation types map to hardware resources

3. **CDFG Integration** (`cdfg.jl`):
   - Operations are assigned to states
   - Critical path is computed
   - Dependencies are validated

### Scheduling Algorithms

```
┌──────────────────────────────────────────────────────────────┐
│                    Scheduling Options                         │
├──────────────────────────────────────────────────────────────┤
│  ASAP       │  As-Soon-As-Possible - Minimize latency        │
│  ALAP       │  As-Late-As-Possible - Compute scheduling slack │
│  List       │  Resource-constrained heuristic scheduling     │
│  ILP        │  Optimal scheduling via JuMP.jl + HiGHS        │
│  Modulo     │  Pipelined loop scheduling with target II      │
└──────────────────────────────────────────────────────────────┘
```

#### ILP Scheduling Model

The ILP scheduler formulates scheduling as an optimization problem:

**Variables:**
- `x[i,t]` ∈ {0,1}: Operation i starts at cycle t

**Objective:**
- Minimize: total latency (maximum completion time)

**Constraints:**
- Each operation scheduled exactly once
- Dependencies respected (producer completes before consumer)
- Resource constraints per cycle

### Resource Binding

The left-edge algorithm minimizes resource instances:

1. Sort operations by start time
2. For each operation:
   - Find available resource instance (end_time ≤ start_time)
   - If none available, allocate new instance
3. Track end times for each instance

```
Time:   0   1   2   3   4   5
        ├───┼───┼───┼───┼───┤
ALU_1:  [op1]   [op3]   [op5]
ALU_2:      [op2]   [op4]
```

### RTL Generation

The RTL module generates synthesizable Verilog with:

1. **FSM**: Moore machine with state register, next-state logic
2. **Datapath**: Combinational and registered operations
3. **Memory Interface**: BRAM ports, address/data muxing
4. **Output Logic**: Done signal, output port assignments

```verilog
module generated_kernel (
    input wire clk,
    input wire rst,
    input wire start,
    output reg done,
    // ... ports
);
    // State encoding
    localparam IDLE = 0, S_COMPUTE = 1, DONE = 2;

    // FSM
    always @(posedge clk) ...

    // Datapath
    always @(posedge clk) ...

    // Outputs
    assign done = (current_state == DONE);
endmodule
```

### Simulation Integration

The simulation module integrates with Verilator for cycle-accurate verification:

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   Generate   │───▶│   Verilator  │───▶│   Execute    │
│   Verilog    │    │   Compile    │    │   Simulate   │
└──────────────┘    └──────────────┘    └──────────────┘
                                              │
                                              ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   Verify vs  │◀───│   Parse      │◀───│   Capture    │
│   Reference  │    │   Outputs    │    │   Results    │
└──────────────┘    └──────────────┘    └──────────────┘
```

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| GPUCompiler.jl | 1.x | Julia GPU compilation framework |
| LLVM.jl | 9.x | Julia wrapper for LLVM C API |
| Graphs.jl | 1.x | Graph data structures for CDFG |
| JuMP.jl | 1.x | Mathematical optimization modeling |
| HiGHS.jl | 1.x | ILP solver for optimal scheduling |
