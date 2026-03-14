# Native RTL Simulator Waveform Output
# VCD file generation and signal tracing

# ============================================================================
# VCD File Generation
# ============================================================================

"""
    VCDWriter

Writer for Value Change Dump (VCD) format files.
"""
mutable struct VCDWriter
    io::IO
    timescale::String
    module_name::String
    signal_ids::Dict{String, String}
    next_id::Int
    current_time::Int
    last_values::Dict{String, SimValue}
    is_header_written::Bool
end

function VCDWriter(io::IO; timescale::String="1ns", module_name::String="top")
    VCDWriter(io, timescale, module_name, Dict{String, String}(),
              1, 0, Dict{String, SimValue}(), false)
end

"""
    generate_id(writer::VCDWriter)

Generate a unique identifier for VCD signal.
"""
function generate_id(writer::VCDWriter)::String
    id = ""
    n = writer.next_id
    writer.next_id += 1

    # Generate identifier using printable ASCII characters
    while n > 0
        id = Char('!' + (n % 94)) * id
        n ÷= 94
    end

    return isempty(id) ? "!" : id
end

"""
    write_vcd_header!(writer::VCDWriter, signals::Vector{Tuple{String, Int}})

Write VCD file header with signal definitions.
signals is a vector of (name, bit_width) tuples.
"""
function write_vcd_header!(writer::VCDWriter, signals::Vector{Tuple{String, Int}})
    io = writer.io

    # Date
    println(io, "\$date")
    println(io, "   $(Dates.format(Dates.now(), "e u d HH:MM:SS yyyy"))")
    println(io, "\$end")

    # Version
    println(io, "\$version")
    println(io, "   FPGACompiler.jl Native Simulator")
    println(io, "\$end")

    # Timescale
    println(io, "\$timescale $(writer.timescale) \$end")

    # Scope
    println(io, "\$scope module $(writer.module_name) \$end")

    # Variables
    for (name, width) in signals
        id = generate_id(writer)
        writer.signal_ids[name] = id

        var_type = width == 1 ? "wire" : "reg"
        println(io, "\$var $var_type $width $id $name \$end")
    end

    println(io, "\$upscope \$end")
    println(io, "\$enddefinitions \$end")

    # Initial values
    println(io, "\$dumpvars")
    for (name, _) in signals
        id = writer.signal_ids[name]
        println(io, "x$id")  # Initially undefined
    end
    println(io, "\$end")

    writer.is_header_written = true
end

"""
    write_vcd_change!(writer::VCDWriter, time::Int, name::String, value::SimValue)

Write a value change to VCD.
"""
function write_vcd_change!(writer::VCDWriter, time::Int, name::String, value::SimValue)
    if !haskey(writer.signal_ids, name)
        return
    end

    id = writer.signal_ids[name]

    # Check if time has changed
    if time != writer.current_time
        println(writer.io, "#$time")
        writer.current_time = time
    end

    # Check if value has changed
    if haskey(writer.last_values, name)
        if writer.last_values[name] == value
            return  # No change
        end
    end
    writer.last_values[name] = value

    # Write value
    if !value.is_valid
        if value.bit_width == 1
            println(writer.io, "x$id")
        else
            println(writer.io, "bx $id")
        end
    elseif value.bit_width == 1
        println(writer.io, "$(value.bits & 1)$id")
    else
        # Binary format for multi-bit values
        bits_str = bitstring(value.bits)[end-value.bit_width+1:end]
        println(writer.io, "b$bits_str $id")
    end
end

"""
    close_vcd!(writer::VCDWriter)

Finalize and close VCD file.
"""
function close_vcd!(writer::VCDWriter)
    # VCD files don't need explicit closing
    flush(writer.io)
end

# ============================================================================
# Simulation Tracing
# ============================================================================

"""
    trace_signals!(sim::NativeSimulator, signals::Vector{String})

Enable tracing for specified signals.
"""
function trace_signals!(sim::NativeSimulator, signals::Vector{String})
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
    end
end

"""
    trace_all!(sim::NativeSimulator)

Enable tracing for all signals.
"""
function trace_all!(sim::NativeSimulator)
    sim.trace_enabled = true

    # Trace all wires
    for (name, wire) in sim.wires
        wire.trace_enabled = true
        push!(sim.traced_signals, name)
    end

    # Trace all registers
    for (name, reg) in sim.registers
        reg.trace_enabled = true
        push!(sim.traced_signals, name)
    end
end

"""
    record_trace!(sim::NativeSimulator)

Record current values of all traced signals.
Called during simulation.
"""
function record_trace!(sim::NativeSimulator)
    cycle = sim.cycle

    # Record wire values
    for (name, wire) in sim.wires
        if wire.trace_enabled
            push!(wire.trace_history, (cycle, wire.value))
        end
    end

    # Record register values
    for (name, reg) in sim.registers
        if reg.trace_enabled
            push!(reg.trace_history, (cycle, reg.current_value))
        end
    end
end

# ============================================================================
# VCD File Output
# ============================================================================

"""
    write_vcd(sim::NativeSimulator, filepath::String)

Write simulation traces to a VCD file.
"""
function write_vcd(sim::NativeSimulator, filepath::String)
    open(filepath, "w") do io
        writer = VCDWriter(io; module_name=sim.name)

        # Collect all traced signals with their widths
        signals = Tuple{String, Int}[]

        # Add FSM state
        state_width = max(1, ceil(Int, log2(sim.fsm.num_states + 1)))
        push!(signals, ("fsm_state", state_width))

        # Add clock and done
        push!(signals, ("clk", 1))
        push!(signals, ("done", 1))
        push!(signals, ("start", 1))

        # Add traced wires
        for (name, wire) in sim.wires
            if wire.trace_enabled || name in sim.traced_signals
                push!(signals, (name, wire.bit_width))
            end
        end

        # Add traced registers
        for (name, reg) in sim.registers
            if reg.trace_enabled || name in sim.traced_signals
                push!(signals, (name, reg.bit_width))
            end
        end

        # Write header
        write_vcd_header!(writer, signals)

        # Write trace data
        # First, collect all events sorted by time
        events = collect_trace_events(sim)

        for (time, name, value) in events
            write_vcd_change!(writer, time, name, value)
        end

        close_vcd!(writer)
    end
end

"""
    collect_trace_events(sim::NativeSimulator)

Collect all trace events sorted by time.
"""
function collect_trace_events(sim::NativeSimulator)::Vector{Tuple{Int, String, SimValue}}
    events = Tuple{Int, String, SimValue}[]

    # Collect from wires
    for (name, wire) in sim.wires
        for (time, value) in wire.trace_history
            push!(events, (time, name, value))
        end
    end

    # Collect from registers
    for (name, reg) in sim.registers
        for (time, value) in reg.trace_history
            push!(events, (name, name, value))
        end
    end

    # Add FSM state transitions
    for (i, state_id) in enumerate(sim.states_visited)
        state_width = max(1, ceil(Int, log2(sim.fsm.num_states + 1)))
        push!(events, (i, "fsm_state", SimValue(state_id, state_width)))
    end

    # Sort by time
    sort!(events, by=e -> e[1])

    return events
end

# ============================================================================
# ASCII Waveform Output (for terminal)
# ============================================================================

"""
    print_waveform(traces::Dict{String, Vector{Tuple{Int, SimValue}}};
                   max_cycles::Int=50)

Print ASCII waveform representation to terminal.
"""
function print_waveform(traces::Dict{String, Vector{Tuple{Int, SimValue}}};
                        max_cycles::Int=50, width::Int=80)

    # Find the longest signal name for alignment
    max_name_len = maximum(length(name) for name in keys(traces); init=0)
    max_name_len = min(max_name_len, 20)  # Cap at 20 chars

    # Calculate available width for waveform
    wave_width = width - max_name_len - 5

    for (name, history) in traces
        # Truncate/pad name
        display_name = length(name) > max_name_len ? name[1:max_name_len] : rpad(name, max_name_len)

        # Build waveform string
        wave = IOBuffer()
        last_value = SimValue()
        last_cycle = 0

        for (cycle, value) in history
            if cycle > max_cycles
                break
            end

            # Fill gaps with last value
            while last_cycle < cycle && last_cycle < max_cycles
                write(wave, value_to_char(last_value))
                last_cycle += 1
            end

            last_value = value
        end

        # Fill remaining
        while last_cycle < max_cycles
            write(wave, value_to_char(last_value))
            last_cycle += 1
        end

        # Print
        wave_str = String(take!(wave))
        if length(wave_str) > wave_width
            wave_str = wave_str[1:wave_width]
        end
        println("$display_name | $wave_str")
    end
end

"""
    value_to_char(value::SimValue)

Convert a SimValue to a single character for ASCII waveform.
"""
function value_to_char(value::SimValue)::Char
    if !value.is_valid
        return 'x'
    elseif value.bit_width == 1
        return value.bits == 1 ? '▀' : '_'
    else
        # For multi-bit, show as digit or letter
        v = value.bits & 0xF
        if v < 10
            return Char('0' + v)
        else
            return Char('A' + v - 10)
        end
    end
end

"""
    print_signal_table(sim::NativeSimulator; cycles::UnitRange{Int}=1:10)

Print a table of signal values over time.
"""
function print_signal_table(sim::NativeSimulator; cycles::UnitRange{Int}=1:10)
    # Collect traced signals
    signals = String[]
    for (name, wire) in sim.wires
        if wire.trace_enabled && !isempty(wire.trace_history)
            push!(signals, name)
        end
    end
    for (name, reg) in sim.registers
        if reg.trace_enabled && !isempty(reg.trace_history)
            push!(signals, name)
        end
    end

    sort!(signals)

    # Print header
    print(rpad("Signal", 20))
    for c in cycles
        print(" | ", lpad(string(c), 4))
    end
    println()
    println("-" ^ (20 + 7 * length(cycles)))

    # Print each signal
    for signal in signals
        print(rpad(signal[1:min(length(signal), 19)], 20))

        # Get history
        history = if haskey(sim.wires, signal)
            sim.wires[signal].trace_history
        elseif haskey(sim.registers, signal)
            sim.registers[signal].trace_history
        else
            Tuple{Int, SimValue}[]
        end

        # Build cycle -> value map
        cycle_values = Dict{Int, SimValue}()
        for (cycle, value) in history
            cycle_values[cycle] = value
        end

        # Print values for each cycle
        last_value = SimValue()
        for c in cycles
            if haskey(cycle_values, c)
                last_value = cycle_values[c]
            end

            if !last_value.is_valid
                print(" |    X")
            elseif last_value.bit_width == 1
                print(" |    ", last_value.bits == 1 ? "1" : "0")
            else
                val = to_unsigned(last_value)
                print(" | ", lpad(string(val), 4))
            end
        end
        println()
    end
end

# ============================================================================
# Trace Analysis
# ============================================================================

"""
    find_transitions(history::Vector{Tuple{Int, SimValue}})

Find all value transitions in a trace history.
"""
function find_transitions(history::Vector{Tuple{Int, SimValue}})::Vector{Tuple{Int, SimValue, SimValue}}
    transitions = Tuple{Int, SimValue, SimValue}[]

    if length(history) < 2
        return transitions
    end

    for i in 2:length(history)
        prev_cycle, prev_value = history[i-1]
        curr_cycle, curr_value = history[i]

        if prev_value != curr_value
            push!(transitions, (curr_cycle, prev_value, curr_value))
        end
    end

    return transitions
end

"""
    count_toggles(history::Vector{Tuple{Int, SimValue}})

Count the number of value transitions in a trace.
"""
function count_toggles(history::Vector{Tuple{Int, SimValue}})::Int
    length(find_transitions(history))
end
