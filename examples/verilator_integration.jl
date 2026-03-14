# Verilator Integration Example
# ==============================
# This example demonstrates how to use Verilator for cycle-accurate
# C++ simulation of generated Verilog, with Julia integration via CxxWrap.jl
#
# Prerequisites:
#   1. Verilator installed (https://verilator.org)
#   2. CxxWrap.jl package (for C++ integration)
#   3. C++ compiler (g++ or clang++)

using FPGACompiler
using FPGACompiler.HLS
using FPGACompiler.RTL
using FPGACompiler.Sim

# ============================================================================
# Part 1: Generate RTL from Julia Function
# ============================================================================

println("=" ^ 70)
println("Part 1: Generating RTL from Julia Function")
println("=" ^ 70)

# Define the hardware function
function fibonacci(n::Int32)::Int32
    if n <= 1
        return n
    end
    a = Int32(0)
    b = Int32(1)
    for i in Int32(2):n
        c = a + b
        a = b
        b = c
    end
    return b
end

# Compile through HLS pipeline
println("\nCompiling fibonacci function to RTL...")
cdfg = compile_to_cdfg(fibonacci, (Int32,))
schedule = schedule_cdfg(cdfg)
rtl = generate_rtl(cdfg, schedule)

# Generate Verilog
output_dir = "verilator_build"
mkpath(output_dir)

verilog_file = joinpath(output_dir, "fibonacci.v")
write_verilog(rtl, verilog_file)
println("Generated: $verilog_file")

# ============================================================================
# Part 2: Generate Verilator Testbench
# ============================================================================

println("\n" * "=" ^ 70)
println("Part 2: Creating Verilator Testbench")
println("=" ^ 70)

# Generate C++ testbench wrapper
testbench_cpp = """
// Auto-generated Verilator testbench wrapper
// Provides Julia-callable interface via CxxWrap

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vfibonacci.h"
#include "jlcxx/jlcxx.hpp"

class FibonacciSim {
private:
    Vfibonacci* dut;
    VerilatedVcdC* tfp;
    uint64_t sim_time;
    bool trace_enabled;

public:
    FibonacciSim() : sim_time(0), trace_enabled(false) {
        dut = new Vfibonacci;
        tfp = nullptr;
    }

    ~FibonacciSim() {
        if (tfp) {
            tfp->close();
            delete tfp;
        }
        delete dut;
    }

    void enable_trace(const std::string& filename) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        dut->trace(tfp, 99);
        tfp->open(filename.c_str());
        trace_enabled = true;
    }

    void reset() {
        dut->rst = 1;
        dut->clk = 0;
        dut->eval();
        tick();
        tick();
        dut->rst = 0;
        tick();
    }

    void tick() {
        dut->clk = 0;
        dut->eval();
        if (trace_enabled) tfp->dump(sim_time++);

        dut->clk = 1;
        dut->eval();
        if (trace_enabled) tfp->dump(sim_time++);
    }

    void set_input(int32_t n) {
        dut->n = n;
    }

    void start() {
        dut->start = 1;
        tick();
        dut->start = 0;
    }

    bool is_done() {
        return dut->done;
    }

    int32_t get_result() {
        return dut->result;
    }

    int run_to_completion(int max_cycles = 10000) {
        int cycles = 0;
        while (!is_done() && cycles < max_cycles) {
            tick();
            cycles++;
        }
        return cycles;
    }

    void close_trace() {
        if (tfp) {
            tfp->close();
        }
    }
};

// CxxWrap module definition
JLCXX_MODULE define_julia_module(jlcxx::Module& mod) {
    mod.add_type<FibonacciSim>("FibonacciSim")
        .constructor<>()
        .method("enable_trace!", &FibonacciSim::enable_trace)
        .method("reset!", &FibonacciSim::reset)
        .method("tick!", &FibonacciSim::tick)
        .method("set_input!", &FibonacciSim::set_input)
        .method("start!", &FibonacciSim::start)
        .method("is_done", &FibonacciSim::is_done)
        .method("get_result", &FibonacciSim::get_result)
        .method("run_to_completion!", &FibonacciSim::run_to_completion)
        .method("close_trace!", &FibonacciSim::close_trace);
}
"""

testbench_file = joinpath(output_dir, "testbench_wrapper.cpp")
open(testbench_file, "w") do f
    write(f, testbench_cpp)
end
println("Generated: $testbench_file")

# ============================================================================
# Part 3: Generate Build Script
# ============================================================================

println("\n" * "=" ^ 70)
println("Part 3: Generating Build Script")
println("=" ^ 70)

# CMakeLists.txt for building with CxxWrap
cmake_content = """
cmake_minimum_required(VERSION 3.15)
project(fibonacci_sim)

# Find required packages
find_package(verilator REQUIRED)
find_package(JlCxx REQUIRED)

# Get Julia includes
execute_process(
    COMMAND julia -e "print(joinpath(Sys.BINDIR, Base.DATAROOTDIR, \\"julia\\", \\"include\\", \\"julia\\"))"
    OUTPUT_VARIABLE JULIA_INCLUDE_DIR
)

# Verilate the design
verilate(fibonacci_sim SOURCES fibonacci.v
    TRACE
    INCLUDE_DIRS .
)

# Create shared library for Julia
add_library(fibonacci_jl SHARED testbench_wrapper.cpp)
target_link_libraries(fibonacci_jl PRIVATE
    fibonacci_sim
    JlCxx::cxxwrap_julia
)
target_include_directories(fibonacci_jl PRIVATE
    \${CMAKE_CURRENT_BINARY_DIR}
    \${JULIA_INCLUDE_DIR}
)

# Set output name for Julia
set_target_properties(fibonacci_jl PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libfibonacci_jl"
)
"""

cmake_file = joinpath(output_dir, "CMakeLists.txt")
open(cmake_file, "w") do f
    write(f, cmake_content)
end
println("Generated: $cmake_file")

# Alternative: Direct Makefile for simpler builds
makefile_content = """
# Makefile for Verilator simulation
# Usage: make && julia verilator_test.jl

VERILATOR = verilator
VERILATOR_FLAGS = --cc --trace --exe -O3

# Julia paths (adjust for your system)
JULIA_DIR := \$(shell julia -e 'print(joinpath(Sys.BINDIR, ".."))')
JULIA_INCLUDE := \$(JULIA_DIR)/include/julia
JULIA_LIB := \$(JULIA_DIR)/lib

# CxxWrap paths
CXXWRAP_INCLUDE := \$(shell julia -e 'using CxxWrap; print(CxxWrap.prefix_path())')/include
CXXWRAP_LIB := \$(shell julia -e 'using CxxWrap; print(CxxWrap.prefix_path())')/lib

CXX = g++
CXXFLAGS = -std=c++17 -fPIC -shared -O3
INCLUDES = -I\$(JULIA_INCLUDE) -I\$(CXXWRAP_INCLUDE) -Iobj_dir

.PHONY: all clean verilate lib

all: verilate lib

verilate:
\t\$(VERILATOR) \$(VERILATOR_FLAGS) fibonacci.v --top-module fibonacci
\t\$(MAKE) -C obj_dir -f Vfibonacci.mk

lib: verilate
\t\$(CXX) \$(CXXFLAGS) \$(INCLUDES) testbench_wrapper.cpp \\
\t\t-Lobj_dir -lVfibonacci \\
\t\t-L\$(JULIA_LIB) -ljulia \\
\t\t-L\$(CXXWRAP_LIB) -lcxxwrap_julia \\
\t\t-o libfibonacci_jl.so

clean:
\trm -rf obj_dir *.so *.vcd
"""

makefile = joinpath(output_dir, "Makefile")
open(makefile, "w") do f
    write(f, makefile_content)
end
println("Generated: $makefile")

# ============================================================================
# Part 4: Julia Test Script
# ============================================================================

println("\n" * "=" ^ 70)
println("Part 4: Julia Test Script")
println("=" ^ 70)

julia_test_script = """
# Verilator Test Script
# Run after building: julia verilator_test.jl

using CxxWrap

# Load the compiled shared library
@wrapmodule(() -> joinpath(@__DIR__, "libfibonacci_jl.so"))

function __init__()
    @initcxx
end

# Create simulator instance
sim = FibonacciSim()

# Optional: Enable VCD tracing
sim.enable_trace!("fibonacci.vcd")

# Test cases
test_cases = [
    (n=0, expected=0),
    (n=1, expected=1),
    (n=2, expected=1),
    (n=5, expected=5),
    (n=10, expected=55),
    (n=15, expected=610),
    (n=20, expected=6765),
]

println("Running Verilator simulation tests...")
println("-" ^ 50)

all_passed = true
for tc in test_cases
    # Reset and configure
    sim.reset!()
    sim.set_input!(tc.n)
    sim.start!()

    # Run simulation
    cycles = sim.run_to_completion!(10000)

    # Get result
    result = sim.get_result()
    passed = result == tc.expected

    status = passed ? "PASS" : "FAIL"
    println("fib(\$(tc.n)) = \$result (expected: \$(tc.expected)) [\$status] (\$cycles cycles)")

    if !passed
        all_passed = false
    end
end

sim.close_trace!()

println("-" ^ 50)
if all_passed
    println("All tests PASSED!")
else
    println("Some tests FAILED!")
    exit(1)
end
"""

test_script = joinpath(output_dir, "verilator_test.jl")
open(test_script, "w") do f
    write(f, julia_test_script)
end
println("Generated: $test_script")

# ============================================================================
# Part 5: Native Simulation for Comparison
# ============================================================================

println("\n" * "=" ^ 70)
println("Part 5: Native Julia Simulation (Reference)")
println("=" ^ 70)

# Use native simulator for reference results
sim_native = build_simulator(cdfg, schedule)

println("\nRunning native simulation for comparison:")
println("-" ^ 50)

test_values = [0, 1, 2, 5, 10, 15, 20]
for n in test_values
    reset!(sim_native)
    result = simulate_native(sim_native, Dict(:n => n))
    println("fib($n) = $(result.outputs[:result]) ($(result.cycles) cycles)")
end

# ============================================================================
# Part 6: Batch Verification
# ============================================================================

println("\n" * "=" ^ 70)
println("Part 6: Generating Batch Verification Script")
println("=" ^ 70)

# Generate a comprehensive test script
batch_test_script = """
#!/bin/bash
# Batch verification script for Fibonacci RTL

set -e

echo "======================================"
echo "FPGACompiler.jl Verilator Integration"
echo "======================================"

# Check prerequisites
command -v verilator >/dev/null 2>&1 || {
    echo "Error: Verilator not found. Install from https://verilator.org"
    exit 1
}

echo "Step 1: Compiling Verilog with Verilator..."
verilator --cc --trace -O3 fibonacci.v --top-module fibonacci

echo "Step 2: Building simulation library..."
make -C obj_dir -f Vfibonacci.mk

echo "Step 3: Building Julia wrapper..."
make lib

echo "Step 4: Running Julia tests..."
julia verilator_test.jl

echo "======================================"
echo "Verification complete!"
echo "VCD waveform: fibonacci.vcd"
echo "======================================"
"""

batch_script = joinpath(output_dir, "run_verification.sh")
open(batch_script, "w") do f
    write(f, batch_test_script)
end
println("Generated: $batch_script")

# Windows batch file
windows_batch = """
@echo off
REM Batch verification script for Fibonacci RTL (Windows)

echo ======================================
echo FPGACompiler.jl Verilator Integration
echo ======================================

REM Check Verilator
where verilator >nul 2>&1 || (
    echo Error: Verilator not found. Install from https://verilator.org
    exit /b 1
)

echo Step 1: Compiling Verilog with Verilator...
verilator --cc --trace -O3 fibonacci.v --top-module fibonacci

echo Step 2: Building simulation library...
cd obj_dir
nmake -f Vfibonacci.mk
cd ..

echo Step 3: Running Julia tests...
julia verilator_test.jl

echo ======================================
echo Verification complete!
echo ======================================
"""

windows_script = joinpath(output_dir, "run_verification.bat")
open(windows_script, "w") do f
    write(f, windows_batch)
end
println("Generated: $windows_script")

# ============================================================================
# Summary
# ============================================================================

println("\n" * "=" ^ 70)
println("Setup Complete!")
println("=" ^ 70)

println("""
Generated files in '$output_dir/':
  - fibonacci.v           : Generated Verilog RTL
  - testbench_wrapper.cpp : C++ wrapper for Julia/CxxWrap
  - CMakeLists.txt        : CMake build configuration
  - Makefile              : Direct build for Linux/macOS
  - verilator_test.jl     : Julia test script
  - run_verification.sh   : Linux/macOS batch script
  - run_verification.bat  : Windows batch script

To run Verilator simulation:
  1. cd $output_dir
  2. ./run_verification.sh  (Linux/macOS)
     or
     run_verification.bat   (Windows with MSVC)

Prerequisites:
  - Verilator (https://verilator.org)
  - CxxWrap.jl: Pkg.add("CxxWrap")
  - C++ compiler with C++17 support

For GTKWave waveform viewing:
  gtkwave fibonacci.vcd
""")

println("=" ^ 70)
println("See docs/simulation.md for detailed integration guide")
println("=" ^ 70)
