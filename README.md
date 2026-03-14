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
7. **Dual simulation backends**: Native Julia simulator and Verilator integration
8. **Hardware-Software CoDesign** with interactive DSE exploration and Makie visualization
9. Outputting clean LLVM IR for vendor HLS tools (Intel oneAPI, AMD Vitis, Bambu)

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

Verifies generated RTL with two backends:

#### Native Julia Simulator

A pure Julia cycle-accurate RTL simulator with:
- **Two-phase clock semantics** - Combinational evaluation followed by sequential latching
- **X-value propagation** - Tracks undefined signals through the design
- **VCD waveform output** - Compatible with GTKWave and other viewers
- **No external dependencies** - Runs anywhere Julia runs

#### Verilator Integration

The open-source Verilator compiles Verilog into extremely fast C++ simulation:
- **High performance** - 10-100x faster than interpreted simulation
- **Cycle-accurate** - Exact hardware behavior
- **Waveform tracing** - Full signal visibility

### Phase 7: Hardware-Software CoDesign

Interactive design space exploration without full compilation:

- **Parametric Simulation** - Fast performance estimation without LLVM
- **DSE Sweeps** - Explore unroll factors, initiation intervals, BRAM ports
- **Virtual Devices** - Simulate Alveo, Zynq, Arty targets
- **Observable Integration** - Ready for Makie.jl live visualization
- **Workload Patterns** - Conv2D, MatMul, FIR, and custom workloads

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

## Simulation

FPGACompiler provides two simulation backends for verifying generated RTL.

### Native Julia Simulator

The native simulator runs entirely in Julia with no external dependencies:

```julia
using FPGACompiler.Sim

# Create simulator from CDFG and schedule
sim = build_simulator(cdfg, schedule)

# Set input values
set_input!(sim, :a, 10)
set_input!(sim, :b, 5)

# Start the computation
start!(sim)

# Run until completion (or max cycles)
result = run!(sim; max_cycles=1000, verbose=true)

# Check outputs
if result.success
    output = get_output(sim, :result)
    println("Result: $(to_unsigned(output))")
end
```

#### Cycle-by-Cycle Debugging

```julia
# Reset simulator
reset!(sim)
set_input!(sim, :a, 42)
start!(sim)

# Step through cycles
while !is_done(sim)
    state = step!(sim)
    println("Cycle $(state[:cycle]): State = $(state[:fsm_state])")

    # Inspect any signal
    val = get_signal_value(sim, "add_result")
    println("  add_result = $val")
end
```

#### VCD Waveform Output

```julia
# Enable tracing for specific signals
enable_trace!(sim, ["a", "b", "result", "fsm_state"])

# Run simulation
simulate_native(sim, Dict(:a => 10, :b => 5))

# Write VCD file
write_vcd(sim, "simulation.vcd")
```

View with GTKWave:
```bash
gtkwave simulation.vcd
```

#### Memory Initialization

```julia
# Initialize BRAM contents
initialize_memory!(sim, "data_mem", [1, 2, 3, 4, 5, 6, 7, 8])

# Run computation
run!(sim)

# Read memory results
for i in 0:7
    val = read_memory(sim, "data_mem", i)
    println("mem[$i] = $(to_unsigned(val))")
end
```

### Verilator Integration

For higher performance simulation, use Verilator:

```julia
using FPGACompiler.Sim

# Generate testbench
tb = generate_testbench(rtl_module, [
    (a=1.0f0, b=2.0f0, c=3.0f0),  # Test vector 1
    (a=4.0f0, b=5.0f0, c=6.0f0),  # Test vector 2
])

# Run simulation with Verilator
result = run_verilator(rtl_module, tb)
@assert result.passed
```

### Unified Simulation Interface

Both backends support a unified interface:

```julia
using FPGACompiler.Sim

# Native simulation (no external tools required)
result = simulate(cdfg, schedule, Dict(:a => 10, :b => 5); backend=:native)

# Verilator simulation (faster, requires Verilator installed)
result = simulate(rtl_module, Dict("a" => 10, "b" => 5); backend=:verilator)
```

## Hardware-Software CoDesign

The CoDesign module enables rapid design space exploration without full FPGA compilation.

### Quick Start

```julia
using FPGACompiler.CoDesign

# Define workload (no compilation needed)
workload = conv2d_workload(kernel_size=3, img_height=28, img_width=28)

# Configure DSE parameters
dse = DSEParameters(unroll_factor=4, bram_ports=2, max_dsps=64)

# Create kernel and get performance estimate
kernel = CoDesignKernel("conv2d"; workload=workload, dse=dse)
estimate = estimate!(kernel)

println("Estimated cycles: $(estimate.estimated_cycles)")
println("Throughput: $(estimate.estimated_throughput) items/cycle")
println("Bottleneck: $(estimate.bottleneck)")
```

### Workload Patterns

Define kernel characteristics without writing actual kernel code:

```julia
# 2D Convolution (image processing, ML)
conv = conv2d_workload(kernel_size=5, img_height=224, img_width=224)

# Matrix Multiplication
matmul = matmul_workload(M=128, N=128, K=128)

# FIR Filter (signal processing)
fir = fir_filter_workload(taps=32, samples=4096)

# Elementwise operations
elem = elementwise_workload(height=10000, ops_per_element=3)

# Reduction (sum, max, etc.)
reduce = reduction_workload(length=1024)
```

### DSE Parameter Sweeps

Explore the design space automatically:

```julia
using FPGACompiler.CoDesign

workload = conv2d_workload(kernel_size=3)

# Sweep unroll factors
results = sweep_unroll_factor(workload, 1:16)
for r in results
    println("UF=$(r.unroll_factor): $(r.cycles) cycles, $(r.throughput) items/cycle")
end

# Multi-dimensional sweep
points = sweep_dse_space(workload;
    unroll_range = 1:8,
    ii_range = 1:2,
    bram_range = 1:4
)

# Find optimal configuration
best = find_optimal_config(workload;
    optimize_for = :throughput,  # or :latency, :efficiency
    max_dsps = 64,
    max_brams = 32
)
println("Best config: UF=$(best.unroll_factor), II=$(best.initiation_interval)")
```

### Virtual FPGA Devices

Target specific FPGA platforms:

```julia
using FPGACompiler.CoDesign

# Preset device configurations
device = zynq_7020()       # Embedded: 220 DSPs, 140 BRAMs
# device = arty_a7()       # Hobbyist: 90 DSPs, 50 BRAMs
# device = alveo_u200()    # Datacenter: 6840 DSPs, 2160 BRAMs
# device = alveo_u280()    # HBM: 9024 DSPs, 2016 BRAMs

# Device-constrained optimization
workload = matmul_workload(M=64, N=64, K=64)
best = find_optimal_config(workload;
    max_dsps = device.total_dsps,
    max_brams = device.total_brams
)

# Check resource utilization
util = resource_utilization(device)
println("DSP utilization: $(util.dsps)%")
```

### Virtual Device Memory

Simulate FPGA memory with access tracking:

```julia
using FPGACompiler.CoDesign

device = VirtualFPGADevice("MyFPGA"; dsps=100, brams=50)

# Allocate device memory
input_data = allocate!(device, :input, Float32, (1024,))
output_data = allocate!(device, :output, Float32, (1024,))

# Simulate data transfer (returns cycle count)
host_data = rand(Float32, 1024)
transfer_cycles = copyto_device!(device, input_data, host_data)
println("DMA transfer: $transfer_cycles cycles")

# Track memory accesses
enable_tracking!(input_data, true)
# ... run kernel ...
println("Total reads: $(input_data.total_reads)")
```

### Interactive Simulation with Observables

The CoDesign module integrates with Makie.jl for live visualization:

```julia
using FPGACompiler.CoDesign

workload = conv2d_workload(kernel_size=3, img_height=28, img_width=28)
kernel = CoDesignKernel("conv2d"; workload=workload)

# Observables update automatically during simulation
obs = kernel.observables

# These can be connected to Makie plots
# obs.clock[]           # Current cycle
# obs.progress[]        # 0-100%
# obs.throughput[]      # Items per cycle
# obs.pipeline[]        # Pipeline stage occupancy
# obs.dsp_util[]        # DSP utilization %
# obs.fsm_state[]       # FSM state name

# Run simulation (observables update each cycle)
result = simulate!(kernel; backend=:parametric)
```

### Full Pipeline Integration

For cycle-accurate simulation, compile through the full FPGACompiler pipeline:

```julia
using FPGACompiler
using FPGACompiler.CoDesign

# Define actual Julia function
function my_add(a::Int32, b::Int32)::Int32
    return a + b
end

# Compile through full pipeline (LLVM → CDFG → Schedule → Simulator)
compiled = compile_kernel(my_add, Tuple{Int32, Int32})

if compiled.is_compiled
    println("Critical path: $(compiled.critical_path) cycles")
    println("Total nodes: $(compiled.total_nodes)")

    # Run cycle-accurate simulation
    result = simulate_compiled(compiled, Dict(:a => 5, :b => 3))
    println("Result: $(result.outputs)")
end
```

## Getting Started with Verilator

The open-source community provides **Verilator**, which compiles Verilog into an extremely fast C++ simulation. You can use Julia's `CxxWrap.jl` to compile the generated Verilog, wrap the C++ simulator cycle-by-cycle, and inject Julia arrays directly into the simulated hardware clock pins to verify the outputs.

### Installing Verilator

**Ubuntu/Debian:**
```bash
sudo apt-get install verilator
```

**macOS:**
```bash
brew install verilator
```

**Windows (MSYS2):**
```bash
pacman -S mingw-w64-x86_64-verilator
```

**From source:**
```bash
git clone https://github.com/verilator/verilator
cd verilator
autoconf
./configure
make -j$(nproc)
sudo make install
```

### Basic Verilator Workflow

1. **Generate Verilog from Julia:**

```julia
using FPGACompiler
using FPGACompiler.HLS
using FPGACompiler.RTL

# Create your design
cdfg = CDFG("adder")
# ... add operations ...

# Generate RTL
rtl = generate_rtl(cdfg)
verilog = emit_verilog(rtl)

# Write Verilog file
write("adder.v", verilog)
```

2. **Compile with Verilator:**

```bash
verilator --cc adder.v --exe --build sim_main.cpp
```

3. **Run simulation:**

```bash
./obj_dir/Vadder
```

### Advanced: Julia-Verilator Integration with CxxWrap.jl

For tight integration between Julia and Verilator, use `CxxWrap.jl` to call the C++ simulator directly:

**Step 1: Generate wrapper code**

```cpp
// verilator_wrapper.cpp
#include "jlcxx/jlcxx.hpp"
#include "Vadder.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

class AdderSim {
public:
    Vadder* dut;
    VerilatedVcdC* tfp;
    vluint64_t sim_time;

    AdderSim() : sim_time(0) {
        dut = new Vadder;
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        dut->trace(tfp, 99);
        tfp->open("trace.vcd");
    }

    ~AdderSim() {
        tfp->close();
        delete tfp;
        delete dut;
    }

    void reset() {
        dut->rst = 1;
        for (int i = 0; i < 5; i++) {
            dut->clk = 0; dut->eval(); tfp->dump(sim_time++);
            dut->clk = 1; dut->eval(); tfp->dump(sim_time++);
        }
        dut->rst = 0;
    }

    void set_input_a(uint32_t val) { dut->a = val; }
    void set_input_b(uint32_t val) { dut->b = val; }
    uint32_t get_output() { return dut->result; }
    bool is_done() { return dut->done; }

    void tick() {
        dut->clk = 0; dut->eval(); tfp->dump(sim_time++);
        dut->clk = 1; dut->eval(); tfp->dump(sim_time++);
    }

    void start() {
        dut->start = 1;
        tick();
        dut->start = 0;
    }
};

JLCXX_MODULE define_julia_module(jlcxx::Module& mod) {
    mod.add_type<AdderSim>("AdderSim")
        .constructor<>()
        .method("reset!", &AdderSim::reset)
        .method("set_a!", &AdderSim::set_input_a)
        .method("set_b!", &AdderSim::set_input_b)
        .method("get_output", &AdderSim::get_output)
        .method("is_done", &AdderSim::is_done)
        .method("tick!", &AdderSim::tick)
        .method("start!", &AdderSim::start);
}
```

**Step 2: Build the wrapper**

```bash
# Compile Verilog to C++
verilator --cc adder.v --trace -CFLAGS "-fPIC"

# Build wrapper library
g++ -shared -fPIC -o libadder_sim.so \
    verilator_wrapper.cpp \
    obj_dir/Vadder.cpp \
    obj_dir/verilated.cpp \
    obj_dir/verilated_vcd_c.cpp \
    $(julia -e 'using CxxWrap; print(CxxWrap.prefix_path())') \
    -I$(julia -e 'using CxxWrap; print(CxxWrap.include_dir())') \
    -I/usr/share/verilator/include \
    -L$(julia -e 'print(Sys.BINDIR, "/../lib")') -ljulia
```

**Step 3: Use from Julia**

```julia
using CxxWrap

# Load the wrapper
@wrapmodule("./libadder_sim.so")
function __init__()
    @initcxx
end

# Create simulator and run tests
function test_adder()
    sim = AdderSim()
    reset!(sim)

    # Test case 1: 5 + 3 = 8
    set_a!(sim, 5)
    set_b!(sim, 3)
    start!(sim)

    while !is_done(sim)
        tick!(sim)
    end

    result = get_output(sim)
    @assert result == 8 "Expected 8, got $result"

    println("Test passed! 5 + 3 = $result")
end

test_adder()
```

### Batch Testing with Julia Arrays

Inject Julia arrays directly into simulation:

```julia
function batch_test(sim, test_vectors::Vector{Tuple{UInt32, UInt32, UInt32}})
    passed = 0
    failed = 0

    for (a, b, expected) in test_vectors
        reset!(sim)
        set_a!(sim, a)
        set_b!(sim, b)
        start!(sim)

        cycles = 0
        while !is_done(sim) && cycles < 1000
            tick!(sim)
            cycles += 1
        end

        result = get_output(sim)
        if result == expected
            passed += 1
        else
            println("FAIL: $a + $b = $result (expected $expected)")
            failed += 1
        end
    end

    println("Results: $passed passed, $failed failed")
    return failed == 0
end

# Generate random test vectors
test_vectors = [(rand(UInt32) % 1000, rand(UInt32) % 1000, 0) for _ in 1:100]
test_vectors = [(a, b, a + b) for (a, b, _) in test_vectors]

sim = AdderSim()
batch_test(sim, test_vectors)
```

## Compiler Parameters

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

#### Native Simulator

| Function | Description |
|----------|-------------|
| `build_simulator(cdfg, schedule)` | Create simulator from CDFG |
| `reset!(sim)` | Reset to initial state |
| `tick!(sim)` | Execute one clock cycle |
| `run!(sim; max_cycles)` | Run until completion |
| `start!(sim)` | Assert start signal |
| `set_input!(sim, port, value)` | Set input port value |
| `get_output(sim, port)` | Get output port value |
| `get_state(sim)` | Get current FSM state |
| `is_done(sim)` | Check if simulation complete |
| `enable_trace!(sim, signals)` | Enable signal tracing |
| `write_vcd(sim, file)` | Write VCD waveform |

#### Verilator Integration

| Function | Description |
|----------|-------------|
| `check_verilator()` | Check if Verilator is installed |
| `compile_verilator(verilog, output_dir)` | Compile Verilog to C++ |
| `run_verilator(executable)` | Run compiled simulation |
| `simulate(rtl, inputs)` | High-level simulation wrapper |

#### Types

| Type | Description |
|------|-------------|
| `SimValue` | Hardware value with X support |
| `Wire` | Combinational signal |
| `Register` | Sequential flip-flop |
| `ALU` | Arithmetic/logic unit |
| `Memory` | BRAM simulation |
| `NativeSimulator` | Main simulation engine |
| `SimulationResult` | Simulation output |

### CoDesign Module (`FPGACompiler.CoDesign`)

#### Workload Definition

| Function | Description |
|----------|-------------|
| `conv2d_workload(; kernel_size, img_height, img_width)` | 2D convolution workload |
| `matmul_workload(; M, N, K)` | Matrix multiplication workload |
| `fir_filter_workload(; taps, samples)` | FIR filter workload |
| `elementwise_workload(; height, width, ops)` | Elementwise operation workload |
| `reduction_workload(; length)` | Reduction workload |

#### DSE Functions

| Function | Description |
|----------|-------------|
| `sweep_unroll_factor(workload, range)` | Sweep unroll factor |
| `sweep_dse_space(workload; kwargs...)` | Multi-dimensional DSE sweep |
| `find_optimal_config(workload; kwargs...)` | Find optimal configuration |
| `estimate_performance(sim)` | Quick performance estimate |

#### Virtual Devices

| Function | Description |
|----------|-------------|
| `alveo_u200()` | Xilinx Alveo U200 preset |
| `alveo_u280()` | Xilinx Alveo U280 preset |
| `zynq_7020()` | Xilinx Zynq-7020 preset |
| `arty_a7()` | Digilent Arty A7-35T preset |
| `allocate!(device, name, type, dims)` | Allocate device memory |
| `copyto_device!(device, dst, src)` | DMA transfer to device |
| `resource_utilization(device)` | Get resource utilization % |

#### Simulation

| Function | Description |
|----------|-------------|
| `CoDesignKernel(name; workload, dse)` | Create CoDesign kernel |
| `simulate!(kernel; backend)` | Run simulation |
| `estimate!(kernel)` | Get performance estimate |
| `compile_kernel(f, types)` | Compile through full pipeline |

#### Types

| Type | Description |
|------|-------------|
| `DSEParameters` | Design space exploration parameters |
| `WorkloadDescriptor` | Kernel workload characteristics |
| `VirtualFPGADevice` | Virtual FPGA device |
| `VirtualFPGAArray` | Device memory array |
| `ParametricSimulator` | Fast parametric simulator |
| `CoDesignKernel` | Unified kernel wrapper |
| `CompiledKernel` | Full-pipeline compiled kernel |

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
| Open Source | Verilator | `verilator --cc kernel.v` |

## Dependencies

- [GPUCompiler.jl](https://github.com/JuliaGPU/GPUCompiler.jl) - Julia GPU compilation framework
- [LLVM.jl](https://github.com/maleadt/LLVM.jl) - Julia wrapper for LLVM C API
- [Graphs.jl](https://github.com/JuliaGraphs/Graphs.jl) - Graph data structures for CFG/DFG
- [JuMP.jl](https://github.com/jump-dev/JuMP.jl) - Mathematical optimization for ILP scheduling
- [HiGHS.jl](https://github.com/jump-dev/HiGHS.jl) - High-performance LP/MIP solver
- [Observables.jl](https://github.com/JuliaGizmos/Observables.jl) - Reactive programming for CoDesign UI

### Optional Dependencies

- [Verilator](https://verilator.org/) - Fast Verilog simulation
- [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl) - C++ integration for Verilator
- [GTKWave](http://gtkwave.sourceforge.net/) - VCD waveform viewer
- [Makie.jl](https://github.com/JuliaPlots/Makie.jl) - Visualization for CoDesign dashboards
- [Pluto.jl](https://github.com/fonsp/Pluto.jl) - Interactive notebooks for DSE exploration

## Documentation

- [API Reference](docs/api.md) - Complete function and type documentation
- [Architecture](docs/architecture.md) - Internal design and extension points
- [Tutorial](docs/tutorial.md) - Step-by-step usage guide
- [Simulation Guide](docs/simulation.md) - Native and Verilator simulation
- [Vendor Integration](docs/vendor-integration.md) - Intel/AMD/Bambu workflows

## Examples

See the `examples/` directory for complete working examples:

- [`vector_add.jl`](examples/vector_add.jl) - Basic kernel compilation
- [`matrix_mul.jl`](examples/matrix_mul.jl) - Pipelined matrix multiplication
- [`memory_partition.jl`](examples/memory_partition.jl) - PartitionedArray usage
- [`custom_bitwidth.jl`](examples/custom_bitwidth.jl) - FixedInt for resource efficiency
- [`native_simulation.jl`](examples/native_simulation.jl) - Native Julia simulation
- [`verilator_integration.jl`](examples/verilator_integration.jl) - Verilator workflow

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
- Simulation performance optimizations

## License

MIT License - see [LICENSE](LICENSE) for details.
