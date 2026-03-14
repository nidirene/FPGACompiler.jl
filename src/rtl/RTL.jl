# RTL Generation Submodule
# Generates synthesizable Verilog from scheduled CDFG

module RTL

using ..HLS

# Include RTL generation modules
include("module.jl")
include("fsm.jl")
include("datapath.jl")
include("memory.jl")
include("emit.jl")

# Export types
export RTLModule, RTLPort, RTLSignal

# Export main generation functions
export generate_rtl, generate_verilog, write_verilog
export generate_fsm, generate_datapath, generate_memory_interface

# Export emission functions
export emit_verilog, emit_testbench, write_testbench
export emit_cocotb_testbench, emit_makefile, emit_verilator_main

# Export memory interface generators
export generate_bram_interface, generate_partitioned_memory, generate_fifo_interface

# Export helper functions
export sanitize_name, get_wire_name, get_operand_wire

end # module RTL
