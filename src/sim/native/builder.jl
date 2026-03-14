# Native RTL Simulator Builder
# Build simulation graph from CDFG and Schedule

using ..HLS: CDFG, Schedule, DFGNode, DFGEdge, FSMState, HLSConstant
using ..HLS: OperationType, ResourceType
using ..HLS: OP_NOP, OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_UDIV, OP_SDIV
using ..HLS: OP_MOD, OP_UREM, OP_SREM, OP_AND, OP_OR, OP_XOR
using ..HLS: OP_SHL, OP_SHR, OP_ASHR, OP_CMP, OP_ICMP, OP_FCMP
using ..HLS: OP_SELECT, OP_PHI, OP_LOAD, OP_STORE, OP_BR, OP_BR_COND, OP_RET
using ..HLS: OP_ZEXT, OP_SEXT, OP_TRUNC, OP_COPY, OP_GEP
using ..HLS: is_memory_op, is_control_op, is_combinational

# ============================================================================
# Main Builder Function
# ============================================================================

"""
    build_simulator(cdfg::CDFG, schedule::Schedule)

Build a NativeSimulator from a CDFG and Schedule.
"""
function build_simulator(cdfg::CDFG, schedule::Schedule)::NativeSimulator
    sim = NativeSimulator(cdfg.name)

    # Build components in order
    build_ports!(sim, cdfg)
    build_wires!(sim, cdfg)
    build_registers!(sim, cdfg, schedule)
    build_alus!(sim, cdfg, schedule)
    build_muxes!(sim, cdfg)
    build_memories!(sim, cdfg)
    build_fsm!(sim, cdfg, schedule)

    # Build combinational evaluation order
    build_evaluation_order!(sim, cdfg, schedule)

    # Connect all components
    connect_datapath!(sim, cdfg, schedule)

    return sim
end

# ============================================================================
# Port Building
# ============================================================================

"""
    build_ports!(sim::NativeSimulator, cdfg::CDFG)

Build input and output ports from CDFG interface.
"""
function build_ports!(sim::NativeSimulator, cdfg::CDFG)
    # Input ports from input nodes
    for node in cdfg.input_nodes
        port_name = Symbol(sanitize_signal_name(node.name))
        port = Port(port_name, node.bit_width; is_input=true, signed=node.is_signed)
        sim.input_ports[port_name] = port
        sim.wires[String(port_name)] = port.wire
    end

    # Output ports from output nodes
    for node in cdfg.output_nodes
        port_name = Symbol(sanitize_signal_name(node.name))
        port = Port(port_name, node.bit_width; is_input=false, signed=node.is_signed)
        sim.output_ports[port_name] = port
        sim.wires[String(port_name)] = port.wire
    end

    # Standard control ports
    # Start port
    start_port = Port(:start, 1; is_input=true)
    sim.input_ports[:start] = start_port
    sim.wires["start"] = start_port.wire

    # Done port
    done_port = Port(:done, 1; is_input=false)
    sim.output_ports[:done] = done_port
    sim.wires["done"] = done_port.wire

    # Connect FSM
    sim.fsm.start_wire = start_port.wire
    sim.fsm.done_wire = done_port.wire
end

# ============================================================================
# Wire Building
# ============================================================================

"""
    build_wires!(sim::NativeSimulator, cdfg::CDFG)

Build wires for all intermediate values in the CDFG.
"""
function build_wires!(sim::NativeSimulator, cdfg::CDFG)
    for node in cdfg.nodes
        # Skip nodes that don't produce values
        if is_control_op(node.op) && node.op != OP_SELECT
            continue
        end

        wire_name = get_wire_name(node)
        if !haskey(sim.wires, wire_name)
            wire = Wire(wire_name, node.bit_width; signed=node.is_signed)
            sim.wires[wire_name] = wire
        end
    end

    # Create wires for constants
    for node in cdfg.nodes
        for (i, operand) in enumerate(node.operands)
            if operand isa HLSConstant
                const_name = get_constant_wire_name(node, i)
                if !haskey(sim.wires, const_name)
                    wire = Wire(const_name, operand.bit_width; signed=operand.is_signed)
                    wire.value = SimValue(operand.value, operand.bit_width; signed=operand.is_signed)
                    sim.wires[const_name] = wire
                end
            end
        end
    end
end

# ============================================================================
# Register Building
# ============================================================================

"""
    build_registers!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)

Build registers for values that need to be stored across cycles.
"""
function build_registers!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)
    # Identify values that span multiple cycles
    for node in cdfg.nodes
        if node.live_end > node.live_start + 1
            # This value is live across multiple cycles - needs a register
            reg_name = "reg_$(get_wire_name(node))"
            if !haskey(sim.registers, reg_name)
                reg = Register(reg_name, node.bit_width; reset_value=0, signed=node.is_signed)
                sim.registers[reg_name] = reg
                sim.wires[reg.output_wire.name] = reg.output_wire
            end
        end
    end

    # Create registers for loop-carried values (PHI nodes)
    for node in cdfg.nodes
        if node.op == OP_PHI
            reg_name = "phi_reg_$(node.id)"
            if !haskey(sim.registers, reg_name)
                reg = Register(reg_name, node.bit_width; reset_value=0, signed=node.is_signed)
                sim.registers[reg_name] = reg
                sim.wires[reg.output_wire.name] = reg.output_wire
            end
        end
    end
end

# ============================================================================
# ALU Building
# ============================================================================

"""
    build_alus!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)

Build ALU units for arithmetic/logic operations.
"""
function build_alus!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)
    for node in cdfg.nodes
        if !is_memory_op(node.op) && !is_control_op(node.op) &&
           node.op != OP_PHI && node.op != OP_SELECT

            alu_op = map_operation_to_alu(node.op, node)
            alu_name = "alu_$(node.id)"

            alu = ALU(alu_name, alu_op, node.bit_width; latency=node.latency)
            sim.alus[alu_name] = alu

            # Register ALU wires
            sim.wires[alu.input_a.name] = alu.input_a
            if alu.input_b !== nothing
                sim.wires[alu.input_b.name] = alu.input_b
            end
            sim.wires[alu.output.name] = alu.output

            # Create primitive for evaluation
            prim = ALUPrimitive(
                alu,
                node.id,
                Wire[],  # Will be connected later
                alu.output,
                node.scheduled_cycle,
                node.state_id
            )
            push!(sim.combinational_order, prim)
        end
    end
end

"""
    map_operation_to_alu(op::OperationType, node::DFGNode)

Map a CDFG operation type to ALU operation.
"""
function map_operation_to_alu(op::OperationType, node::DFGNode)::ALUOp
    if op == OP_ADD
        ALU_ADD
    elseif op == OP_SUB
        ALU_SUB
    elseif op == OP_MUL
        ALU_MUL
    elseif op == OP_DIV || op == OP_UDIV
        ALU_UDIV
    elseif op == OP_SDIV
        ALU_SDIV
    elseif op == OP_MOD || op == OP_UREM
        ALU_UREM
    elseif op == OP_SREM
        ALU_SREM
    elseif op == OP_AND
        ALU_AND
    elseif op == OP_OR
        ALU_OR
    elseif op == OP_XOR
        ALU_XOR
    elseif op == OP_SHL
        ALU_SHL
    elseif op == OP_SHR
        ALU_SHR
    elseif op == OP_ASHR
        ALU_ASHR
    elseif op == OP_CMP || op == OP_ICMP
        # Get comparison predicate from node metadata if available
        get_comparison_alu_op(node)
    elseif op == OP_ZEXT
        ALU_ZEXT
    elseif op == OP_SEXT
        ALU_SEXT
    elseif op == OP_TRUNC
        ALU_TRUNC
    elseif op == OP_COPY || op == OP_GEP
        ALU_COPY
    else
        ALU_NOP
    end
end

"""
    get_comparison_alu_op(node::DFGNode)

Get the ALU operation for a comparison based on node metadata.
"""
function get_comparison_alu_op(node::DFGNode)::ALUOp
    # Check if node has comparison predicate metadata
    if isdefined(node, :metadata) && haskey(node.metadata, "predicate")
        predicate = node.metadata["predicate"]
        return predicate_to_alu_op(predicate, node.is_signed)
    end

    # Default to equality comparison
    return ALU_EQ
end

# ============================================================================
# MUX Building
# ============================================================================

"""
    build_muxes!(sim::NativeSimulator, cdfg::CDFG)

Build MUX units for SELECT and PHI operations.
"""
function build_muxes!(sim::NativeSimulator, cdfg::CDFG)
    for node in cdfg.nodes
        if node.op == OP_SELECT
            # SELECT is a 2-input mux with condition
            mux_name = "mux_$(node.id)"
            mux = MUX(mux_name, 2, node.bit_width)
            sim.muxes[mux_name] = mux

            # Register wires
            for inp in mux.inputs
                sim.wires[inp.name] = inp
            end
            sim.wires[mux.select.name] = mux.select
            sim.wires[mux.output.name] = mux.output

            # Create primitive
            prim = MUXPrimitive(mux, node.id, false)
            push!(sim.combinational_order, prim)

        elseif node.op == OP_PHI
            # PHI is a multi-input mux based on incoming edge
            num_inputs = length(node.operands)
            mux_name = "phi_mux_$(node.id)"
            mux = MUX(mux_name, max(2, num_inputs), node.bit_width)
            sim.muxes[mux_name] = mux

            # Register wires
            for inp in mux.inputs
                sim.wires[inp.name] = inp
            end
            sim.wires[mux.select.name] = mux.select
            sim.wires[mux.output.name] = mux.output

            # Create primitive
            prim = MUXPrimitive(mux, node.id, true)
            push!(sim.combinational_order, prim)
        end
    end
end

# ============================================================================
# Memory Building
# ============================================================================

"""
    build_memories!(sim::NativeSimulator, cdfg::CDFG)

Build memory units for LOAD/STORE operations.
"""
function build_memories!(sim::NativeSimulator, cdfg::CDFG)
    # Collect memory operations and group by array
    memory_ops = Dict{String, Vector{DFGNode}}()

    for node in cdfg.memory_nodes
        # Try to extract memory name from node name or operand
        mem_name = extract_memory_name(node)
        if !haskey(memory_ops, mem_name)
            memory_ops[mem_name] = DFGNode[]
        end
        push!(memory_ops[mem_name], node)
    end

    # Create memory instances
    for (mem_name, ops) in memory_ops
        if !haskey(sim.memories, mem_name)
            # Determine memory parameters
            word_width = 32  # Default
            if !isempty(ops)
                word_width = ops[1].bit_width
            end

            mem = Memory(mem_name;
                depth=1024,  # Default depth, could be extracted from analysis
                word_width=word_width,
                read_latency=2,
                write_latency=1
            )
            sim.memories[mem_name] = mem

            # Register memory wires
            sim.wires[mem.read_addr.name] = mem.read_addr
            sim.wires[mem.read_data.name] = mem.read_data
            sim.wires[mem.read_enable.name] = mem.read_enable
            sim.wires[mem.write_addr.name] = mem.write_addr
            sim.wires[mem.write_data.name] = mem.write_data
            sim.wires[mem.write_enable.name] = mem.write_enable
        end
    end

    # Create memory primitives for read operations
    for node in cdfg.memory_nodes
        if node.op == OP_LOAD
            mem_name = extract_memory_name(node)
            if haskey(sim.memories, mem_name)
                mem = sim.memories[mem_name]
                addr_wire = get_or_create_wire(sim, "addr_$(node.id)", 32)
                prim = MemoryPrimitive(mem, node.id, true, addr_wire, mem.read_data,
                                       node.scheduled_cycle, node.state_id)
                push!(sim.combinational_order, prim)
            end
        end
    end
end

"""
    extract_memory_name(node::DFGNode)

Extract memory array name from a load/store node.
"""
function extract_memory_name(node::DFGNode)::String
    # Try to get from node name
    if contains(node.name, "mem_") || contains(node.name, "array_")
        parts = split(node.name, "_")
        if length(parts) >= 2
            return join(parts[1:2], "_")
        end
    end

    # Default name based on node ID
    return "mem_$(node.id)"
end

# ============================================================================
# FSM Building
# ============================================================================

"""
    build_fsm!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)

Build the FSM controller from CDFG states.
"""
function build_fsm!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)
    fsm = sim.fsm

    # Set up states
    fsm.num_states = length(cdfg.states) + 1  # +1 for IDLE

    # IDLE state is 0
    fsm.state_names[0] = "IDLE"
    fsm.idle_state = 0

    # Map CDFG states
    for state in cdfg.states
        fsm.state_names[state.id] = state.name
        fsm.state_cycles[state.id] = state.num_cycles

        # Build transitions
        transitions = FSMTransition[]

        # Check for conditional branches in this state
        cond_node = nothing
        for op in state.operations
            if op.op == OP_BR_COND
                cond_node = op
                break
            end
        end

        if cond_node !== nothing && length(state.successor_ids) >= 2
            # Conditional transition
            # First successor for true, second for false
            cond_wire = get_or_create_wire(sim, "br_cond_$(cond_node.id)", 1)

            # True branch
            push!(transitions, FSMTransition(cond_wire, state.successor_ids[1], true))
            # False branch (unconditional to second successor)
            push!(transitions, FSMTransition(nothing, state.successor_ids[2], false))
        elseif !isempty(state.successor_ids)
            # Unconditional transition
            push!(transitions, FSMTransition(nothing, state.successor_ids[1], false))
        end

        fsm.transitions[state.id] = transitions
    end

    # Find done state (return state)
    for state in cdfg.states
        for op in state.operations
            if op.op == OP_RET
                fsm.done_state = state.id
                break
            end
        end
    end

    # If no explicit return, use last state or mark as not found
    if fsm.done_state == -1 && !isempty(cdfg.states)
        fsm.done_state = cdfg.states[end].id
    end

    # Create transition from IDLE to first state
    if cdfg.entry_state_id > 0
        fsm.transitions[0] = [FSMTransition(sim.fsm.start_wire, cdfg.entry_state_id, true)]
    end
end

# ============================================================================
# Evaluation Order
# ============================================================================

"""
    build_evaluation_order!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)

Build the topological order for combinational evaluation.
"""
function build_evaluation_order!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)
    # Sort primitives by their data dependencies
    # For now, use scheduled cycle as a proxy for topological order
    sort!(sim.combinational_order, by=p -> begin
        if p isa ALUPrimitive
            p.scheduled_cycle
        elseif p isa MUXPrimitive
            # MUXes should be evaluated after their inputs
            findfirst(n -> n.id == p.node_id, cdfg.nodes)
        elseif p isa MemoryPrimitive
            p.scheduled_cycle
        else
            0
        end
    end)
end

# ============================================================================
# Datapath Connection
# ============================================================================

"""
    connect_datapath!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)

Connect all datapath components based on CDFG edges.
"""
function connect_datapath!(sim::NativeSimulator, cdfg::CDFG, schedule::Schedule)
    # Connect ALU inputs
    for node in cdfg.nodes
        alu_name = "alu_$(node.id)"
        if haskey(sim.alus, alu_name)
            alu = sim.alus[alu_name]

            # Connect operands
            for (i, operand) in enumerate(node.operands)
                input_wire = i == 1 ? alu.input_a : alu.input_b
                if input_wire !== nothing
                    source_wire = get_operand_source_wire(sim, operand, cdfg)
                    if source_wire !== nothing
                        # Copy value (in real sim, this would be a wire connection)
                        push!(source_wire.fanout, alu)
                    end
                end
            end

            # Connect output to node's wire
            node_wire = get(sim.wires, get_wire_name(node), nothing)
            if node_wire !== nothing
                alu.output = node_wire
                node_wire.driver = alu
            end
        end
    end

    # Connect MUX inputs
    for node in cdfg.nodes
        if node.op == OP_SELECT
            mux_name = "mux_$(node.id)"
            if haskey(sim.muxes, mux_name)
                mux = sim.muxes[mux_name]

                # SELECT: operand[0] = condition, operand[1] = true value, operand[2] = false value
                if length(node.operands) >= 3
                    # Condition to select
                    cond_wire = get_operand_source_wire(sim, node.operands[1], cdfg)
                    if cond_wire !== nothing
                        mux.select = cond_wire
                    end

                    # True value to input[0]
                    true_wire = get_operand_source_wire(sim, node.operands[2], cdfg)
                    if true_wire !== nothing && length(mux.inputs) >= 1
                        mux.inputs[1] = true_wire
                    end

                    # False value to input[1]
                    false_wire = get_operand_source_wire(sim, node.operands[3], cdfg)
                    if false_wire !== nothing && length(mux.inputs) >= 2
                        mux.inputs[2] = false_wire
                    end
                end
            end

        elseif node.op == OP_PHI
            mux_name = "phi_mux_$(node.id)"
            if haskey(sim.muxes, mux_name)
                mux = sim.muxes[mux_name]

                # Connect PHI operands
                for (i, operand) in enumerate(node.operands)
                    if i <= length(mux.inputs)
                        source_wire = get_operand_source_wire(sim, operand, cdfg)
                        if source_wire !== nothing
                            mux.inputs[i] = source_wire
                        end
                    end
                end
            end
        end
    end

    # Connect memory operations
    for node in cdfg.memory_nodes
        mem_name = extract_memory_name(node)
        if haskey(sim.memories, mem_name)
            mem = sim.memories[mem_name]

            if node.op == OP_LOAD
                # Connect address operand to read_addr
                if !isempty(node.operands)
                    addr_wire = get_operand_source_wire(sim, node.operands[1], cdfg)
                    if addr_wire !== nothing
                        mem.read_addr = addr_wire
                    end
                end

            elseif node.op == OP_STORE
                # Connect address and data operands
                if length(node.operands) >= 2
                    # First operand is data, second is address (LLVM convention)
                    data_wire = get_operand_source_wire(sim, node.operands[1], cdfg)
                    addr_wire = get_operand_source_wire(sim, node.operands[2], cdfg)

                    if addr_wire !== nothing
                        mem.write_addr = addr_wire
                    end
                    if data_wire !== nothing
                        mem.write_data = data_wire
                    end
                end
            end
        end
    end

    # Connect output ports
    for node in cdfg.output_nodes
        port_name = Symbol(sanitize_signal_name(node.name))
        if haskey(sim.output_ports, port_name)
            port = sim.output_ports[port_name]

            # Find the producing node
            if !isempty(node.operands)
                source_wire = get_operand_source_wire(sim, node.operands[1], cdfg)
                if source_wire !== nothing
                    # Connect source to port wire
                    push!(source_wire.fanout, port)
                end
            end
        end
    end
end

"""
    get_operand_source_wire(sim::NativeSimulator, operand::Union{DFGNode, HLSConstant}, cdfg::CDFG)

Get the wire that provides the value for an operand.
"""
function get_operand_source_wire(sim::NativeSimulator, operand::Union{DFGNode, HLSConstant},
                                  cdfg::CDFG)::Union{Wire, Nothing}
    if operand isa DFGNode
        wire_name = get_wire_name(operand)
        return get(sim.wires, wire_name, nothing)
    elseif operand isa HLSConstant
        # Find or create constant wire
        const_name = "const_$(operand.value)_w$(operand.bit_width)"
        if !haskey(sim.wires, const_name)
            wire = Wire(const_name, operand.bit_width; signed=operand.is_signed)
            wire.value = SimValue(operand.value, operand.bit_width; signed=operand.is_signed)
            sim.wires[const_name] = wire
        end
        return sim.wires[const_name]
    end
    return nothing
end

# ============================================================================
# Helper Functions
# ============================================================================

"""
    get_wire_name(node::DFGNode)

Generate a wire name for a DFG node's output.
"""
function get_wire_name(node::DFGNode)::String
    sanitize_signal_name(node.name)
end

"""
    get_constant_wire_name(node::DFGNode, operand_idx::Int)

Generate a wire name for a constant operand.
"""
function get_constant_wire_name(node::DFGNode, operand_idx::Int)::String
    operand = node.operands[operand_idx]
    if operand isa HLSConstant
        return "const_$(operand.value)_w$(operand.bit_width)"
    end
    return "const_$(node.id)_$(operand_idx)"
end

"""
    sanitize_signal_name(name::String)

Sanitize a name for use as a signal/wire name.
"""
function sanitize_signal_name(name::String)::String
    # Replace invalid characters
    result = replace(name, "%" => "")
    result = replace(result, "." => "_")
    result = replace(result, "-" => "_")
    result = replace(result, " " => "_")

    # Ensure it starts with a letter or underscore
    if !isempty(result) && isdigit(result[1])
        result = "_" * result
    end

    return result
end

"""
    get_or_create_wire(sim::NativeSimulator, name::String, bit_width::Int)

Get an existing wire or create a new one.
"""
function get_or_create_wire(sim::NativeSimulator, name::String, bit_width::Int)::Wire
    if haskey(sim.wires, name)
        return sim.wires[name]
    end

    wire = Wire(name, bit_width)
    sim.wires[name] = wire
    return wire
end
