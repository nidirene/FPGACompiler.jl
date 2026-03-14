# FSM Generation
# Generates Verilog FSM from CDFG states

"""
    generate_fsm(cdfg::CDFG, rtl::RTLModule)

Generate FSM Verilog code.
"""
function generate_fsm(cdfg::CDFG, rtl::RTLModule)::String
    lines = String[]

    push!(lines, "    // =========================================================")
    push!(lines, "    // Finite State Machine")
    push!(lines, "    // =========================================================")
    push!(lines, "")

    # State register
    push!(lines, "    // State register")
    push!(lines, "    always @(posedge clk or posedge rst) begin")
    push!(lines, "        if (rst) begin")
    push!(lines, "            current_state <= IDLE;")
    push!(lines, "            cycle_count <= 8'd0;")
    push!(lines, "        end else begin")
    push!(lines, "            current_state <= next_state;")
    push!(lines, "            if (current_state != next_state)")
    push!(lines, "                cycle_count <= 8'd0;")
    push!(lines, "            else")
    push!(lines, "                cycle_count <= cycle_count + 8'd1;")
    push!(lines, "        end")
    push!(lines, "    end")
    push!(lines, "")

    # Next state logic
    push!(lines, "    // Next state logic")
    push!(lines, "    always @(*) begin")
    push!(lines, "        next_state = current_state;")
    push!(lines, "        ")
    push!(lines, "        case (current_state)")

    # IDLE state
    push!(lines, "            IDLE: begin")
    push!(lines, "                if (start)")
    if !isempty(cdfg.states)
        first_state = "S_$(uppercase(sanitize_name(cdfg.states[cdfg.entry_state_id].name)))"
        push!(lines, "                    next_state = $first_state;")
    else
        push!(lines, "                    next_state = DONE;")
    end
    push!(lines, "            end")
    push!(lines, "")

    # Generate transitions for each state
    for state in cdfg.states
        state_name = "S_$(uppercase(sanitize_name(state.name)))"
        state_transitions = generate_state_transitions(state, cdfg, rtl)
        push!(lines, "            $state_name: begin")
        append!(lines, state_transitions)
        push!(lines, "            end")
        push!(lines, "")
    end

    # DONE state
    push!(lines, "            DONE: begin")
    push!(lines, "                if (!start)")
    push!(lines, "                    next_state = IDLE;")
    push!(lines, "            end")
    push!(lines, "")

    push!(lines, "            default: next_state = IDLE;")
    push!(lines, "        endcase")
    push!(lines, "    end")

    return join(lines, "\n")
end

"""
    generate_state_transitions(state::FSMState, cdfg::CDFG, rtl::RTLModule)

Generate transition logic for a single state.
"""
function generate_state_transitions(state::FSMState, cdfg::CDFG, rtl::RTLModule)::Vector{String}
    lines = String[]

    # Calculate cycles needed for this state
    state_cycles = calculate_state_cycles(state, cdfg)

    if state_cycles > 1
        # Multi-cycle state: wait for operations to complete
        push!(lines, "                // Wait for $(state_cycles) cycles")
        push!(lines, "                if (cycle_count >= 8'd$(state_cycles - 1)) begin")
    end

    if isempty(state.successor_ids)
        # Exit state - go to DONE
        if state_cycles > 1
            push!(lines, "                    next_state = DONE;")
            push!(lines, "                end")
        else
            push!(lines, "                next_state = DONE;")
        end
    elseif length(state.successor_ids) == 1 && state.transition_conditions[1] == -1
        # Unconditional transition
        succ_state = cdfg.states[state.successor_ids[1]]
        succ_name = "S_$(uppercase(sanitize_name(succ_state.name)))"
        if state_cycles > 1
            push!(lines, "                    next_state = $succ_name;")
            push!(lines, "                end")
        else
            push!(lines, "                next_state = $succ_name;")
        end
    else
        # Conditional transition
        cond_signal = find_condition_signal(state, cdfg)

        if state_cycles > 1
            # Inside the cycle wait
            for (i, succ_id) in enumerate(state.successor_ids)
                succ_state = cdfg.states[succ_id]
                succ_name = "S_$(uppercase(sanitize_name(succ_state.name)))"
                cond = state.transition_conditions[i]

                if cond == 1  # True branch
                    push!(lines, "                    if ($cond_signal)")
                    push!(lines, "                        next_state = $succ_name;")
                elseif cond == 0  # False branch
                    push!(lines, "                    else")
                    push!(lines, "                        next_state = $succ_name;")
                end
            end
            push!(lines, "                end")
        else
            for (i, succ_id) in enumerate(state.successor_ids)
                succ_state = cdfg.states[succ_id]
                succ_name = "S_$(uppercase(sanitize_name(succ_state.name)))"
                cond = state.transition_conditions[i]

                if cond == 1  # True branch
                    push!(lines, "                if ($cond_signal)")
                    push!(lines, "                    next_state = $succ_name;")
                elseif cond == 0  # False branch
                    push!(lines, "                else")
                    push!(lines, "                    next_state = $succ_name;")
                elseif cond == -1  # Unconditional
                    push!(lines, "                next_state = $succ_name;")
                end
            end
        end
    end

    return lines
end

"""
    calculate_state_cycles(state::FSMState, cdfg::CDFG)

Calculate the number of cycles needed for a state.
"""
function calculate_state_cycles(state::FSMState, cdfg::CDFG)::Int
    if isempty(state.operations)
        return 1
    end

    # Find the maximum completion time of operations in this state
    max_completion = 0
    min_start = typemax(Int)

    for op in state.operations
        if op.scheduled_cycle >= 0
            min_start = min(min_start, op.scheduled_cycle)
            completion = op.scheduled_cycle + op.latency
            max_completion = max(max_completion, completion)
        end
    end

    if min_start == typemax(Int)
        return 1
    end

    return max(1, max_completion - min_start)
end

"""
    find_condition_signal(state::FSMState, cdfg::CDFG)

Find the signal that produces the branch condition for a state.
"""
function find_condition_signal(state::FSMState, cdfg::CDFG)::String
    # Look for comparison operations in this state
    for op in state.operations
        if op.op in (OP_CMP, OP_ICMP, OP_FCMP)
            return sanitize_name(op.name)
        end
    end

    # Default to a generic condition
    return "cond_$(state.id)"
end

"""
    generate_fsm_output_logic(cdfg::CDFG, rtl::RTLModule)

Generate FSM output logic (Moore machine outputs).
"""
function generate_fsm_output_logic(cdfg::CDFG, rtl::RTLModule)::String
    lines = String[]

    push!(lines, "    // FSM outputs")
    push!(lines, "    always @(*) begin")
    push!(lines, "        // Default values")
    push!(lines, "        mem_we = 1'b0;")
    push!(lines, "        mem_re = 1'b0;")
    push!(lines, "        ")
    push!(lines, "        case (current_state)")

    for state in cdfg.states
        state_name = "S_$(uppercase(sanitize_name(state.name)))"
        push!(lines, "            $state_name: begin")

        # Check for memory operations
        for op in state.operations
            if op.op == OP_LOAD
                push!(lines, "                mem_re = 1'b1;")
            elseif op.op == OP_STORE
                push!(lines, "                mem_we = 1'b1;")
            end
        end

        push!(lines, "            end")
    end

    push!(lines, "            default: begin")
    push!(lines, "                // Keep defaults")
    push!(lines, "            end")
    push!(lines, "        endcase")
    push!(lines, "    end")

    return join(lines, "\n")
end
