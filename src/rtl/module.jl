# RTL Module Generation
# Creates RTL module structure from scheduled CDFG

"""
    generate_rtl(cdfg::CDFG, schedule::Schedule; options::HLSOptions=HLSOptions())

Generate RTL module from a scheduled CDFG.
Returns an RTLModule containing all generated Verilog components.
"""
function generate_rtl(cdfg::CDFG, schedule::Schedule; options::HLSOptions=HLSOptions())::RTLModule
    rtl = RTLModule(cdfg.name)

    # Generate ports
    generate_ports!(rtl, cdfg)

    # Generate signals (wires and registers)
    generate_signals!(rtl, cdfg, schedule)

    # Generate state encoding
    generate_state_encoding!(rtl, cdfg)

    # Generate FSM logic
    rtl.fsm_logic = generate_fsm(cdfg, rtl)

    # Generate datapath logic
    rtl.datapath_logic = generate_datapath(cdfg, schedule, rtl)

    # Generate memory interface
    rtl.memory_logic = generate_memory_interface(cdfg, rtl)

    # Generate output logic
    rtl.output_logic = generate_output_logic(cdfg, rtl)

    # Generate declarations
    rtl.port_declarations = generate_port_declarations(rtl)
    rtl.signal_declarations = generate_signal_declarations(rtl)
    rtl.parameter_declarations = generate_parameter_declarations(rtl)

    return rtl
end

"""
    generate_ports!(rtl::RTLModule, cdfg::CDFG)

Generate port definitions for the module.
"""
function generate_ports!(rtl::RTLModule, cdfg::CDFG)
    # Clock and reset are always present
    push!(rtl.ports, RTLPort("clk", 1, true, false))
    push!(rtl.ports, RTLPort("rst", 1, true, false))

    # Start signal
    push!(rtl.ports, RTLPort("start", 1, true, false))

    # Done signal
    push!(rtl.ports, RTLPort("done", 1, false, false))

    # Input ports from function arguments
    for (i, input_node) in enumerate(cdfg.input_nodes)
        port_name = sanitize_name(input_node.name)
        bit_width = max(1, input_node.bit_width)
        is_signed = input_node.is_signed
        push!(rtl.ports, RTLPort(port_name, bit_width, true, is_signed))
    end

    # Output ports from stores or return values
    for (i, output_node) in enumerate(cdfg.output_nodes)
        port_name = "out_$(i)"
        bit_width = max(1, output_node.bit_width)
        is_signed = output_node.is_signed
        push!(rtl.ports, RTLPort(port_name, bit_width, false, is_signed))
    end

    # Memory interface ports (if needed)
    if !isempty(cdfg.memory_nodes)
        # Memory address
        push!(rtl.ports, RTLPort("mem_addr", 32, false, false))
        # Memory write data
        push!(rtl.ports, RTLPort("mem_wdata", 32, false, false))
        # Memory read data
        push!(rtl.ports, RTLPort("mem_rdata", 32, true, false))
        # Memory write enable
        push!(rtl.ports, RTLPort("mem_we", 1, false, false))
        # Memory read enable
        push!(rtl.ports, RTLPort("mem_re", 1, false, false))
    end
end

"""
    generate_signals!(rtl::RTLModule, cdfg::CDFG, schedule::Schedule)

Generate internal signals (wires and registers).
"""
function generate_signals!(rtl::RTLModule, cdfg::CDFG, schedule::Schedule)
    # State register
    state_width = max(1, ceil(Int, log2(length(cdfg.states) + 1)))
    rtl.state_width = state_width
    push!(rtl.signals, RTLSignal("current_state", state_width, true, false, 0))
    push!(rtl.signals, RTLSignal("next_state", state_width, false, false, nothing))

    # Cycle counter (for multi-cycle states)
    push!(rtl.signals, RTLSignal("cycle_count", 8, true, false, 0))

    # Generate a wire/register for each DFG node
    for node in cdfg.nodes
        if node.op == OP_NOP && startswith(node.name, "arg_")
            continue  # Arguments are ports, not internal signals
        end

        signal_name = sanitize_name(node.name)
        bit_width = max(1, node.bit_width)
        is_signed = node.is_signed

        # Determine if this needs to be a register or wire
        needs_register = node.latency > 0 || node.live_end > node.live_start + 1

        push!(rtl.signals, RTLSignal(signal_name, bit_width, needs_register, is_signed, nothing))

        # Add valid signal for pipelined operations
        if node.latency > 1
            push!(rtl.signals, RTLSignal("$(signal_name)_valid", 1, true, false, 0))
        end
    end

    # Pipeline registers for multi-cycle operations
    for node in cdfg.nodes
        if node.latency > 1
            for stage in 1:(node.latency-1)
                signal_name = "$(sanitize_name(node.name))_stage$(stage)"
                push!(rtl.signals, RTLSignal(signal_name, max(1, node.bit_width), true, node.is_signed, nothing))
            end
        end
    end
end

"""
    generate_state_encoding!(rtl::RTLModule, cdfg::CDFG)

Generate state encoding (one-hot or binary).
"""
function generate_state_encoding!(rtl::RTLModule, cdfg::CDFG)
    rtl.state_names = String[]
    rtl.state_encoding = Dict{String, Int}()

    # Add IDLE state
    push!(rtl.state_names, "IDLE")
    rtl.state_encoding["IDLE"] = 0

    # Add states from CDFG
    for (i, state) in enumerate(cdfg.states)
        state_name = "S_$(uppercase(sanitize_name(state.name)))"
        push!(rtl.state_names, state_name)
        rtl.state_encoding[state_name] = i
    end

    # Add DONE state
    push!(rtl.state_names, "DONE")
    rtl.state_encoding["DONE"] = length(cdfg.states) + 1
end

"""
    generate_port_declarations(rtl::RTLModule)

Generate Verilog port declarations.
"""
function generate_port_declarations(rtl::RTLModule)::String
    lines = String[]

    for port in rtl.ports
        direction = port.is_input ? "input" : "output"
        wire_or_reg = port.is_input ? "wire" : "reg"
        signed_str = port.is_signed ? "signed " : ""

        if port.bit_width == 1
            push!(lines, "    $direction $wire_or_reg $(signed_str)$(port.name)")
        else
            push!(lines, "    $direction $wire_or_reg $(signed_str)[$(port.bit_width-1):0] $(port.name)")
        end
    end

    return join(lines, ",\n")
end

"""
    generate_signal_declarations(rtl::RTLModule)

Generate Verilog signal declarations (wires and registers).
"""
function generate_signal_declarations(rtl::RTLModule)::String
    lines = String[]

    for signal in rtl.signals
        type_str = signal.is_register ? "reg" : "wire"
        signed_str = signal.is_signed ? "signed " : ""

        if signal.bit_width == 1
            decl = "$type_str $(signed_str)$(signal.name);"
        else
            decl = "$type_str $(signed_str)[$(signal.bit_width-1):0] $(signal.name);"
        end
        push!(lines, "    $decl")
    end

    return join(lines, "\n")
end

"""
    generate_parameter_declarations(rtl::RTLModule)

Generate Verilog parameter declarations for state encoding.
"""
function generate_parameter_declarations(rtl::RTLModule)::String
    lines = String[]

    for state_name in rtl.state_names
        value = rtl.state_encoding[state_name]
        push!(lines, "    localparam $(state_name) = $(rtl.state_width)'d$(value);")
    end

    return join(lines, "\n")
end

"""
    generate_output_logic(cdfg::CDFG, rtl::RTLModule)

Generate output assignment logic.
"""
function generate_output_logic(cdfg::CDFG, rtl::RTLModule)::String
    lines = String[]

    push!(lines, "    // Output assignments")

    # Done signal
    push!(lines, "    assign done = (current_state == DONE);")

    # Output port assignments
    for (i, output_node) in enumerate(cdfg.output_nodes)
        out_port = "out_$(i)"
        signal_name = sanitize_name(output_node.name)
        push!(lines, "    assign $out_port = $signal_name;")
    end

    return join(lines, "\n")
end

"""
    sanitize_name(name::String)

Sanitize a name for use as a Verilog identifier.
"""
function sanitize_name(name::String)::String
    # Replace invalid characters
    sanitized = replace(name, r"[^a-zA-Z0-9_]" => "_")

    # Ensure it doesn't start with a number
    if !isempty(sanitized) && isdigit(sanitized[1])
        sanitized = "_" * sanitized
    end

    # Avoid Verilog keywords
    keywords = ["module", "input", "output", "wire", "reg", "always", "begin", "end",
                "if", "else", "case", "endcase", "assign", "initial", "posedge", "negedge"]
    if lowercase(sanitized) in keywords
        sanitized = sanitized * "_sig"
    end

    return sanitized
end

"""
    get_wire_name(node::DFGNode)

Get the Verilog wire/register name for a DFG node.
"""
function get_wire_name(node::DFGNode)::String
    if node.op == OP_NOP && startswith(node.name, "arg_")
        return sanitize_name(node.name)
    end
    return sanitize_name(node.name)
end

"""
    get_operand_wire(operand::Union{DFGNode, HLSConstant})

Get the Verilog representation of an operand.
"""
function get_operand_wire(operand::Union{DFGNode, HLSConstant})::String
    if operand isa DFGNode
        return get_wire_name(operand)
    elseif operand isa HLSConstant
        if operand.value isa Integer
            return "$(operand.bit_width)'d$(operand.value)"
        elseif operand.value isa AbstractFloat
            # Convert float to fixed-point or use $bitstoreal
            int_val = reinterpret(UInt32, Float32(operand.value))
            return "32'h$(string(int_val, base=16))"
        else
            return "0"
        end
    else
        return "0"
    end
end
