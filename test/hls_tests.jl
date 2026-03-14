# HLS Tests
# Tests for HLS backend functionality

@testset "HLS Backend" begin

    @testset "HLS Types" begin
        using FPGACompiler.HLS

        @testset "OperationType" begin
            @test OP_ADD isa OperationType
            @test OP_MUL isa OperationType
            @test OP_LOAD isa OperationType
            @test OP_STORE isa OperationType
            @test OP_PHI isa OperationType
        end

        @testset "ResourceType" begin
            @test RES_ALU isa ResourceType
            @test RES_MUL isa ResourceType
            @test RES_DIV isa ResourceType
            @test RES_MEM isa ResourceType
        end

        @testset "HLSOptions" begin
            opts = HLSOptions()
            @test opts.target_clock_mhz == 100.0
            @test opts.enable_pipelining == true
            @test opts.enable_resource_sharing == true

            opts2 = HLSOptions(target_clock_mhz=200.0, enable_pipelining=false)
            @test opts2.target_clock_mhz == 200.0
            @test opts2.enable_pipelining == false
        end

        @testset "ResourceConstraints" begin
            rc = ResourceConstraints()
            @test rc.max_alus == 8
            @test rc.max_dsps == 4
            @test rc.max_bram_read_ports == 2

            rc2 = ResourceConstraints(max_alus=16, max_dsps=8)
            @test rc2.max_alus == 16
            @test rc2.max_dsps == 8
        end

        @testset "Default Latencies" begin
            @test get_default_latency(OP_ADD) == 1
            @test get_default_latency(OP_MUL) == 3
            @test get_default_latency(OP_LOAD) == 2
            @test get_default_latency(OP_DIV) == 18
        end
    end

    @testset "DFG Node" begin
        using FPGACompiler.HLS

        # Create node using positional constructor
        node = DFGNode(1, OP_ADD, "add_1")
        node.bit_width = 32
        node.is_signed = true

        @test node.id == 1
        @test node.name == "add_1"
        @test node.op == OP_ADD
        @test node.bit_width == 32
        @test node.is_signed == true
        @test node.latency == 1  # Default for ADD
        @test node.scheduled_cycle == -1  # Not scheduled
    end

    @testset "FSM State" begin
        using FPGACompiler.HLS

        state = FSMState(1, "state_1")

        @test state.id == 1
        @test state.name == "state_1"
        @test isempty(state.operations)
        @test isempty(state.successor_ids)
        @test state.loop_depth == 0
        @test state.is_loop_header == false
    end

    @testset "CDFG" begin
        using FPGACompiler.HLS

        cdfg = CDFG("test_function")

        @test cdfg.name == "test_function"
        @test isempty(cdfg.nodes)
        @test isempty(cdfg.edges)
        @test isempty(cdfg.states)
    end

    @testset "Schedule" begin
        using FPGACompiler.HLS

        cdfg = CDFG("test")
        schedule = Schedule(cdfg)

        @test schedule.total_cycles == 0
        @test isempty(schedule.cycle_to_ops)
    end

    @testset "Operation Classification" begin
        using FPGACompiler.HLS

        @test is_control_op(OP_BR) == true
        @test is_control_op(OP_BR_COND) == true
        @test is_control_op(OP_RET) == true
        @test is_control_op(OP_ADD) == false

        @test is_memory_op(OP_LOAD) == true
        @test is_memory_op(OP_STORE) == true
        @test is_memory_op(OP_ADD) == false

        @test needs_dsp(OP_MUL) == true
        @test needs_dsp(OP_ADD) == false
    end

    @testset "Operation to Resource Mapping" begin
        using FPGACompiler.HLS

        @test operation_to_resource(OP_ADD) == RES_ALU
        @test operation_to_resource(OP_SUB) == RES_ALU
        @test operation_to_resource(OP_MUL) == RES_DSP
        @test operation_to_resource(OP_DIV) == RES_DIVIDER
        @test operation_to_resource(OP_LOAD) == RES_BRAM_PORT
        @test operation_to_resource(OP_STORE) == RES_BRAM_PORT
    end

    @testset "Scheduling Algorithms" begin
        using FPGACompiler.HLS

        # Create a simple test CDFG
        cdfg = CDFG("test_schedule")

        # Add some nodes (positional: id, op, name)
        node1 = DFGNode(1, OP_NOP, "input")
        node2 = DFGNode(2, OP_ADD, "add1")
        node3 = DFGNode(3, OP_ADD, "add2")
        node4 = DFGNode(4, OP_MUL, "mul1")

        push!(cdfg.nodes, node1)
        push!(cdfg.nodes, node2)
        push!(cdfg.nodes, node3)
        push!(cdfg.nodes, node4)

        # Add edges (dependencies) - positional: src, dst, operand_index
        push!(cdfg.edges, DFGEdge(node1, node2, 0))
        push!(cdfg.edges, DFGEdge(node2, node3, 0))
        push!(cdfg.edges, DFGEdge(node3, node4, 0))

        # Add a state
        state = FSMState(1, "compute")
        state.operations = [node1, node2, node3, node4]
        push!(cdfg.states, state)
        cdfg.entry_state_id = 1

        @testset "ASAP Scheduling" begin
            schedule = schedule_asap!(cdfg)
            @test schedule isa Schedule
            @test schedule.total_cycles > 0
        end
    end

    @testset "Analysis Functions" begin
        using FPGACompiler.HLS

        # Create test CDFG
        cdfg = CDFG("test_analysis")

        # Add nodes (positional: id, op, name)
        node1 = DFGNode(1, OP_LOAD, "load1")
        node2 = DFGNode(2, OP_ADD, "add1")
        node3 = DFGNode(3, OP_MUL, "mul1")

        push!(cdfg.nodes, node1)
        push!(cdfg.nodes, node2)
        push!(cdfg.nodes, node3)

        # Add a state
        state = FSMState(1, "compute")
        push!(cdfg.states, state)
        cdfg.entry_state_id = 1

        @testset "Resource Usage Analysis" begin
            result = analyze_resource_usage(cdfg)
            @test haskey(result, "operation_counts")
            @test haskey(result, "resource_counts")
            @test haskey(result, "memory_ops")
        end

        @testset "Memory Pattern Analysis" begin
            result = analyze_memory_access_pattern(cdfg)
            @test haskey(result, "num_loads")
            @test haskey(result, "num_stores")
            @test result["num_loads"] == 1
            @test result["num_stores"] == 0
        end

        @testset "Parallelism Analysis" begin
            # Schedule first
            for (i, node) in enumerate(cdfg.nodes)
                node.scheduled_cycle = i - 1
            end

            result = analyze_parallelism(cdfg)
            @test haskey(result, "ops_per_cycle")
            @test haskey(result, "max_parallel_ops")
            @test haskey(result, "ilp")
        end

        @testset "Optimization Suggestions" begin
            suggestions = suggest_optimizations(cdfg)
            @test suggestions isa Vector{String}
            @test !isempty(suggestions)
        end
    end

    @testset "Resource Binding" begin
        using FPGACompiler.HLS

        # Create test CDFG with overlapping operations
        cdfg = CDFG("test_binding")

        # Create operations that could share resources (positional: id, op, name)
        node1 = DFGNode(1, OP_ADD, "add1")
        node2 = DFGNode(2, OP_ADD, "add2")
        node3 = DFGNode(3, OP_ADD, "add3")

        # Schedule at different times (can share)
        node1.scheduled_cycle = 0
        node2.scheduled_cycle = 1
        node3.scheduled_cycle = 0  # Overlaps with node1

        push!(cdfg.nodes, node1)
        push!(cdfg.nodes, node2)
        push!(cdfg.nodes, node3)

        # Create schedule
        schedule = Schedule(cdfg)
        schedule.total_cycles = 2

        @testset "Left-edge Binding" begin
            bind_resources!(cdfg, schedule)

            # Check that resources were bound
            @test node1.bound_resource == RES_ALU
            @test node2.bound_resource == RES_ALU
            @test node3.bound_resource == RES_ALU

            # Node2 should share with node1 (different cycles)
            # Node3 should get a different instance (same cycle as node1)
            @test node1.resource_instance != node3.resource_instance
        end

        @testset "Resource Count" begin
            counts = get_resource_count(cdfg)
            @test haskey(counts, RES_ALU)
            @test counts[RES_ALU] >= 1
        end
    end
end
