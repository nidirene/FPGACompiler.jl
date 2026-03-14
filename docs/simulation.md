# Simulation Guide

FPGACompiler.jl provides comprehensive simulation capabilities for verifying hardware designs before synthesis. This guide covers both the native Julia simulator and Verilator integration.

## Table of Contents

1. [Overview](#overview)
2. [Native Julia Simulator](#native-julia-simulator)
3. [Verilator Integration](#verilator-integration)
4. [Waveform Tracing](#waveform-tracing)
5. [Test Suites](#test-suites)
6. [Debugging](#debugging)
7. [Performance Comparison](#performance-comparison)

---

## Overview

FPGACompiler.jl supports two simulation backends:

| Backend | Description | Pros | Cons |
|---------|-------------|------|------|
| **Native** | Pure Julia cycle-accurate simulator | No dependencies, interactive debugging, seamless integration | Slower for large designs |
| **Verilator** | C++ simulation via Verilator | Very fast, industry-standard, VCD support | Requires external tools |

### Quick Start

```julia
using FPGACompiler
using FPGACompiler.HLS
using FPGACompiler.Sim

# Define your function
function my_adder(a::Int32, b::Int32)::Int32
    return a + b
end

# Compile to hardware representation
cdfg = compile_to_cdfg(my_adder, (Int32, Int32))
schedule = schedule_cdfg(cdfg)

# Build and run native simulator
sim = build_simulator(cdfg, schedule)
result = simulate_native(sim, Dict(:a => 5, :b => 3))
println("Result: $(result.outputs[:result])")  # Output: 8
```

---

## Native Julia Simulator

The native simulator provides cycle-accurate hardware simulation entirely in Julia.

### Core Types

#### SimValue - Hardware Value with X Support

```julia
# Create values
v = SimValue(42, 32)           # 32-bit unsigned
v_signed = SimValue(-5, 16; signed=true)  # 16-bit signed

# Extract values
to_unsigned(v)  # Get as UInt64
to_signed(v)    # Get as Int64
to_bool(v)      # Get LSB as Bool

# Undefined (X) values
v_x = SimValue(nothing, 32)  # X (undefined)
v_x.is_valid  # false
```

#### Wire - Combinational Signal

```julia
wire = Wire("my_signal", 32)  # 32-bit wire
wire.value = SimValue(100, 32)
```

#### Register - Sequential Element

```julia
reg = Register("counter", 32; reset_value=0)
reg.current_value  # Current Q output
reg.next_value     # D input (latches on clock)
```

### Simulation API

#### Building the Simulator

```julia
sim = build_simulator(cdfg, schedule)
```

#### Setting Inputs

```julia
# Single input
set_input!(sim, :a, 42)

# Multiple inputs
set_inputs!(sim, Dict(:a => 10, :b => 20))
```

#### Running Simulation

```julia
# Method 1: Run to completion
start!(sim)
while !is_done(sim)
    tick!(sim)
end

# Method 2: Single function call
result = simulate_native(sim, Dict(:a => 5, :b => 3))
println(result.outputs[:result])
println(result.cycles)

# Method 3: Unified interface
result = simulate(cdfg, schedule, Dict(:a => 5, :b => 3); backend=:native)
```

#### Reading Outputs

```julia
# After simulation completes
result = get_output(sim, :result)

# All outputs
outputs = get_outputs(sim)  # Dict{Symbol, SimValue}
```

#### State Inspection

```julia
# Get current FSM state
state = get_state(sim)

# Check completion
is_done(sim)

# Get internal signals
wire_value = get_wire(sim, "alu_out")
reg_value = get_register(sim, "accumulator")
```

### Two-Phase Clock Semantics

The native simulator implements proper RTL semantics:

**Phase 1 - Combinational Evaluation:**
- All wires propagate instantly
- ALU outputs update based on inputs
- MUX outputs selected

**Phase 2 - Sequential Update:**
- Registers latch `next_value` to `current_value`
- FSM transitions to next state
- Memory write completes

```julia
# Manual stepping to observe both phases
tick!(sim)  # Advances one full clock cycle

# Or step through phases manually
peek_combinational!(sim)  # Evaluate without clock edge
step!(sim)  # Apply clock edge (sequential update)
```

---

## Verilator Integration

For high-performance simulation, use Verilator to compile Verilog to optimized C++.

### Prerequisites

1. **Install Verilator:**
   ```bash
   # Ubuntu/Debian
   sudo apt-get install verilator

   # macOS
   brew install verilator

   # Windows (via MSYS2)
   pacman -S mingw-w64-x86_64-verilator

   # From source
   git clone https://github.com/verilator/verilator
   cd verilator && autoconf && ./configure && make && sudo make install
   ```

2. **Install CxxWrap.jl:**
   ```julia
   using Pkg
   Pkg.add("CxxWrap")
   ```

### Basic Verilator Flow

#### Step 1: Generate Verilog

```julia
using FPGACompiler
using FPGACompiler.HLS
using FPGACompiler.RTL

# Compile Julia function
cdfg = compile_to_cdfg(my_function, (Int32, Int32))
schedule = schedule_cdfg(cdfg)
rtl = generate_rtl(cdfg, schedule)

# Write Verilog file
write_verilog(rtl, "my_module.v")
```

#### Step 2: Create C++ Testbench

```cpp
// testbench.cpp
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vmy_module.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vmy_module* dut = new Vmy_module;

    // Enable tracing
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("waveform.vcd");

    // Reset
    dut->rst = 1;
    dut->clk = 0;
    dut->eval();

    // Clock cycles
    for (int i = 0; i < 100; i++) {
        dut->clk = !dut->clk;
        dut->eval();
        tfp->dump(i);

        if (i == 5) dut->rst = 0;  // Release reset
    }

    tfp->close();
    delete dut;
    return 0;
}
```

#### Step 3: Compile and Run

```bash
# Verilate
verilator --cc --trace --exe my_module.v testbench.cpp

# Build
make -C obj_dir -f Vmy_module.mk

# Run
./obj_dir/Vmy_module
```

### Julia Integration via CxxWrap

For seamless Julia integration, wrap the Verilator model with CxxWrap.jl:

```cpp
// wrapper.cpp
#include <verilated.h>
#include "Vmy_module.h"
#include "jlcxx/jlcxx.hpp"

class MyModuleSim {
private:
    Vmy_module* dut;
    uint64_t sim_time = 0;

public:
    MyModuleSim() { dut = new Vmy_module; }
    ~MyModuleSim() { delete dut; }

    void reset() {
        dut->rst = 1;
        tick(); tick();
        dut->rst = 0;
    }

    void tick() {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }

    void set_a(int32_t val) { dut->a = val; }
    void set_b(int32_t val) { dut->b = val; }
    int32_t get_result() { return dut->result; }
    bool is_done() { return dut->done; }
};

JLCXX_MODULE define_julia_module(jlcxx::Module& mod) {
    mod.add_type<MyModuleSim>("MyModuleSim")
        .constructor<>()
        .method("reset!", &MyModuleSim::reset)
        .method("tick!", &MyModuleSim::tick)
        .method("set_a!", &MyModuleSim::set_a)
        .method("set_b!", &MyModuleSim::set_b)
        .method("get_result", &MyModuleSim::get_result)
        .method("is_done", &MyModuleSim::is_done);
}
```

Use in Julia:

```julia
using CxxWrap
@wrapmodule(() -> "path/to/libwrapper.so")

sim = MyModuleSim()
sim.reset!()
sim.set_a!(10)
sim.set_b!(20)

while !sim.is_done()
    sim.tick!()
end

println("Result: ", sim.get_result())
```

---

## Waveform Tracing

### Native Simulator VCD Output

```julia
# Enable tracing
enable_trace!(sim)
trace_all!(sim)  # Trace all signals

# Or trace specific signals
trace_signals!(sim, ["fsm_state", "alu_out", "accumulator"])

# Run simulation
result = simulate_native(sim, inputs)

# Write VCD file
write_vcd(sim, "output.vcd")
```

### VCD Writer API

```julia
# Low-level VCD writing
vcd = VCDWriter("trace.vcd", "1ns")

# Write header
write_vcd_header!(vcd, sim)

# During simulation
for cycle in 1:100
    tick!(sim)
    write_vcd_change!(vcd, sim, cycle)
end

close_vcd!(vcd)
```

### Viewing Waveforms

```bash
# GTKWave (recommended)
gtkwave output.vcd

# WaveDrom (web-based)
# Export signals to JSON and view at wavedrom.com
```

### Signal Table Output

```julia
# Print ASCII signal table
print_signal_table(sim)

# Output:
# Cycle | fsm_state | a_reg | b_reg | result
# ------|-----------|-------|-------|-------
#     0 |      IDLE |     0 |     0 |      0
#     1 |   STATE_1 |     5 |     3 |      0
#     2 |   STATE_2 |     5 |     3 |      8
#     3 |      DONE |     5 |     3 |      8
```

---

## Test Suites

### Creating Test Vectors

```julia
# Individual test vector
tv = TestVector(
    "test_add_positive",
    Dict("a" => 5, "b" => 3),        # inputs
    Dict("result" => 8)               # expected outputs
)

# Test suite
suite = TestSuite(
    "Adder Tests",
    "Comprehensive adder verification",
    [
        TestVector("pos+pos", Dict("a" => 5, "b" => 3), Dict("result" => 8)),
        TestVector("neg+pos", Dict("a" => -5, "b" => 10), Dict("result" => 5)),
        TestVector("zero", Dict("a" => 0, "b" => 0), Dict("result" => 0)),
    ]
)
```

### Running Test Suites

```julia
# Build simulator
sim = build_simulator(cdfg, schedule)

# Run all tests
result = run_test_suite(sim, suite; verbose=true)

# Check results
println("Passed: $(result.passed)/$(result.total_tests)")
println("Pass rate: $(result.statistics["test_pass_rate"])%")

if !result.success
    println("Failed tests:")
    for failure in result.failures
        println("  - $(failure["test_name"]): $(failure["mismatches"])")
    end
end
```

### Generating Test Vectors

```julia
# From Julia reference function
function reference_add(a, b)
    return a + b
end

vectors = generate_test_vectors_from_function(
    reference_add,
    [:a, :b],
    [:result];
    ranges=Dict(:a => -100:100, :b => -100:100),
    num_random=50
)

# Directed tests for edge cases
edge_cases = generate_directed_tests(
    [:a, :b],
    [:result];
    corner_cases=true,
    overflow_tests=true,
    bit_width=32
)
```

---

## Debugging

### State Inspection

```julia
# Dump complete state
dump_state(sim)

# Dump FSM information
dump_fsm(sim)

# Dump datapath
dump_datapath(sim)
```

### Watch Points

```julia
# Watch specific signals
watch(sim, "alu_out")
watch(sim, "fsm_state")

# Examine signal value
examine(sim, "accumulator")

# List all signals
list_signals(sim)
```

### Reference Verification

```julia
# Compare against Julia reference
function reference_impl(a, b)
    return a + b
end

success = verify_against_reference(
    sim,
    Dict(:a => 5, :b => 3),
    reference_impl
)
```

### Verbose Simulation

```julia
# Enable verbose output
result = simulate_native(sim, inputs; verbose=true)

# Output shows:
# Cycle 0: State=IDLE
# Cycle 1: State=STATE_1, alu_out=8
# Cycle 2: State=DONE, result=8
# Simulation complete: 3 cycles
```

---

## Performance Comparison

### Benchmark Results

| Design | Native Sim | Verilator | Speedup |
|--------|------------|-----------|---------|
| Simple adder | 50k cycles/s | 10M cycles/s | 200x |
| 16-bit multiplier | 30k cycles/s | 8M cycles/s | 267x |
| FIR filter | 10k cycles/s | 5M cycles/s | 500x |
| Matrix multiply | 5k cycles/s | 3M cycles/s | 600x |

### When to Use Each Backend

**Use Native Simulator when:**
- Rapid prototyping and debugging
- Interactive exploration
- No external dependencies required
- Small to medium designs
- Need tight Julia integration

**Use Verilator when:**
- Large designs
- Long simulations (millions of cycles)
- Final verification before synthesis
- Performance-critical testing
- CI/CD pipelines

### Hybrid Approach

```julia
# Quick iteration with native
result_native = simulate(cdfg, schedule, inputs; backend=:native)

# Final verification with Verilator
rtl = generate_rtl(cdfg, schedule)
result_verilator = simulate(rtl, inputs; backend=:verilator)

# Compare results
@assert result_native.outputs == result_verilator.outputs
```

---

## API Reference

### Core Functions

| Function | Description |
|----------|-------------|
| `build_simulator(cdfg, schedule)` | Create simulator from CDFG |
| `reset!(sim)` | Reset to initial state |
| `tick!(sim)` | Execute one clock cycle |
| `run!(sim; max_cycles)` | Run until completion |
| `set_input!(sim, port, value)` | Set input port value |
| `get_output(sim, port)` | Get output port value |
| `is_done(sim)` | Check if simulation complete |
| `get_state(sim)` | Get current FSM state |

### Tracing Functions

| Function | Description |
|----------|-------------|
| `enable_trace!(sim)` | Enable signal tracing |
| `trace_all!(sim)` | Trace all signals |
| `trace_signals!(sim, names)` | Trace specific signals |
| `write_vcd(sim, filename)` | Write VCD waveform file |
| `print_signal_table(sim)` | Print ASCII signal table |

### Debug Functions

| Function | Description |
|----------|-------------|
| `dump_state(sim)` | Print complete state |
| `dump_fsm(sim)` | Print FSM information |
| `examine(sim, signal)` | Get signal value |
| `watch(sim, signal)` | Add signal to watch list |
| `list_signals(sim)` | List all signals |

---

## Troubleshooting

### Common Issues

**X-Value Propagation:**
```julia
# Check for undefined values
if !result.is_valid
    println("Warning: Output contains X values")
    dump_state(sim)
end
```

**Infinite Loops:**
```julia
# Set maximum cycles
result = simulate_native(sim, inputs; max_cycles=10000)
if result.cycles >= 10000
    println("Warning: Max cycles reached")
end
```

**FSM Stuck:**
```julia
# Debug FSM transitions
dump_fsm(sim)
# Check conditions for state transitions
```

### Getting Help

- GitHub Issues: https://github.com/your-repo/FPGACompiler.jl/issues
- Documentation: See `docs/` directory
- Examples: See `examples/` directory
