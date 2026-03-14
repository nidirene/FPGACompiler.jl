# Control Flow Graph Extraction
# Extracts FSM states from LLVM basic blocks

"""
    extract_cfg(llvm_func::LLVM.Function)

Extract Control Flow Graph from an LLVM function.
Each basic block becomes an FSM state.

Returns a vector of FSMState objects representing the control flow.
"""
function extract_cfg(llvm_func::LLVM.Function)::Vector{FSMState}
    states = FSMState[]
    block_to_state = Dict{LLVM.BasicBlock, FSMState}()
    name_to_state = Dict{String, FSMState}()

    # First pass: create states for each basic block
    for (id, block) in enumerate(LLVM.blocks(llvm_func))
        block_name = LLVM.name(block)
        if isempty(block_name)
            block_name = "bb_$id"
        end

        state = FSMState(id, block_name)
        push!(states, state)
        block_to_state[block] = state
        name_to_state[block_name] = state
    end

    # Second pass: connect states based on terminators
    for block in LLVM.blocks(llvm_func)
        state = block_to_state[block]
        terminator = LLVM.terminator(block)

        if terminator !== nothing
            connect_successors!(state, terminator, block_to_state, states)
        end
    end

    # Third pass: set up predecessor lists
    for state in states
        for succ_id in state.successor_ids
            succ_state = states[succ_id]
            if !(state.id in succ_state.predecessor_ids)
                push!(succ_state.predecessor_ids, state.id)
            end
        end
    end

    # Fourth pass: detect loops
    detect_loops!(states)

    return states
end

"""
    connect_successors!(state, terminator, block_to_state, states)

Connect state to its successors based on the terminator instruction.
"""
function connect_successors!(state::FSMState,
                             terminator::LLVM.Instruction,
                             block_to_state::Dict{LLVM.BasicBlock, FSMState},
                             states::Vector{FSMState})

    opcode = LLVM.opcode(terminator)

    if opcode == LLVM.API.LLVMBr
        # Branch instruction
        num_operands = length(collect(LLVM.operands(terminator)))

        if num_operands == 1
            # Unconditional branch
            target = LLVM.operands(terminator)[1]
            if target isa LLVM.BasicBlock && haskey(block_to_state, target)
                succ_state = block_to_state[target]
                push!(state.successor_ids, succ_state.id)
                push!(state.transition_conditions, -1)  # Unconditional
            end
        elseif num_operands == 3
            # Conditional branch: condition, true_block, false_block
            ops = collect(LLVM.operands(terminator))
            # Order in LLVM IR: true_dest, false_dest, condition
            true_block = ops[1]
            false_block = ops[2]
            # condition = ops[3] - we'll handle this in DFG

            if true_block isa LLVM.BasicBlock && haskey(block_to_state, true_block)
                succ_state = block_to_state[true_block]
                push!(state.successor_ids, succ_state.id)
                push!(state.transition_conditions, 1)  # True condition
            end

            if false_block isa LLVM.BasicBlock && haskey(block_to_state, false_block)
                succ_state = block_to_state[false_block]
                push!(state.successor_ids, succ_state.id)
                push!(state.transition_conditions, 0)  # False condition
            end
        end

    elseif opcode == LLVM.API.LLVMSwitch
        # Switch instruction
        # First operand is condition, second is default, rest are case/block pairs
        ops = collect(LLVM.operands(terminator))
        if length(ops) >= 2
            default_block = ops[2]
            if default_block isa LLVM.BasicBlock && haskey(block_to_state, default_block)
                succ_state = block_to_state[default_block]
                push!(state.successor_ids, succ_state.id)
                push!(state.transition_conditions, -2)  # Default case
            end

            # Handle case blocks (pairs of value, block)
            for i in 3:2:length(ops)
                if i+1 <= length(ops)
                    case_block = ops[i+1]
                    if case_block isa LLVM.BasicBlock && haskey(block_to_state, case_block)
                        succ_state = block_to_state[case_block]
                        push!(state.successor_ids, succ_state.id)
                        push!(state.transition_conditions, i)  # Case index
                    end
                end
            end
        end

    elseif opcode == LLVM.API.LLVMRet
        # Return instruction - no successors
        # Mark as exit state (handled in CDFG construction)

    elseif opcode == LLVM.API.LLVMUnreachable
        # Unreachable - no successors
    end
end

"""
    detect_loops!(states)

Detect loops in the CFG using back-edge analysis.
A back-edge is an edge from a node to one of its dominators.
"""
function detect_loops!(states::Vector{FSMState})
    if isempty(states)
        return
    end

    # Simple back-edge detection: edge to a state with lower ID
    # (assumes states are in topological order from LLVM)
    for state in states
        for succ_id in state.successor_ids
            if succ_id <= state.id
                # Back edge detected
                state.is_loop_latch = true
                states[succ_id].is_loop_header = true
            end
        end
    end

    # Compute loop depth using a simple algorithm
    compute_loop_depth!(states)
end

"""
    compute_loop_depth!(states)

Compute the loop nesting depth for each state.
"""
function compute_loop_depth!(states::Vector{FSMState})
    # Find all loop headers
    headers = [s for s in states if s.is_loop_header]

    for header in headers
        # Find all states in this loop using a simple reachability check
        loop_states = find_loop_body(states, header)

        for ls in loop_states
            ls.loop_depth += 1
        end
    end
end

"""
    find_loop_body(states, header)

Find all states that belong to the loop with the given header.
Uses backward reachability from loop latches.
"""
function find_loop_body(states::Vector{FSMState}, header::FSMState)::Vector{FSMState}
    # Find latches that branch back to this header
    latches = FSMState[]
    for state in states
        if state.is_loop_latch && header.id in state.successor_ids
            push!(latches, state)
        end
    end

    if isempty(latches)
        return [header]
    end

    # Backward reachability from latches to header
    in_loop = Set{Int}([header.id])
    worklist = [l.id for l in latches]

    while !isempty(worklist)
        current_id = pop!(worklist)
        if current_id in in_loop
            continue
        end

        push!(in_loop, current_id)

        # Add predecessors (except going past header)
        current = states[current_id]
        for pred_id in current.predecessor_ids
            if !(pred_id in in_loop) && pred_id >= header.id
                push!(worklist, pred_id)
            end
        end
    end

    return [states[id] for id in in_loop]
end

"""
    get_entry_state(states)

Get the entry state (first block of the function).
"""
function get_entry_state(states::Vector{FSMState})::Union{FSMState, Nothing}
    if isempty(states)
        return nothing
    end
    return states[1]
end

"""
    get_exit_states(states)

Get all exit states (states with return instructions).
"""
function get_exit_states(states::Vector{FSMState})::Vector{FSMState}
    return [s for s in states if isempty(s.successor_ids)]
end

"""
    cfg_to_graph(states)

Convert FSM states to a Graphs.jl DiGraph for analysis.
"""
function cfg_to_graph(states::Vector{FSMState})::SimpleDiGraph{Int}
    n = length(states)
    g = SimpleDiGraph{Int}(n)

    for state in states
        for succ_id in state.successor_ids
            add_edge!(g, state.id, succ_id)
        end
    end

    return g
end

"""
    print_cfg(states)

Print the CFG for debugging.
"""
function print_cfg(states::Vector{FSMState})
    println("Control Flow Graph:")
    println("=" ^ 50)

    for state in states
        flags = String[]
        state.is_loop_header && push!(flags, "HEADER")
        state.is_loop_latch && push!(flags, "LATCH")
        flag_str = isempty(flags) ? "" : " [$(join(flags, ", "))]"

        println("State $(state.id): $(state.name)$flag_str (depth=$(state.loop_depth))")

        if !isempty(state.predecessor_ids)
            println("  Predecessors: $(state.predecessor_ids)")
        end

        if !isempty(state.successor_ids)
            for (i, succ_id) in enumerate(state.successor_ids)
                cond = state.transition_conditions[i]
                cond_str = cond == -1 ? "unconditional" :
                          cond == -2 ? "default" :
                          cond == 1 ? "if true" :
                          cond == 0 ? "if false" : "case $cond"
                println("  -> State $succ_id ($cond_str)")
            end
        else
            println("  -> EXIT")
        end
    end
end
