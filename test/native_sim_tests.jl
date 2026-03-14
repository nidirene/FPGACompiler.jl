# Native RTL Simulator Tests
# Comprehensive tests for the native Julia simulation engine

using Test
using FPGACompiler
using FPGACompiler.HLS
using FPGACompiler.Sim
import FPGACompiler.Sim: Memory as SimMemory  # Avoid conflict with Core.Memory

@testset "Native RTL Simulator" begin

    @testset "SimValue Tests" begin
        @testset "Construction" begin
            # Default construction
            v0 = SimValue()
            @test !v0.is_valid
            @test v0.bit_width == 32

            # Integer construction
            v1 = SimValue(42, 32)
            @test v1.is_valid
            @test to_unsigned(v1) == 42
            @test v1.bit_width == 32

            # Signed value
            v2 = SimValue(-5, 32; signed=true)
            @test v2.is_valid
            @test to_signed(v2) == -5

            # Undefined value
            v3 = SimValue(nothing, 16)
            @test !v3.is_valid
            @test v3.bit_width == 16

            # Small width
            v4 = SimValue(255, 8)
            @test to_unsigned(v4) == 255

            # Overflow masking
            v5 = SimValue(256, 8)
            @test to_unsigned(v5) == 0  # Masked to 8 bits
        end

        @testset "Conversions" begin
            # Unsigned
            v = SimValue(200, 8)
            @test to_unsigned(v) == 200

            # Signed negative (2's complement)
            v_neg = SimValue(0xFF, 8; signed=true)  # -1 in 8-bit signed
            @test to_signed(v_neg) == -1

            # Boolean
            v_true = SimValue(1, 1)
            @test to_bool(v_true) == true

            v_false = SimValue(0, 1)
            @test to_bool(v_false) == false

            # X value conversion
            v_x = SimValue(nothing, 32)
            @test to_unsigned(v_x) == 0
            @test to_signed(v_x) == 0
            @test to_bool(v_x) == false
        end

        @testset "Mask" begin
            @test mask_for_width(1) == 0x1
            @test mask_for_width(8) == 0xFF
            @test mask_for_width(16) == 0xFFFF
            @test mask_for_width(32) == 0xFFFFFFFF
            @test mask_for_width(64) == 0xFFFFFFFFFFFFFFFF
        end
    end

    @testset "ALU Operations" begin
        @testset "Arithmetic" begin
            a = SimValue(10, 32)
            b = SimValue(5, 32)

            # Addition
            result = compute_alu_result(ALU_ADD, a, b, 32)
            @test to_unsigned(result) == 15

            # Subtraction
            result = compute_alu_result(ALU_SUB, a, b, 32)
            @test to_unsigned(result) == 5

            # Multiplication
            result = compute_alu_result(ALU_MUL, a, b, 32)
            @test to_unsigned(result) == 50

            # Division
            result = compute_alu_result(ALU_UDIV, a, b, 32)
            @test to_unsigned(result) == 2

            # Modulo
            result = compute_alu_result(ALU_UREM, a, b, 32)
            @test to_unsigned(result) == 0
        end

        @testset "Logic" begin
            a = SimValue(0b1100, 32)
            b = SimValue(0b1010, 32)

            # AND
            result = compute_alu_result(ALU_AND, a, b, 32)
            @test to_unsigned(result) == 0b1000

            # OR
            result = compute_alu_result(ALU_OR, a, b, 32)
            @test to_unsigned(result) == 0b1110

            # XOR
            result = compute_alu_result(ALU_XOR, a, b, 32)
            @test to_unsigned(result) == 0b0110
        end

        @testset "Shifts" begin
            a = SimValue(0b1000, 32)
            b = SimValue(2, 32)

            # Shift left
            result = compute_alu_result(ALU_SHL, a, b, 32)
            @test to_unsigned(result) == 0b100000

            # Shift right (logical)
            result = compute_alu_result(ALU_SHR, a, b, 32)
            @test to_unsigned(result) == 0b10

            # Shift right (arithmetic)
            neg = SimValue(0xFFFFFFFF, 32; signed=true)
            result = compute_alu_result(ALU_ASHR, neg, SimValue(4, 32), 32)
            @test to_signed(result) == -1  # Sign extended
        end

        @testset "Comparisons" begin
            a = SimValue(10, 32)
            b = SimValue(5, 32)

            # Equal
            result = compute_alu_result(ALU_EQ, a, b, 1)
            @test to_bool(result) == false

            result = compute_alu_result(ALU_EQ, a, a, 1)
            @test to_bool(result) == true

            # Not equal
            result = compute_alu_result(ALU_NE, a, b, 1)
            @test to_bool(result) == true

            # Less than
            result = compute_alu_result(ALU_ULT, b, a, 1)
            @test to_bool(result) == true

            # Greater than
            result = compute_alu_result(ALU_UGT, a, b, 1)
            @test to_bool(result) == true

            # Signed comparison
            neg = SimValue(-5, 32; signed=true)
            pos = SimValue(5, 32; signed=true)
            result = compute_alu_result(ALU_LT, neg, pos, 1)
            @test to_bool(result) == true
        end

        @testset "Extensions" begin
            # Zero extend
            small = SimValue(0xFF, 8)
            result = compute_alu_result(ALU_ZEXT, small, SimValue(0, 32), 32)
            @test to_unsigned(result) == 0xFF

            # Sign extend (negative)
            neg_small = SimValue(0xFF, 8; signed=true)  # -1 in 8 bits
            result = compute_alu_result(ALU_SEXT, neg_small, SimValue(0, 32), 32)
            @test to_signed(result) == -1

            # Truncate
            large = SimValue(0x12345678, 32)
            result = compute_alu_result(ALU_TRUNC, large, SimValue(0, 8), 8)
            @test to_unsigned(result) == 0x78
        end

        @testset "X Propagation" begin
            valid = SimValue(10, 32)
            invalid = SimValue(nothing, 32)

            # X input produces X output
            result = compute_alu_result(ALU_ADD, valid, invalid, 32)
            @test !result.is_valid
        end
    end

    @testset "MUX Operations" begin
        inputs = [SimValue(10, 32), SimValue(20, 32), SimValue(30, 32), SimValue(40, 32)]

        # Select input 0
        select = SimValue(0, 2)
        result = compute_mux_result(inputs, select)
        @test to_unsigned(result) == 10

        # Select input 2
        select = SimValue(2, 2)
        result = compute_mux_result(inputs, select)
        @test to_unsigned(result) == 30

        # X select produces X output
        x_select = SimValue(nothing, 2)
        result = compute_mux_result(inputs, x_select)
        @test !result.is_valid
    end

    @testset "Wire and Register" begin
        @testset "Wire" begin
            wire = Wire("test_wire", 32)
            @test wire.name == "test_wire"
            @test wire.bit_width == 32
            @test !wire.value.is_valid  # Initially undefined

            wire.value = SimValue(42, 32)
            @test to_unsigned(wire.value) == 42
        end

        @testset "Register" begin
            reg = Register("test_reg", 32; reset_value=100)
            @test reg.name == "test_reg"
            @test reg.bit_width == 32
            @test to_unsigned(reg.reset_value) == 100
            @test to_unsigned(reg.current_value) == 100  # Starts at reset value

            # Set next value
            reg.next_value = SimValue(200, 32)

            # Latch
            reg.current_value = reg.next_value
            @test to_unsigned(reg.current_value) == 200
        end
    end

    @testset "Memory Operations" begin
        mem = SimMemory("test_mem"; depth=16, word_width=32, read_latency=1)

        @test mem.depth == 16
        @test mem.word_width == 32
        @test mem.read_latency == 1

        # Write
        addr = SimValue(5, 4)
        data = SimValue(12345, 32)
        memory_write!(mem, addr, data)

        # Read back
        result = memory_read(mem, addr)
        @test to_unsigned(result) == 12345

        # Out of bounds read
        bad_addr = SimValue(100, 8)
        result = memory_read(mem, bad_addr)
        @test !result.is_valid
    end

    @testset "NativeSimulator Basic" begin
        # Create a simple simulator
        sim = NativeSimulator("test_sim")

        # Add ports
        in_port = Port(:a, 32; is_input=true)
        sim.input_ports[:a] = in_port
        sim.wires["a"] = in_port.wire

        out_port = Port(:result, 32; is_input=false)
        sim.output_ports[:result] = out_port
        sim.wires["result"] = out_port.wire

        # Add start/done
        start_port = Port(:start, 1; is_input=true)
        sim.input_ports[:start] = start_port
        sim.wires["start"] = start_port.wire
        sim.fsm.start_wire = start_port.wire

        done_port = Port(:done, 1; is_input=false)
        sim.output_ports[:done] = done_port
        sim.wires["done"] = done_port.wire
        sim.fsm.done_wire = done_port.wire

        # Configure simple FSM: IDLE -> COMPUTE -> DONE
        sim.fsm.state_names[0] = "IDLE"
        sim.fsm.state_names[1] = "COMPUTE"
        sim.fsm.state_names[2] = "DONE"
        sim.fsm.done_state = 2
        sim.fsm.transitions[0] = [FSMTransition(start_port.wire, 1, true)]
        sim.fsm.transitions[1] = [FSMTransition(nothing, 2, false)]
        sim.fsm.transitions[2] = [FSMTransition(nothing, 2, false)]  # Stay done

        # Reset
        reset!(sim)
        @test sim.cycle == 0
        @test sim.fsm.current_state == 0

        # Set input
        set_input!(sim, :a, 42)
        @test to_unsigned(sim.input_ports[:a].wire.value) == 42

        # Get state
        @test get_state(sim) == :IDLE
    end

    @testset "FSMController" begin
        fsm = FSMController("test_fsm"; num_states=4)

        # Configure states
        fsm.state_names[0] = "IDLE"
        fsm.state_names[1] = "STATE1"
        fsm.state_names[2] = "STATE2"
        fsm.state_names[3] = "DONE"
        fsm.done_state = 3

        # Add transitions
        fsm.transitions[0] = [FSMTransition(nothing, 1, false)]  # IDLE -> STATE1
        fsm.transitions[1] = [FSMTransition(nothing, 2, false)]  # STATE1 -> STATE2
        fsm.transitions[2] = [FSMTransition(nothing, 3, false)]  # STATE2 -> DONE

        @test fsm.current_state == 0
        @test fsm.idle_state == 0
        @test fsm.done_state == 3
    end

    @testset "ALU Unit" begin
        alu = ALU("test_alu", ALU_ADD, 32; latency=1)

        @test alu.name == "test_alu"
        @test alu.op == ALU_ADD
        @test alu.latency == 1

        # Set inputs
        alu.input_a.value = SimValue(10, 32)
        alu.input_b.value = SimValue(5, 32)

        # Evaluate
        evaluate_alu!(alu)

        @test to_unsigned(alu.output.value) == 15
    end

    @testset "MUX Unit" begin
        mux = MUX("test_mux", 4, 32)

        @test mux.name == "test_mux"
        @test mux.num_inputs == 4
        @test length(mux.inputs) == 4

        # Set inputs
        for (i, wire) in enumerate(mux.inputs)
            wire.value = SimValue(i * 10, 32)
        end

        # Select input 2
        mux.select.value = SimValue(2, 2)

        # Evaluate
        evaluate_mux!(mux)

        @test to_unsigned(mux.output.value) == 30
    end

    @testset "VCD Waveform" begin
        # Create writer to buffer
        buf = IOBuffer()
        writer = VCDWriter(buf; module_name="test")

        # Write header
        signals = [("clk", 1), ("data", 8), ("ready", 1)]
        write_vcd_header!(writer, signals)

        # Write some changes
        write_vcd_change!(writer, 0, "clk", SimValue(0, 1))
        write_vcd_change!(writer, 0, "data", SimValue(0xAB, 8))
        write_vcd_change!(writer, 10, "clk", SimValue(1, 1))
        write_vcd_change!(writer, 20, "clk", SimValue(0, 1))
        write_vcd_change!(writer, 20, "data", SimValue(0xCD, 8))

        close_vcd!(writer)

        # Check output
        vcd_content = String(take!(buf))
        @test contains(vcd_content, "\$timescale")
        @test contains(vcd_content, "test")
        @test contains(vcd_content, "\$var")
        @test contains(vcd_content, "\$dumpvars")
    end

    @testset "Debug Utilities" begin
        sim = NativeSimulator("debug_test")

        # Add a wire
        wire = Wire("test_signal", 32)
        wire.value = SimValue(123, 32)
        sim.wires["test_signal"] = wire

        # Add a register
        reg = Register("test_reg", 16; reset_value=0)
        reg.current_value = SimValue(456, 16)
        sim.registers["test_reg"] = reg

        # Get signal value
        val = get_signal_value(sim, "test_signal")
        @test to_unsigned(val) == 123

        # Test statistics
        stats = get_statistics(sim)
        @test stats[:num_wires] == 1
        @test stats[:num_registers] == 1
    end

    @testset "Trace Collection" begin
        sim = NativeSimulator("trace_test")

        # Add wire with trace
        wire = Wire("traced_wire", 8)
        wire.trace_enabled = true
        sim.wires["traced_wire"] = wire

        # Simulate some values
        wire.value = SimValue(10, 8)
        push!(wire.trace_history, (0, wire.value))

        wire.value = SimValue(20, 8)
        push!(wire.trace_history, (1, wire.value))

        wire.value = SimValue(30, 8)
        push!(wire.trace_history, (2, wire.value))

        # Collect traces
        traces = collect_traces(sim, ["traced_wire"])
        @test length(traces["traced_wire"]) == 3
        @test to_unsigned(traces["traced_wire"][1][2]) == 10
        @test to_unsigned(traces["traced_wire"][3][2]) == 30
    end

    @testset "Integration - Simple Adder CDFG" begin
        # Create a simple CDFG for a + b
        cdfg = CDFG("adder")

        # Input nodes
        node_a = DFGNode(1, OP_NOP, "input_a")
        node_a.bit_width = 32
        node_a.scheduled_cycle = 0
        push!(cdfg.nodes, node_a)
        push!(cdfg.input_nodes, node_a)

        node_b = DFGNode(2, OP_NOP, "input_b")
        node_b.bit_width = 32
        node_b.scheduled_cycle = 0
        push!(cdfg.nodes, node_b)
        push!(cdfg.input_nodes, node_b)

        # Add operation
        node_add = DFGNode(3, OP_ADD, "add_result")
        node_add.bit_width = 32
        node_add.scheduled_cycle = 1
        node_add.latency = 1
        push!(node_add.operands, node_a)
        push!(node_add.operands, node_b)
        push!(cdfg.nodes, node_add)

        # Output node
        node_out = DFGNode(4, OP_RET, "output")
        node_out.bit_width = 32
        node_out.scheduled_cycle = 2
        push!(node_out.operands, node_add)
        push!(cdfg.nodes, node_out)
        push!(cdfg.output_nodes, node_out)

        # Create simple state
        state = FSMState(1, "compute")
        push!(state.operations, node_add)
        state.num_cycles = 2
        push!(cdfg.states, state)
        cdfg.entry_state_id = 1

        # Create schedule
        schedule = Schedule(cdfg)
        schedule.total_cycles = 3

        # Build simulator
        sim = build_simulator(cdfg, schedule)

        @test sim.name == "adder"
        @test haskey(sim.input_ports, :input_a) || haskey(sim.wires, "input_a")
    end

end  # @testset "Native RTL Simulator"

# Run tests if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    include("runtests.jl")
end
