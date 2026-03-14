# Native RTL Simulator Debug Utilities
# Debugging and inspection tools for simulation

# ============================================================================
# State Inspection
# ============================================================================

"""
    dump_state(sim::NativeSimulator)

Print complete simulation state for debugging.
"""
function dump_state(sim::NativeSimulator)
    println("=" ^ 60)
    println("Simulation State: $(sim.name)")
    println("=" ^ 60)

    # Cycle info
    println("\nCycle: $(sim.cycle)")
    println("Done: $(sim.is_done)")
    println("Started: $(sim.is_started)")

    # FSM state
    println("\nFSM State:")
    state_name = get(sim.fsm.state_names, sim.fsm.current_state, "S$(sim.fsm.current_state)")
    println("  Current: $state_name ($(sim.fsm.current_state))")
    println("  Next: $(sim.fsm.next_state)")
    println("  Cycle in state: $(sim.fsm.cycle_in_state)")

    # Input ports
    println("\nInput Ports:")
    for (name, port) in sort(collect(sim.input_ports), by=x->String(x[1]))
        println("  $name = $(port.wire.value)")
    end

    # Output ports
    println("\nOutput Ports:")
    for (name, port) in sort(collect(sim.output_ports), by=x->String(x[1]))
        println("  $name = $(port.wire.value)")
    end

    # Registers
    if !isempty(sim.registers)
        println("\nRegisters:")
        for (name, reg) in sort(collect(sim.registers), by=x->x[1])
            println("  $name: Q=$(reg.current_value), D=$(reg.next_value)")
        end
    end

    # Key wires
    println("\nKey Wires (first 20):")
    wire_list = sort(collect(sim.wires), by=x->x[1])
    for (name, wire) in wire_list[1:min(20, length(wire_list))]
        if wire.value.is_valid
            println("  $name = $(wire.value)")
        end
    end

    println("=" ^ 60)
end

"""
    dump_fsm(sim::NativeSimulator)

Print FSM structure and transitions.
"""
function dump_fsm(sim::NativeSimulator)
    fsm = sim.fsm

    println("=" ^ 40)
    println("FSM: $(fsm.name)")
    println("=" ^ 40)

    println("\nStates:")
    for (id, name) in sort(collect(fsm.state_names), by=x->x[1])
        cycles = get(fsm.state_cycles, id, 1)
        is_current = id == fsm.current_state ? " <-- CURRENT" : ""
        is_done = id == fsm.done_state ? " (DONE)" : ""
        println("  [$id] $name ($cycles cycles)$is_done$is_current")
    end

    println("\nTransitions:")
    for (state_id, transitions) in sort(collect(fsm.transitions), by=x->x[1])
        state_name = get(fsm.state_names, state_id, "S$state_id")
        println("  From $state_name:")
        for trans in transitions
            target_name = get(fsm.state_names, trans.target_state, "S$(trans.target_state)")
            if trans.is_conditional
                cond = trans.condition !== nothing ? trans.condition.name : "???"
                println("    -> $target_name (if $cond)")
            else
                println("    -> $target_name (unconditional)")
            end
        end
    end

    println("\nVisited states: $(sim.states_visited)")
end

"""
    dump_datapath(sim::NativeSimulator)

Print datapath structure (ALUs, MUXes, connections).
"""
function dump_datapath(sim::NativeSimulator)
    println("=" ^ 40)
    println("Datapath Structure")
    println("=" ^ 40)

    # ALUs
    if !isempty(sim.alus)
        println("\nALUs:")
        for (name, alu) in sort(collect(sim.alus), by=x->x[1])
            op_str = string(alu.op)
            lat_str = alu.latency > 1 ? " (lat=$(alu.latency))" : ""
            println("  $name: $op_str$lat_str")
            println("    A: $(alu.input_a.name) = $(alu.input_a.value)")
            if alu.input_b !== nothing
                println("    B: $(alu.input_b.name) = $(alu.input_b.value)")
            end
            println("    Out: $(alu.output.name) = $(alu.output.value)")
        end
    end

    # MUXes
    if !isempty(sim.muxes)
        println("\nMUXes:")
        for (name, mux) in sort(collect(sim.muxes), by=x->x[1])
            println("  $name: $(mux.num_inputs)-input")
            println("    Sel: $(mux.select.name) = $(mux.select.value)")
            for (i, inp) in enumerate(mux.inputs)
                println("    In[$i]: $(inp.name) = $(inp.value)")
            end
            println("    Out: $(mux.output.name) = $(mux.output.value)")
        end
    end

    # Memories
    if !isempty(sim.memories)
        println("\nMemories:")
        for (name, mem) in sort(collect(sim.memories), by=x->x[1])
            println("  $name: $(mem.depth) x $(mem.word_width)-bit")
            println("    Read latency: $(mem.read_latency)")
            println("    Banks: $(mem.num_banks)")
        end
    end
end

# ============================================================================
# Breakpoints and Watchpoints
# ============================================================================

"""
    BreakCondition

Represents a condition for stopping simulation.
"""
struct BreakCondition
    signal::String
    op::Symbol          # :eq, :ne, :gt, :lt, :ge, :le
    value::Integer
    description::String
end

"""
    Breakpoint

Represents a breakpoint in simulation.
"""
mutable struct Breakpoint
    id::Int
    condition::BreakCondition
    enabled::Bool
    hit_count::Int
end

"""
    check_breakpoint(bp::Breakpoint, sim::NativeSimulator)

Check if a breakpoint condition is met.
"""
function check_breakpoint(bp::Breakpoint, sim::NativeSimulator)::Bool
    if !bp.enabled
        return false
    end

    # Get signal value
    sig_value = get_signal_value(sim, bp.condition.signal)
    if !sig_value.is_valid
        return false
    end

    current = to_signed(sig_value)
    target = bp.condition.value

    result = if bp.condition.op == :eq
        current == target
    elseif bp.condition.op == :ne
        current != target
    elseif bp.condition.op == :gt
        current > target
    elseif bp.condition.op == :lt
        current < target
    elseif bp.condition.op == :ge
        current >= target
    elseif bp.condition.op == :le
        current <= target
    else
        false
    end

    if result
        bp.hit_count += 1
    end

    return result
end

# ============================================================================
# Debug Commands
# ============================================================================

"""
    watch(sim::NativeSimulator, signal::String)

Add a signal to watch list (enables tracing).
"""
function watch(sim::NativeSimulator, signal::String)
    push!(sim.traced_signals, signal)

    if haskey(sim.wires, signal)
        sim.wires[signal].trace_enabled = true
        println("Watching wire: $signal")
    elseif haskey(sim.registers, signal)
        sim.registers[signal].trace_enabled = true
        println("Watching register: $signal")
    else
        println("Warning: Signal '$signal' not found")
    end
end

"""
    unwatch(sim::NativeSimulator, signal::String)

Remove a signal from watch list.
"""
function unwatch(sim::NativeSimulator, signal::String)
    delete!(sim.traced_signals, signal)

    if haskey(sim.wires, signal)
        sim.wires[signal].trace_enabled = false
    elseif haskey(sim.registers, signal)
        sim.registers[signal].trace_enabled = false
    end
end

"""
    examine(sim::NativeSimulator, signal::String)

Print detailed information about a signal.
"""
function examine(sim::NativeSimulator, signal::String)
    println("Examining: $signal")
    println("-" ^ 30)

    if haskey(sim.wires, signal)
        wire = sim.wires[signal]
        println("Type: Wire")
        println("Width: $(wire.bit_width) bits")
        println("Value: $(wire.value)")
        if wire.value.is_valid
            println("  Unsigned: $(to_unsigned(wire.value))")
            println("  Signed: $(to_signed(wire.value))")
            println("  Hex: 0x$(string(to_unsigned(wire.value), base=16))")
        end
        println("Driver: $(wire.driver !== nothing ? typeof(wire.driver) : "none")")
        println("Fanout: $(length(wire.fanout)) consumers")

    elseif haskey(sim.registers, signal)
        reg = sim.registers[signal]
        println("Type: Register")
        println("Width: $(reg.bit_width) bits")
        println("Current (Q): $(reg.current_value)")
        println("Next (D): $(reg.next_value)")
        println("Reset: $(reg.reset_value)")
        println("Enable: $(reg.enable_wire !== nothing ? reg.enable_wire.name : "always")")

    elseif haskey(sim.memories, signal)
        mem = sim.memories[signal]
        println("Type: Memory")
        println("Size: $(mem.depth) x $(mem.word_width)-bit")
        println("Read latency: $(mem.read_latency) cycles")
        println("Write latency: $(mem.write_latency) cycles")
        println("Banks: $(mem.num_banks)")

    else
        println("Signal not found: $signal")
    end
end

"""
    list_signals(sim::NativeSimulator; filter::String="")

List all signals in the simulation.
"""
function list_signals(sim::NativeSimulator; filter::String="", show_values::Bool=false)
    println("Signals in $(sim.name):")
    println("-" ^ 40)

    all_signals = String[]

    # Collect all signal names
    for name in keys(sim.wires)
        if isempty(filter) || contains(name, filter)
            push!(all_signals, "W: $name")
        end
    end
    for name in keys(sim.registers)
        if isempty(filter) || contains(name, filter)
            push!(all_signals, "R: $name")
        end
    end
    for name in keys(sim.memories)
        if isempty(filter) || contains(name, filter)
            push!(all_signals, "M: $name")
        end
    end

    sort!(all_signals)

    for sig in all_signals
        if show_values
            sig_name = split(sig, ": ")[2]
            val = try
                get_signal_value(sim, sig_name)
            catch
                SimValue()
            end
            println("  $sig = $val")
        else
            println("  $sig")
        end
    end

    println("-" ^ 40)
    println("Total: $(length(all_signals)) signals")
end

# ============================================================================
# Assertion Checking
# ============================================================================

"""
    SimAssertion

A simulation-time assertion.
"""
struct SimAssertion
    name::String
    condition::Function     # (sim) -> Bool
    message::String
    fatal::Bool
end

"""
    check_assertions(sim::NativeSimulator, assertions::Vector{SimAssertion})

Check all assertions, return list of failures.
"""
function check_assertions(sim::NativeSimulator, assertions::Vector{SimAssertion})::Vector{SimAssertion}
    failures = SimAssertion[]

    for assertion in assertions
        try
            if !assertion.condition(sim)
                push!(failures, assertion)
                if assertion.fatal
                    println("FATAL: $(assertion.name) failed at cycle $(sim.cycle)")
                    println("  Message: $(assertion.message)")
                end
            end
        catch e
            println("Warning: Assertion $(assertion.name) threw exception: $e")
        end
    end

    return failures
end

# ============================================================================
# Comparison and Verification
# ============================================================================

"""
    compare_results(sim::NativeSimulator, expected::Dict{Symbol, Integer})

Compare simulation outputs with expected values.
Returns (match::Bool, details::Vector{String})
"""
function compare_results(sim::NativeSimulator, expected::Dict{Symbol, <:Integer})::Tuple{Bool, Vector{String}}
    all_match = true
    details = String[]

    for (port_name, expected_value) in expected
        if !haskey(sim.output_ports, port_name)
            push!(details, "Missing port: $port_name")
            all_match = false
            continue
        end

        actual = sim.output_ports[port_name].wire.value

        if !actual.is_valid
            push!(details, "$port_name: expected $expected_value, got X (undefined)")
            all_match = false
        else
            actual_val = to_unsigned(actual)
            if actual_val != unsigned(expected_value)
                push!(details, "$port_name: expected $expected_value, got $actual_val")
                all_match = false
            else
                push!(details, "$port_name: OK ($actual_val)")
            end
        end
    end

    return (all_match, details)
end

"""
    verify_against_reference(sim::NativeSimulator, ref_func::Function,
                             inputs::Dict{Symbol, <:Integer})

Compare simulation against a Julia reference function.
"""
function verify_against_reference(sim::NativeSimulator, ref_func::Function,
                                   inputs::Dict{Symbol, <:Integer})::Tuple{Bool, Dict{Symbol, Any}}
    # Run reference function
    ref_inputs = [inputs[name] for name in sort(collect(keys(inputs)))]
    ref_result = ref_func(ref_inputs...)

    # Get simulation outputs
    sim_outputs = Dict{Symbol, Integer}()
    for (name, port) in sim.output_ports
        if name != :done  # Skip control signal
            sim_outputs[name] = to_unsigned(port.wire.value)
        end
    end

    # Compare
    match = true
    comparison = Dict{Symbol, Any}()

    if ref_result isa Integer
        # Single output
        if length(sim_outputs) == 1
            out_name = first(keys(sim_outputs))
            sim_val = sim_outputs[out_name]
            comparison[out_name] = (expected=ref_result, actual=sim_val, match=sim_val==ref_result)
            match = sim_val == ref_result
        else
            comparison[:error] = "Reference returned single value but simulation has multiple outputs"
            match = false
        end
    elseif ref_result isa Tuple
        # Multiple outputs
        ref_vals = collect(ref_result)
        for (i, (name, sim_val)) in enumerate(sort(collect(sim_outputs)))
            if i <= length(ref_vals)
                ref_val = ref_vals[i]
                comparison[name] = (expected=ref_val, actual=sim_val, match=sim_val==ref_val)
                match = match && (sim_val == ref_val)
            end
        end
    end

    return (match, comparison)
end

# ============================================================================
# Debug Output Formatting
# ============================================================================

"""
    format_hex(value::SimValue)

Format a SimValue as hexadecimal.
"""
function format_hex(value::SimValue)::String
    if !value.is_valid
        return "X"
    end

    width_hex = (value.bit_width + 3) ÷ 4
    return "0x" * lpad(string(to_unsigned(value), base=16), width_hex, '0')
end

"""
    format_binary(value::SimValue)

Format a SimValue as binary.
"""
function format_binary(value::SimValue)::String
    if !value.is_valid
        return repeat("x", value.bit_width)
    end

    bits = bitstring(value.bits)
    return bits[end-value.bit_width+1:end]
end
