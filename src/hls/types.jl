# HLS Type Definitions
# Core data structures for High-Level Synthesis

using Graphs

# ============================================================================
# Operation Types (maps to hardware components)
# ============================================================================

"""
    OperationType

Enumeration of hardware operation types extracted from LLVM IR.
Each operation maps to specific hardware components with known latencies.
"""
@enum OperationType begin
    OP_NOP          # No operation
    OP_ADD          # Integer addition (1 cycle)
    OP_SUB          # Integer subtraction (1 cycle)
    OP_MUL          # Integer multiplication (3 cycles, uses DSP)
    OP_DIV          # Integer division (10+ cycles)
    OP_UDIV         # Unsigned integer division
    OP_SDIV         # Signed integer division
    OP_MOD          # Modulo operation
    OP_UREM         # Unsigned remainder
    OP_SREM         # Signed remainder
    OP_AND          # Bitwise AND
    OP_OR           # Bitwise OR
    OP_XOR          # Bitwise XOR
    OP_SHL          # Shift left
    OP_SHR          # Shift right (logical)
    OP_ASHR         # Shift right (arithmetic)
    OP_FADD         # Floating-point add (4-8 cycles)
    OP_FSUB         # Floating-point subtract
    OP_FMUL         # Floating-point multiply (3-5 cycles)
    OP_FDIV         # Floating-point divide (15+ cycles)
    OP_LOAD         # Memory load (1-N cycles, depends on memory)
    OP_STORE        # Memory store
    OP_PHI          # SSA phi node (mux in hardware)
    OP_SELECT       # Conditional select (mux)
    OP_CMP          # Integer comparison
    OP_FCMP         # Floating-point comparison
    OP_BR           # Branch (control)
    OP_BR_COND      # Conditional branch
    OP_RET          # Return
    OP_CALL         # Function call (inlined or FSM)
    OP_ZEXT         # Zero extend
    OP_SEXT         # Sign extend
    OP_TRUNC        # Truncate
    OP_BITCAST      # Bitcast
    OP_GEP          # GetElementPtr (address calculation)
    OP_ALLOCA       # Stack allocation
    OP_ICMP         # Integer comparison (alias for CMP)
    OP_COPY         # Copy operation (wire)
end

# ============================================================================
# Hardware Resource Types
# ============================================================================

"""
    ResourceType

Types of hardware resources available for binding operations.
"""
@enum ResourceType begin
    RES_ALU         # Generic ALU (add, sub, logic)
    RES_DSP         # DSP block (multiply, MAC)
    RES_MUL         # Multiplier (alias for DSP)
    RES_FPU         # Floating-point unit
    RES_DIVIDER     # Divider unit
    RES_DIV         # Divider (alias)
    RES_BRAM_PORT   # BRAM read/write port
    RES_MEM         # Memory port (alias)
    RES_REG         # Register
    RES_MUX         # Multiplexer
    RES_COMPARATOR  # Comparison unit
    RES_SHIFTER     # Shift unit
end

# ============================================================================
# Constant Value Representation
# ============================================================================

"""
    HLSConstant

Represents a constant value in the dataflow graph.
"""
struct HLSConstant
    value::Any
    bit_width::Int
    is_signed::Bool
end

# ============================================================================
# DFG Node - Represents one operation in the datapath
# ============================================================================

"""
    DFGNode

Represents a single operation node in the Data Flow Graph.
Maps to a hardware functional unit with scheduling and binding information.
"""
mutable struct DFGNode
    id::Int                                          # Unique node ID
    op::OperationType                                # Operation type
    name::String                                     # Name/identifier

    # Type information
    result_type::DataType                            # Julia type of result
    bit_width::Int                                   # Bit width of result
    is_signed::Bool                                  # Signed vs unsigned

    # Operands (input edges) - can be DFGNode or HLSConstant
    operands::Vector{Union{DFGNode, HLSConstant}}
    operand_indices::Vector{Int}                     # Original LLVM operand indices

    # Scheduling information (filled by scheduler)
    scheduled_cycle::Int                             # Clock cycle when operation starts
    latency::Int                                     # Cycles until result is ready
    asap_cycle::Int                                  # As-soon-as-possible time
    alap_cycle::Int                                  # As-late-as-possible time
    mobility::Int                                    # Scheduling flexibility

    # Binding information (filled by binder)
    bound_resource::Union{ResourceType, Nothing}
    resource_instance::Int                           # Which instance of the resource

    # Liveness information (for register allocation)
    live_start::Int                                  # Cycle when value becomes live
    live_end::Int                                    # Last cycle when value is used

    # State membership
    state_id::Int                                    # Which FSM state this belongs to

    function DFGNode(id::Int, op::OperationType, name::String="")
        new(
            id, op, name,
            Any, 32, true,                           # Default type info
            Union{DFGNode, HLSConstant}[], Int[],    # Operands
            -1, get_default_latency(op), -1, -1, 0,  # Scheduling
            nothing, 0,                              # Binding
            -1, -1,                                  # Liveness
            0                                        # State
        )
    end
end

"""
    get_default_latency(op::OperationType)

Get the default hardware latency for an operation type.
"""
function get_default_latency(op::OperationType)::Int
    latency_map = Dict{OperationType, Int}(
        OP_NOP => 0,
        OP_ADD => 1,
        OP_SUB => 1,
        OP_MUL => 3,        # DSP multiplier
        OP_DIV => 18,       # Iterative divider
        OP_UDIV => 18,      # Unsigned division
        OP_SDIV => 18,      # Signed division
        OP_MOD => 18,
        OP_UREM => 18,      # Unsigned remainder
        OP_SREM => 18,      # Signed remainder
        OP_AND => 1,
        OP_OR => 1,
        OP_XOR => 1,
        OP_SHL => 1,
        OP_SHR => 1,
        OP_ASHR => 1,
        OP_FADD => 5,       # FP adder
        OP_FSUB => 5,
        OP_FMUL => 4,       # FP multiplier
        OP_FDIV => 15,      # FP divider
        OP_LOAD => 2,       # BRAM latency
        OP_STORE => 1,
        OP_PHI => 0,        # Mux, combinational
        OP_SELECT => 0,     # Mux, combinational
        OP_CMP => 1,
        OP_ICMP => 1,
        OP_FCMP => 2,
        OP_BR => 0,
        OP_BR_COND => 0,    # Conditional branch
        OP_RET => 0,
        OP_CALL => 1,
        OP_ZEXT => 0,       # Wire
        OP_SEXT => 0,       # Wire with sign extension
        OP_TRUNC => 0,      # Wire
        OP_BITCAST => 0,    # Wire
        OP_GEP => 1,        # Address calculation
        OP_ALLOCA => 0,     # Compile-time only
        OP_COPY => 0,       # Wire
    )
    return get(latency_map, op, 1)
end

# ============================================================================
# DFG Edge - Represents a data dependency (wire)
# ============================================================================

"""
    DFGEdge

Represents a data dependency edge between DFG nodes.
In hardware, this becomes a physical wire connection.
"""
struct DFGEdge
    src::DFGNode                     # Producer
    dst::DFGNode                     # Consumer
    operand_index::Int               # Which operand of dst
end

# ============================================================================
# FSM State - Represents one state in the control FSM
# ============================================================================

"""
    FSMState

Represents one state in the hardware Finite State Machine.
Corresponds to one or more LLVM basic blocks.
"""
mutable struct FSMState
    id::Int                          # State ID (for encoding)
    name::String                     # State name (from LLVM block name)

    # Operations scheduled in this state
    operations::Vector{DFGNode}

    # Control flow (indices into states vector)
    predecessor_ids::Vector{Int}
    successor_ids::Vector{Int}

    # Transition conditions (node id that produces condition, or -1 for unconditional)
    transition_conditions::Vector{Int}

    # For loop detection
    is_loop_header::Bool
    is_loop_latch::Bool
    loop_depth::Int

    # Timing
    start_cycle::Int                 # First cycle of this state
    end_cycle::Int                   # Last cycle of this state
    num_cycles::Int                  # Total cycles in this state

    function FSMState(id::Int, name::String)
        new(
            id, name,
            DFGNode[],
            Int[], Int[],
            Int[],
            false, false, 0,
            0, 0, 1
        )
    end
end

# ============================================================================
# CDFG - Combined Control and Data Flow Graph
# ============================================================================

"""
    CDFG

Combined Control and Data Flow Graph - the central intermediate representation
for HLS. Contains both the FSM (control) and DFG (datapath) information.
"""
mutable struct CDFG
    name::String                     # Kernel name

    # Graph structure
    nodes::Vector{DFGNode}           # All DFG nodes
    edges::Vector{DFGEdge}           # All data dependencies
    states::Vector{FSMState}         # All FSM states
    graph::SimpleDiGraph{Int}        # Graphs.jl representation

    # Entry/exit
    entry_state_id::Int
    exit_state_ids::Vector{Int}

    # Interface
    input_nodes::Vector{DFGNode}     # Input arguments
    output_nodes::Vector{DFGNode}    # Output values

    # Memory operations
    memory_nodes::Vector{DFGNode}    # Load/store operations

    # Analysis results
    critical_path_length::Int
    estimated_cycles::Int
    resource_usage::Dict{ResourceType, Int}

    # Scheduling constraints
    target_ii::Int                   # Target initiation interval for pipelining

    function CDFG(name::String)
        new(
            name,
            DFGNode[], DFGEdge[], FSMState[], SimpleDiGraph{Int}(),
            1, Int[],
            DFGNode[], DFGNode[],
            DFGNode[],
            0, 0, Dict{ResourceType, Int}(),
            1
        )
    end
end

# ============================================================================
# Schedule - Result of scheduling algorithm
# ============================================================================

"""
    Schedule

Result of the scheduling phase. Maps operations to clock cycles
and tracks resource usage.
"""
mutable struct Schedule
    cdfg::CDFG
    cycle_to_ops::Dict{Int, Vector{DFGNode}}  # Operations per cycle
    op_to_cycle::Dict{Int, Int}               # Node ID to scheduled cycle
    total_cycles::Int
    initiation_interval::Int                   # For pipelined loops

    # Resource usage per cycle
    resource_usage_per_cycle::Dict{Int, Dict{ResourceType, Int}}

    # Statistics
    critical_path::Vector{DFGNode}
    achieved_ii::Int

    function Schedule(cdfg::CDFG)
        new(
            cdfg,
            Dict{Int, Vector{DFGNode}}(),
            Dict{Int, Int}(),
            0, 1,
            Dict{Int, Dict{ResourceType, Int}}(),
            DFGNode[], 1
        )
    end
end

# ============================================================================
# RTL Module - Represents generated hardware
# ============================================================================

"""
    RTLPort

Represents a port in the RTL module.
"""
struct RTLPort
    name::String
    bit_width::Int
    is_input::Bool
    is_signed::Bool
end

"""
    RTLSignal

Represents an internal signal (wire or register).
"""
struct RTLSignal
    name::String
    bit_width::Int
    is_register::Bool
    is_signed::Bool
    initial_value::Union{Int, Nothing}
end

"""
    RTLModule

Represents the complete generated hardware module.
Contains all information needed to emit Verilog/VHDL.
"""
mutable struct RTLModule
    name::String

    # Ports
    clock::String
    reset::String
    ports::Vector{RTLPort}

    # Internal signals
    signals::Vector{RTLSignal}

    # FSM
    state_width::Int
    state_names::Vector{String}
    state_encoding::Dict{String, Int}

    # Generated code sections (filled during emission)
    parameter_declarations::String
    port_declarations::String
    signal_declarations::String
    fsm_logic::String
    datapath_logic::String
    output_logic::String
    memory_logic::String

    function RTLModule(name::String)
        new(
            name,
            "clk", "rst",
            RTLPort[],
            RTLSignal[],
            1, String[], Dict{String, Int}(),
            "", "", "", "", "", "", ""
        )
    end
end

# ============================================================================
# Resource Constraints
# ============================================================================

"""
    ResourceConstraints

Defines hardware resource limits for scheduling.
"""
struct ResourceConstraints
    max_alus::Int
    max_dsps::Int
    max_fpus::Int
    max_dividers::Int
    max_bram_read_ports::Int
    max_bram_write_ports::Int
    max_multiplexers::Int

    function ResourceConstraints(;
        max_alus::Int=8,
        max_dsps::Int=4,
        max_fpus::Int=2,
        max_dividers::Int=1,
        max_bram_read_ports::Int=2,
        max_bram_write_ports::Int=2,
        max_multiplexers::Int=16
    )
        new(max_alus, max_dsps, max_fpus, max_dividers,
            max_bram_read_ports, max_bram_write_ports, max_multiplexers)
    end
end

# ============================================================================
# HLS Options
# ============================================================================

"""
    HLSOptions

Configuration options for the HLS synthesis flow.
"""
struct HLSOptions
    # Scheduling
    scheduling_algorithm::Symbol    # :asap, :alap, :list, :ilp
    target_ii::Int                  # Target initiation interval
    target_clock_mhz::Float64       # Target clock frequency

    # Resource constraints
    constraints::ResourceConstraints

    # Optimization
    enable_pipelining::Bool
    enable_resource_sharing::Bool
    enable_chaining::Bool          # Chain operations in same cycle

    # Output
    output_format::Symbol          # :verilog, :vhdl, :systemverilog
    generate_testbench::Bool

    function HLSOptions(;
        scheduling_algorithm::Symbol=:ilp,
        target_ii::Int=1,
        target_clock_mhz::Float64=100.0,
        constraints::ResourceConstraints=ResourceConstraints(),
        enable_pipelining::Bool=true,
        enable_resource_sharing::Bool=true,
        enable_chaining::Bool=false,
        output_format::Symbol=:verilog,
        generate_testbench::Bool=true
    )
        new(scheduling_algorithm, target_ii, target_clock_mhz,
            constraints, enable_pipelining, enable_resource_sharing,
            enable_chaining, output_format, generate_testbench)
    end
end

# ============================================================================
# Helper Functions
# ============================================================================

"""
    operation_to_resource(op::OperationType)

Map operation type to hardware resource type.
"""
function operation_to_resource(op::OperationType)::ResourceType
    resource_map = Dict{OperationType, ResourceType}(
        OP_ADD => RES_ALU,
        OP_SUB => RES_ALU,
        OP_AND => RES_ALU,
        OP_OR => RES_ALU,
        OP_XOR => RES_ALU,
        OP_SHL => RES_SHIFTER,
        OP_SHR => RES_SHIFTER,
        OP_ASHR => RES_SHIFTER,
        OP_MUL => RES_DSP,
        OP_FMUL => RES_DSP,
        OP_FADD => RES_FPU,
        OP_FSUB => RES_FPU,
        OP_DIV => RES_DIVIDER,
        OP_MOD => RES_DIVIDER,
        OP_FDIV => RES_DIVIDER,
        OP_LOAD => RES_BRAM_PORT,
        OP_STORE => RES_BRAM_PORT,
        OP_CMP => RES_COMPARATOR,
        OP_ICMP => RES_COMPARATOR,
        OP_FCMP => RES_COMPARATOR,
        OP_PHI => RES_MUX,
        OP_SELECT => RES_MUX,
    )
    return get(resource_map, op, RES_ALU)
end

"""
    needs_dsp(op::OperationType)

Check if operation requires a DSP block.
"""
function needs_dsp(op::OperationType)::Bool
    return op in (OP_MUL, OP_FMUL)
end

"""
    is_memory_op(op::OperationType)

Check if operation is a memory access.
"""
function is_memory_op(op::OperationType)::Bool
    return op in (OP_LOAD, OP_STORE)
end

"""
    is_control_op(op::OperationType)

Check if operation is a control flow operation.
"""
function is_control_op(op::OperationType)::Bool
    return op in (OP_BR, OP_BR_COND, OP_RET, OP_CALL)
end

"""
    is_combinational(op::OperationType)

Check if operation is purely combinational (0 cycle latency).
"""
function is_combinational(op::OperationType)::Bool
    return get_default_latency(op) == 0
end
