# FPGA Target Definition
# Extends GPUCompiler.jl to target FPGA hardware via HLS

"""
    FPGATarget <: GPUCompiler.AbstractCompilerTarget

Custom compiler target for FPGA High-Level Synthesis.
This target configures LLVM to generate IR suitable for vendor HLS tools
(Intel aoc, AMD Vitis HLS, or open-source tools like Bambu/CIRCT).
"""
struct FPGATarget <: GPUCompiler.AbstractCompilerTarget end

"""
    FPGACompilerParams <: GPUCompiler.AbstractCompilerParams

Parameters for FPGA compilation jobs. Controls optimization levels
and hardware-specific settings.
"""
Base.@kwdef struct FPGACompilerParams <: GPUCompiler.AbstractCompilerParams
    # Target initiation interval for loop pipelining (1 = fully pipelined)
    target_ii::Int = 1
    # Enable aggressive inlining (required for FPGAs - no function call overhead)
    aggressive_inline::Bool = true
    # Enable memory partitioning analysis
    partition_memory::Bool = true
    # Emit human-readable LLVM IR (.ll) instead of bitcode (.bc)
    emit_llvm_ir::Bool = true
end

# Configure the LLVM triple for FPGA targets
# Note: SPIR-V would be ideal but requires LLVM with SPIR backend
# For development/testing, use native target; for production, use SPIR
function GPUCompiler.llvm_triple(::FPGATarget)
    # Check if SPIR target is available, otherwise fall back to native
    native_triple = unsafe_string(LLVM.API.LLVMGetDefaultTargetTriple())
    return native_triple
end

# Use native LLVM machine for compilation (SPIR target not available in bundled LLVM)
function GPUCompiler.llvm_machine(target::FPGATarget)
    triple = GPUCompiler.llvm_triple(target)
    t = LLVM.Target(; triple=triple)
    tm = LLVM.TargetMachine(t, triple)
    return tm
end

# FPGA targets typically use 64-bit data layout
GPUCompiler.llvm_datalayout(::FPGATarget) = "e-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024"

# FPGAs don't support runtime features like GC or exceptions
GPUCompiler.runtime_module(::CompilerJob{FPGATarget}) = nothing

# Mark that we need Julia runtime stripped
GPUCompiler.uses_julia_runtime(::CompilerJob{FPGATarget}) = false

# FPGAs support all address spaces (used for memory banking)
GPUCompiler.can_throw(::CompilerJob{FPGATarget}) = false

# Method table for FPGA-specific intrinsics (use global table for now)
GPUCompiler.method_table(::CompilerJob{FPGATarget}) = GPUCompiler.GLOBAL_METHOD_TABLE

# Runtime slug for caching compiled code
GPUCompiler.runtime_slug(::CompilerJob{FPGATarget}) = "fpga"
