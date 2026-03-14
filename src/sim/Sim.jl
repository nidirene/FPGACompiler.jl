# Simulation Submodule
# Provides Verilator integration and verification utilities

module Sim

using Random
using ..HLS
using ..RTL

# Include simulation modules
include("verilator.jl")
include("testbench.jl")
include("verify.jl")

# Export types
export VerilatorConfig, SimulationResult, VerificationResult
export TestVector, TestSuite

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

end # module Sim
