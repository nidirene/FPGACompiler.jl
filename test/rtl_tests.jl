# RTL Tests
# Tests for RTL generation functionality

@testset "RTL Generation" begin

    @testset "RTL Types" begin
        using FPGACompiler.RTL
        using FPGACompiler.HLS

        @testset "RTLPort" begin
            port = RTLPort("clk", 1, true, false)
            @test port.name == "clk"
            @test port.bit_width == 1
            @test port.is_input == true
            @test port.is_signed == false

            port2 = RTLPort("data_out", 32, false, true)
            @test port2.name == "data_out"
            @test port2.bit_width == 32
            @test port2.is_input == false
            @test port2.is_signed == true
        end

        @testset "RTLSignal" begin
            sig = RTLSignal("counter", 8, true, false, 0)
            @test sig.name == "counter"
            @test sig.bit_width == 8
            @test sig.is_register == true
            @test sig.is_signed == false
            @test sig.initial_value == 0

            wire = RTLSignal("sum", 32, false, true, nothing)
            @test wire.is_register == false
            @test wire.initial_value === nothing
        end

        @testset "RTLModule" begin
            rtl = RTLModule("test_module")
            @test rtl.name == "test_module"
            @test isempty(rtl.ports)
            @test isempty(rtl.signals)
            @test isempty(rtl.state_names)
        end
    end

    @testset "Name Sanitization" begin
        using FPGACompiler.RTL

        # Test basic sanitization
        @test sanitize_name("valid_name") == "valid_name"
        @test sanitize_name("123invalid") == "_123invalid"
        @test sanitize_name("with-dash") == "with_dash"
        @test sanitize_name("with.dot") == "with_dot"
        @test sanitize_name("with space") == "with_space"

        # Test keyword avoidance
        @test sanitize_name("module") == "module_sig"
        @test sanitize_name("input") == "input_sig"
        @test sanitize_name("wire") == "wire_sig"
    end

    @testset "RTL Generation from CDFG" begin
        using FPGACompiler.RTL
        using FPGACompiler.HLS

        # Create a simple CDFG
        cdfg = CDFG("simple_add")

        # Add input nodes (positional: id, op, name)
        in1 = DFGNode(1, OP_NOP, "arg_a")
        in2 = DFGNode(2, OP_NOP, "arg_b")
        add_node = DFGNode(3, OP_ADD, "sum")

        push!(cdfg.nodes, in1)
        push!(cdfg.nodes, in2)
        push!(cdfg.nodes, add_node)
        push!(cdfg.input_nodes, in1)
        push!(cdfg.input_nodes, in2)
        push!(cdfg.output_nodes, add_node)

        # Add edge (positional: src, dst, operand_index)
        push!(cdfg.edges, DFGEdge(in1, add_node, 0))
        push!(cdfg.edges, DFGEdge(in2, add_node, 1))

        # Add state (positional: id, name)
        state = FSMState(1, "compute")
        state.operations = [add_node]
        push!(cdfg.states, state)
        cdfg.entry_state_id = 1

        # Schedule
        in1.scheduled_cycle = 0
        in2.scheduled_cycle = 0
        add_node.scheduled_cycle = 0

        schedule = Schedule(cdfg)
        schedule.total_cycles = 1

        @testset "Generate RTL Module" begin
            rtl = generate_rtl(cdfg, schedule)

            @test rtl isa RTLModule
            @test rtl.name == "simple_add"

            # Check ports
            @test length(rtl.ports) >= 4  # clk, rst, start, done + inputs + outputs

            # Check for clk and rst
            port_names = [p.name for p in rtl.ports]
            @test "clk" in port_names
            @test "rst" in port_names
            @test "start" in port_names
            @test "done" in port_names
        end

        @testset "Port Declarations" begin
            rtl = generate_rtl(cdfg, schedule)

            decl = rtl.port_declarations
            @test contains(decl, "clk")
            @test contains(decl, "rst")
            @test contains(decl, "input")
            @test contains(decl, "output")
        end

        @testset "Signal Declarations" begin
            rtl = generate_rtl(cdfg, schedule)

            decl = rtl.signal_declarations
            @test contains(decl, "current_state")
            @test contains(decl, "next_state")
            @test contains(decl, "reg") || contains(decl, "wire")
        end

        @testset "State Encoding" begin
            rtl = generate_rtl(cdfg, schedule)

            @test "IDLE" in rtl.state_names
            @test "DONE" in rtl.state_names
            @test haskey(rtl.state_encoding, "IDLE")
            @test rtl.state_encoding["IDLE"] == 0
        end
    end

    @testset "Verilog Emission" begin
        using FPGACompiler.RTL
        using FPGACompiler.HLS

        # Create minimal RTL module
        rtl = RTLModule("test_emit")
        push!(rtl.ports, RTLPort("clk", 1, true, false))
        push!(rtl.ports, RTLPort("rst", 1, true, false))
        push!(rtl.ports, RTLPort("out", 8, false, false))

        push!(rtl.signals, RTLSignal("counter", 8, true, false, 0))

        rtl.state_names = ["IDLE", "RUN", "DONE"]
        rtl.state_encoding = Dict("IDLE" => 0, "RUN" => 1, "DONE" => 2)
        rtl.state_width = 2

        rtl.port_declarations = "input wire clk,\n    input wire rst,\n    output reg [7:0] out"
        rtl.signal_declarations = "reg [7:0] counter;"
        rtl.parameter_declarations = "localparam IDLE = 2'd0;\n    localparam RUN = 2'd1;\n    localparam DONE = 2'd2;"
        rtl.fsm_logic = ""
        rtl.datapath_logic = ""
        rtl.memory_logic = ""
        rtl.output_logic = "assign out = counter;"

        @testset "Emit Verilog" begin
            verilog = emit_verilog(rtl)

            @test contains(verilog, "module test_emit")
            @test contains(verilog, "endmodule")
            @test contains(verilog, "input wire clk")
            @test contains(verilog, "output reg")
            @test contains(verilog, "localparam IDLE")
        end

        @testset "Write Verilog File" begin
            tmpdir = mktempdir()
            filepath = joinpath(tmpdir, "test.v")

            write_verilog(rtl, filepath)

            @test isfile(filepath)

            content = read(filepath, String)
            @test contains(content, "module test_emit")
        end

        @testset "Emit Testbench" begin
            tb = emit_testbench(rtl)

            @test contains(tb, "module test_emit_tb")
            @test contains(tb, "test_emit dut")
            @test contains(tb, "initial begin")
            @test contains(tb, "clk = 0")
            @test contains(tb, "forever")
            @test contains(tb, "\$finish")
        end
    end

    @testset "FSM Generation" begin
        using FPGACompiler.RTL
        using FPGACompiler.HLS

        # Create CDFG with multiple states
        cdfg = CDFG("fsm_test")

        # Add states (positional: id, name)
        s1 = FSMState(1, "init")
        s2 = FSMState(2, "compute")
        s3 = FSMState(3, "finish")

        s1.successor_ids = [2]
        s1.transition_conditions = [-1]  # Unconditional

        s2.successor_ids = [3]
        s2.transition_conditions = [-1]

        push!(cdfg.states, s1)
        push!(cdfg.states, s2)
        push!(cdfg.states, s3)
        cdfg.entry_state_id = 1

        # Create minimal RTL
        rtl = RTLModule("fsm_test")
        rtl.state_names = ["IDLE", "S_INIT", "S_COMPUTE", "S_FINISH", "DONE"]
        rtl.state_encoding = Dict(
            "IDLE" => 0, "S_INIT" => 1, "S_COMPUTE" => 2,
            "S_FINISH" => 3, "DONE" => 4
        )
        rtl.state_width = 3

        @testset "Generate FSM Logic" begin
            fsm = generate_fsm(cdfg, rtl)

            @test contains(fsm, "always @(posedge clk")
            @test contains(fsm, "current_state")
            @test contains(fsm, "next_state")
            @test contains(fsm, "case")
            @test contains(fsm, "IDLE")
        end
    end

    @testset "Memory Interface Generation" begin
        using FPGACompiler.RTL
        using FPGACompiler.HLS

        # Test BRAM interface generation
        @testset "BRAM Interface" begin
            bram = generate_bram_interface("data_mem", 10, 32, 1, 1)

            @test contains(bram, "module data_mem_bram")
            @test contains(bram, "raddr")
            @test contains(bram, "waddr")
            @test contains(bram, "ren")
            @test contains(bram, "wen")
        end

        @testset "Partitioned Memory" begin
            pmem = generate_partitioned_memory("array", :cyclic, 4, 10, 32)

            @test contains(pmem, "module array_partitioned")
            @test contains(pmem, "bank_sel")
            @test contains(pmem, "bank_0")
            @test contains(pmem, "bank_1")
        end

        @testset "FIFO Interface" begin
            fifo = generate_fifo_interface("stream", 32, 16)

            @test contains(fifo, "module stream_fifo")
            @test contains(fifo, "din")
            @test contains(fifo, "dout")
            @test contains(fifo, "full")
            @test contains(fifo, "empty")
            @test contains(fifo, "wr_en")
            @test contains(fifo, "rd_en")
        end
    end
end
