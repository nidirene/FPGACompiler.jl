# Native RTL Simulator Engine
# Main simulation loop with two-phase clock semantics

# ============================================================================
# Simulation Control Functions
# ============================================================================

"""
    reset!(sim::NativeSimulator)

Reset the simulator to initial state.
All registers reset to their reset values, FSM returns to idle.
"""
function reset!(sim::NativeSimulator)
    # Reset all registers
    for (_, reg) in sim.registers
        reg.current_value = reg.reset_value
        reg.next_value = reg.reset_value
        reg.output_wire.value = reg.reset_value
    end

    # Reset all wires to undefined
    for (_, wire) in sim.wires
        wire.value = SimValue(nothing, wire.bit_width)
    end

    # Reset ALU pipelines
    for (_, alu) in sim.alus
        for i in 1:length(alu.pipeline_stages)
            alu.pipeline_stages[i] = SimValue()
            alu.pipeline_valid[i] = false
        end
        alu.is_active = false
        alu.output.value = SimValue(nothing, alu.output.bit_width)
    end

    # Reset memory pipelines
    for (_, mem) in sim.memories
        for i in 1:length(mem.read_pipeline)
            mem.read_pipeline[i] = SimValue()
            mem.read_pipeline_valid[i] = false
        end
        mem.read_data.value = SimValue(nothing, mem.word_width)
    end

    # Reset FSM
    sim.fsm.current_state = sim.fsm.idle_state
    sim.fsm.next_state = sim.fsm.idle_state
    sim.fsm.cycle_in_state = 0
    sim.fsm.done_wire.value = SimValue(0, 1)
    sim.fsm.start_wire.value = SimValue(0, 1)

    # Reset simulation state
    sim.cycle = 0
    sim.is_done = false
    sim.is_started = false
    sim.total_cycles = 0
    empty!(sim.states_visited)

    # Clear trace histories
    for (_, wire) in sim.wires
        empty!(wire.trace_history)
    end
    for (_, reg) in sim.registers
        empty!(reg.trace_history)
    end
    for (_, mem) in sim.memories
        empty!(mem.access_history)
    end
end

"""
    tick!(sim::NativeSimulator)

Execute one clock cycle with proper two-phase semantics:
1. Phase 1 (Combinational): Propagate all wires through ALUs/MUXes
2. Phase 2 (Sequential): Registers latch, FSM transitions

Returns true if simulation should continue.
"""
function tick!(sim::NativeSimulator)::Bool
    # Check if already done or exceeded max cycles
    if sim.is_done || sim.cycle >= sim.max_cycles
        return false
    end

    # Phase 1: Evaluate combinational logic
    evaluate_combinational!(sim)

    # Phase 2: Evaluate sequential logic (clock edge)
    evaluate_sequential!(sim)

    # Continue if not done
    return !sim.is_done && sim.cycle < sim.max_cycles
end

"""
    run!(sim::NativeSimulator; max_cycles::Int=10000, verbose::Bool=false)

Run simulation until completion or max cycles reached.
Returns a SimulationResult.
"""
function run!(sim::NativeSimulator;
              max_cycles::Int=10000,
              verbose::Bool=false)::SimulationResult

    sim.max_cycles = max_cycles

    # Capture start state
    if verbose
        println("Starting simulation of $(sim.name)")
        println("Initial state: $(sim.fsm.state_names[sim.fsm.current_state])")
    end

    # Run simulation loop
    while tick!(sim)
        if verbose && sim.cycle % 100 == 0
            state_name = get(sim.fsm.state_names, sim.fsm.current_state, "S$(sim.fsm.current_state)")
            println("  Cycle $(sim.cycle): State = $state_name")
        end
    end

    if verbose
        if sim.is_done
            println("Simulation completed successfully in $(sim.cycle) cycles")
        else
            println("Simulation ended after $(sim.cycle) cycles (max cycles reached)")
        end
    end

    # Collect outputs
    outputs = Dict{String, Any}()
    for (name, port) in sim.output_ports
        outputs[String(name)] = to_unsigned(port.wire.value)
    end

    return SimulationResult(
        sim.is_done,
        "",  # output string
        "",  # error output
        sim.is_done ? 0 : 1,  # exit code
        sim.cycle,
        outputs,
        nothing  # VCD file
    )
end

"""
    start!(sim::NativeSimulator)

Assert the start signal to begin computation.
"""
function start!(sim::NativeSimulator)
    sim.fsm.start_wire.value = SimValue(1, 1)
    sim.is_started = true

    # Run one cycle with start asserted
    tick!(sim)

    # Deassert start
    sim.fsm.start_wire.value = SimValue(0, 1)
end

# ============================================================================
# Input/Output Interface
# ============================================================================

"""
    set_input!(sim::NativeSimulator, port_name::Symbol, value::Integer)

Set an input port value.
"""
function set_input!(sim::NativeSimulator, port_name::Symbol, value::Integer)
    if !haskey(sim.input_ports, port_name)
        error("Unknown input port: $port_name")
    end

    port = sim.input_ports[port_name]
    port.wire.value = SimValue(value, port.bit_width; signed=port.is_signed)
end

"""
    set_input!(sim::NativeSimulator, port_name::Symbol, value::SimValue)

Set an input port value with a SimValue.
"""
function set_input!(sim::NativeSimulator, port_name::Symbol, value::SimValue)
    if !haskey(sim.input_ports, port_name)
        error("Unknown input port: $port_name")
    end

    port = sim.input_ports[port_name]
    port.wire.value = value
end

"""
    set_inputs!(sim::NativeSimulator, inputs::Dict{Symbol, <:Integer})

Set multiple input port values.
"""
function set_inputs!(sim::NativeSimulator, inputs::Dict{Symbol, <:Integer})
    for (name, value) in inputs
        set_input!(sim, name, value)
    end
end

"""
    get_output(sim::NativeSimulator, port_name::Symbol)

Get an output port value.
"""
function get_output(sim::NativeSimulator, port_name::Symbol)::SimValue
    if !haskey(sim.output_ports, port_name)
        error("Unknown output port: $port_name")
    end

    return sim.output_ports[port_name].wire.value
end

"""
    get_outputs(sim::NativeSimulator)

Get all output port values as a dictionary.
"""
function get_outputs(sim::NativeSimulator)::Dict{Symbol, SimValue}
    outputs = Dict{Symbol, SimValue}()
    for (name, port) in sim.output_ports
        outputs[name] = port.wire.value
    end
    return outputs
end

"""
    get_state(sim::NativeSimulator)

Get the current FSM state as a symbol.
"""
function get_state(sim::NativeSimulator)::Symbol
    state_id = sim.fsm.current_state
    state_name = get(sim.fsm.state_names, state_id, "S$state_id")
    return Symbol(state_name)
end

"""
    is_done(sim::NativeSimulator)

Check if simulation has completed.
"""
function is_done(sim::NativeSimulator)::Bool
    sim.is_done
end

# ============================================================================
# Signal Access
# ============================================================================

"""
    get_wire(sim::NativeSimulator, name::String)

Get a wire by name.
"""
function get_wire(sim::NativeSimulator, name::String)::Union{Wire, Nothing}
    get(sim.wires, name, nothing)
end

"""
    get_register(sim::NativeSimulator, name::String)

Get a register by name.
"""
function get_register(sim::NativeSimulator, name::String)::Union{Register, Nothing}
    get(sim.registers, name, nothing)
end

"""
    get_signal_value(sim::NativeSimulator, name::String)

Get the current value of a signal (wire or register).
"""
function get_signal_value(sim::NativeSimulator, name::String)::SimValue
    # Check wires
    wire = get_wire(sim, name)
    if wire !== nothing
        return wire.value
    end

    # Check registers
    reg = get_register(sim, name)
    if reg !== nothing
        return reg.current_value
    end

    # Check ports
    for (pname, port) in sim.input_ports
        if String(pname) == name
            return port.wire.value
        end
    end
    for (pname, port) in sim.output_ports
        if String(pname) == name
            return port.wire.value
        end
    end

    error("Unknown signal: $name")
end

# ============================================================================
# Memory Access
# ============================================================================

"""
    read_memory(sim::NativeSimulator, mem_name::String, addr::Integer)

Read a value from memory directly (for debugging/initialization).
"""
function read_memory(sim::NativeSimulator, mem_name::String, addr::Integer)::SimValue
    if !haskey(sim.memories, mem_name)
        error("Unknown memory: $mem_name")
    end

    mem = sim.memories[mem_name]
    idx = addr + 1
    if idx < 1 || idx > mem.depth
        return SimValue(nothing, mem.word_width)
    end

    return mem.data[idx]
end

"""
    write_memory!(sim::NativeSimulator, mem_name::String, addr::Integer, value::Integer)

Write a value to memory directly (for initialization).
"""
function write_memory!(sim::NativeSimulator, mem_name::String, addr::Integer, value::Integer)
    if !haskey(sim.memories, mem_name)
        error("Unknown memory: $mem_name")
    end

    mem = sim.memories[mem_name]
    idx = addr + 1
    if idx < 1 || idx > mem.depth
        return
    end

    mem.data[idx] = SimValue(value, mem.word_width)
end

"""
    initialize_memory!(sim::NativeSimulator, mem_name::String, data::Vector{<:Integer})

Initialize memory contents from a vector.
"""
function initialize_memory!(sim::NativeSimulator, mem_name::String, data::Vector{<:Integer})
    if !haskey(sim.memories, mem_name)
        error("Unknown memory: $mem_name")
    end

    mem = sim.memories[mem_name]
    for (i, value) in enumerate(data)
        if i > mem.depth
            break
        end
        mem.data[i] = SimValue(value, mem.word_width)
    end
end

# ============================================================================
# Cycle-by-Cycle Debug Interface
# ============================================================================

"""
    step!(sim::NativeSimulator)

Execute a single clock cycle and return detailed state.
"""
function step!(sim::NativeSimulator)::Dict{Symbol, Any}
    prev_cycle = sim.cycle
    prev_state = sim.fsm.current_state

    # Execute cycle
    continuing = tick!(sim)

    # Collect state information
    state = Dict{Symbol, Any}(
        :cycle => sim.cycle,
        :prev_cycle => prev_cycle,
        :fsm_state => get_state(sim),
        :prev_fsm_state => get(sim.fsm.state_names, prev_state, "S$prev_state"),
        :is_done => sim.is_done,
        :continuing => continuing,
    )

    # Collect output values
    for (name, port) in sim.output_ports
        state[name] = port.wire.value
    end

    return state
end

"""
    peek_combinational!(sim::NativeSimulator)

Evaluate combinational logic without advancing clock.
Useful for debugging to see intermediate values.
"""
function peek_combinational!(sim::NativeSimulator)
    evaluate_combinational!(sim)
end

# ============================================================================
# Simulation Statistics
# ============================================================================

"""
    get_statistics(sim::NativeSimulator)

Get simulation statistics.
"""
function get_statistics(sim::NativeSimulator)::Dict{Symbol, Any}
    Dict{Symbol, Any}(
        :total_cycles => sim.total_cycles,
        :states_visited => length(sim.states_visited),
        :unique_states => length(unique(sim.states_visited)),
        :is_done => sim.is_done,
        :num_registers => length(sim.registers),
        :num_wires => length(sim.wires),
        :num_alus => length(sim.alus),
        :num_memories => length(sim.memories),
    )
end

# ============================================================================
# High-Level Simulation Interface
# ============================================================================

"""
    simulate(sim::NativeSimulator, inputs::Dict{Symbol, <:Integer};
             max_cycles::Int=10000, verbose::Bool=false)

Complete simulation workflow: set inputs, start, run until done.
"""
function simulate_native(sim::NativeSimulator, inputs::Dict{Symbol, <:Integer};
                         max_cycles::Int=10000, verbose::Bool=false)::SimulationResult
    # Reset
    reset!(sim)

    # Set inputs
    set_inputs!(sim, inputs)

    # Start
    start!(sim)

    # Run
    return run!(sim; max_cycles=max_cycles, verbose=verbose)
end

"""
    simulate_with_trace(sim::NativeSimulator, inputs::Dict{Symbol, <:Integer},
                        signals::Vector{String};
                        max_cycles::Int=10000)

Simulate with signal tracing enabled.
"""
function simulate_with_trace(sim::NativeSimulator, inputs::Dict{Symbol, <:Integer},
                             signals::Vector{String};
                             max_cycles::Int=10000)::Tuple{SimulationResult, Dict{String, Vector{Tuple{Int, SimValue}}}}
    # Enable tracing
    enable_trace!(sim, signals)

    # Run simulation
    result = simulate_native(sim, inputs; max_cycles=max_cycles)

    # Collect traces
    traces = collect_traces(sim, signals)

    return (result, traces)
end

"""
    enable_trace!(sim::NativeSimulator, signals::Vector{String})

Enable tracing for specified signals.
"""
function enable_trace!(sim::NativeSimulator, signals::Vector{String})
    sim.trace_enabled = true
    for signal in signals
        push!(sim.traced_signals, signal)

        # Enable on wire
        if haskey(sim.wires, signal)
            sim.wires[signal].trace_enabled = true
        end

        # Enable on register
        if haskey(sim.registers, signal)
            sim.registers[signal].trace_enabled = true
        end

        # Enable on memory
        if haskey(sim.memories, signal)
            sim.memories[signal].trace_enabled = true
        end
    end
end

"""
    collect_traces(sim::NativeSimulator, signals::Vector{String})

Collect recorded trace data.
"""
function collect_traces(sim::NativeSimulator, signals::Vector{String})::Dict{String, Vector{Tuple{Int, SimValue}}}
    traces = Dict{String, Vector{Tuple{Int, SimValue}}}()

    for signal in signals
        if haskey(sim.wires, signal)
            traces[signal] = sim.wires[signal].trace_history
        elseif haskey(sim.registers, signal)
            traces[signal] = sim.registers[signal].trace_history
        end
    end

    return traces
end
