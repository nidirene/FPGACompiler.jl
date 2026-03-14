# Native Julia RTL Simulation Example
# ====================================
# This example demonstrates how to use FPGACompiler.jl's native Julia simulator
# for cycle-accurate hardware simulation without external dependencies.

using FPGACompiler
using FPGACompiler.HLS
using FPGACompiler.Sim

# ============================================================================
# Example 1: Simple Adder Simulation
# ============================================================================

println("=" ^ 60)
println("Example 1: Simple Adder Simulation")
println("=" ^ 60)

# Define a simple adder function
function simple_add(a::Int32, b::Int32)::Int32
    return a + b
end

# Compile to CDFG (Control Data Flow Graph)
println("\nCompiling simple_add to CDFG...")
cdfg = compile_to_cdfg(simple_add, (Int32, Int32))

# Apply scheduling
println("Scheduling operations...")
schedule = schedule_cdfg(cdfg)

# Build native simulator
println("Building native simulator...")
sim = build_simulator(cdfg, schedule)

# Set inputs and run simulation
println("\nRunning simulation with inputs a=5, b=3...")
set_inputs!(sim, Dict(:a => 5, :b => 3))
start!(sim)

# Run until completion
while !is_done(sim)
    tick!(sim)
end

# Get result
result = get_output(sim, :result)
println("Result: $result (expected: 8)")
println("Cycles taken: $(sim.cycle)")

# ============================================================================
# Example 2: Simulation with Tracing (VCD Output)
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 2: Simulation with Waveform Tracing")
println("=" ^ 60)

# Reset simulator for new run
reset!(sim)

# Enable signal tracing
enable_trace!(sim)
trace_all!(sim)

# Run with different inputs
println("\nRunning traced simulation with a=10, b=7...")
set_inputs!(sim, Dict(:a => 10, :b => 7))
start!(sim)

while !is_done(sim)
    tick!(sim)
end

# Write VCD waveform file
vcd_file = "adder_trace.vcd"
write_vcd(sim, vcd_file)
println("VCD waveform written to: $vcd_file")
println("Open with GTKWave: gtkwave $vcd_file")

# Print signal table
println("\nSignal trace table:")
print_signal_table(sim)

# ============================================================================
# Example 3: Multiplier with Multi-Cycle Operations
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 3: Multiplier Simulation")
println("=" ^ 60)

function multiplier(a::Int32, b::Int32)::Int32
    return a * b
end

# Compile and schedule
cdfg_mul = compile_to_cdfg(multiplier, (Int32, Int32))
schedule_mul = schedule_cdfg(cdfg_mul)
sim_mul = build_simulator(cdfg_mul, schedule_mul)

# Run simulation
println("\nSimulating 7 * 6...")
result_mul = simulate_native(sim_mul, Dict(:a => 7, :b => 6))
println("Result: $(result_mul.outputs[:result]) (expected: 42)")
println("Cycles: $(result_mul.cycles)")

# ============================================================================
# Example 4: Conditional Logic (if-else)
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 4: Conditional Logic Simulation")
println("=" ^ 60)

function max_value(a::Int32, b::Int32)::Int32
    if a > b
        return a
    else
        return b
    end
end

# Compile and simulate
cdfg_max = compile_to_cdfg(max_value, (Int32, Int32))
schedule_max = schedule_cdfg(cdfg_max)
sim_max = build_simulator(cdfg_max, schedule_max)

# Test cases
test_cases = [
    (a=5, b=3, expected=5),
    (a=3, b=7, expected=7),
    (a=4, b=4, expected=4),
]

println("\nRunning test cases:")
for tc in test_cases
    reset!(sim_max)
    result = simulate_native(sim_max, Dict(:a => tc.a, :b => tc.b))
    actual = result.outputs[:result]
    status = actual == tc.expected ? "PASS" : "FAIL"
    println("  max($(tc.a), $(tc.b)) = $actual (expected: $(tc.expected)) [$status]")
end

# ============================================================================
# Example 5: Loop Simulation (Sum Array)
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 5: Loop Simulation")
println("=" ^ 60)

function sum_n(n::Int32)::Int32
    total = Int32(0)
    for i in Int32(1):n
        total += i
    end
    return total
end

# Compile with loop unrolling
cdfg_sum = compile_to_cdfg(sum_n, (Int32,))
schedule_sum = schedule_cdfg(cdfg_sum)
sim_sum = build_simulator(cdfg_sum, schedule_sum)

# Test sum of 1 to 5
println("\nComputing sum(1..5)...")
result_sum = simulate_native(sim_sum, Dict(:n => 5))
println("Result: $(result_sum.outputs[:result]) (expected: 15)")
println("Cycles: $(result_sum.cycles)")

# ============================================================================
# Example 6: Using the Unified Interface
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 6: Unified Simulation Interface")
println("=" ^ 60)

# The unified `simulate` function works with both native and Verilator backends
function compute(x::Int32, y::Int32)::Int32
    return (x + y) * 2
end

cdfg_compute = compile_to_cdfg(compute, (Int32, Int32))
schedule_compute = schedule_cdfg(cdfg_compute)

# Use native backend (default)
result_native = simulate(cdfg_compute, schedule_compute,
                         Dict(:x => 10, :y => 5);
                         backend=:native, verbose=true)

println("Native simulation result: $(result_native.outputs[:result])")
println("Expected: 30")

# ============================================================================
# Example 7: Debugging with State Inspection
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 7: Interactive Debugging")
println("=" ^ 60)

# Build a fresh simulator
sim_debug = build_simulator(cdfg, schedule)
set_inputs!(sim_debug, Dict(:a => 100, :b => 23))

# Start and step through execution
start!(sim_debug)

println("\nStepping through execution:")
for i in 1:5
    println("\n--- Cycle $(sim_debug.cycle) ---")

    # Dump current state
    dump_state(sim_debug)

    # Examine specific signals
    println("FSM state: $(get_state(sim_debug))")

    if is_done(sim_debug)
        println("Simulation complete!")
        break
    end

    tick!(sim_debug)
end

# Get final output
if is_done(sim_debug)
    final_result = get_output(sim_debug, :result)
    println("\nFinal result: $final_result")
end

# ============================================================================
# Example 8: Test Suite Execution
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 8: Running Test Suites")
println("=" ^ 60)

# Create test vectors
test_vectors = [
    TestVector("add_1", Dict("a" => 1, "b" => 2), Dict("result" => 3)),
    TestVector("add_2", Dict("a" => 10, "b" => 20), Dict("result" => 30)),
    TestVector("add_3", Dict("a" => 0, "b" => 0), Dict("result" => 0)),
    TestVector("add_4", Dict("a" => -5, "b" => 10), Dict("result" => 5)),
    TestVector("add_5", Dict("a" => 100, "b" => -50), Dict("result" => 50)),
]

test_suite = TestSuite("Adder Tests", "Simple addition test cases", test_vectors)

# Build simulator and run test suite
sim_test = build_simulator(cdfg, schedule)
verification_result = run_test_suite(sim_test, test_suite; verbose=true)

println("\nTest Results:")
println("  Total: $(verification_result.total_tests)")
println("  Passed: $(verification_result.passed)")
println("  Failed: $(verification_result.failed)")
println("  Pass Rate: $(verification_result.statistics["test_pass_rate"])%")

# ============================================================================
# Example 9: Memory Operations
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 9: Memory Simulation")
println("=" ^ 60)

# Direct memory component testing
mem = Sim.Memory("test_bram"; depth=256, word_width=32, read_latency=2)

# Initialize memory
println("Initializing memory with test pattern...")
initialize_memory!(mem, [i * 10 for i in 1:256])

# Read back values
println("Reading memory addresses:")
for addr in [0, 10, 100, 255]
    value = memory_read(mem, addr)
    println("  mem[$addr] = $(to_unsigned(value))")
end

# Write new values
println("\nWriting new values...")
memory_write!(mem, 50, SimValue(12345, 32))
memory_write!(mem, 51, SimValue(67890, 32))

println("  mem[50] = $(to_unsigned(memory_read(mem, 50)))")
println("  mem[51] = $(to_unsigned(memory_read(mem, 51)))")

# ============================================================================
# Example 10: Statistics and Profiling
# ============================================================================

println("\n" * "=" ^ 60)
println("Example 10: Simulation Statistics")
println("=" ^ 60)

# Run a longer simulation and collect statistics
sim_stats = build_simulator(cdfg_sum, schedule_sum)

for n in [5, 10, 20, 50]
    reset!(sim_stats)
    result = simulate_native(sim_stats, Dict(:n => n); verbose=false)
    stats = get_statistics(sim_stats)

    println("sum(1..$n):")
    println("  Result: $(result.outputs[:result])")
    println("  Cycles: $(result.cycles)")
    println("  States visited: $(length(sim_stats.states_visited))")
end

println("\n" * "=" ^ 60)
println("All examples completed successfully!")
println("=" ^ 60)
