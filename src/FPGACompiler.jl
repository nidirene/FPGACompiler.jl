module FPGACompiler

using GPUCompiler
using LLVM
using LLVM.Interop

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

# Include submodules
include("target.jl")
include("types.jl")
include("optimize.jl")
include("metadata.jl")
include("compiler.jl")

end # module FPGACompiler
