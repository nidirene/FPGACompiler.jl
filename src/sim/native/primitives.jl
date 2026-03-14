# Native RTL Simulator Primitives
# Operation implementations for ALU, MUX, Memory, and evaluation functions

# ============================================================================
# ALU Operations
# ============================================================================

"""
    compute_alu_result(op::ALUOp, a::SimValue, b::SimValue, result_width::Int)

Compute the result of an ALU operation on two input values.
Handles X propagation: if any input is invalid, output is invalid.
"""
function compute_alu_result(op::ALUOp, a::SimValue, b::SimValue, result_width::Int)::SimValue
    # X propagation: undefined inputs produce undefined outputs
    # Exception: some operations like AND with 0 can produce defined results
    if !a.is_valid || (!b.is_valid && needs_two_operands(op))
        return SimValue(nothing, result_width)
    end

    # Get raw values
    a_unsigned = to_unsigned(a)
    b_unsigned = to_unsigned(b)
    a_signed = to_signed(a)
    b_signed = to_signed(b)

    # Compute result based on operation
    result = compute_op(op, a_unsigned, b_unsigned, a_signed, b_signed, a.bit_width, b.bit_width, result_width)

    return result
end

"""
    needs_two_operands(op::ALUOp)

Check if operation requires two valid operands.
"""
function needs_two_operands(op::ALUOp)::Bool
    op in (ALU_ADD, ALU_SUB, ALU_MUL, ALU_DIV, ALU_UDIV, ALU_SDIV,
           ALU_MOD, ALU_UREM, ALU_SREM, ALU_AND, ALU_OR, ALU_XOR,
           ALU_SHL, ALU_SHR, ALU_ASHR, ALU_EQ, ALU_NE, ALU_LT,
           ALU_LE, ALU_GT, ALU_GE, ALU_ULT, ALU_ULE, ALU_UGT, ALU_UGE)
end

"""
    compute_op(op, a_u, b_u, a_s, b_s, a_width, b_width, result_width)

Core operation computation.
"""
function compute_op(op::ALUOp, a_u::UInt64, b_u::UInt64,
                    a_s::Int64, b_s::Int64,
                    a_width::Int, b_width::Int, result_width::Int)::SimValue

    result_mask = mask_for_width(result_width)

    result_bits = if op == ALU_NOP
        UInt64(0)
    elseif op == ALU_ADD
        (a_u + b_u) & result_mask
    elseif op == ALU_SUB
        (a_u - b_u) & result_mask
    elseif op == ALU_MUL
        (a_u * b_u) & result_mask
    elseif op == ALU_DIV || op == ALU_UDIV
        b_u == 0 ? UInt64(0) : (a_u ÷ b_u) & result_mask
    elseif op == ALU_SDIV
        b_s == 0 ? UInt64(0) : reinterpret(UInt64, a_s ÷ b_s) & result_mask
    elseif op == ALU_MOD || op == ALU_UREM
        b_u == 0 ? UInt64(0) : (a_u % b_u) & result_mask
    elseif op == ALU_SREM
        b_s == 0 ? UInt64(0) : reinterpret(UInt64, a_s % b_s) & result_mask
    elseif op == ALU_AND
        a_u & b_u
    elseif op == ALU_OR
        a_u | b_u
    elseif op == ALU_XOR
        a_u ⊻ b_u
    elseif op == ALU_SHL
        (a_u << min(b_u, 63)) & result_mask
    elseif op == ALU_SHR
        (a_u >> min(b_u, 63)) & result_mask
    elseif op == ALU_ASHR
        # Arithmetic shift preserves sign - use reinterpret to avoid conversion error
        reinterpret(UInt64, a_s >> min(b_u, 63)) & result_mask
    elseif op == ALU_EQ
        a_u == b_u ? UInt64(1) : UInt64(0)
    elseif op == ALU_NE
        a_u != b_u ? UInt64(1) : UInt64(0)
    elseif op == ALU_LT
        a_s < b_s ? UInt64(1) : UInt64(0)
    elseif op == ALU_LE
        a_s <= b_s ? UInt64(1) : UInt64(0)
    elseif op == ALU_GT
        a_s > b_s ? UInt64(1) : UInt64(0)
    elseif op == ALU_GE
        a_s >= b_s ? UInt64(1) : UInt64(0)
    elseif op == ALU_ULT
        a_u < b_u ? UInt64(1) : UInt64(0)
    elseif op == ALU_ULE
        a_u <= b_u ? UInt64(1) : UInt64(0)
    elseif op == ALU_UGT
        a_u > b_u ? UInt64(1) : UInt64(0)
    elseif op == ALU_UGE
        a_u >= b_u ? UInt64(1) : UInt64(0)
    elseif op == ALU_ZEXT
        a_u & mask_for_width(a_width)
    elseif op == ALU_SEXT
        # Sign extend from a_width to result_width
        if a_width < 64 && (a_u >> (a_width - 1)) & 1 == 1
            # Negative - extend sign bits
            a_u | (~mask_for_width(a_width) & result_mask)
        else
            a_u & result_mask
        end
    elseif op == ALU_TRUNC
        a_u & result_mask
    elseif op == ALU_COPY
        a_u & result_mask
    else
        UInt64(0)
    end

    # Determine if result is signed based on operation
    is_signed = op in (ALU_SDIV, ALU_SREM, ALU_LT, ALU_LE, ALU_GT, ALU_GE, ALU_SEXT, ALU_ASHR)

    return SimValue(result_bits, result_width, true, is_signed)
end

# ============================================================================
# MUX Operations
# ============================================================================

"""
    compute_mux_result(inputs::Vector{SimValue}, select::SimValue)

Compute the result of a multiplexer selection.
"""
function compute_mux_result(inputs::Vector{SimValue}, select::SimValue)::SimValue
    if !select.is_valid
        # If select is X, output is X
        return isempty(inputs) ? SimValue() : SimValue(nothing, inputs[1].bit_width)
    end

    idx = Int(to_unsigned(select)) + 1
    if idx < 1 || idx > length(inputs)
        # Out of bounds - return X or last valid
        return isempty(inputs) ? SimValue() : inputs[end]
    end

    return inputs[idx]
end

"""
    compute_phi_result(inputs::Vector{SimValue}, prev_state::Int, incoming_states::Vector{Int})

Compute the result of a PHI node based on previous state.
"""
function compute_phi_result(inputs::Vector{SimValue}, prev_state::Int,
                            incoming_states::Vector{Int})::SimValue
    if isempty(inputs)
        return SimValue()
    end

    # Find which input corresponds to the previous state
    for (i, state_id) in enumerate(incoming_states)
        if state_id == prev_state && i <= length(inputs)
            return inputs[i]
        end
    end

    # Default to first input if no match
    return inputs[1]
end

# ============================================================================
# Memory Operations
# ============================================================================

"""
    memory_read(mem::Memory, addr::SimValue)

Perform a memory read operation.
Returns the value at the given address.
"""
function memory_read(mem::Memory, addr::SimValue)::SimValue
    if !addr.is_valid
        return SimValue(nothing, mem.word_width)
    end

    idx = Int(to_unsigned(addr)) + 1
    if idx < 1 || idx > mem.depth
        # Out of bounds
        return SimValue(nothing, mem.word_width)
    end

    return mem.data[idx]
end

"""
    memory_write!(mem::Memory, addr::SimValue, data::SimValue)

Perform a memory write operation.
Writes data to the given address.
"""
function memory_write!(mem::Memory, addr::SimValue, data::SimValue)
    if !addr.is_valid
        return  # Cannot write to undefined address
    end

    idx = Int(to_unsigned(addr)) + 1
    if idx < 1 || idx > mem.depth
        return  # Out of bounds - silently ignore
    end

    mem.data[idx] = data
end

# ============================================================================
# Combinational Evaluation
# ============================================================================

"""
    evaluate_wire!(wire::Wire, cycle::Int)

Evaluate a wire's value from its driver.
Records trace if enabled.
"""
function evaluate_wire!(wire::Wire, cycle::Int)
    if wire.trace_enabled
        push!(wire.trace_history, (cycle, wire.value))
    end
end

"""
    evaluate_alu!(alu::ALU)

Evaluate an ALU's combinational output.
"""
function evaluate_alu!(alu::ALU)
    a_val = alu.input_a.value
    b_val = alu.input_b !== nothing ? alu.input_b.value : SimValue(0, alu.input_a.bit_width)

    result = compute_alu_result(alu.op, a_val, b_val, alu.output.bit_width)

    if alu.latency <= 1
        # Combinational - output immediately
        alu.output.value = result
    else
        # Pipelined - result enters first pipeline stage
        # Will be handled in sequential evaluation
    end
end

"""
    evaluate_mux!(mux::MUX)

Evaluate a MUX's combinational output.
"""
function evaluate_mux!(mux::MUX)
    input_values = [w.value for w in mux.inputs]
    select_val = mux.select.value

    mux.output.value = compute_mux_result(input_values, select_val)
end

"""
    evaluate_memory_read!(mem::Memory)

Evaluate memory read (combinational part).
"""
function evaluate_memory_read!(mem::Memory)
    if to_bool(mem.read_enable.value)
        # Initiate read - for single-cycle latency, output is available
        if mem.read_latency == 1
            mem.read_data.value = memory_read(mem, mem.read_addr.value)
        end
        # Multi-cycle reads handled in sequential evaluation
    end
end

"""
    evaluate_combinational!(sim::NativeSimulator)

Evaluate all combinational logic in topological order.
This is Phase 1 of the two-phase clock semantics.
"""
function evaluate_combinational!(sim::NativeSimulator)
    # First, propagate register outputs to their wires
    for (_, reg) in sim.registers
        reg.output_wire.value = reg.current_value
    end

    # Evaluate combinational elements in topological order
    for prim in sim.combinational_order
        evaluate_primitive!(prim, sim)
    end

    # Evaluate FSM outputs
    evaluate_fsm_outputs!(sim.fsm)
end

"""
    evaluate_primitive!(prim::ALUPrimitive, sim::NativeSimulator)

Evaluate an ALU primitive.
"""
function evaluate_primitive!(prim::ALUPrimitive, sim::NativeSimulator)
    # Only evaluate if in correct state
    if sim.fsm.current_state == prim.state_id || prim.state_id == -1
        evaluate_alu!(prim.alu)
    end
end

"""
    evaluate_primitive!(prim::MUXPrimitive, sim::NativeSimulator)

Evaluate a MUX primitive.
"""
function evaluate_primitive!(prim::MUXPrimitive, sim::NativeSimulator)
    evaluate_mux!(prim.mux)
end

"""
    evaluate_primitive!(prim::MemoryPrimitive, sim::NativeSimulator)

Evaluate a memory primitive.
"""
function evaluate_primitive!(prim::MemoryPrimitive, sim::NativeSimulator)
    if prim.is_read
        evaluate_memory_read!(prim.memory)
    end
end

"""
    evaluate_fsm_outputs!(fsm::FSMController)

Evaluate FSM output signals.
"""
function evaluate_fsm_outputs!(fsm::FSMController)
    # Done signal
    fsm.done_wire.value = SimValue(fsm.current_state == fsm.done_state ? 1 : 0, 1)
end

# ============================================================================
# Sequential Evaluation
# ============================================================================

"""
    evaluate_sequential!(sim::NativeSimulator)

Evaluate all sequential logic (register updates, FSM transitions).
This is Phase 2 of the two-phase clock semantics - the clock edge.
"""
function evaluate_sequential!(sim::NativeSimulator)
    # Update registers
    for (_, reg) in sim.registers
        if reg.enable_wire === nothing || to_bool(reg.enable_wire.value)
            reg.current_value = reg.next_value

            # Record trace
            if reg.trace_enabled
                push!(reg.trace_history, (sim.cycle, reg.current_value))
            end
        end
    end

    # Update pipeline stages in ALUs
    update_alu_pipelines!(sim)

    # Update memory read pipelines
    update_memory_pipelines!(sim)

    # Perform memory writes
    perform_memory_writes!(sim)

    # FSM transition
    update_fsm!(sim)

    # Increment cycle counter
    sim.cycle += 1
    sim.total_cycles = sim.cycle
end

"""
    update_alu_pipelines!(sim::NativeSimulator)

Update pipeline stages in multi-cycle ALUs.
"""
function update_alu_pipelines!(sim::NativeSimulator)
    for (_, alu) in sim.alus
        if alu.latency > 1 && alu.is_active
            # Shift pipeline stages
            for i in alu.latency:-1:2
                alu.pipeline_stages[i] = alu.pipeline_stages[i-1]
                alu.pipeline_valid[i] = alu.pipeline_valid[i-1]
            end

            # Compute new input value
            a_val = alu.input_a.value
            b_val = alu.input_b !== nothing ? alu.input_b.value : SimValue(0, alu.input_a.bit_width)
            result = compute_alu_result(alu.op, a_val, b_val, alu.output.bit_width)

            alu.pipeline_stages[1] = result
            alu.pipeline_valid[1] = true

            # Output from last stage
            if alu.pipeline_valid[alu.latency]
                alu.output.value = alu.pipeline_stages[alu.latency]
            end
        end
    end
end

"""
    update_memory_pipelines!(sim::NativeSimulator)

Update memory read pipelines for multi-cycle reads.
"""
function update_memory_pipelines!(sim::NativeSimulator)
    for (_, mem) in sim.memories
        if mem.read_latency > 1
            # Shift read pipeline
            for i in mem.read_latency:-1:2
                mem.read_pipeline[i] = mem.read_pipeline[i-1]
                mem.read_pipeline_valid[i] = mem.read_pipeline_valid[i-1]
            end

            # New read enters pipeline
            if to_bool(mem.read_enable.value)
                mem.read_pipeline[1] = memory_read(mem, mem.read_addr.value)
                mem.read_pipeline_valid[1] = true
            else
                mem.read_pipeline_valid[1] = false
            end

            # Output from last stage
            if mem.read_pipeline_valid[mem.read_latency]
                mem.read_data.value = mem.read_pipeline[mem.read_latency]
            end
        end
    end
end

"""
    perform_memory_writes!(sim::NativeSimulator)

Perform all pending memory writes.
"""
function perform_memory_writes!(sim::NativeSimulator)
    for (_, mem) in sim.memories
        if to_bool(mem.write_enable.value)
            memory_write!(mem, mem.write_addr.value, mem.write_data.value)

            # Record access for tracing
            if mem.trace_enabled
                push!(mem.access_history, (
                    sim.cycle,
                    :write,
                    Int(to_unsigned(mem.write_addr.value)),
                    mem.write_data.value
                ))
            end
        end
    end
end

"""
    update_fsm!(sim::NativeSimulator)

Update FSM state based on transitions.
"""
function update_fsm!(sim::NativeSimulator)
    fsm = sim.fsm
    prev_state = fsm.current_state

    # Check for start signal when idle
    if fsm.current_state == fsm.idle_state
        if to_bool(fsm.start_wire.value)
            # Transition to first state
            fsm.next_state = 1
            fsm.cycle_in_state = 0
        end
    end

    # Check if we need to stay in current state (multi-cycle states)
    cycles_needed = get(fsm.state_cycles, fsm.current_state, 1)
    if fsm.cycle_in_state < cycles_needed - 1
        # Stay in current state
        fsm.cycle_in_state += 1
        return
    end

    # Evaluate transitions from current state
    if haskey(fsm.transitions, fsm.current_state)
        for transition in fsm.transitions[fsm.current_state]
            if transition.is_conditional
                if transition.condition !== nothing && to_bool(transition.condition.value)
                    fsm.next_state = transition.target_state
                    break
                end
            else
                # Unconditional transition
                fsm.next_state = transition.target_state
                break
            end
        end
    end

    # Apply transition
    if fsm.next_state != fsm.current_state
        fsm.current_state = fsm.next_state
        fsm.cycle_in_state = 0
        push!(sim.states_visited, fsm.current_state)

        # Check if done
        if fsm.current_state == fsm.done_state
            sim.is_done = true
        end
    else
        fsm.cycle_in_state += 1
    end
end

# ============================================================================
# OperationType to ALUOp Conversion
# ============================================================================

"""
    operation_type_to_alu_op(op::OperationType)

Convert HLS OperationType to simulation ALUOp.
"""
function operation_type_to_alu_op(op)::ALUOp
    # Import OperationType enum values
    mapping = Dict(
        :OP_NOP => ALU_NOP,
        :OP_ADD => ALU_ADD,
        :OP_SUB => ALU_SUB,
        :OP_MUL => ALU_MUL,
        :OP_DIV => ALU_DIV,
        :OP_UDIV => ALU_UDIV,
        :OP_SDIV => ALU_SDIV,
        :OP_MOD => ALU_MOD,
        :OP_UREM => ALU_UREM,
        :OP_SREM => ALU_SREM,
        :OP_AND => ALU_AND,
        :OP_OR => ALU_OR,
        :OP_XOR => ALU_XOR,
        :OP_SHL => ALU_SHL,
        :OP_SHR => ALU_SHR,
        :OP_ASHR => ALU_ASHR,
        :OP_CMP => ALU_EQ,      # Default comparison
        :OP_ICMP => ALU_EQ,     # Need to check predicate
        :OP_ZEXT => ALU_ZEXT,
        :OP_SEXT => ALU_SEXT,
        :OP_TRUNC => ALU_TRUNC,
        :OP_COPY => ALU_COPY,
    )

    op_sym = Symbol(op)
    return get(mapping, op_sym, ALU_NOP)
end

"""
    predicate_to_alu_op(predicate::String, is_signed::Bool)

Convert LLVM comparison predicate to ALUOp.
"""
function predicate_to_alu_op(predicate::String, is_signed::Bool)::ALUOp
    if predicate == "eq"
        ALU_EQ
    elseif predicate == "ne"
        ALU_NE
    elseif predicate == "slt" || (predicate == "lt" && is_signed)
        ALU_LT
    elseif predicate == "sle" || (predicate == "le" && is_signed)
        ALU_LE
    elseif predicate == "sgt" || (predicate == "gt" && is_signed)
        ALU_GT
    elseif predicate == "sge" || (predicate == "ge" && is_signed)
        ALU_GE
    elseif predicate == "ult" || (predicate == "lt" && !is_signed)
        ALU_ULT
    elseif predicate == "ule" || (predicate == "le" && !is_signed)
        ALU_ULE
    elseif predicate == "ugt" || (predicate == "gt" && !is_signed)
        ALU_UGT
    elseif predicate == "uge" || (predicate == "ge" && !is_signed)
        ALU_UGE
    else
        ALU_EQ  # Default
    end
end
