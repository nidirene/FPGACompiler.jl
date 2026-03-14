# Combined Control and Data Flow Graph
# Integrates CFG and DFG into a unified representation

"""
    build_cdfg(llvm_func::LLVM.Function; name::String="")

Build a Combined Control and Data Flow Graph from an LLVM function.
This is the main entry point for CDFG construction.
"""
function build_cdfg(llvm_func::LLVM.Function; name::String="")::CDFG
    # Use function name if not provided
    if isempty(name)
        name = LLVM.name(llvm_func)
        if isempty(name)
            name = "kernel"
        end
    end

    cdfg = CDFG(name)

    # Extract Control Flow Graph (FSM states)
    cdfg.states = extract_cfg(llvm_func)

    # Extract Data Flow Graph (operations and dependencies)
    nodes, edges, value_to_node = extract_dfg(llvm_func, cdfg.states)
    cdfg.nodes = nodes
    cdfg.edges = edges

    # Build Graphs.jl representation
    cdfg.graph = dfg_to_graph(nodes, edges)

    # Set entry and exit states
    if !isempty(cdfg.states)
        cdfg.entry_state_id = 1
        cdfg.exit_state_ids = [s.id for s in get_exit_states(cdfg.states)]
    end

    # Identify input and output nodes
    cdfg.input_nodes = [n for n in nodes if n.op == OP_NOP && startswith(n.name, "arg_")]
    cdfg.output_nodes = find_output_nodes(nodes)
    cdfg.memory_nodes = find_memory_nodes(nodes)

    # Initial analysis
    analyze_cdfg!(cdfg)

    return cdfg
end

"""
    build_cdfg_from_module(llvm_mod::LLVM.Module, func_name::String)

Build CDFG from a specific function in an LLVM module.
"""
function build_cdfg_from_module(llvm_mod::LLVM.Module, func_name::String)::CDFG
    for func in LLVM.functions(llvm_mod)
        if LLVM.name(func) == func_name || occursin(func_name, LLVM.name(func))
            return build_cdfg(func; name=func_name)
        end
    end
    error("Function '$func_name' not found in module")
end

"""
    analyze_cdfg!(cdfg::CDFG)

Perform initial analysis on the CDFG.
"""
function analyze_cdfg!(cdfg::CDFG)
    # Compute critical path
    cdfg.critical_path_length = compute_critical_path_length(cdfg)

    # Estimate total cycles (will be refined by scheduling)
    cdfg.estimated_cycles = estimate_total_cycles(cdfg)

    # Count resource usage
    cdfg.resource_usage = count_resource_usage(cdfg)
end

"""
    compute_critical_path_length(cdfg::CDFG)

Compute the length of the critical path (longest path through the DFG).
"""
function compute_critical_path_length(cdfg::CDFG)::Int
    if isempty(cdfg.nodes)
        return 0
    end

    # Use dynamic programming: longest path in DAG
    # dist[i] = longest path ending at node i
    n = length(cdfg.nodes)
    dist = zeros(Int, n)

    # Topological order
    try
        sorted_indices = topological_sort_by_dfs(cdfg.graph)

        for idx in sorted_indices
            node = cdfg.nodes[idx]
            max_pred_dist = 0

            # Check all predecessors (operands that are DFGNodes)
            for op in node.operands
                if op isa DFGNode
                    pred_idx = findfirst(==(op), cdfg.nodes)
                    if pred_idx !== nothing
                        pred_dist = dist[pred_idx] + op.latency
                        max_pred_dist = max(max_pred_dist, pred_dist)
                    end
                end
            end

            dist[idx] = max_pred_dist
        end

        # Add latency of the last node
        max_dist = 0
        for (i, node) in enumerate(cdfg.nodes)
            total_dist = dist[i] + node.latency
            max_dist = max(max_dist, total_dist)
        end

        return max_dist
    catch
        # If topological sort fails (cycle), return simple estimate
        return sum(n.latency for n in cdfg.nodes)
    end
end

"""
    estimate_total_cycles(cdfg::CDFG)

Estimate total execution cycles based on critical path and state count.
"""
function estimate_total_cycles(cdfg::CDFG)::Int
    # Base estimate: critical path length
    estimate = cdfg.critical_path_length

    # Add overhead for FSM transitions
    estimate += length(cdfg.states) - 1

    # Add memory latency overhead
    num_mem_ops = length(cdfg.memory_nodes)
    estimate += num_mem_ops  # Conservative estimate

    return max(1, estimate)
end

"""
    count_resource_usage(cdfg::CDFG)

Count the number of each resource type needed.
"""
function count_resource_usage(cdfg::CDFG)::Dict{ResourceType, Int}
    usage = Dict{ResourceType, Int}()

    for node in cdfg.nodes
        if node.op == OP_NOP
            continue
        end

        res_type = operation_to_resource(node.op)
        usage[res_type] = get(usage, res_type, 0) + 1
    end

    return usage
end

"""
    get_nodes_in_state(cdfg::CDFG, state_id::Int)

Get all DFG nodes that belong to a specific FSM state.
"""
function get_nodes_in_state(cdfg::CDFG, state_id::Int)::Vector{DFGNode}
    return [n for n in cdfg.nodes if n.state_id == state_id]
end

"""
    get_state_by_id(cdfg::CDFG, state_id::Int)

Get FSM state by ID.
"""
function get_state_by_id(cdfg::CDFG, state_id::Int)::Union{FSMState, Nothing}
    for state in cdfg.states
        if state.id == state_id
            return state
        end
    end
    return nothing
end

"""
    get_predecessors(cdfg::CDFG, node::DFGNode)

Get all predecessor nodes (nodes that this node depends on).
"""
function get_predecessors(cdfg::CDFG, node::DFGNode)::Vector{DFGNode}
    preds = DFGNode[]
    for op in node.operands
        if op isa DFGNode
            push!(preds, op)
        end
    end
    return preds
end

"""
    get_successors(cdfg::CDFG, node::DFGNode)

Get all successor nodes (nodes that depend on this node).
"""
function get_successors(cdfg::CDFG, node::DFGNode)::Vector{DFGNode}
    succs = DFGNode[]
    for edge in cdfg.edges
        if edge.src === node
            push!(succs, edge.dst)
        end
    end
    return succs
end

"""
    find_node_by_name(cdfg::CDFG, name::String)

Find a DFG node by name.
"""
function find_node_by_name(cdfg::CDFG, name::String)::Union{DFGNode, Nothing}
    for node in cdfg.nodes
        if node.name == name
            return node
        end
    end
    return nothing
end

"""
    validate_cdfg(cdfg::CDFG)

Validate the CDFG structure.
Returns a list of validation errors (empty if valid).
"""
function validate_cdfg(cdfg::CDFG)::Vector{String}
    errors = String[]

    # Check for cycles (should be a DAG)
    if !is_directed_acyclic_graph(cdfg.graph)
        push!(errors, "DFG contains cycles - not a valid DAG")
    end

    # Check that all node operands exist
    for node in cdfg.nodes
        for op in node.operands
            if op isa DFGNode && !(op in cdfg.nodes)
                push!(errors, "Node $(node.name) references non-existent operand $(op.name)")
            end
        end
    end

    # Check state consistency
    for state in cdfg.states
        for succ_id in state.successor_ids
            if succ_id < 1 || succ_id > length(cdfg.states)
                push!(errors, "State $(state.name) has invalid successor ID $succ_id")
            end
        end
    end

    # Check that we have an entry state
    if cdfg.entry_state_id < 1 || cdfg.entry_state_id > length(cdfg.states)
        push!(errors, "Invalid entry state ID: $(cdfg.entry_state_id)")
    end

    return errors
end

"""
    is_directed_acyclic_graph(g::SimpleDiGraph)

Check if a directed graph is acyclic.
"""
function is_directed_acyclic_graph(g::SimpleDiGraph)::Bool
    try
        topological_sort_by_dfs(g)
        return true
    catch
        return false
    end
end

"""
    print_cdfg(cdfg::CDFG)

Print the CDFG for debugging.
"""
function print_cdfg(cdfg::CDFG)
    println("Combined Control and Data Flow Graph: $(cdfg.name)")
    println("=" ^ 60)
    println()

    println("Statistics:")
    println("  States: $(length(cdfg.states))")
    println("  Nodes: $(length(cdfg.nodes))")
    println("  Edges: $(length(cdfg.edges))")
    println("  Critical Path: $(cdfg.critical_path_length) cycles")
    println("  Estimated Cycles: $(cdfg.estimated_cycles)")
    println()

    println("Resource Usage:")
    for (res, count) in cdfg.resource_usage
        println("  $res: $count")
    end
    println()

    println("Inputs: $(length(cdfg.input_nodes))")
    for node in cdfg.input_nodes
        println("  $(node.name): $(node.bit_width)-bit")
    end
    println()

    println("Outputs: $(length(cdfg.output_nodes))")
    for node in cdfg.output_nodes
        println("  $(node.name)")
    end
    println()

    print_cfg(cdfg.states)
    println()
    print_dfg(cdfg.nodes, cdfg.edges)
end

"""
    clone_cdfg(cdfg::CDFG)

Create a deep copy of the CDFG.
"""
function clone_cdfg(cdfg::CDFG)::CDFG
    # Create new CDFG
    new_cdfg = CDFG(cdfg.name)

    # Clone nodes
    node_map = Dict{DFGNode, DFGNode}()
    for node in cdfg.nodes
        new_node = DFGNode(node.id, node.op, node.name)
        new_node.result_type = node.result_type
        new_node.bit_width = node.bit_width
        new_node.is_signed = node.is_signed
        new_node.latency = node.latency
        new_node.scheduled_cycle = node.scheduled_cycle
        new_node.state_id = node.state_id
        push!(new_cdfg.nodes, new_node)
        node_map[node] = new_node
    end

    # Clone operand references
    for (old_node, new_node) in node_map
        for op in old_node.operands
            if op isa DFGNode
                push!(new_node.operands, node_map[op])
            else
                push!(new_node.operands, op)
            end
        end
        new_node.operand_indices = copy(old_node.operand_indices)
    end

    # Clone edges
    for edge in cdfg.edges
        new_edge = DFGEdge(node_map[edge.src], node_map[edge.dst], edge.operand_index)
        push!(new_cdfg.edges, new_edge)
    end

    # Clone states
    for state in cdfg.states
        new_state = FSMState(state.id, state.name)
        new_state.predecessor_ids = copy(state.predecessor_ids)
        new_state.successor_ids = copy(state.successor_ids)
        new_state.transition_conditions = copy(state.transition_conditions)
        new_state.is_loop_header = state.is_loop_header
        new_state.is_loop_latch = state.is_loop_latch
        new_state.loop_depth = state.loop_depth
        new_state.operations = [node_map[n] for n in state.operations if haskey(node_map, n)]
        push!(new_cdfg.states, new_state)
    end

    # Copy other fields
    new_cdfg.graph = copy(cdfg.graph)
    new_cdfg.entry_state_id = cdfg.entry_state_id
    new_cdfg.exit_state_ids = copy(cdfg.exit_state_ids)
    new_cdfg.input_nodes = [node_map[n] for n in cdfg.input_nodes if haskey(node_map, n)]
    new_cdfg.output_nodes = [node_map[n] for n in cdfg.output_nodes if haskey(node_map, n)]
    new_cdfg.memory_nodes = [node_map[n] for n in cdfg.memory_nodes if haskey(node_map, n)]
    new_cdfg.critical_path_length = cdfg.critical_path_length
    new_cdfg.estimated_cycles = cdfg.estimated_cycles
    new_cdfg.resource_usage = copy(cdfg.resource_usage)
    new_cdfg.target_ii = cdfg.target_ii

    return new_cdfg
end
