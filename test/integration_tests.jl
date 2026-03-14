# Integration Tests
# End-to-end tests for FPGA compilation
# Note: Many tests require full GPUCompiler/LLVM setup

@testset "Integration Tests" begin

    @testset "Target and Params" begin
        target = FPGATarget()
        @test target isa FPGACompiler.FPGATarget

        params = FPGACompilerParams()
        @test params.target_ii == 1
        @test params.aggressive_inline == true
        @test params.partition_memory == true
        @test params.emit_llvm_ir == true

        # Custom params
        custom = FPGACompilerParams(target_ii=4, aggressive_inline=false)
        @test custom.target_ii == 4
        @test custom.aggressive_inline == false
    end

    @testset "Macro Expansion" begin
        # Test @fpga_kernel
        @test_nowarn @eval @fpga_kernel function test_kernel_macro(x)
            return x * 2
        end
        @test is_registered_kernel(:test_kernel_macro)

        # Test @pipeline with default II
        @test_nowarn @eval function test_pipeline_default()
            sum = 0
            @pipeline for i in 1:10
                sum += i
            end
            sum
        end

        # Test @pipeline with II parameter
        @test_nowarn @eval function test_pipeline_ii()
            sum = 0
            @pipeline II=2 for i in 1:10
                sum += i
            end
            sum
        end

        # Test @unroll with factor
        @test_nowarn @eval function test_unroll_factor()
            sum = 0
            @unroll factor=4 for i in 1:8
                sum += i
            end
            sum
        end

        # Test @unroll with full
        @test_nowarn @eval function test_unroll_full()
            sum = 0
            @unroll full=true for i in 1:4
                sum += i
            end
            sum
        end

        # Test nested macros
        @test_nowarn @eval @fpga_kernel function test_nested_macros(A, n)
            sum = 0.0
            @pipeline II=1 for i in 1:n
                @inbounds sum += A[i]
            end
            return sum
        end
    end

    @testset "Macro Semantics" begin
        # Verify macros don't change runtime behavior
        function baseline_sum()
            sum = 0
            for i in 1:10
                sum += i
            end
            sum
        end

        function pipeline_sum()
            sum = 0
            @pipeline for i in 1:10
                sum += i
            end
            sum
        end

        function unroll_sum()
            sum = 0
            @unroll factor=2 for i in 1:10
                sum += i
            end
            sum
        end

        @test baseline_sum() == pipeline_sum()
        @test baseline_sum() == unroll_sum()
    end

    @testset "Validation Function" begin
        # Valid kernel
        function valid_kernel(A, B, n)
            for i in 1:n
                @inbounds B[i] = A[i] * 2
            end
        end

        # This should not produce issues for a simple kernel
        issues = validate_kernel(valid_kernel, Tuple{Vector{Float64}, Vector{Float64}, Int})
        # Issues may be empty or contain warnings depending on type inference
        @test issues isa Vector{String}

        # Test with Any type (should warn)
        issues_any = validate_kernel(valid_kernel, Tuple{Any, Vector{Float64}, Int})
        @test any(occursin("Any", issue) for issue in issues_any)
    end

    @testset "Function API Signatures" begin
        # Verify all exported functions exist with correct signatures
        @test hasmethod(fpga_compile, Tuple{Function, Type})
        @test hasmethod(fpga_code_llvm, Tuple{Function, Type})
        @test hasmethod(fpga_code_native, Tuple{Function, Type})
        @test hasmethod(validate_kernel, Tuple{Function, Type})
        @test hasmethod(estimate_resources, Tuple{Function, Type})
    end

    # Full compilation tests require GPUCompiler and LLVM to be properly set up
    # These are marked as broken until the full toolchain is available

    @testset "Full Compilation (requires LLVM)" begin
        function simple_add(a, b)
            return a + b
        end

        # Skip actual compilation test
        @test_skip "Full compilation requires GPUCompiler setup"

        # When GPUCompiler is available, uncomment:
        # @test_nowarn fpga_compile(simple_add, Tuple{Float32, Float32})
        # ir = fpga_code_llvm(simple_add, Tuple{Float32, Float32})
        # @test occursin("fadd", ir)
    end

    @testset "File Output (requires LLVM)" begin
        function test_output_kernel(x, y)
            return x + y
        end

        # Skip actual file output test
        @test_skip "File output requires GPUCompiler setup"

        # When GPUCompiler is available, uncomment:
        # path = fpga_code_native(test_output_kernel, Tuple{Float32, Float32})
        # @test isfile(path)
        # @test endswith(path, ".ll")
        # rm(path)  # Clean up
    end

    @testset "Resource Estimation (requires LLVM)" begin
        function matrix_kernel(A, B, C, n)
            for i in 1:n
                for j in 1:n
                    sum = 0.0f0
                    for k in 1:n
                        @inbounds sum += A[(i-1)*n + k] * B[(k-1)*n + j]
                    end
                    @inbounds C[(i-1)*n + j] = sum
                end
            end
        end

        # Skip actual estimation test
        @test_skip "Resource estimation requires GPUCompiler setup"

        # When GPUCompiler is available, uncomment:
        # resources = estimate_resources(matrix_kernel,
        #     Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})
        # @test haskey(resources, "estimated_dsps")
        # @test haskey(resources, "estimated_luts")
    end
end

@testset "Error Handling" begin

    @testset "Invalid Macro Usage" begin
        # @fpga_kernel without function
        @test_throws LoadError @eval @fpga_kernel 42

        # @pipeline without loop
        @test_throws LoadError @eval @pipeline 42

        # @unroll without loop
        @test_throws LoadError @eval @unroll 42

        # Invalid II value (non-integer) - this would be caught at parse time
        # @test_throws ... @eval @pipeline II="invalid" for i in 1:10 end
    end

    @testset "Invalid Parameters" begin
        # PartitionedArray with invalid factor
        @test_throws ArgumentError PartitionedArray{Float32, 1, 0, CYCLIC}(zeros(Float32, 10))

        # FixedInt with invalid bit width would be caught by assertion
        # @test_throws AssertionError FixedInt{0, Int8}(0)
        # @test_throws AssertionError FixedInt{100, Int8}(0)  # > sizeof(Int8)*8
    end
end
