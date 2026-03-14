module FPGACompiler

using GPUCompiler
using LLVM
using LLVM.Interop
using Graphs
using JuMP
using HiGHS

# Export main types and functions
export FPGATarget, FPGACompilerParams
export PartitionedArray, PartitionStyle, CYCLIC, BLOCK, COMPLETE
export partition_factor, partition_style
export FixedInt, Int7, Int12, Int14, Int24, UInt7, UInt12, UInt14, UInt24, bitwidth
export fpga_compile, fpga_code_llvm, fpga_code_native
export apply_pipeline_metadata!, apply_partition_metadata!
export apply_unroll_metadata!, apply_interface_metadata!, apply_noalias_metadata!
export @fpga_kernel, @pipeline, @unroll
export validate_kernel, estimate_resources
export get_phase2_analysis, verify_fpga_compatible!
export is_registered_kernel, clear_hints!

# Include core submodules
include("target.jl")
include("types.jl")
include("optimize.jl")
include("metadata.jl")
include("compiler.jl")

# Include HLS backend submodule
include("hls/HLS.jl")
using .HLS
export HLS

# Include RTL generation submodule
include("rtl/RTL.jl")
using .RTL
export RTL

# Include Simulation submodule
include("sim/Sim.jl")
using .Sim
export Sim

# Re-export key HLS types and functions
export CDFG, DFGNode, FSMState, Schedule, HLSOptions, ResourceConstraints
export build_cdfg, schedule_asap!, schedule_alap!, schedule_list!, schedule_ilp!
export bind_resources!, analyze_critical_path, analyze_resource_usage
export generate_analysis_report, suggest_optimizations

# Re-export key RTL functions
export RTLModule, RTLPort, RTLSignal
export generate_rtl, generate_verilog, write_verilog
export emit_verilog, emit_testbench

# Re-export key Simulation functions
export simulate, run_verilator, compile_verilator
export verify_rtl, VerificationResult
export generate_test_vectors, run_testbench

end # module FPGACompiler
