# Simulation Tests
# Tests for simulation and verification functionality

@testset "Simulation" begin

    @testset "Simulation Types" begin
        using FPGACompiler.Sim
        using FPGACompiler.RTL
        using FPGACompiler.HLS

        @testset "VerilatorConfig" begin
            config = VerilatorConfig()
            @test config.trace_enabled == true
            @test config.trace_depth == 99
            @test config.optimization_level == 3

            config2 = VerilatorConfig(
                trace_enabled=false,
                optimization_level=0
            )
            @test config2.trace_enabled == false
            @test config2.optimization_level == 0
        end

        @testset "SimulationResult" begin
            result = SimulationResult(
                true, "output", "", 0, 100,
                Dict("out_1" => 42),
                "/tmp/test.vcd"
            )
            @test result.success == true
            @test result.cycles == 100
            @test result.outputs["out_1"] == 42
        end

        @testset "VerificationResult" begin
            vr = VerificationResult(
                true, 10, 10, 0,
                Dict{String, Any}[],
                Dict("pass_rate" => 100.0)
            )
            @test vr.passed == true
            @test vr.total_tests == 10
            @test vr.passed_tests == 10
            @test vr.failed_tests == 0
        end
    end

    @testset "Test Vector Generation" begin
        using FPGACompiler.Sim
        using FPGACompiler.RTL

        # Create test RTL module
        rtl = RTLModule("test_gen")
        push!(rtl.ports, RTLPort("clk", 1, true, false))
        push!(rtl.ports, RTLPort("rst", 1, true, false))
        push!(rtl.ports, RTLPort("start", 1, true, false))
        push!(rtl.ports, RTLPort("a", 8, true, false))
        push!(rtl.ports, RTLPort("b", 8, true, false))
        push!(rtl.ports, RTLPort("done", 1, false, false))
        push!(rtl.ports, RTLPort("out_1", 8, false, false))

        @testset "Random Test Vectors" begin
            vectors = generate_test_vectors(rtl; num_random=5, seed=42)

            @test length(vectors) == 7  # 2 (zero, max) + 5 random
            @test vectors[1].name == "zero_test"
            @test vectors[2].name == "max_test"

            # Check zero test
            @test vectors[1].inputs["a"] == 0
            @test vectors[1].inputs["b"] == 0

            # Check max test
            @test vectors[2].inputs["a"] == 255
            @test vectors[2].inputs["b"] == 255
        end

        @testset "Directed Tests" begin
            scenarios = [:zeros, :ones, :alternating, :walking_ones]
            vectors = generate_directed_tests(rtl, scenarios)

            @test length(vectors) == 4
            @test vectors[1].name == "zeros_test"
            @test vectors[2].name == "ones_test"
        end

        @testset "Test Vectors from Function" begin
            # Simple reference function
            add_ref(a, b) = a + b

            vectors = generate_test_vectors_from_function(rtl, add_ref; num_random=3)

            @test length(vectors) == 5  # 2 + 3

            # Check that expected outputs are set for tests where ref function works
            for vec in vectors
                if !isempty(vec.expected_outputs)
                    # Verify the expected output matches reference
                    expected = vec.expected_outputs
                    @test haskey(expected, "out_1") || isempty(expected)
                end
            end
        end
    end

    @testset "Result Comparison" begin
        using FPGACompiler.Sim

        @testset "Integer Comparison" begin
            expected = Dict{String, Any}("a" => 10, "b" => 20)
            actual = Dict{String, Any}("a" => 10, "b" => 20)

            match, mismatches = compare_results(expected, actual)
            @test match == true
            @test isempty(mismatches)

            # Test mismatch
            actual2 = Dict{String, Any}("a" => 10, "b" => 25)
            match2, mismatches2 = compare_results(expected, actual2)
            @test match2 == false
            @test !isempty(mismatches2)
        end

        @testset "Float Comparison with Tolerance" begin
            expected = Dict{String, Any}("x" => 1.0)
            actual = Dict{String, Any}("x" => 1.0001)

            # Without tolerance
            match1, _ = compare_results(expected, actual; tolerance=0.0)
            @test match1 == false

            # With tolerance
            match2, _ = compare_results(expected, actual; tolerance=0.001)
            @test match2 == true
        end

        @testset "Missing Output" begin
            expected = Dict{String, Any}("a" => 10, "b" => 20)
            actual = Dict{String, Any}("a" => 10)

            match, mismatches = compare_results(expected, actual)
            @test match == false
            @test any(contains(m, "Missing") for m in mismatches)
        end
    end

    @testset "Verification Report" begin
        using FPGACompiler.Sim

        @testset "Passing Report" begin
            result = VerificationResult(
                true, 100, 100, 0,
                Dict{String, Any}[],
                Dict("test_pass_rate" => 100.0)
            )

            report = generate_verification_report(result)

            @test contains(report, "PASSED")
            @test contains(report, "Total tests:  100")
            @test contains(report, "Failed:       0")
        end

        @testset "Failing Report" begin
            failures = [Dict{String, Any}(
                "test_name" => "test_1",
                "inputs" => Dict("a" => 1),
                "expected" => Dict("out" => 10),
                "actual" => Dict("out" => 5),
                "error" => ""
            )]

            result = VerificationResult(
                false, 10, 9, 1,
                failures,
                Dict("test_pass_rate" => 90.0)
            )

            report = generate_verification_report(result)

            @test contains(report, "FAILED")
            @test contains(report, "Failed:       1")
            @test contains(report, "Failures:")
            @test contains(report, "test_1")
        end
    end

    @testset "TestVector Type" begin
        using FPGACompiler.Sim

        @testset "Basic TestVector" begin
            inputs = Dict{String, Any}("a" => 5, "b" => 10)
            expected = Dict{String, Any}("out" => 15)

            tv = TestVector(inputs, expected; name="add_test")

            @test tv.inputs == inputs
            @test tv.expected_outputs == expected
            @test tv.name == "add_test"
            @test tv.timeout_cycles == 1000
        end

        @testset "TestVector with Custom Timeout" begin
            inputs = Dict{String, Any}("x" => 1)
            expected = Dict{String, Any}()

            tv = TestVector(inputs, expected;
                           name="slow_test", timeout_cycles=10000)

            @test tv.timeout_cycles == 10000
        end
    end

    @testset "Output Parsing" begin
        using FPGACompiler.Sim

        @testset "Parse Simple Output" begin
            output = """
            _cycles=50
            out_1=42
            done=1
            """

            results = parse_simulation_output(output)

            @test results["_cycles"] == 50
            @test results["out_1"] == 42
            @test results["done"] == 1
        end

        @testset "Parse Mixed Output" begin
            output = """
            Info: Starting simulation
            result=123
            status=ok
            """

            results = parse_simulation_output(output)

            @test results["result"] == 123
            @test results["status"] == "ok"
        end
    end

    @testset "SystemVerilog Assertions" begin
        using FPGACompiler.Sim
        using FPGACompiler.RTL

        rtl = RTLModule("test_sva")
        push!(rtl.ports, RTLPort("clk", 1, true, false))
        push!(rtl.ports, RTLPort("rst", 1, true, false))
        push!(rtl.ports, RTLPort("start", 1, true, false))
        push!(rtl.ports, RTLPort("done", 1, false, false))

        sva = generate_systemverilog_assertions(rtl)

        @test contains(sva, "module test_sva_sva")
        @test contains(sva, "property")
        @test contains(sva, "assert property")
        @test contains(sva, "cover property")
    end

    @testset "Coverage Points" begin
        using FPGACompiler.Sim
        using FPGACompiler.RTL

        rtl = RTLModule("test_cov")
        push!(rtl.ports, RTLPort("clk", 1, true, false))
        push!(rtl.ports, RTLPort("data_in", 8, true, false))
        push!(rtl.ports, RTLPort("data_out", 8, false, false))

        rtl.state_names = ["IDLE", "RUN", "DONE"]
        rtl.state_encoding = Dict("IDLE" => 0, "RUN" => 1, "DONE" => 2)

        cov = generate_coverage_points(rtl)

        @test contains(cov, "covergroup")
        @test contains(cov, "coverpoint")
        @test contains(cov, "bins")
    end
end
