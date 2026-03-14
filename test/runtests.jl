using Test
using FPGACompiler
using FPGACompiler: LLVM

# Import internal functions for testing
import FPGACompiler: register_pipeline_hint!, register_unroll_hint!, register_kernel!
import FPGACompiler: get_pipeline_hint, get_unroll_hint, is_registered_kernel, clear_hints!

@testset "FPGACompiler.jl" begin

    @testset "Target Definition" begin
        target = FPGATarget()
        @test target isa FPGACompiler.FPGATarget

        params = FPGACompilerParams()
        @test params.target_ii == 1
        @test params.aggressive_inline == true
        @test params.partition_memory == true
    end

    @testset "Custom Types" begin
        @testset "PartitionedArray" begin
            data = zeros(Float32, 1024)
            pa = PartitionedArray{Float32, 1, 4, CYCLIC}(data)

            @test size(pa) == (1024,)
            @test length(pa) == 1024
            @test partition_factor(pa) == 4
            @test partition_style(pa) == CYCLIC

            # Test element access
            pa[1] = 42.0f0
            @test pa[1] == 42.0f0
        end

        @testset "Convenience Constructor" begin
            data = zeros(Float64, 100)
            pa = PartitionedArray(data; factor=8, style=BLOCK)

            @test partition_factor(pa) == 8
            @test partition_style(pa) == BLOCK
        end
    end

    @testset "PartitionStyle Enum" begin
        @test CYCLIC isa PartitionStyle
        @test BLOCK isa PartitionStyle
        @test COMPLETE isa PartitionStyle
    end

    @testset "FixedInt Basic" begin
        x = Int7(42)
        @test x.value == 42
        @test bitwidth(x) == 7

        y = UInt12(1000)
        @test y.value == 1000
        @test bitwidth(y) == 12
    end

    @testset "Macros" begin
        # Clear hints before tests
        clear_hints!()

        # Test that @fpga_kernel registers the kernel
        @test_nowarn @eval @fpga_kernel function test_kernel(x)
            return x * 2
        end
        @test is_registered_kernel(:test_kernel)

        # Test @pipeline macro parsing
        @test_nowarn @eval function test_pipeline()
            sum = 0
            @pipeline for i in 1:10
                sum += i
            end
            sum
        end

        @test_nowarn @eval function test_pipeline_ii()
            sum = 0
            @pipeline II=2 for i in 1:10
                sum += i
            end
            sum
        end

        # Test @unroll macro parsing
        @test_nowarn @eval function test_unroll()
            sum = 0
            @unroll factor=4 for i in 1:8
                sum += i
            end
            sum
        end

        @test_nowarn @eval function test_unroll_full()
            sum = 0
            @unroll full=true for i in 1:4
                sum += i
            end
            sum
        end
    end

    @testset "Hint Registry" begin
        clear_hints!()

        # Test pipeline hint
        register_pipeline_hint!(UInt64(123), 2)
        hint = get_pipeline_hint(UInt64(123))
        @test hint !== nothing
        @test hint.ii == 2

        # Test unroll hint
        register_unroll_hint!(UInt64(456), 4, false)
        hint2 = get_unroll_hint(UInt64(456))
        @test hint2 !== nothing
        @test hint2.factor == 4
        @test hint2.full == false

        # Test full unroll
        register_unroll_hint!(UInt64(789), 0, true)
        hint3 = get_unroll_hint(UInt64(789))
        @test hint3.full == true

        # Test kernel registration
        register_kernel!(:my_kernel)
        @test is_registered_kernel(:my_kernel)
        @test !is_registered_kernel(:not_a_kernel)

        # Test clear
        clear_hints!()
        @test get_pipeline_hint(UInt64(123)) === nothing
        @test !is_registered_kernel(:my_kernel)
    end

    @testset "Validation" begin
        # Simple valid kernel
        function simple_kernel(a, b)
            return a + b
        end

        issues = validate_kernel(simple_kernel, Tuple{Float32, Float32})
        @test issues isa Vector{String}

        # Test with Any type
        issues_any = validate_kernel(simple_kernel, Tuple{Any, Float32})
        @test any(occursin("Any", i) for i in issues_any)
    end

    # Include additional test files
    include("types_tests.jl")
    include("metadata_tests.jl")
    include("integration_tests.jl")

    # Phase 4: HLS Backend tests
    include("hls_tests.jl")
    include("rtl_tests.jl")
    include("sim_tests.jl")

    # Integration tests require GPUCompiler and LLVM to be properly set up
    # These are marked as broken until the full toolchain is available

    @testset "Compilation (requires LLVM)" begin
        # Simple bitstype kernel (must return nothing)
        function vadd_simple(a::Float32, b::Float32)
            c = a + b
            return nothing
        end

        # Test that compilation works
        @test_nowarn fpga_compile(vadd_simple, Tuple{Float32, Float32})
    end
end
