# Simulation Submodule
# Provides Verilator integration, native simulation, and verification utilities

module Sim

using Random
using Dates
using ..HLS
using ..RTL

# Include simulation modules
include("verilator.jl")
include("testbench.jl")
include("verify.jl")

# Include native simulator modules
include("native/types.jl")
include("native/primitives.jl")
include("native/simulator.jl")
include("native/builder.jl")
include("native/waveform.jl")
include("native/debug.jl")

# Export types - Verilator
export VerilatorConfig, SimulationResult, VerificationResult
export TestVector, TestSuite

# Export types - Native Simulator
export SimValue, Wire, Register, ALU, MUX, Memory, FSMController
export NativeSimulator, SimulationConfig
export ALUOp, Port
export ALU_NOP, ALU_ADD, ALU_SUB, ALU_MUL, ALU_DIV, ALU_UDIV, ALU_SDIV
export ALU_MOD, ALU_UREM, ALU_SREM, ALU_AND, ALU_OR, ALU_XOR
export ALU_SHL, ALU_SHR, ALU_ASHR, ALU_EQ, ALU_NE, ALU_LT, ALU_LE
export ALU_GT, ALU_GE, ALU_ULT, ALU_ULE, ALU_UGT, ALU_UGE
export ALU_ZEXT, ALU_SEXT, ALU_TRUNC, ALU_COPY

# Export Verilator functions
export simulate, run_verilator, compile_verilator
export check_verilator, parse_simulation_output, read_vcd_signals

# Export testbench functions
export generate_test_vectors, generate_test_vectors_from_function
export generate_directed_tests, run_testbench
export generate_systemverilog_assertions, generate_coverage_points

# Export verification functions
export verify_rtl, compare_results
export equivalence_check, regression_test
export generate_verification_report
export check_timing_constraints, analyze_simulation_waveform

# Export native simulator core functions
export build_simulator
export reset!, tick!, run!, start!
export set_input!, set_inputs!, get_output, get_outputs
export get_state, is_done
export simulate_native, simulate_with_trace

# Export native simulator helpers
export to_unsigned, to_signed, to_bool
export mask_for_width
export compute_alu_result, compute_mux_result
export memory_read, memory_write!
export evaluate_alu!, evaluate_mux!, evaluate_memory_read!
export FSMTransition

# Export simulation state access
export get_wire, get_register, get_signal_value
export read_memory, write_memory!, initialize_memory!
export step!, peek_combinational!
export get_statistics

# Export trace and waveform functions
export enable_trace!, collect_traces
export write_vcd, trace_signals!, trace_all!
export print_waveform, print_signal_table
export VCDWriter, write_vcd_header!, write_vcd_change!, close_vcd!

# Export debug functions
export dump_state, dump_fsm, dump_datapath
export watch, unwatch, examine, list_signals
export verify_against_reference

# ============================================================================
# Unified Simulation Interface
# ============================================================================

"""
    simulate(cdfg::CDFG, schedule::Schedule, inputs::Dict{Symbol, <:Integer};
             backend::Symbol=:native, max_cycles::Int=10000, verbose::Bool=false)

Unified simulation interface supporting both native and Verilator backends.

# Arguments
- `cdfg::CDFG`: The CDFG to simulate
- `schedule::Schedule`: The schedule for the CDFG
- `inputs::Dict{Symbol, <:Integer}`: Input port values
- `backend::Symbol`: Simulation backend (:native or :verilator)
- `max_cycles::Int`: Maximum simulation cycles
- `verbose::Bool`: Print verbose output

# Returns
- `SimulationResult`: Result containing outputs and statistics
"""
function simulate(cdfg::HLS.CDFG, schedule::HLS.Schedule,
                  inputs::Dict{Symbol, <:Integer};
                  backend::Symbol=:native,
                  max_cycles::Int=10000,
                  verbose::Bool=false)::SimulationResult

    if backend == :native
        # Build and run native simulator
        sim = build_simulator(cdfg, schedule)
        return simulate_native(sim, inputs; max_cycles=max_cycles, verbose=verbose)

    elseif backend == :verilator
        # Use Verilator backend (requires RTL generation)
        error("Verilator backend requires RTL module. Use simulate(rtl, inputs) instead.")

    else
        error("Unknown simulation backend: $backend. Use :native or :verilator")
    end
end

"""
    create_simulator(cdfg::CDFG, schedule::Schedule)

Create a NativeSimulator from a CDFG and schedule.
The simulator can be used for interactive debugging or batch simulation.
"""
function create_simulator(cdfg::HLS.CDFG, schedule::HLS.Schedule)::NativeSimulator
    build_simulator(cdfg, schedule)
end

"""
    run_test_suite(sim::NativeSimulator, test_suite::TestSuite;
                   verbose::Bool=false, max_cycles::Int=10000)

Run a complete test suite against the native simulator.
Returns a VerificationResult.
"""
function run_test_suite(sim::NativeSimulator, test_suite::TestSuite;
                        verbose::Bool=false, max_cycles::Int=10000)::VerificationResult
    passed = 0
    failed = 0
    failures = Dict{String, Any}[]

    for (i, test) in enumerate(test_suite.vectors)
        # Reset simulator
        reset!(sim)

        # Convert string keys to symbols if needed
        inputs = Dict{Symbol, Integer}()
        for (k, v) in test.inputs
            inputs[Symbol(k)] = v
        end

        # Run simulation
        result = simulate_native(sim, inputs; max_cycles=max_cycles, verbose=false)

        # Compare outputs
        all_match = true
        mismatches = String[]
        for (out_name, expected_val) in test.expected_outputs
            port_name = Symbol(out_name)
            if haskey(sim.output_ports, port_name)
                actual = to_unsigned(sim.output_ports[port_name].wire.value)
                if actual != expected_val
                    all_match = false
                    push!(mismatches, "$out_name: expected $expected_val, got $actual")
                end
            else
                all_match = false
                push!(mismatches, "Missing output port $out_name")
            end
        end

        if all_match
            passed += 1
            if verbose
                println("Test $i ($(test.name)): PASS")
            end
        else
            failed += 1
            if verbose
                println("Test $i ($(test.name)): FAIL - $(join(mismatches, ", "))")
            end
            push!(failures, Dict{String, Any}(
                "test_name" => test.name,
                "inputs" => test.inputs,
                "expected" => test.expected_outputs,
                "mismatches" => mismatches
            ))
        end
    end

    return VerificationResult(
        failed == 0,
        passed + failed,
        passed,
        failed,
        failures,
        Dict("test_pass_rate" => passed / (passed + failed) * 100)
    )
end

export create_simulator, run_test_suite

end # module Sim
