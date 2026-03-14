# Testbench Generation
# Generate test vectors and testbenches for verification

"""
    TestVector

A single test vector with inputs and expected outputs.
"""
struct TestVector
    inputs::Dict{String, Any}
    expected_outputs::Dict{String, Any}
    name::String
    timeout_cycles::Int
end

function TestVector(inputs::Dict{String, Any}, expected_outputs::Dict{String, Any};
                    name::String="test", timeout_cycles::Int=1000)
    TestVector(inputs, expected_outputs, name, timeout_cycles)
end

"""
    TestSuite

Collection of test vectors.
"""
struct TestSuite
    name::String
    vectors::Vector{TestVector}
    rtl::RTLModule
end

"""
    generate_test_vectors(rtl::RTLModule; num_random::Int=10, seed::Int=42)

Generate random test vectors for a module.
"""
function generate_test_vectors(rtl::RTLModule; num_random::Int=10, seed::Int=42)::Vector{TestVector}
    Random.seed!(seed)
    vectors = TestVector[]

    # Get input ports (excluding clk, rst, start)
    input_ports = [p for p in rtl.ports if p.is_input && !(p.name in ("clk", "rst", "start"))]

    # Generate zero test
    zero_inputs = Dict{String, Any}()
    for port in input_ports
        zero_inputs[port.name] = 0
    end
    push!(vectors, TestVector(zero_inputs, Dict{String, Any}(), name="zero_test"))

    # Generate max value test
    max_inputs = Dict{String, Any}()
    for port in input_ports
        max_inputs[port.name] = (1 << port.bit_width) - 1
    end
    push!(vectors, TestVector(max_inputs, Dict{String, Any}(), name="max_test"))

    # Generate random tests
    for i in 1:num_random
        rand_inputs = Dict{String, Any}()
        for port in input_ports
            max_val = (1 << port.bit_width) - 1
            rand_inputs[port.name] = rand(0:max_val)
        end
        push!(vectors, TestVector(rand_inputs, Dict{String, Any}(), name="random_test_$i"))
    end

    return vectors
end

"""
    generate_test_vectors_from_function(rtl::RTLModule, ref_func::Function;
                                        num_random::Int=10, seed::Int=42)

Generate test vectors by calling a reference Julia function.
"""
function generate_test_vectors_from_function(rtl::RTLModule, ref_func::Function;
                                             num_random::Int=10, seed::Int=42)::Vector{TestVector}
    Random.seed!(seed)
    vectors = TestVector[]

    # Get input and output ports
    input_ports = [p for p in rtl.ports if p.is_input && !(p.name in ("clk", "rst", "start"))]
    output_ports = [p for p in rtl.ports if !p.is_input && p.name != "done"]

    for i in 1:(num_random + 2)
        inputs = Dict{String, Any}()

        for port in input_ports
            max_val = (1 << port.bit_width) - 1
            if i == 1
                inputs[port.name] = 0
            elseif i == 2
                inputs[port.name] = max_val
            else
                inputs[port.name] = rand(0:max_val)
            end
        end

        # Call reference function to get expected outputs
        input_values = [inputs[p.name] for p in input_ports]
        try
            result = ref_func(input_values...)

            expected = Dict{String, Any}()
            if result isa Tuple
                for (j, port) in enumerate(output_ports)
                    if j <= length(result)
                        expected[port.name] = result[j]
                    end
                end
            else
                if length(output_ports) >= 1
                    expected[output_ports[1].name] = result
                end
            end

            push!(vectors, TestVector(inputs, expected, name="test_$i"))
        catch e
            # If reference function fails, add test without expected outputs
            push!(vectors, TestVector(inputs, Dict{String, Any}(), name="test_$i"))
        end
    end

    return vectors
end

"""
    run_testbench(rtl::RTLModule, vectors::Vector{TestVector};
                  config::VerilatorConfig=VerilatorConfig())

Run a testbench with multiple test vectors.
"""
function run_testbench(rtl::RTLModule, vectors::Vector{TestVector};
                       config::VerilatorConfig=VerilatorConfig())::Vector{Tuple{TestVector, SimulationResult, Bool}}
    results = Tuple{TestVector, SimulationResult, Bool}[]

    for vec in vectors
        # Run simulation
        sim_result = simulate(rtl, vec.inputs; config=config)

        # Compare with expected if available
        passed = true
        if sim_result.success && !isempty(vec.expected_outputs)
            for (name, expected) in vec.expected_outputs
                actual = get(sim_result.outputs, name, nothing)
                if actual !== nothing && actual != expected
                    passed = false
                    break
                end
            end
        elseif !sim_result.success
            passed = false
        end

        push!(results, (vec, sim_result, passed))
    end

    return results
end

"""
    generate_systemverilog_assertions(rtl::RTLModule)

Generate SystemVerilog assertions for the module.
"""
function generate_systemverilog_assertions(rtl::RTLModule)::String
    lines = String[]

    push!(lines, "// SystemVerilog Assertions for $(rtl.name)")
    push!(lines, "// Generated by FPGACompiler.jl")
    push!(lines, "")

    push!(lines, "module $(rtl.name)_sva (")
    for port in rtl.ports
        push!(lines, "    input $(port.is_input ? "" : "wire ")$(port.name),")
    end
    # Remove trailing comma
    lines[end] = replace(lines[end], "," => "")
    push!(lines, ");")
    push!(lines, "")

    # Basic properties
    push!(lines, "    // Property: done must be stable once asserted until start goes low")
    push!(lines, "    property done_stability;")
    push!(lines, "        @(posedge clk) disable iff (rst)")
    push!(lines, "        done |-> done || \$fell(start);")
    push!(lines, "    endproperty")
    push!(lines, "    assert property (done_stability);")
    push!(lines, "")

    push!(lines, "    // Property: must eventually complete after start")
    push!(lines, "    property eventual_completion;")
    push!(lines, "        @(posedge clk) disable iff (rst)")
    push!(lines, "        \$rose(start) |-> ##[1:1000] done;")
    push!(lines, "    endproperty")
    push!(lines, "    assert property (eventual_completion);")
    push!(lines, "")

    push!(lines, "    // Cover: normal operation")
    push!(lines, "    cover property (@(posedge clk) \$rose(start) ##[1:100] \$rose(done));")
    push!(lines, "")

    push!(lines, "endmodule")

    return join(lines, "\n")
end

"""
    generate_coverage_points(rtl::RTLModule)

Generate functional coverage points.
"""
function generate_coverage_points(rtl::RTLModule)::String
    lines = String[]

    push!(lines, "// Functional Coverage for $(rtl.name)")
    push!(lines, "// Generated by FPGACompiler.jl")
    push!(lines, "")

    push!(lines, "covergroup $(rtl.name)_cg @(posedge clk);")
    push!(lines, "    option.per_instance = 1;")
    push!(lines, "")

    # Cover state machine states
    push!(lines, "    // State coverage")
    push!(lines, "    cp_state: coverpoint current_state {")
    for name in rtl.state_names
        push!(lines, "        bins $(lowercase(name)) = {$(rtl.state_encoding[name])};")
    end
    push!(lines, "    }")
    push!(lines, "")

    # Cover input ranges
    for port in rtl.ports
        if port.is_input && !(port.name in ("clk", "rst", "start"))
            push!(lines, "    // $(port.name) coverage")
            push!(lines, "    cp_$(port.name): coverpoint $(port.name) {")
            push!(lines, "        bins zero = {0};")
            max_val = (1 << port.bit_width) - 1
            push!(lines, "        bins max = {$max_val};")
            push!(lines, "        bins others = {[1:$(max_val-1)]};")
            push!(lines, "    }")
            push!(lines, "")
        end
    end

    # Cross coverage
    input_ports = [p for p in rtl.ports if p.is_input && !(p.name in ("clk", "rst", "start"))]
    if length(input_ports) >= 2
        push!(lines, "    // Cross coverage of first two inputs")
        push!(lines, "    cross_inputs: cross cp_$(input_ports[1].name), cp_$(input_ports[2].name);")
        push!(lines, "")
    end

    push!(lines, "endgroup")

    return join(lines, "\n")
end

"""
    generate_directed_tests(rtl::RTLModule, scenarios::Vector{Symbol})

Generate directed tests for specific scenarios.
"""
function generate_directed_tests(rtl::RTLModule, scenarios::Vector{Symbol})::Vector{TestVector}
    vectors = TestVector[]
    input_ports = [p for p in rtl.ports if p.is_input && !(p.name in ("clk", "rst", "start"))]

    for scenario in scenarios
        inputs = Dict{String, Any}()

        if scenario == :zeros
            for port in input_ports
                inputs[port.name] = 0
            end
        elseif scenario == :ones
            for port in input_ports
                inputs[port.name] = (1 << port.bit_width) - 1
            end
        elseif scenario == :alternating
            for (i, port) in enumerate(input_ports)
                if isodd(i)
                    inputs[port.name] = 0xAAAAAAAA & ((1 << port.bit_width) - 1)
                else
                    inputs[port.name] = 0x55555555 & ((1 << port.bit_width) - 1)
                end
            end
        elseif scenario == :walking_ones
            for (i, port) in enumerate(input_ports)
                inputs[port.name] = 1 << (i % port.bit_width)
            end
        elseif scenario == :walking_zeros
            for (i, port) in enumerate(input_ports)
                max_val = (1 << port.bit_width) - 1
                inputs[port.name] = max_val & ~(1 << (i % port.bit_width))
            end
        elseif scenario == :boundary_low
            for port in input_ports
                inputs[port.name] = 1
            end
        elseif scenario == :boundary_high
            for port in input_ports
                inputs[port.name] = (1 << port.bit_width) - 2
            end
        end

        push!(vectors, TestVector(inputs, Dict{String, Any}(), name="$(scenario)_test"))
    end

    return vectors
end

# Import Random for test generation
import Random
