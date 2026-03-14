# Datapath Generation
# Generates Verilog datapath from scheduled CDFG

"""
    generate_datapath(cdfg::CDFG, schedule::Schedule, rtl::RTLModule)

Generate Verilog datapath logic including ALU operations and data routing.
"""
function generate_datapath(cdfg::CDFG, schedule::Schedule, rtl::RTLModule)::String
    lines = String[]

    push!(lines, "    // =========================================================")
    push!(lines, "    // Datapath Logic")
    push!(lines, "    // =========================================================")
    push!(lines, "")

    # Generate combinational operations
    comb_ops = generate_combinational_ops(cdfg, rtl)
    if !isempty(comb_ops)
        push!(lines, "    // Combinational operations")
        append!(lines, comb_ops)
        push!(lines, "")
    end

    # Generate sequential (registered) operations
    seq_ops = generate_sequential_ops(cdfg, rtl)
    if !isempty(seq_ops)
        push!(lines, "    // Sequential operations")
        append!(lines, seq_ops)
        push!(lines, "")
    end

    # Generate pipeline stage registers
    pipeline_regs = generate_pipeline_registers(cdfg, rtl)
    if !isempty(pipeline_regs)
        push!(lines, "    // Pipeline registers")
        append!(lines, pipeline_regs)
        push!(lines, "")
    end

    return join(lines, "\n")
end

"""
    generate_combinational_ops(cdfg::CDFG, rtl::RTLModule)

Generate combinational (wire) operations.
"""
function generate_combinational_ops(cdfg::CDFG, rtl::RTLModule)::Vector{String}
    lines = String[]

    for node in cdfg.nodes
        if node.op == OP_NOP || is_control_op(node.op)
            continue
        end

        # Only generate combinational logic for zero-latency operations
        if node.latency == 0
            op_line = generate_operation(node, cdfg, rtl)
            if !isempty(op_line)
                push!(lines, op_line)
            end
        end
    end

    return lines
end

"""
    generate_sequential_ops(cdfg::CDFG, rtl::RTLModule)

Generate sequential (registered) operations with state-based enable.
"""
function generate_sequential_ops(cdfg::CDFG, rtl::RTLModule)::Vector{String}
    lines = String[]

    # Group operations by state
    ops_by_state = Dict{Int, Vector{DFGNode}}()
    for node in cdfg.nodes
        if node.op == OP_NOP || is_control_op(node.op) || node.latency == 0
            continue
        end
        if !haskey(ops_by_state, node.state_id)
            ops_by_state[node.state_id] = DFGNode[]
        end
        push!(ops_by_state[node.state_id], node)
    end

    if isempty(ops_by_state)
        return lines
    end

    push!(lines, "    always @(posedge clk) begin")
    push!(lines, "        if (rst) begin")

    # Reset all registered outputs
    for (state_id, ops) in ops_by_state
        for op in ops
            signal_name = sanitize_name(op.name)
            if op.bit_width == 1
                push!(lines, "            $signal_name <= 1'b0;")
            else
                push!(lines, "            $signal_name <= $(op.bit_width)'d0;")
            end
        end
    end

    push!(lines, "        end else begin")

    # Generate operations for each state
    for (state_id, ops) in sort(collect(ops_by_state), by=x->x[1])
        # Find state by ID (not index)
        state_idx = findfirst(s -> s.id == state_id, cdfg.states)
        state = state_idx !== nothing ? cdfg.states[state_idx] : nothing
        state_name = state !== nothing ? "S_$(uppercase(sanitize_name(state.name)))" : "S_$(state_id)"

        push!(lines, "            if (current_state == $state_name) begin")

        for op in ops
            op_line = generate_registered_operation(op, cdfg, rtl)
            if !isempty(op_line)
                push!(lines, "                $op_line")
            end
        end

        push!(lines, "            end")
    end

    push!(lines, "        end")
    push!(lines, "    end")

    return lines
end

"""
    generate_operation(node::DFGNode, cdfg::CDFG, rtl::RTLModule)

Generate Verilog for a single combinational operation.
"""
function generate_operation(node::DFGNode, cdfg::CDFG, rtl::RTLModule)::String
    result = sanitize_name(node.name)
    operands = get_operand_wires(node, cdfg)

    if length(operands) < 1
        return ""
    end

    expr = case_expression(node.op, operands, node)

    if isempty(expr)
        return ""
    end

    return "    assign $result = $expr;"
end

"""
    generate_registered_operation(node::DFGNode, cdfg::CDFG, rtl::RTLModule)

Generate Verilog for a single registered operation.
"""
function generate_registered_operation(node::DFGNode, cdfg::CDFG, rtl::RTLModule)::String
    result = sanitize_name(node.name)
    operands = get_operand_wires(node, cdfg)

    if length(operands) < 1
        return ""
    end

    expr = case_expression(node.op, operands, node)

    if isempty(expr)
        return ""
    end

    return "$result <= $expr;"
end

"""
    case_expression(op::OperationType, operands::Vector{String}, node::DFGNode)

Generate the expression for an operation.
"""
function case_expression(op::OperationType, operands::Vector{String}, node::DFGNode)::String
    a = length(operands) >= 1 ? operands[1] : "0"
    b = length(operands) >= 2 ? operands[2] : "0"
    c = length(operands) >= 3 ? operands[3] : "0"

    signed_str = node.is_signed ? "\$signed" : ""

    return if op == OP_ADD
        "$a + $b"
    elseif op == OP_SUB
        "$a - $b"
    elseif op == OP_MUL
        "$signed_str($a) * $signed_str($b)"
    elseif op == OP_UDIV
        "$a / $b"
    elseif op == OP_SDIV
        "\$signed($a) / \$signed($b)"
    elseif op == OP_UREM
        "$a % $b"
    elseif op == OP_SREM
        "\$signed($a) % \$signed($b)"
    elseif op == OP_AND
        "$a & $b"
    elseif op == OP_OR
        "$a | $b"
    elseif op == OP_XOR
        "$a ^ $b"
    elseif op == OP_SHL
        "$a << $b"
    elseif op == OP_SHR
        if node.is_signed
            "\$signed($a) >>> $b"
        else
            "$a >> $b"
        end
    elseif op == OP_ICMP || op == OP_CMP
        generate_comparison(a, b, node)
    elseif op == OP_FCMP
        generate_comparison(a, b, node)
    elseif op == OP_SELECT
        "$a ? $b : $c"
    elseif op == OP_ZEXT
        "{{$(node.bit_width - parse_bit_width(a)){1'b0}}, $a}"
    elseif op == OP_SEXT
        "{{$(node.bit_width - parse_bit_width(a)){$a[$(parse_bit_width(a)-1)]}}, $a}"
    elseif op == OP_TRUNC
        "$a[$(node.bit_width-1):0]"
    elseif op == OP_PHI
        # PHI nodes become muxes controlled by previous state
        generate_phi_mux(operands, node)
    elseif op == OP_COPY
        a
    else
        ""
    end
end

"""
    generate_comparison(a::String, b::String, node::DFGNode)

Generate comparison expression based on node metadata.
"""
function generate_comparison(a::String, b::String, node::DFGNode)::String
    # Default to equality comparison
    # In practice, this would use metadata from the LLVM icmp/fcmp instruction
    predicate = get(node.metadata, "predicate", "eq")

    if node.is_signed
        a = "\$signed($a)"
        b = "\$signed($b)"
    end

    return if predicate == "eq"
        "$a == $b"
    elseif predicate == "ne"
        "$a != $b"
    elseif predicate in ("slt", "ult")
        "$a < $b"
    elseif predicate in ("sle", "ule")
        "$a <= $b"
    elseif predicate in ("sgt", "ugt")
        "$a > $b"
    elseif predicate in ("sge", "uge")
        "$a >= $b"
    else
        "$a == $b"
    end
end

"""
    generate_phi_mux(operands::Vector{String}, node::DFGNode)

Generate a mux for PHI node based on incoming edges.
"""
function generate_phi_mux(operands::Vector{String}, node::DFGNode)::String
    if length(operands) == 1
        return operands[1]
    elseif length(operands) == 2
        # Simple 2-input mux - would need control signal from CFG
        # For now, generate a placeholder
        return "phi_sel_$(node.id) ? $(operands[1]) : $(operands[2])"
    else
        # Multi-input mux
        return operands[1]  # Simplified
    end
end

"""
    get_operand_wires(node::DFGNode, cdfg::CDFG)

Get wire names for all operands of a node.
"""
function get_operand_wires(node::DFGNode, cdfg::CDFG)::Vector{String}
    wires = String[]

    for operand in node.operands
        push!(wires, get_operand_wire(operand))
    end

    return wires
end

"""
    parse_bit_width(wire_name::String)

Parse bit width from a wire name (returns default if not determinable).
"""
function parse_bit_width(wire_name::String)::Int
    # Try to extract width from constant format like "32'd5"
    m = match(r"(\d+)'[dh]", wire_name)
    if m !== nothing
        return parse(Int, m.captures[1])
    end
    return 32  # Default width
end

"""
    generate_pipeline_registers(cdfg::CDFG, rtl::RTLModule)

Generate pipeline stage registers for multi-cycle operations.
"""
function generate_pipeline_registers(cdfg::CDFG, rtl::RTLModule)::Vector{String}
    lines = String[]

    # Find nodes with latency > 1
    pipelined_nodes = [n for n in cdfg.nodes if n.latency > 1]

    if isempty(pipelined_nodes)
        return lines
    end

    push!(lines, "    always @(posedge clk) begin")
    push!(lines, "        if (rst) begin")

    # Reset pipeline registers
    for node in pipelined_nodes
        signal_name = sanitize_name(node.name)
        for stage in 1:(node.latency-1)
            stage_name = "$(signal_name)_stage$(stage)"
            if node.bit_width == 1
                push!(lines, "            $stage_name <= 1'b0;")
            else
                push!(lines, "            $stage_name <= $(node.bit_width)'d0;")
            end
        end
        push!(lines, "            $(signal_name)_valid <= 1'b0;")
    end

    push!(lines, "        end else begin")

    # Pipeline shifting
    for node in pipelined_nodes
        signal_name = sanitize_name(node.name)
        state = cdfg.states[node.state_id]
        state_name = "S_$(uppercase(sanitize_name(state.name)))"

        push!(lines, "            // Pipeline for $(node.name)")
        push!(lines, "            if (current_state == $state_name) begin")

        # First stage gets the computed value
        operands = get_operand_wires(node, cdfg)
        expr = case_expression(node.op, operands, node)
        if !isempty(expr)
            push!(lines, "                $(signal_name)_stage1 <= $expr;")
        end

        # Subsequent stages shift
        for stage in 2:(node.latency-1)
            prev_stage = "$(signal_name)_stage$(stage-1)"
            curr_stage = "$(signal_name)_stage$(stage)"
            push!(lines, "                $curr_stage <= $prev_stage;")
        end

        # Final output
        if node.latency > 1
            last_stage = "$(signal_name)_stage$(node.latency-1)"
            push!(lines, "                $signal_name <= $last_stage;")
            push!(lines, "                $(signal_name)_valid <= (cycle_count >= 8'd$(node.latency-1));")
        end

        push!(lines, "            end")
    end

    push!(lines, "        end")
    push!(lines, "    end")

    return lines
end

"""
    generate_mux(inputs::Vector{String}, select::String, output::String)

Generate a multiplexer.
"""
function generate_mux(inputs::Vector{String}, select::String, output::String)::String
    if length(inputs) == 2
        return "    assign $output = $select ? $(inputs[2]) : $(inputs[1]);"
    else
        lines = String[]
        push!(lines, "    always @(*) begin")
        push!(lines, "        case ($select)")
        for (i, inp) in enumerate(inputs)
            push!(lines, "            $(length(inputs))'d$(i-1): $output = $inp;")
        end
        push!(lines, "            default: $output = $(inputs[1]);")
        push!(lines, "        endcase")
        push!(lines, "    end")
        return join(lines, "\n")
    end
end

"""
    generate_alu(cdfg::CDFG, rtl::RTLModule)

Generate a shared ALU for resource-bound operations (if using resource sharing).
"""
function generate_alu(cdfg::CDFG, rtl::RTLModule)::String
    lines = String[]

    # Find all operations bound to the same ALU instance
    alu_ops = [n for n in cdfg.nodes if n.bound_resource == RES_ALU]

    if isempty(alu_ops)
        return ""
    end

    # Group by instance
    instances = Dict{Int, Vector{DFGNode}}()
    for op in alu_ops
        inst = op.resource_instance
        if !haskey(instances, inst)
            instances[inst] = DFGNode[]
        end
        push!(instances[inst], op)
    end

    # Generate shared ALU for each instance
    for (inst, ops) in instances
        if length(ops) > 1
            alu_code = generate_shared_alu(inst, ops, cdfg, rtl)
            push!(lines, alu_code)
        end
    end

    return join(lines, "\n")
end

"""
    generate_shared_alu(instance::Int, ops::Vector{DFGNode}, cdfg::CDFG, rtl::RTLModule)

Generate a time-multiplexed ALU for shared operations.
"""
function generate_shared_alu(instance::Int, ops::Vector{DFGNode}, cdfg::CDFG, rtl::RTLModule)::String
    lines = String[]

    # Determine the maximum operand width
    max_width = maximum(n.bit_width for n in ops)

    push!(lines, "    // Shared ALU instance $instance")
    push!(lines, "    reg [$(max_width-1):0] alu$(instance)_a, alu$(instance)_b;")
    push!(lines, "    reg [3:0] alu$(instance)_op;")
    push!(lines, "    wire [$(max_width-1):0] alu$(instance)_result;")
    push!(lines, "")

    # ALU operation encoding
    push!(lines, "    // ALU operation select")
    push!(lines, "    always @(*) begin")
    push!(lines, "        alu$(instance)_a = 0;")
    push!(lines, "        alu$(instance)_b = 0;")
    push!(lines, "        alu$(instance)_op = 4'd0;")
    push!(lines, "        ")
    push!(lines, "        case (current_state)")

    for op in ops
        state = cdfg.states[op.state_id]
        state_name = "S_$(uppercase(sanitize_name(state.name)))"
        operands = get_operand_wires(op, cdfg)

        push!(lines, "            $state_name: begin")
        if length(operands) >= 1
            push!(lines, "                alu$(instance)_a = $(operands[1]);")
        end
        if length(operands) >= 2
            push!(lines, "                alu$(instance)_b = $(operands[2]);")
        end
        push!(lines, "                alu$(instance)_op = 4'd$(Int(op.op));")
        push!(lines, "            end")
    end

    push!(lines, "            default: begin end")
    push!(lines, "        endcase")
    push!(lines, "    end")
    push!(lines, "")

    # ALU computation
    push!(lines, "    // ALU computation")
    push!(lines, "    assign alu$(instance)_result = ")
    push!(lines, "        (alu$(instance)_op == 4'd$(Int(OP_ADD))) ? alu$(instance)_a + alu$(instance)_b :")
    push!(lines, "        (alu$(instance)_op == 4'd$(Int(OP_SUB))) ? alu$(instance)_a - alu$(instance)_b :")
    push!(lines, "        (alu$(instance)_op == 4'd$(Int(OP_AND))) ? alu$(instance)_a & alu$(instance)_b :")
    push!(lines, "        (alu$(instance)_op == 4'd$(Int(OP_OR)))  ? alu$(instance)_a | alu$(instance)_b :")
    push!(lines, "        (alu$(instance)_op == 4'd$(Int(OP_XOR))) ? alu$(instance)_a ^ alu$(instance)_b :")
    push!(lines, "        alu$(instance)_a;")

    return join(lines, "\n")
end
