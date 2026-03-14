# Metadata Function Tests
# Tests for LLVM metadata injection functions
# Note: These tests require LLVM.jl to be properly set up

@testset "Metadata Functions" begin

    # Most metadata tests require a full LLVM context
    # These are marked as skip/broken until the toolchain is set up

    @testset "Pipeline Metadata Structure" begin
        # Test that the function signature is correct
        @test hasmethod(apply_pipeline_metadata!, Tuple{LLVM.BasicBlock, Int})
    end

    @testset "Unroll Metadata Structure" begin
        @test hasmethod(apply_unroll_metadata!, Tuple{LLVM.BasicBlock, Int})
    end

    @testset "Partition Metadata Structure" begin
        @test hasmethod(apply_partition_metadata!, Tuple{LLVM.Instruction, Int, PartitionStyle})
    end

    @testset "Interface Metadata Structure" begin
        @test hasmethod(apply_interface_metadata!, Tuple{LLVM.Function, Int, Symbol})
    end

    @testset "NoAlias Metadata Structure" begin
        @test hasmethod(apply_noalias_metadata!, Tuple{LLVM.Module})
    end

    # Integration tests with actual LLVM module would go here
    # These require GPUCompiler to create a proper module

    @testset "Hint Registry" begin
        # Clear any existing hints
        clear_hints!()

        # Test pipeline hint registration
        FPGACompiler.register_pipeline_hint!(UInt64(12345), 2)
        hint = FPGACompiler.get_pipeline_hint(UInt64(12345))
        @test hint !== nothing
        @test hint.ii == 2

        # Test unroll hint registration
        FPGACompiler.register_unroll_hint!(UInt64(67890), 4, false)
        hint2 = FPGACompiler.get_unroll_hint(UInt64(67890))
        @test hint2 !== nothing
        @test hint2.factor == 4
        @test hint2.full == false

        # Test full unroll
        FPGACompiler.register_unroll_hint!(UInt64(11111), 0, true)
        hint3 = FPGACompiler.get_unroll_hint(UInt64(11111))
        @test hint3.full == true

        # Test kernel registration
        FPGACompiler.register_kernel!(:test_kernel)
        @test is_registered_kernel(:test_kernel)
        @test !is_registered_kernel(:nonexistent_kernel)

        # Test clearing
        clear_hints!()
        @test FPGACompiler.get_pipeline_hint(UInt64(12345)) === nothing
        @test FPGACompiler.get_unroll_hint(UInt64(67890)) === nothing
        @test !is_registered_kernel(:test_kernel)
    end
end
