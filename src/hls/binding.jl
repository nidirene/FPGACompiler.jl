# Resource Binding
# Maps operations to physical hardware resources

"""
    bind_resources!(cdfg::CDFG, schedule::Schedule)

Bind operations to physical hardware resource instances.
Uses left-edge algorithm to minimize resource usage through sharing.
"""
function bind_resources!(cdfg::CDFG, schedule::Schedule)
    # Group operations by resource type
    ops_by_type = Dict{ResourceType, Vector{DFGNode}}()

    for node in cdfg.nodes
        if node.op == OP_NOP || is_control_op(node.op)
            continue
        end

        res_type = operation_to_resource(node.op)
        if !haskey(ops_by_type, res_type)
            ops_by_type[res_type] = DFGNode[]
        end
        push!(ops_by_type[res_type], node)
    end

    # For each resource type, perform binding
    for (res_type, ops) in ops_by_type
        bind_left_edge!(ops, res_type)
    end

    # Allocate registers for values that need to persist across cycles
    allocate_registers!(cdfg, schedule)
end

"""
    bind_left_edge!(operations, res_type)

Left-edge algorithm for resource binding.
Minimizes resource instances by sharing when operation lifetimes don't overlap.
"""
function bind_left_edge!(operations::Vector{DFGNode}, res_type::ResourceType)
    if isempty(operations)
        return
    end

    # Sort operations by start time (scheduled cycle)
    sorted_ops = sort(operations, by=n -> n.scheduled_cycle)

    # Track end times for each resource instance
    # instance_end_times[i] = cycle when instance i becomes free
    instance_end_times = Int[]

    for node in sorted_ops
        start = node.scheduled_cycle
        duration = max(1, node.latency)  # At least 1 cycle

        # Find an available instance
        bound = false
        for (i, end_time) in enumerate(instance_end_times)
            if end_time <= start
                # This instance is free - bind to it
                node.bound_resource = res_type
                node.resource_instance = i
                instance_end_times[i] = start + duration
                bound = true
                break
            end
        end

        if !bound
            # Need a new instance
            push!(instance_end_times, start + duration)
            node.bound_resource = res_type
            node.resource_instance = length(instance_end_times)
        end
    end
end

"""
    allocate_registers!(cdfg::CDFG, schedule::Schedule)

Allocate registers for values that need to persist across clock cycles.
"""
function allocate_registers!(cdfg::CDFG, schedule::Schedule)
    # Calculate liveness for each node
    calculate_liveness!(cdfg, schedule)

    # Group values by their live range
    live_ranges = Dict{Tuple{Int, Int}, Vector{DFGNode}}()

    for node in cdfg.nodes
        if node.live_start >= 0 && node.live_end > node.live_start
            key = (node.live_start, node.live_end)
            if !haskey(live_ranges, key)
                live_ranges[key] = DFGNode[]
            end
            push!(live_ranges[key], node)
        end
    end

    # For now, each value gets its own register
    # Could optimize using graph coloring for register sharing
    register_count = 0
    for node in cdfg.nodes
        if node.live_end > node.live_start + node.latency
            # Value needs to be stored in a register
            register_count += 1
            # Could store register assignment in node metadata
        end
    end
end

"""
    calculate_liveness!(cdfg::CDFG, schedule::Schedule)

Calculate when each value is live (from production to last use).
"""
function calculate_liveness!(cdfg::CDFG, schedule::Schedule)
    for node in cdfg.nodes
        # Value becomes live when the operation completes
        node.live_start = node.scheduled_cycle + node.latency

        # Find the latest use
        successors = get_successors(cdfg, node)
        if isempty(successors)
            # No users - value is only live for the completion cycle
            node.live_end = node.live_start
        else
            # Value lives until the last successor starts
            node.live_end = maximum(s.scheduled_cycle for s in successors)
        end
    end
end

"""
    get_resource_count(cdfg::CDFG)

Get the number of each resource type needed after binding.
"""
function get_resource_count(cdfg::CDFG)::Dict{ResourceType, Int}
    counts = Dict{ResourceType, Int}()

    for node in cdfg.nodes
        if node.bound_resource !== nothing
            max_instance = get(counts, node.bound_resource, 0)
            counts[node.bound_resource] = max(max_instance, node.resource_instance)
        end
    end

    return counts
end

"""
    get_binding_info(node::DFGNode)

Get human-readable binding information for a node.
"""
function get_binding_info(node::DFGNode)::String
    if node.bound_resource === nothing
        return "unbound"
    end
    return "$(node.bound_resource)_$(node.resource_instance)"
end

"""
    print_binding(cdfg::CDFG)

Print resource binding information.
"""
function print_binding(cdfg::CDFG)
    println("Resource Binding:")
    println("=" ^ 50)

    resource_counts = get_resource_count(cdfg)
    println("Resource Usage:")
    for (res, count) in resource_counts
        println("  $res: $count instances")
    end
    println()

    println("Node Bindings:")
    for node in cdfg.nodes
        if node.bound_resource !== nothing
            println("  $(node.name): $(get_binding_info(node)) @ cycle $(node.scheduled_cycle)")
        end
    end
end

# ============================================================================
# Chaining Support
# ============================================================================

"""
    find_chaining_opportunities(cdfg::CDFG, clock_period_ns::Float64)

Find operations that can be chained (executed in same cycle).
Returns pairs of (producer, consumer) that can be chained.
"""
function find_chaining_opportunities(cdfg::CDFG, clock_period_ns::Float64)::Vector{Tuple{DFGNode, DFGNode}}
    chains = Tuple{DFGNode, DFGNode}[]

    # Typical operation delays in nanoseconds (for 100MHz)
    op_delays = Dict{OperationType, Float64}(
        OP_ADD => 1.0,
        OP_SUB => 1.0,
        OP_AND => 0.5,
        OP_OR => 0.5,
        OP_XOR => 0.5,
        OP_SHL => 0.8,
        OP_SHR => 0.8,
        OP_CMP => 1.2,
        OP_ICMP => 1.2,
        OP_SELECT => 0.8,
        OP_MUL => 3.0,  # DSP is fast
        OP_ZEXT => 0.0,
        OP_SEXT => 0.2,
        OP_TRUNC => 0.0,
    )

    for edge in cdfg.edges
        src = edge.src
        dst = edge.dst

        src_delay = get(op_delays, src.op, clock_period_ns)
        dst_delay = get(op_delays, dst.op, clock_period_ns)

        # Can chain if total delay fits in clock period
        if src_delay + dst_delay <= clock_period_ns
            push!(chains, (src, dst))
        end
    end

    return chains
end

"""
    apply_chaining!(cdfg::CDFG, chains::Vector{Tuple{DFGNode, DFGNode}})

Apply chaining by scheduling chained operations in the same cycle.
"""
function apply_chaining!(cdfg::CDFG, chains::Vector{Tuple{DFGNode, DFGNode}})
    for (src, dst) in chains
        # If src has 0 latency after chaining, schedule dst at same cycle
        if src.scheduled_cycle >= 0
            # Check if all other predecessors of dst are ready
            all_ready = all(get_predecessors(cdfg, dst)) do pred
                if pred === src
                    return true  # Will be chained
                end
                return pred.scheduled_cycle + pred.latency <= src.scheduled_cycle
            end

            if all_ready
                dst.scheduled_cycle = src.scheduled_cycle
            end
        end
    end
end

# ============================================================================
# Memory Port Binding
# ============================================================================

"""
    bind_memory_ports!(cdfg::CDFG, schedule::Schedule, num_read_ports::Int, num_write_ports::Int)

Bind memory operations to physical BRAM ports.
"""
function bind_memory_ports!(cdfg::CDFG, schedule::Schedule,
                            num_read_ports::Int, num_write_ports::Int)

    # Separate loads and stores
    loads = [n for n in cdfg.memory_nodes if n.op == OP_LOAD]
    stores = [n for n in cdfg.memory_nodes if n.op == OP_STORE]

    # Bind read ports
    if num_read_ports > 0
        bind_memory_ops_to_ports!(loads, num_read_ports, :read)
    end

    # Bind write ports
    if num_write_ports > 0
        bind_memory_ops_to_ports!(stores, num_write_ports, :write)
    end
end

"""
    bind_memory_ops_to_ports!(ops, num_ports, port_type)

Bind memory operations to ports using left-edge algorithm.
"""
function bind_memory_ops_to_ports!(ops::Vector{DFGNode}, num_ports::Int, port_type::Symbol)
    if isempty(ops)
        return
    end

    # Sort by scheduled cycle
    sorted_ops = sort(ops, by=n -> n.scheduled_cycle)

    # Track when each port becomes free
    port_end_times = zeros(Int, num_ports)

    for node in sorted_ops
        start = node.scheduled_cycle

        # Find an available port
        for port in 1:num_ports
            if port_end_times[port] <= start
                # Bind to this port
                node.resource_instance = port
                port_end_times[port] = start + node.latency
                break
            end
        end
    end
end
