# Vector Addition Example
# Demonstrates basic FPGA kernel compilation with FPGACompiler.jl

using FPGACompiler

# =============================================================================
# Basic Vector Addition Kernel
# =============================================================================

"""
Simple element-wise vector addition: C = A + B

Hardware characteristics:
- Memory bound: 2 loads + 1 store per iteration
- No loop-carried dependencies
- Ideal for pipelining (II=1 achievable)
"""
@fpga_kernel function vector_add!(A::Vector{Float32}, B::Vector{Float32}, C::Vector{Float32}, n::Int)
    @pipeline II=1 for i in 1:n
        @inbounds C[i] = A[i] + B[i]
    end
end

# =============================================================================
# Test in Julia
# =============================================================================

function test_vector_add()
    n = 1024

    # Create test data
    A = rand(Float32, n)
    B = rand(Float32, n)
    C = zeros(Float32, n)

    # Run kernel
    vector_add!(A, B, C, n)

    # Verify
    expected = A .+ B
    if all(C .≈ expected)
        println("✓ Vector add test passed")
        return true
    else
        println("✗ Vector add test failed")
        return false
    end
end

# =============================================================================
# Compile for FPGA
# =============================================================================

function compile_vector_add()
    println("Compiling vector_add for FPGA...")

    # Define argument types
    types = Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int}

    # Validate kernel before compilation
    issues = validate_kernel(vector_add!, types)
    if !isempty(issues)
        println("Warnings:")
        for issue in issues
            println("  - $issue")
        end
    end

    # Generate LLVM IR file
    output_path = fpga_code_native(vector_add!, types, format=:ll, output="vector_add_fpga.ll")
    println("Generated: $output_path")

    # Print IR for inspection
    println("\nLLVM IR Preview:")
    println("=" ^ 60)
    ir = fpga_code_llvm(vector_add!, types)
    # Print first 50 lines
    lines = split(ir, '\n')
    for line in lines[1:min(50, length(lines))]
        println(line)
    end
    if length(lines) > 50
        println("... ($(length(lines) - 50) more lines)")
    end

    return output_path
end

# =============================================================================
# Estimate Resources
# =============================================================================

function estimate_vector_add_resources()
    types = Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int}

    resources = estimate_resources(vector_add!, types)

    println("\nEstimated FPGA Resources:")
    println("  LUTs:  $(resources["estimated_luts"])")
    println("  FFs:   $(resources["estimated_ffs"])")
    println("  DSPs:  $(resources["estimated_dsps"])")
    println("  BRAMs: $(resources["estimated_brams"])")
end

# =============================================================================
# Main
# =============================================================================

if abspath(PROGRAM_FILE) == @__FILE__
    println("FPGACompiler.jl - Vector Addition Example")
    println("=" ^ 60)

    # Test locally first
    println("\n1. Testing in Julia...")
    test_vector_add()

    # Compile for FPGA
    println("\n2. Compiling for FPGA...")
    try
        compile_vector_add()
    catch e
        println("Compilation requires GPUCompiler and LLVM setup")
        println("Error: $e")
    end

    # Resource estimation
    println("\n3. Estimating resources...")
    try
        estimate_vector_add_resources()
    catch e
        println("Resource estimation requires full compilation")
    end
end
