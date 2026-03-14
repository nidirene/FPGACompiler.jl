# Verilator Integration
# Provides Verilator simulation capabilities from Julia

"""
    VerilatorConfig

Configuration for Verilator simulation.
"""
struct VerilatorConfig
    verilator_path::String
    trace_enabled::Bool
    trace_depth::Int
    optimization_level::Int
    extra_flags::Vector{String}
    include_paths::Vector{String}
    defines::Dict{String, String}
end

function VerilatorConfig(;
    verilator_path::String = "verilator",
    trace_enabled::Bool = true,
    trace_depth::Int = 99,
    optimization_level::Int = 3,
    extra_flags::Vector{String} = String[],
    include_paths::Vector{String} = String[],
    defines::Dict{String, String} = Dict{String, String}()
)
    VerilatorConfig(verilator_path, trace_enabled, trace_depth, optimization_level,
                    extra_flags, include_paths, defines)
end

"""
    SimulationResult

Result of a Verilator simulation run.
"""
struct SimulationResult
    success::Bool
    output::String
    error_output::String
    exit_code::Int
    cycles::Int
    outputs::Dict{String, Any}
    vcd_file::Union{String, Nothing}
end

"""
    compile_verilator(verilog_file::String, output_dir::String;
                      config::VerilatorConfig=VerilatorConfig())

Compile Verilog with Verilator.
"""
function compile_verilator(verilog_file::String, output_dir::String;
                           config::VerilatorConfig=VerilatorConfig())
    # Check if Verilator is available
    verilator_available = check_verilator(config.verilator_path)
    if !verilator_available
        return (success=false, error="Verilator not found at $(config.verilator_path)")
    end

    # Extract module name from file
    module_name = basename(verilog_file)
    module_name = replace(module_name, ".v" => "")

    # Build Verilator command
    cmd_parts = String[config.verilator_path]

    # Basic flags
    push!(cmd_parts, "--cc")
    push!(cmd_parts, "--exe")
    push!(cmd_parts, "--build")
    push!(cmd_parts, "-j", "0")  # Use all CPUs

    # Optimization
    if config.optimization_level > 0
        push!(cmd_parts, "-O$(config.optimization_level)")
    end

    # Tracing
    if config.trace_enabled
        push!(cmd_parts, "--trace")
        push!(cmd_parts, "--trace-depth", string(config.trace_depth))
    end

    # Include paths
    for path in config.include_paths
        push!(cmd_parts, "-I$path")
    end

    # Defines
    for (name, value) in config.defines
        if isempty(value)
            push!(cmd_parts, "-D$name")
        else
            push!(cmd_parts, "-D$name=$value")
        end
    end

    # Extra flags
    append!(cmd_parts, config.extra_flags)

    # Output directory
    push!(cmd_parts, "--Mdir", output_dir)

    # Source files
    push!(cmd_parts, verilog_file)

    # Generate main if not provided
    main_cpp = joinpath(output_dir, "sim_main.cpp")
    if !isfile(main_cpp)
        # Create a basic main file
        write_sim_main(main_cpp, module_name, config.trace_enabled)
    end
    push!(cmd_parts, main_cpp)

    # Run Verilator
    cmd = Cmd(cmd_parts)

    try
        result = read(cmd, String)
        return (success=true, output=result, executable=joinpath(output_dir, "V$module_name"))
    catch e
        return (success=false, error=string(e))
    end
end

"""
    run_verilator(executable::String, args::Vector{String}=String[];
                  timeout_seconds::Int=60)

Run a compiled Verilator simulation.
"""
function run_verilator(executable::String, args::Vector{String}=String[];
                       timeout_seconds::Int=60)
    if !isfile(executable)
        return SimulationResult(false, "", "Executable not found: $executable", -1, 0, Dict(), nothing)
    end

    cmd = Cmd([executable; args])

    try
        proc = run(pipeline(cmd, stdout=IOBuffer(), stderr=IOBuffer()), wait=false)

        # Wait with timeout
        start_time = time()
        while process_running(proc) && (time() - start_time) < timeout_seconds
            sleep(0.1)
        end

        if process_running(proc)
            kill(proc)
            return SimulationResult(false, "", "Simulation timeout", -1, 0, Dict(), nothing)
        end

        exit_code = proc.exitcode
        output = String(take!(proc.stdout))
        error_output = String(take!(proc.stderr))

        # Parse output for results
        outputs = parse_simulation_output(output)
        cycles = get(outputs, "_cycles", 0)

        # Find VCD file
        vcd_file = nothing
        dir = dirname(executable)
        for file in readdir(dir)
            if endswith(file, ".vcd")
                vcd_file = joinpath(dir, file)
                break
            end
        end

        return SimulationResult(
            exit_code == 0,
            output,
            error_output,
            exit_code,
            cycles,
            outputs,
            vcd_file
        )
    catch e
        return SimulationResult(false, "", string(e), -1, 0, Dict(), nothing)
    end
end

"""
    simulate(rtl::RTLModule, inputs::Dict{String, Any};
             config::VerilatorConfig=VerilatorConfig(),
             work_dir::String=mktempdir())

High-level simulation function: compile and run in one step.
"""
function simulate(rtl::RTLModule, inputs::Dict{String, Any};
                  config::VerilatorConfig=VerilatorConfig(),
                  work_dir::String=mktempdir())

    # Write Verilog file
    verilog_file = joinpath(work_dir, "$(rtl.name).v")
    write_verilog(rtl, verilog_file)

    # Generate custom sim main with inputs
    main_cpp = joinpath(work_dir, "sim_main.cpp")
    write_sim_main_with_inputs(main_cpp, rtl, inputs, config.trace_enabled)

    # Compile
    compile_result = compile_verilator(verilog_file, work_dir; config=config)
    if !compile_result.success
        return SimulationResult(false, "", get(compile_result, :error, "Compilation failed"),
                               -1, 0, Dict(), nothing)
    end

    # Run
    return run_verilator(compile_result.executable)
end

"""
    check_verilator(path::String)

Check if Verilator is available.
"""
function check_verilator(path::String)::Bool
    try
        result = read(`$path --version`, String)
        return contains(result, "Verilator")
    catch
        return false
    end
end

"""
    write_sim_main(filepath::String, module_name::String, trace_enabled::Bool)

Write a basic Verilator C++ main file.
"""
function write_sim_main(filepath::String, module_name::String, trace_enabled::Bool)
    code = """
    // Auto-generated Verilator simulation main
    #include <verilated.h>
    $(trace_enabled ? "#include <verilated_vcd_c.h>" : "")
    #include "V$(module_name).h"
    #include <iostream>

    int main(int argc, char** argv) {
        Verilated::commandArgs(argc, argv);
        V$(module_name)* dut = new V$(module_name);

        $(trace_enabled ? """
        Verilated::traceEverOn(true);
        VerilatedVcdC* tfp = new VerilatedVcdC;
        dut->trace(tfp, 99);
        tfp->open("$(module_name).vcd");
        """ : "")

        // Initialize
        dut->clk = 0;
        dut->rst = 1;
        dut->start = 0;

        vluint64_t sim_time = 0;
        const vluint64_t max_time = 100000;

        // Reset
        for (int i = 0; i < 10; i++) {
            dut->clk = !dut->clk;
            dut->eval();
            $(trace_enabled ? "tfp->dump(sim_time++);" : "sim_time++;")
        }
        dut->rst = 0;

        // Start
        dut->start = 1;
        dut->clk = !dut->clk;
        dut->eval();
        $(trace_enabled ? "tfp->dump(sim_time++);" : "sim_time++;")
        dut->clk = !dut->clk;
        dut->eval();
        $(trace_enabled ? "tfp->dump(sim_time++);" : "sim_time++;")
        dut->start = 0;

        // Run until done
        while (sim_time < max_time && !dut->done) {
            dut->clk = !dut->clk;
            dut->eval();
            $(trace_enabled ? "tfp->dump(sim_time++);" : "sim_time++;")
        }

        std::cout << "_cycles=" << (sim_time/2) << std::endl;
        std::cout << "_done=" << (int)dut->done << std::endl;

        $(trace_enabled ? """
        tfp->close();
        delete tfp;
        """ : "")
        delete dut;
        return 0;
    }
    """

    open(filepath, "w") do f
        write(f, code)
    end
end

"""
    write_sim_main_with_inputs(filepath::String, rtl::RTLModule,
                                inputs::Dict{String, Any}, trace_enabled::Bool)

Write a Verilator C++ main file with specific input values.
"""
function write_sim_main_with_inputs(filepath::String, rtl::RTLModule,
                                    inputs::Dict{String, Any}, trace_enabled::Bool)
    module_name = rtl.name

    # Generate input assignments
    input_assignments = String[]
    for port in rtl.ports
        if port.is_input && port.name in keys(inputs)
            value = inputs[port.name]
            push!(input_assignments, "dut->$(port.name) = $value;")
        end
    end

    # Generate output captures
    output_prints = String[]
    for port in rtl.ports
        if !port.is_input
            push!(output_prints, "std::cout << \"$(port.name)=\" << (int)dut->$(port.name) << std::endl;")
        end
    end

    code = """
    // Auto-generated Verilator simulation main with inputs
    #include <verilated.h>
    $(trace_enabled ? "#include <verilated_vcd_c.h>" : "")
    #include "V$(module_name).h"
    #include <iostream>

    int main(int argc, char** argv) {
        Verilated::commandArgs(argc, argv);
        V$(module_name)* dut = new V$(module_name);

        $(trace_enabled ? """
        Verilated::traceEverOn(true);
        VerilatedVcdC* tfp = new VerilatedVcdC;
        dut->trace(tfp, 99);
        tfp->open("$(module_name).vcd");
        """ : "")

        // Initialize
        dut->clk = 0;
        dut->rst = 1;
        dut->start = 0;

        vluint64_t sim_time = 0;
        const vluint64_t max_time = 100000;

        // Reset phase
        for (int i = 0; i < 10; i++) {
            dut->clk = !dut->clk;
            dut->eval();
            $(trace_enabled ? "tfp->dump(sim_time++);" : "sim_time++;")
        }
        dut->rst = 0;

        // Set inputs
        $(join(input_assignments, "\n        "))

        // Start operation
        dut->start = 1;
        dut->clk = !dut->clk;
        dut->eval();
        $(trace_enabled ? "tfp->dump(sim_time++);" : "sim_time++;")
        dut->clk = !dut->clk;
        dut->eval();
        $(trace_enabled ? "tfp->dump(sim_time++);" : "sim_time++;")
        dut->start = 0;

        // Run until done
        while (sim_time < max_time && !dut->done) {
            dut->clk = !dut->clk;
            dut->eval();
            $(trace_enabled ? "tfp->dump(sim_time++);" : "sim_time++;")
        }

        // Output results
        std::cout << "_cycles=" << (sim_time/2) << std::endl;
        $(join(output_prints, "\n        "))

        $(trace_enabled ? """
        tfp->close();
        delete tfp;
        """ : "")
        delete dut;
        return dut->done ? 0 : 1;
    }
    """

    open(filepath, "w") do f
        write(f, code)
    end
end

"""
    parse_simulation_output(output::String)

Parse simulation output to extract result values.
"""
function parse_simulation_output(output::String)::Dict{String, Any}
    results = Dict{String, Any}()

    for line in split(output, '\n')
        line = strip(line)
        if contains(line, '=')
            parts = split(line, '=', limit=2)
            if length(parts) == 2
                key = strip(parts[1])
                value_str = strip(parts[2])

                # Try to parse as integer
                value = tryparse(Int, value_str)
                if value === nothing
                    value = tryparse(Float64, value_str)
                end
                if value === nothing
                    value = value_str
                end

                results[key] = value
            end
        end
    end

    return results
end

"""
    read_vcd_signals(vcd_file::String, signals::Vector{String})

Read specific signals from a VCD file.
"""
function read_vcd_signals(vcd_file::String, signals::Vector{String})::Dict{String, Vector{Tuple{Int, Int}}}
    result = Dict{String, Vector{Tuple{Int, Int}}}()

    if !isfile(vcd_file)
        return result
    end

    # Simple VCD parser
    signal_map = Dict{String, String}()  # id -> name
    current_time = 0

    for signal in signals
        result[signal] = Tuple{Int, Int}[]
    end

    open(vcd_file, "r") do f
        in_defs = false

        for line in eachline(f)
            line = strip(line)

            if startswith(line, "\$var")
                # Parse variable definition
                parts = split(line)
                if length(parts) >= 5
                    var_id = parts[4]
                    var_name = parts[5]
                    signal_map[var_id] = var_name
                end
            elseif startswith(line, "#")
                # Timestamp
                time_str = line[2:end]
                current_time = tryparse(Int, time_str)
                if current_time === nothing
                    current_time = 0
                end
            elseif length(line) > 0 && line[1] in ('0', '1', 'b', 'B')
                # Value change
                if line[1] in ('0', '1')
                    value = line[1] == '1' ? 1 : 0
                    id = line[2:end]
                    if haskey(signal_map, id)
                        sig_name = signal_map[id]
                        if haskey(result, sig_name)
                            push!(result[sig_name], (current_time, value))
                        end
                    end
                elseif startswith(line, "b") || startswith(line, "B")
                    # Binary value
                    space_idx = findfirst(' ', line)
                    if space_idx !== nothing
                        bin_str = line[2:space_idx-1]
                        id = line[space_idx+1:end]
                        value = tryparse(Int, bin_str, base=2)
                        if value === nothing
                            value = 0
                        end
                        if haskey(signal_map, id)
                            sig_name = signal_map[id]
                            if haskey(result, sig_name)
                                push!(result[sig_name], (current_time, value))
                            end
                        end
                    end
                end
            end
        end
    end

    return result
end
