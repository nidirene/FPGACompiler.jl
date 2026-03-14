# Native RTL Simulator Type Definitions
# Core data structures for cycle-accurate hardware simulation

# ============================================================================
# SimValue - Hardware value with X (undefined) support
# ============================================================================

"""
    SimValue

Represents a hardware value with support for undefined (X) states.
Supports bit widths from 1-64 bits.
"""
struct SimValue
    bits::UInt64          # Raw bit representation
    bit_width::Int        # Actual width (1-64)
    is_valid::Bool        # False = X (undefined)
    is_signed::Bool       # Interpretation for arithmetic
end

# Constructors
SimValue() = SimValue(UInt64(0), 32, false, false)
function SimValue(value::Integer, width::Int=32; signed::Bool=false)
    # Handle signed integers by reinterpreting as unsigned
    bits = if value < 0
        # For negative values, get the two's complement representation
        UInt64(reinterpret(UInt64, Int64(value))) & mask_for_width(width)
    else
        UInt64(value) & mask_for_width(width)
    end
    SimValue(bits, width, true, signed)
end
SimValue(::Nothing, width::Int=32; signed::Bool=false) = SimValue(UInt64(0), width, false, signed)

# Helper to create bit mask for given width
function mask_for_width(width::Int)::UInt64
    width >= 64 ? typemax(UInt64) : (UInt64(1) << width) - 1
end

# Value extraction
function to_unsigned(v::SimValue)::UInt64
    v.is_valid || return UInt64(0)
    v.bits & mask_for_width(v.bit_width)
end

function to_signed(v::SimValue)::Int64
    v.is_valid || return Int64(0)
    raw = v.bits & mask_for_width(v.bit_width)
    # Sign extend if necessary
    if v.bit_width < 64 && (raw >> (v.bit_width - 1)) & 1 == 1
        # Negative number - sign extend
        # Use reinterpret to safely convert to signed
        extended = raw | ~mask_for_width(v.bit_width)
        return reinterpret(Int64, extended)
    end
    return Int64(raw)
end

function to_bool(v::SimValue)::Bool
    v.is_valid && (v.bits & 1) == 1
end

# Comparison and equality
Base.:(==)(a::SimValue, b::SimValue) = a.bits == b.bits && a.bit_width == b.bit_width && a.is_valid == b.is_valid
Base.hash(v::SimValue, h::UInt) = hash(v.bits, hash(v.bit_width, hash(v.is_valid, h)))

# Display
function Base.show(io::IO, v::SimValue)
    if !v.is_valid
        print(io, "X[$(v.bit_width)]")
    elseif v.is_signed
        print(io, "$(to_signed(v))[$(v.bit_width)s]")
    else
        print(io, "$(to_unsigned(v))[$(v.bit_width)]")
    end
end

# ============================================================================
# ALU Operations Enum
# ============================================================================

"""
    ALUOp

Hardware ALU operation types.
"""
@enum ALUOp begin
    ALU_NOP
    ALU_ADD
    ALU_SUB
    ALU_MUL
    ALU_DIV
    ALU_UDIV
    ALU_SDIV
    ALU_MOD
    ALU_UREM
    ALU_SREM
    ALU_AND
    ALU_OR
    ALU_XOR
    ALU_SHL
    ALU_SHR
    ALU_ASHR
    ALU_EQ
    ALU_NE
    ALU_LT
    ALU_LE
    ALU_GT
    ALU_GE
    ALU_ULT
    ALU_ULE
    ALU_UGT
    ALU_UGE
    ALU_ZEXT
    ALU_SEXT
    ALU_TRUNC
    ALU_COPY
end

# ============================================================================
# Forward declarations for circular references
# ============================================================================

abstract type SimulationElement end

# ============================================================================
# Wire - Combinational signal
# ============================================================================

"""
    Wire

Represents a combinational signal (wire) in the simulated hardware.
Value propagates instantly through combinational logic.
"""
mutable struct Wire <: SimulationElement
    name::String
    value::SimValue
    bit_width::Int
    driver::Union{Nothing, SimulationElement}
    fanout::Vector{SimulationElement}
    trace_enabled::Bool
    trace_history::Vector{Tuple{Int, SimValue}}

    Wire(name::String, bit_width::Int=32; signed::Bool=false) = new(
        name,
        SimValue(nothing, bit_width; signed=signed),
        bit_width,
        nothing,
        SimulationElement[],
        false,
        Tuple{Int, SimValue}[]
    )
end

# ============================================================================
# Register - Sequential element (flip-flop)
# ============================================================================

"""
    Register

Represents a sequential element (D flip-flop) in the simulated hardware.
Current value updates to next value on clock edge.
"""
mutable struct Register <: SimulationElement
    name::String
    current_value::SimValue   # Q output
    next_value::SimValue      # D input (latches on clock edge)
    reset_value::SimValue
    bit_width::Int
    enable_wire::Union{Nothing, Wire}
    output_wire::Wire         # Wire driven by this register
    trace_enabled::Bool
    trace_history::Vector{Tuple{Int, SimValue}}

    function Register(name::String, bit_width::Int=32;
                      reset_value::Integer=0, signed::Bool=false)
        reset_sim = SimValue(reset_value, bit_width; signed=signed)
        out_wire = Wire("$(name)_q", bit_width; signed=signed)
        reg = new(
            name,
            reset_sim,
            reset_sim,
            reset_sim,
            bit_width,
            nothing,
            out_wire,
            false,
            Tuple{Int, SimValue}[]
        )
        out_wire.driver = reg
        return reg
    end
end

# ============================================================================
# ALU - Functional unit
# ============================================================================

"""
    ALU

Represents a functional unit (ALU) that performs arithmetic/logic operations.
Supports pipelined multi-cycle operations.
"""
mutable struct ALU <: SimulationElement
    name::String
    op::ALUOp
    input_a::Wire
    input_b::Union{Wire, Nothing}
    output::Wire
    latency::Int
    pipeline_stages::Vector{SimValue}   # For multi-cycle operations
    pipeline_valid::Vector{Bool}        # Validity of each stage
    is_active::Bool

    function ALU(name::String, op::ALUOp, bit_width::Int=32; latency::Int=1)
        input_a = Wire("$(name)_a", bit_width)
        input_b = Wire("$(name)_b", bit_width)
        output = Wire("$(name)_out", bit_width)

        alu = new(
            name,
            op,
            input_a,
            input_b,
            output,
            latency,
            [SimValue() for _ in 1:max(1, latency)],
            [false for _ in 1:max(1, latency)],
            false
        )
        output.driver = alu
        return alu
    end
end

# ============================================================================
# MUX - Multiplexer
# ============================================================================

"""
    MUX

Represents a multiplexer for data selection.
"""
mutable struct MUX <: SimulationElement
    name::String
    inputs::Vector{Wire}
    select::Wire
    output::Wire
    num_inputs::Int

    function MUX(name::String, num_inputs::Int, bit_width::Int=32)
        inputs = [Wire("$(name)_in$i", bit_width) for i in 1:num_inputs]
        select_width = max(1, ceil(Int, log2(num_inputs)))
        select = Wire("$(name)_sel", select_width)
        output = Wire("$(name)_out", bit_width)

        mux = new(name, inputs, select, output, num_inputs)
        output.driver = mux
        return mux
    end
end

# ============================================================================
# Memory - BRAM simulation
# ============================================================================

"""
    Memory

Represents a block RAM for memory simulation.
Supports configurable depth, width, latency, and banking.
"""
mutable struct Memory <: SimulationElement
    name::String
    data::Vector{SimValue}
    depth::Int
    word_width::Int
    read_latency::Int
    write_latency::Int
    num_banks::Int

    # Read ports
    read_addr::Wire
    read_data::Wire
    read_enable::Wire
    read_pipeline::Vector{SimValue}
    read_pipeline_valid::Vector{Bool}

    # Write ports
    write_addr::Wire
    write_data::Wire
    write_enable::Wire

    # Trace
    trace_enabled::Bool
    access_history::Vector{Tuple{Int, Symbol, Int, SimValue}}  # (cycle, :read/:write, addr, data)

    function Memory(name::String; depth::Int=1024, word_width::Int=32,
                    read_latency::Int=1, write_latency::Int=1, num_banks::Int=1)
        data = [SimValue(0, word_width) for _ in 1:depth]

        addr_width = max(1, ceil(Int, log2(depth)))
        read_addr = Wire("$(name)_raddr", addr_width)
        read_data = Wire("$(name)_rdata", word_width)
        read_enable = Wire("$(name)_re", 1)

        write_addr = Wire("$(name)_waddr", addr_width)
        write_data = Wire("$(name)_wdata", word_width)
        write_enable = Wire("$(name)_we", 1)

        mem = new(
            name,
            data,
            depth,
            word_width,
            read_latency,
            write_latency,
            num_banks,
            read_addr, read_data, read_enable,
            [SimValue() for _ in 1:read_latency],
            [false for _ in 1:read_latency],
            write_addr, write_data, write_enable,
            false,
            Tuple{Int, Symbol, Int, SimValue}[]
        )
        read_data.driver = mem
        return mem
    end
end

# ============================================================================
# FSMController - State machine controller
# ============================================================================

"""
    FSMTransition

Represents a state transition in the FSM.
"""
struct FSMTransition
    condition::Union{Wire, Nothing}   # Condition wire (nothing = unconditional)
    target_state::Int                 # Target state ID
    is_conditional::Bool
end

"""
    FSMController

Represents the finite state machine that controls hardware execution.
"""
mutable struct FSMController <: SimulationElement
    name::String
    current_state::Int
    next_state::Int
    cycle_in_state::Int
    state_cycles::Dict{Int, Int}                    # state_id -> cycles needed
    transitions::Dict{Int, Vector{FSMTransition}}   # state_id -> transitions
    state_names::Dict{Int, String}                  # state_id -> name
    num_states::Int
    start_wire::Wire
    done_wire::Wire
    idle_state::Int
    done_state::Int

    function FSMController(name::String; num_states::Int=1)
        start_wire = Wire("$(name)_start", 1)
        done_wire = Wire("$(name)_done", 1)

        fsm = new(
            name,
            0,      # idle state
            0,
            0,
            Dict{Int, Int}(),
            Dict{Int, Vector{FSMTransition}}(),
            Dict(0 => "IDLE"),
            num_states,
            start_wire,
            done_wire,
            0,      # idle state
            -1      # done state (set during build)
        )
        done_wire.driver = fsm
        return fsm
    end
end

# ============================================================================
# Port - I/O interface
# ============================================================================

"""
    Port

Represents an input or output port of the simulated module.
"""
mutable struct Port <: SimulationElement
    name::Symbol
    wire::Wire
    is_input::Bool
    is_signed::Bool
    bit_width::Int

    function Port(name::Symbol, bit_width::Int; is_input::Bool=true, signed::Bool=false)
        wire = Wire(String(name), bit_width; signed=signed)
        new(name, wire, is_input, signed, bit_width)
    end
end

# ============================================================================
# Primitive - Base type for combinational elements
# ============================================================================

"""
    Primitive

Abstract type for combinational logic primitives that need
to be evaluated in topological order.
"""
abstract type Primitive <: SimulationElement end

"""
    ALUPrimitive

A primitive wrapping ALU computation.
"""
mutable struct ALUPrimitive <: Primitive
    alu::ALU
    node_id::Int
    input_wires::Vector{Wire}
    output_wire::Wire
    scheduled_cycle::Int
    state_id::Int
end

"""
    MUXPrimitive

A primitive wrapping MUX selection.
"""
mutable struct MUXPrimitive <: Primitive
    mux::MUX
    node_id::Int
    is_phi::Bool
end

"""
    MemoryPrimitive

A primitive wrapping memory access.
"""
mutable struct MemoryPrimitive <: Primitive
    memory::Memory
    node_id::Int
    is_read::Bool
    address_wire::Wire
    data_wire::Wire
    scheduled_cycle::Int
    state_id::Int
end

# ============================================================================
# NativeSimulator - Main simulation engine
# ============================================================================

"""
    NativeSimulator

Main simulation engine that manages all hardware elements and
executes cycle-accurate simulation.
"""
mutable struct NativeSimulator
    name::String

    # Hardware elements
    wires::Dict{String, Wire}
    registers::Dict{String, Register}
    alus::Dict{String, ALU}
    muxes::Dict{String, MUX}
    memories::Dict{String, Memory}
    fsm::FSMController

    # I/O
    input_ports::Dict{Symbol, Port}
    output_ports::Dict{Symbol, Port}

    # Primitives in evaluation order
    combinational_order::Vector{Primitive}

    # Simulation state
    cycle::Int
    is_done::Bool
    is_started::Bool
    max_cycles::Int

    # Tracing
    trace_enabled::Bool
    traced_signals::Set{String}
    vcd_timescale::String

    # Statistics
    total_cycles::Int
    states_visited::Vector{Int}

    function NativeSimulator(name::String="sim")
        fsm = FSMController(name)
        new(
            name,
            Dict{String, Wire}(),
            Dict{String, Register}(),
            Dict{String, ALU}(),
            Dict{String, MUX}(),
            Dict{String, Memory}(),
            fsm,
            Dict{Symbol, Port}(),
            Dict{Symbol, Port}(),
            Primitive[],
            0,
            false,
            false,
            100000,
            false,
            Set{String}(),
            "1ns",
            0,
            Int[]
        )
    end
end

# ============================================================================
# Simulation Configuration
# ============================================================================

"""
    SimulationConfig

Configuration options for simulation.
"""
struct SimulationConfig
    max_cycles::Int
    trace_all::Bool
    check_x_propagation::Bool
    verbose::Bool
    stop_on_x::Bool

    SimulationConfig(;
        max_cycles::Int=100000,
        trace_all::Bool=false,
        check_x_propagation::Bool=true,
        verbose::Bool=false,
        stop_on_x::Bool=false
    ) = new(max_cycles, trace_all, check_x_propagation, verbose, stop_on_x)
end
