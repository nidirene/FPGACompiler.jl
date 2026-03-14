# Scheduling Algorithms for HLS
# Implements ASAP, ALAP, List Scheduling, and ILP-based scheduling

using JuMP
using HiGHS

# ============================================================================
# ASAP Scheduling (As-Soon-As-Possible)
# ============================================================================

"""
    schedule_asap!(cdfg::CDFG)

Perform As-Soon-As-Possible scheduling.
Each operation is scheduled at the earliest possible cycle.
"""
function schedule_asap!(cdfg::CDFG)::Schedule
    schedule = Schedule(cdfg)

    # Initialize all nodes to unscheduled
    for node in cdfg.nodes
        node.scheduled_cycle = -1
        node.asap_cycle = -1
    end

    # Topological sort - try using graph if available, otherwise sort by ID
    sorted_nodes = if nv(cdfg.graph) > 0 && nv(cdfg.graph) == length(cdfg.nodes)
        try
            sorted_indices = topological_sort_by_dfs(cdfg.graph)
            [cdfg.nodes[i] for i in sorted_indices]
        catch
            sort(cdfg.nodes, by=n->n.id)
        end
    else
        # Fallback: sort by ID
        sort(cdfg.nodes, by=n->n.id)
    end

    # Schedule in topological order
    for node in sorted_nodes
        if isempty(node.operands)
            # No dependencies - schedule at cycle 0
            node.scheduled_cycle = 0
            node.asap_cycle = 0
        else
            # Schedule after all operands are ready
            earliest = 0
            for op in node.operands
                if op isa DFGNode
                    # Must wait for operand to complete
                    ready_time = op.scheduled_cycle + op.latency
                    earliest = max(earliest, ready_time)
                end
            end
            node.scheduled_cycle = earliest
            node.asap_cycle = earliest
        end
    end

    # Build schedule structure
    build_schedule_structure!(schedule, cdfg)

    return schedule
end

# ============================================================================
# ALAP Scheduling (As-Late-As-Possible)
# ============================================================================

"""
    schedule_alap!(cdfg::CDFG, max_cycles::Int=-1)

Perform As-Late-As-Possible scheduling.
Each operation is scheduled at the latest possible cycle.
If max_cycles is -1, uses ASAP schedule to determine the bound.
"""
function schedule_alap!(cdfg::CDFG, max_cycles::Int=-1)::Schedule
    # First run ASAP to get the minimum latency bound
    if max_cycles == -1
        asap_schedule = schedule_asap!(cdfg)
        max_cycles = asap_schedule.total_cycles
    end

    schedule = Schedule(cdfg)

    # Initialize
    for node in cdfg.nodes
        node.alap_cycle = max_cycles
    end

    # Reverse topological sort
    try
        sorted_indices = reverse(topological_sort_by_dfs(cdfg.graph))
        sorted_nodes = [cdfg.nodes[i] for i in sorted_indices]
    catch
        sorted_nodes = reverse(sort(cdfg.nodes, by=n->n.id))
    end

    # Schedule in reverse topological order
    for node in sorted_nodes
        successors = get_successors(cdfg, node)

        if isempty(successors)
            # No users - schedule at max_cycles minus latency
            node.alap_cycle = max_cycles - node.latency
        else
            # Schedule before all successors
            latest = max_cycles
            for succ in successors
                # Must complete before successor starts
                required_time = succ.alap_cycle - node.latency
                latest = min(latest, required_time)
            end
            node.alap_cycle = max(0, latest)
        end

        node.scheduled_cycle = node.alap_cycle
    end

    # Build schedule structure
    build_schedule_structure!(schedule, cdfg)

    return schedule
end

# ============================================================================
# Mobility Calculation
# ============================================================================

"""
    calculate_mobility!(cdfg::CDFG)

Calculate the scheduling mobility (slack) for each node.
Mobility = ALAP - ASAP. Higher mobility means more scheduling freedom.
"""
function calculate_mobility!(cdfg::CDFG)
    # Run ASAP first
    schedule_asap!(cdfg)

    # Save ASAP times
    asap_times = Dict{DFGNode, Int}()
    for node in cdfg.nodes
        asap_times[node] = node.scheduled_cycle
    end

    # Run ALAP
    max_cycles = maximum(n.scheduled_cycle + n.latency for n in cdfg.nodes)
    schedule_alap!(cdfg, max_cycles)

    # Calculate mobility
    for node in cdfg.nodes
        node.asap_cycle = asap_times[node]
        node.mobility = node.alap_cycle - node.asap_cycle
    end
end

# ============================================================================
# List Scheduling
# ============================================================================

"""
    schedule_list!(cdfg::CDFG, constraints::ResourceConstraints=ResourceConstraints())

Perform list scheduling with resource constraints.
Uses operation priority based on critical path length.
"""
function schedule_list!(cdfg::CDFG, constraints::ResourceConstraints=ResourceConstraints())::Schedule
    schedule = Schedule(cdfg)

    # Calculate mobility for priority
    calculate_mobility!(cdfg)

    # Priority: lower mobility = higher priority (on critical path)
    # Secondary: higher latency = higher priority
    priority = Dict{DFGNode, Int}()
    for node in cdfg.nodes
        # Negative mobility + latency as priority (higher is better)
        priority[node] = -node.mobility + node.latency
    end

    # Initialize
    for node in cdfg.nodes
        node.scheduled_cycle = -1
    end

    # Ready list: nodes with all predecessors scheduled
    ready = DFGNode[]
    scheduled = Set{DFGNode}()

    # Initially, nodes with no predecessors are ready
    for node in cdfg.nodes
        preds = get_predecessors(cdfg, node)
        if isempty(preds)
            push!(ready, node)
        end
    end

    # Resource usage tracking per cycle
    resource_usage = Dict{Int, Dict{ResourceType, Int}}()

    current_cycle = 0

    while length(scheduled) < length(cdfg.nodes)
        # Sort ready list by priority (descending)
        sort!(ready, by=n->priority[n], rev=true)

        # Try to schedule nodes in ready list
        to_remove = DFGNode[]
        for node in ready
            res_type = operation_to_resource(node.op)

            # Check if we can schedule this node
            if can_schedule_at_cycle(node, current_cycle, resource_usage, constraints, cdfg, scheduled)
                # Schedule the node
                node.scheduled_cycle = current_cycle
                push!(scheduled, node)
                push!(to_remove, node)

                # Update resource usage
                if !haskey(resource_usage, current_cycle)
                    resource_usage[current_cycle] = Dict{ResourceType, Int}()
                end
                resource_usage[current_cycle][res_type] = get(resource_usage[current_cycle], res_type, 0) + 1
            end
        end

        # Remove scheduled nodes from ready list
        filter!(n -> !(n in to_remove), ready)

        # Add newly ready nodes
        for node in cdfg.nodes
            if node in scheduled || node in ready
                continue
            end

            preds = get_predecessors(cdfg, node)
            all_ready = all(p -> p in scheduled && (p.scheduled_cycle + p.latency <= current_cycle + 1), preds)

            if all_ready
                push!(ready, node)
            end
        end

        # Advance cycle if ready list is empty or nothing could be scheduled
        if isempty(ready) || isempty(to_remove)
            current_cycle += 1

            # Safety check
            if current_cycle > length(cdfg.nodes) * 100
                @warn "List scheduling exceeded maximum iterations"
                break
            end
        end
    end

    # Build schedule structure
    build_schedule_structure!(schedule, cdfg)
    schedule.resource_usage_per_cycle = resource_usage

    return schedule
end

"""
    can_schedule_at_cycle(node, cycle, resource_usage, constraints, cdfg, scheduled)

Check if a node can be scheduled at a given cycle considering:
- Data dependencies (all predecessors must be complete)
- Resource constraints
"""
function can_schedule_at_cycle(node::DFGNode, cycle::Int,
                               resource_usage::Dict{Int, Dict{ResourceType, Int}},
                               constraints::ResourceConstraints,
                               cdfg::CDFG,
                               scheduled::Set{DFGNode})::Bool

    # Check data dependencies
    for pred in get_predecessors(cdfg, node)
        if !(pred in scheduled)
            return false
        end
        if pred.scheduled_cycle + pred.latency > cycle
            return false
        end
    end

    # Check resource constraints
    res_type = operation_to_resource(node.op)
    current_usage = get(get(resource_usage, cycle, Dict()), res_type, 0)

    max_allowed = get_resource_limit(res_type, constraints)

    return current_usage < max_allowed
end

"""
    get_resource_limit(res_type, constraints)

Get the maximum number of a resource type allowed.
"""
function get_resource_limit(res_type::ResourceType, constraints::ResourceConstraints)::Int
    limits = Dict{ResourceType, Int}(
        RES_ALU => constraints.max_alus,
        RES_DSP => constraints.max_dsps,
        RES_FPU => constraints.max_fpus,
        RES_DIVIDER => constraints.max_dividers,
        RES_BRAM_PORT => constraints.max_bram_read_ports,
        RES_MUX => constraints.max_multiplexers,
        RES_COMPARATOR => constraints.max_alus,
        RES_SHIFTER => constraints.max_alus,
        RES_REG => 1000,  # Effectively unlimited
    )
    return get(limits, res_type, 8)
end

# ============================================================================
# ILP Scheduling (Optimal)
# ============================================================================

"""
    schedule_ilp!(cdfg::CDFG; constraints::ResourceConstraints=ResourceConstraints(),
                  time_limit_sec::Float64=60.0)

Perform optimal scheduling using Integer Linear Programming.
Minimizes total latency while respecting resource constraints.
"""
function schedule_ilp!(cdfg::CDFG;
                       constraints::ResourceConstraints=ResourceConstraints(),
                       time_limit_sec::Float64=60.0)::Schedule

    schedule = Schedule(cdfg)

    n = length(cdfg.nodes)
    if n == 0
        return schedule
    end

    # Run ASAP to get bounds
    asap_schedule = schedule_asap!(cdfg)
    max_cycles = asap_schedule.total_cycles + 10  # Add some slack

    # Create optimization model
    model = Model(HiGHS.Optimizer)
    set_optimizer_attribute(model, "time_limit", time_limit_sec)
    set_silent(model)

    # Decision variables: start cycle for each operation
    @variable(model, 0 <= T[i=1:n] <= max_cycles, Int)

    # Data dependency constraints
    for (i, node) in enumerate(cdfg.nodes)
        for pred in get_predecessors(cdfg, node)
            j = findfirst(==(pred), cdfg.nodes)
            if j !== nothing
                # Node i cannot start until node j completes
                @constraint(model, T[i] >= T[j] + pred.latency)
            end
        end
    end

    # Resource constraints using time-indexed formulation
    # For each cycle c and resource type, limit concurrent usage
    for c in 0:max_cycles
        # Group nodes by resource type
        for res_type in instances(ResourceType)
            nodes_of_type = findall(i -> operation_to_resource(cdfg.nodes[i].op) == res_type, 1:n)

            if !isempty(nodes_of_type)
                limit = get_resource_limit(res_type, constraints)

                # Count nodes active at cycle c
                # A node i is active at cycle c if T[i] <= c < T[i] + latency[i]
                # Using indicator: is_active[i,c] = 1 if node i is active at cycle c
                @variable(model, active[i in nodes_of_type], Bin)

                for i in nodes_of_type
                    lat = cdfg.nodes[i].latency
                    # active[i] = 1 if T[i] <= c and c < T[i] + lat
                    # This is: T[i] <= c AND T[i] > c - lat
                    # Linearize: active[i] = 1 => T[i] <= c
                    #           active[i] = 1 => T[i] > c - lat
                    @constraint(model, T[i] <= c + max_cycles * (1 - active[i]))
                    @constraint(model, T[i] >= (c - lat + 1) - max_cycles * (1 - active[i]))
                end

                @constraint(model, sum(active[i] for i in nodes_of_type) <= limit)
            end
        end
    end

    # Objective: minimize total latency
    @variable(model, total_latency >= 0, Int)
    for (i, node) in enumerate(cdfg.nodes)
        @constraint(model, total_latency >= T[i] + node.latency)
    end
    @objective(model, Min, total_latency)

    # Solve
    optimize!(model)

    # Check solution status
    status = termination_status(model)
    if status != MOI.OPTIMAL && status != MOI.TIME_LIMIT
        @warn "ILP scheduling did not find optimal solution (status: $status), falling back to list scheduling"
        return schedule_list!(cdfg, constraints)
    end

    # Extract solution
    for (i, node) in enumerate(cdfg.nodes)
        node.scheduled_cycle = round(Int, value(T[i]))
    end

    # Build schedule structure
    build_schedule_structure!(schedule, cdfg)

    return schedule
end

# ============================================================================
# Modulo Scheduling for Pipelined Loops
# ============================================================================

"""
    schedule_modulo!(cdfg::CDFG; target_ii::Int=1,
                     constraints::ResourceConstraints=ResourceConstraints())

Perform modulo scheduling for pipelined loop execution.
Achieves the specified Initiation Interval (II).
"""
function schedule_modulo!(cdfg::CDFG;
                          target_ii::Int=1,
                          constraints::ResourceConstraints=ResourceConstraints())::Schedule

    schedule = Schedule(cdfg)
    schedule.initiation_interval = target_ii

    n = length(cdfg.nodes)
    if n == 0
        return schedule
    end

    # Calculate minimum II based on resource constraints
    min_ii_resources = calculate_min_ii_resources(cdfg, constraints)

    # Calculate minimum II based on recurrences (loop-carried dependencies)
    min_ii_recurrence = calculate_min_ii_recurrence(cdfg)

    min_ii = max(min_ii_resources, min_ii_recurrence, 1)

    if target_ii < min_ii
        @warn "Target II=$target_ii is less than minimum achievable II=$min_ii, using II=$min_ii"
        target_ii = min_ii
        schedule.initiation_interval = min_ii
    end

    # Use modulo scheduling with increasing II until success
    current_ii = target_ii

    while current_ii <= n  # Safety bound
        success = try_modulo_schedule!(cdfg, current_ii, constraints)
        if success
            schedule.achieved_ii = current_ii
            break
        end
        current_ii += 1
    end

    # Build schedule structure
    build_schedule_structure!(schedule, cdfg)

    return schedule
end

"""
    calculate_min_ii_resources(cdfg, constraints)

Calculate minimum II based on resource constraints.
MinII_res = ceil(usage[r] / limit[r]) for each resource r
"""
function calculate_min_ii_resources(cdfg::CDFG, constraints::ResourceConstraints)::Int
    min_ii = 1

    for res_type in instances(ResourceType)
        usage = count(n -> operation_to_resource(n.op) == res_type, cdfg.nodes)
        limit = get_resource_limit(res_type, constraints)

        if limit > 0 && usage > 0
            required_ii = ceil(Int, usage / limit)
            min_ii = max(min_ii, required_ii)
        end
    end

    return min_ii
end

"""
    calculate_min_ii_recurrence(cdfg)

Calculate minimum II based on recurrence constraints (loop-carried dependencies).
"""
function calculate_min_ii_recurrence(cdfg::CDFG)::Int
    # For now, return 1 (no loop-carried dependencies detected)
    # Full implementation would analyze PHI nodes and back-edges
    return 1
end

"""
    try_modulo_schedule!(cdfg, ii, constraints)

Attempt modulo scheduling with the given II.
Returns true if successful.
"""
function try_modulo_schedule!(cdfg::CDFG, ii::Int, constraints::ResourceConstraints)::Bool
    n = length(cdfg.nodes)

    # Modulo Resource Table (MRT): track resource usage per modulo cycle
    mrt = Dict{Int, Dict{ResourceType, Int}}()
    for c in 0:(ii-1)
        mrt[c] = Dict{ResourceType, Int}()
    end

    # Schedule nodes in priority order
    calculate_mobility!(cdfg)
    sorted_nodes = sort(cdfg.nodes, by=n->n.asap_cycle)

    for node in sorted_nodes
        # Find earliest valid slot
        earliest = node.asap_cycle

        # Check predecessors
        for pred in get_predecessors(cdfg, node)
            earliest = max(earliest, pred.scheduled_cycle + pred.latency)
        end

        # Try to schedule at each cycle starting from earliest
        scheduled = false
        for cycle in earliest:(earliest + 2*ii)
            modulo_cycle = cycle % ii
            res_type = operation_to_resource(node.op)

            current_usage = get(mrt[modulo_cycle], res_type, 0)
            limit = get_resource_limit(res_type, constraints)

            if current_usage < limit
                node.scheduled_cycle = cycle
                mrt[modulo_cycle][res_type] = current_usage + 1
                scheduled = true
                break
            end
        end

        if !scheduled
            return false
        end
    end

    return true
end

# ============================================================================
# Schedule Building Utilities
# ============================================================================

"""
    build_schedule_structure!(schedule, cdfg)

Build the schedule structure from scheduled nodes.
"""
function build_schedule_structure!(schedule::Schedule, cdfg::CDFG)
    schedule.cycle_to_ops = Dict{Int, Vector{DFGNode}}()
    schedule.op_to_cycle = Dict{Int, Int}()

    for node in cdfg.nodes
        cycle = node.scheduled_cycle
        if cycle >= 0
            if !haskey(schedule.cycle_to_ops, cycle)
                schedule.cycle_to_ops[cycle] = DFGNode[]
            end
            push!(schedule.cycle_to_ops[cycle], node)
            schedule.op_to_cycle[node.id] = cycle
        end
    end

    # Calculate total cycles
    if !isempty(cdfg.nodes)
        schedule.total_cycles = maximum(n.scheduled_cycle + n.latency for n in cdfg.nodes if n.scheduled_cycle >= 0)
    end

    # Find critical path
    schedule.critical_path = find_critical_path(cdfg)
end

"""
    find_critical_path(cdfg)

Find the nodes on the critical path.
"""
function find_critical_path(cdfg::CDFG)::Vector{DFGNode}
    if isempty(cdfg.nodes)
        return DFGNode[]
    end

    # Find the node with maximum completion time
    max_completion = 0
    end_node = cdfg.nodes[1]

    for node in cdfg.nodes
        completion = node.scheduled_cycle + node.latency
        if completion > max_completion
            max_completion = completion
            end_node = node
        end
    end

    # Trace back through critical predecessors
    path = [end_node]
    current = end_node

    while true
        preds = get_predecessors(cdfg, current)
        if isempty(preds)
            break
        end

        # Find critical predecessor (one that determines start time)
        critical_pred = nothing
        for pred in preds
            if pred.scheduled_cycle + pred.latency == current.scheduled_cycle
                critical_pred = pred
                break
            end
        end

        if critical_pred === nothing
            break
        end

        pushfirst!(path, critical_pred)
        current = critical_pred
    end

    return path
end

"""
    print_schedule(schedule)

Print the schedule for debugging.
"""
function print_schedule(schedule::Schedule)
    println("Schedule:")
    println("=" ^ 50)
    println("Total Cycles: $(schedule.total_cycles)")
    println("Initiation Interval: $(schedule.initiation_interval)")
    println()

    for cycle in sort(collect(keys(schedule.cycle_to_ops)))
        ops = schedule.cycle_to_ops[cycle]
        println("Cycle $cycle:")
        for op in ops
            println("  $(op.name) [$(op.op), lat=$(op.latency)]")
        end
    end

    println()
    println("Critical Path:")
    for node in schedule.critical_path
        println("  $(node.name) @ cycle $(node.scheduled_cycle)")
    end
end
