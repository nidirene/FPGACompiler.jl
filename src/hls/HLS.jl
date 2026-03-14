# HLS Submodule
# High-Level Synthesis backend for FPGACompiler.jl

module HLS

using Graphs
using JuMP
using HiGHS
using LLVM

# Include type definitions first
include("types.jl")

# Include implementation modules
include("cfg.jl")
include("dfg.jl")
include("cdfg.jl")
include("schedule.jl")
include("binding.jl")
include("analysis.jl")

# Export types
export OperationType, ResourceType
export DFGNode, DFGEdge, FSMState, CDFG, Schedule
export RTLModule, RTLPort, RTLSignal
export HLSConstant, ResourceConstraints, HLSOptions

# Export operation type enum values
export OP_NOP, OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD
export OP_AND, OP_OR, OP_XOR, OP_SHL, OP_SHR, OP_ASHR
export OP_FADD, OP_FSUB, OP_FMUL, OP_FDIV
export OP_LOAD, OP_STORE, OP_PHI, OP_SELECT
export OP_CMP, OP_ICMP, OP_FCMP, OP_BR, OP_RET, OP_CALL
export OP_ZEXT, OP_SEXT, OP_TRUNC, OP_BITCAST, OP_GEP, OP_ALLOCA

# Export resource type enum values
export RES_ALU, RES_DSP, RES_FPU, RES_DIVIDER
export RES_BRAM_PORT, RES_REG, RES_MUX, RES_COMPARATOR, RES_SHIFTER

# Export functions
export extract_cfg, extract_dfg, build_cdfg
export schedule_asap!, schedule_alap!, schedule_ilp!, schedule_list!, schedule_modulo!
export bind_resources!, allocate_registers!, get_resource_count
export analyze_critical_path, analyze_resource_usage, estimate_cycles
export analyze_parallelism, analyze_memory_access_pattern, analyze_loop_structure
export suggest_optimizations, generate_analysis_report

# Export helper functions
export operation_to_resource, needs_dsp, is_memory_op, is_control_op
export is_combinational, get_default_latency

# Export additional operation types
export OP_UDIV, OP_SDIV, OP_UREM, OP_SREM, OP_BR_COND, OP_COPY

# Export additional resource types
export RES_MUL, RES_DIV, RES_MEM

end # module HLS
