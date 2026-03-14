# HLS Analysis Functions
# Analysis utilities for CDFG inspection and optimization

"""
    analyze_critical_path(cdfg::CDFG)

Analyze the critical path and return detailed information.
"""
function analyze_critical_path(cdfg::CDFG)::Dict{String, Any}
    result = Dict{String, Any}()

    # Ensure ASAP scheduling is done
    if all(n -> n.scheduled_cycle < 0, cdfg.nodes)
        schedule_asap!(cdfg)
    end

    # Find critical path
    critical_path = find_critical_path(cdfg)

    result["length"] = cdfg.critical_path_length
    result["nodes"] = [n.name for n in critical_path]
    result["operations"] = [n.op for n in critical_path]
    result["latencies"] = [n.latency for n in critical_path]

    # Identify bottleneck operations
    bottlenecks = DFGNode[]
    for node in critical_path
        if node.latency > 1
            push!(bottlenecks, node)
        end
    end
    result["bottlenecks"] = [(n.name, n.op, n.latency) for n in bottlenecks]

    return result
end

"""
    analyze_resource_usage(cdfg::CDFG)

Analyze resource usage and identify optimization opportunities.
"""
function analyze_resource_usage(cdfg::CDFG)::Dict{String, Any}
    result = Dict{String, Any}()

    # Count operations by type
    op_counts = Dict{OperationType, Int}()
    for node in cdfg.nodes
        op_counts[node.op] = get(op_counts, node.op, 0) + 1
    end
    result["operation_counts"] = op_counts

    # Count by resource type
    res_counts = Dict{ResourceType, Int}()
    for node in cdfg.nodes
        if node.op != OP_NOP && !is_control_op(node.op)
            res = operation_to_resource(node.op)
            res_counts[res] = get(res_counts, res, 0) + 1
        end
    end
    result["resource_counts"] = res_counts

    # After binding, get actual resource instances used
    if any(n -> n.bound_resource !== nothing, cdfg.nodes)
        instance_counts = get_resource_count(cdfg)
        result["bound_instances"] = instance_counts
    end

    # Memory analysis
    num_loads = count(n -> n.op == OP_LOAD, cdfg.nodes)
    num_stores = count(n -> n.op == OP_STORE, cdfg.nodes)
    result["memory_ops"] = Dict("loads" => num_loads, "stores" => num_stores)

    # DSP usage
    num_muls = count(n -> needs_dsp(n.op), cdfg.nodes)
    result["dsp_ops"] = num_muls

    return result
end

"""
    estimate_cycles(cdfg::CDFG)

Estimate execution cycles based on scheduling.
"""
function estimate_cycles(cdfg::CDFG)::Dict{String, Any}
    result = Dict{String, Any}()

    # Run ASAP if not scheduled
    if all(n -> n.scheduled_cycle < 0, cdfg.nodes)
        schedule = schedule_asap!(cdfg)
        result["scheduling"] = "asap"
    else
        result["scheduling"] = "existing"
    end

    # Total cycles
    if !isempty(cdfg.nodes)
        result["total_cycles"] = maximum(n.scheduled_cycle + n.latency for n in cdfg.nodes if n.scheduled_cycle >= 0)
    else
        result["total_cycles"] = 0
    end

    # Cycles per state
    cycles_per_state = Dict{Int, Int}()
    for state in cdfg.states
        state_ops = [n for n in cdfg.nodes if n.state_id == state.id && n.scheduled_cycle >= 0]
        if !isempty(state_ops)
            start = minimum(n.scheduled_cycle for n in state_ops)
            finish = maximum(n.scheduled_cycle + n.latency for n in state_ops)
            cycles_per_state[state.id] = finish - start
        end
    end
    result["cycles_per_state"] = cycles_per_state

    return result
end

"""
    analyze_parallelism(cdfg::CDFG)

Analyze available parallelism in the CDFG.
"""
function analyze_parallelism(cdfg::CDFG)::Dict{String, Any}
    result = Dict{String, Any}()

    # Ensure scheduling is done
    if all(n -> n.scheduled_cycle < 0, cdfg.nodes)
        schedule_asap!(cdfg)
    end

    # Count operations per cycle
    ops_per_cycle = Dict{Int, Int}()
    for node in cdfg.nodes
        if node.scheduled_cycle >= 0
            ops_per_cycle[node.scheduled_cycle] = get(ops_per_cycle, node.scheduled_cycle, 0) + 1
        end
    end

    result["ops_per_cycle"] = ops_per_cycle

    if !isempty(ops_per_cycle)
        result["max_parallel_ops"] = maximum(values(ops_per_cycle))
        result["avg_parallel_ops"] = sum(values(ops_per_cycle)) / length(ops_per_cycle)
    else
        result["max_parallel_ops"] = 0
        result["avg_parallel_ops"] = 0.0
    end

    # Calculate Instruction Level Parallelism (ILP)
    total_ops = length([n for n in cdfg.nodes if n.scheduled_cycle >= 0])
    total_cycles = result["max_parallel_ops"] > 0 ? length(ops_per_cycle) : 1
    result["ilp"] = total_ops / total_cycles

    return result
end

"""
    analyze_memory_access_pattern(cdfg::CDFG)

Analyze memory access patterns for optimization hints.
"""
function analyze_memory_access_pattern(cdfg::CDFG)::Dict{String, Any}
    result = Dict{String, Any}()

    loads = [n for n in cdfg.nodes if n.op == OP_LOAD]
    stores = [n for n in cdfg.nodes if n.op == OP_STORE]

    result["num_loads"] = length(loads)
    result["num_stores"] = length(stores)
    result["total_memory_ops"] = length(loads) + length(stores)

    # Check for concurrent memory accesses
    if !isempty(loads) && all(n -> n.scheduled_cycle >= 0, loads)
        # Group by cycle
        loads_per_cycle = Dict{Int, Int}()
        for load in loads
            loads_per_cycle[load.scheduled_cycle] = get(loads_per_cycle, load.scheduled_cycle, 0) + 1
        end
        result["max_concurrent_loads"] = maximum(values(loads_per_cycle))
        result["load_cycles"] = loads_per_cycle
    else
        result["max_concurrent_loads"] = 0
    end

    if !isempty(stores) && all(n -> n.scheduled_cycle >= 0, stores)
        stores_per_cycle = Dict{Int, Int}()
        for store in stores
            stores_per_cycle[store.scheduled_cycle] = get(stores_per_cycle, store.scheduled_cycle, 0) + 1
        end
        result["max_concurrent_stores"] = maximum(values(stores_per_cycle))
    else
        result["max_concurrent_stores"] = 0
    end

    return result
end

"""
    analyze_loop_structure(cdfg::CDFG)

Analyze loop structure for pipelining opportunities.
"""
function analyze_loop_structure(cdfg::CDFG)::Dict{String, Any}
    result = Dict{String, Any}()

    # Find loop headers
    headers = [s for s in cdfg.states if s.is_loop_header]
    result["num_loops"] = length(headers)

    # Analyze each loop
    loops = Dict{String, Any}[]
    for header in headers
        loop_info = Dict{String, Any}()
        loop_info["header"] = header.name
        loop_info["depth"] = header.loop_depth

        # Find loop body
        body_states = [s for s in cdfg.states if s.loop_depth >= header.loop_depth]
        loop_info["body_states"] = length(body_states)

        # Count operations in loop
        loop_ops = 0
        for state in body_states
            loop_ops += length(state.operations)
        end
        loop_info["operations"] = loop_ops

        # Check for loop-carried dependencies
        # (simplified: look for PHI nodes in header)
        phi_count = count(n -> n.op == OP_PHI && n.state_id == header.id, cdfg.nodes)
        loop_info["phi_nodes"] = phi_count
        loop_info["has_loop_carried_deps"] = phi_count > 0

        push!(loops, loop_info)
    end
    result["loops"] = loops

    return result
end

"""
    suggest_optimizations(cdfg::CDFG)

Suggest optimizations based on CDFG analysis.
"""
function suggest_optimizations(cdfg::CDFG)::Vector{String}
    suggestions = String[]

    # Analyze current state
    resource_info = analyze_resource_usage(cdfg)
    memory_info = analyze_memory_access_pattern(cdfg)
    loop_info = analyze_loop_structure(cdfg)
    parallelism_info = analyze_parallelism(cdfg)

    # Check for memory bandwidth bottleneck
    if memory_info["max_concurrent_loads"] > 2
        push!(suggestions, "Memory bandwidth bottleneck detected. Consider array partitioning to increase BRAM ports.")
    end

    # Check for low parallelism
    if get(parallelism_info, "ilp", 0) < 2.0
        push!(suggestions, "Low instruction-level parallelism (ILP=$(round(parallelism_info["ilp"], digits=2))). Consider loop unrolling.")
    end

    # Check for high DSP usage
    if get(resource_info, "dsp_ops", 0) > 10
        push!(suggestions, "High DSP usage ($(resource_info["dsp_ops"]) multiplications). Consider resource sharing or strength reduction.")
    end

    # Check for deep loops
    for loop in get(loop_info, "loops", [])
        if get(loop, "operations", 0) > 20
            push!(suggestions, "Large loop body in $(loop["header"]). Consider loop tiling or pipelining.")
        end
    end

    # Check for long critical path
    if cdfg.critical_path_length > 20
        push!(suggestions, "Long critical path ($(cdfg.critical_path_length) cycles). Consider retiming or increasing pipelining.")
    end

    if isempty(suggestions)
        push!(suggestions, "No obvious optimizations detected. Design appears well-structured.")
    end

    return suggestions
end

"""
    generate_analysis_report(cdfg::CDFG)

Generate a comprehensive analysis report.
"""
function generate_analysis_report(cdfg::CDFG)::String
    report = IOBuffer()

    println(report, "=" ^ 60)
    println(report, "HLS Analysis Report: $(cdfg.name)")
    println(report, "=" ^ 60)
    println(report)

    # Basic statistics
    println(report, "## Basic Statistics")
    println(report, "  FSM States: $(length(cdfg.states))")
    println(report, "  DFG Nodes: $(length(cdfg.nodes))")
    println(report, "  DFG Edges: $(length(cdfg.edges))")
    println(report, "  Inputs: $(length(cdfg.input_nodes))")
    println(report, "  Outputs: $(length(cdfg.output_nodes))")
    println(report)

    # Critical path
    cp_info = analyze_critical_path(cdfg)
    println(report, "## Critical Path")
    println(report, "  Length: $(cp_info["length"]) cycles")
    if !isempty(cp_info["bottlenecks"])
        println(report, "  Bottlenecks:")
        for (name, op, lat) in cp_info["bottlenecks"]
            println(report, "    - $name ($op): $lat cycles")
        end
    end
    println(report)

    # Resource usage
    res_info = analyze_resource_usage(cdfg)
    println(report, "## Resource Usage")
    for (res, count) in get(res_info, "resource_counts", Dict())
        println(report, "  $res: $count")
    end
    println(report)

    # Memory
    mem_info = analyze_memory_access_pattern(cdfg)
    println(report, "## Memory Access")
    println(report, "  Loads: $(mem_info["num_loads"])")
    println(report, "  Stores: $(mem_info["num_stores"])")
    println(report, "  Max concurrent loads: $(mem_info["max_concurrent_loads"])")
    println(report)

    # Parallelism
    par_info = analyze_parallelism(cdfg)
    println(report, "## Parallelism")
    println(report, "  Max parallel ops: $(par_info["max_parallel_ops"])")
    println(report, "  Average parallel ops: $(round(par_info["avg_parallel_ops"], digits=2))")
    println(report, "  ILP: $(round(par_info["ilp"], digits=2))")
    println(report)

    # Loop structure
    loop_info = analyze_loop_structure(cdfg)
    println(report, "## Loop Structure")
    println(report, "  Number of loops: $(loop_info["num_loops"])")
    for loop in get(loop_info, "loops", [])
        println(report, "  - $(loop["header"]): depth=$(loop["depth"]), ops=$(loop["operations"])")
    end
    println(report)

    # Suggestions
    suggestions = suggest_optimizations(cdfg)
    println(report, "## Optimization Suggestions")
    for (i, sug) in enumerate(suggestions)
        println(report, "  $i. $sug")
    end

    return String(take!(report))
end
