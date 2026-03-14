# Memory Partitioning Example
# Demonstrates PartitionedArray for parallel memory access on FPGAs

using FPGACompiler

# =============================================================================
# The Memory Bandwidth Problem
# =============================================================================

#=
FPGA Block RAMs (BRAMs) have limited ports:
- Typically 2 read/write ports per BRAM
- Processing N elements per cycle requires N memory accesses
- Without partitioning: bottlenecked to 2 accesses/cycle

Solution: Partition arrays across multiple BRAMs
- 4-way partition = 8 ports = 8 simultaneous accesses
- Enables full loop unrolling with parallel memory access
=#

# =============================================================================
# Without Partitioning (Baseline)
# =============================================================================

"""
Standard dot product - limited by BRAM ports.
Even with @unroll, memory becomes the bottleneck.
"""
@fpga_kernel function dot_product_basic(A::Vector{Float32}, B::Vector{Float32}, n::Int)
    sum = 0.0f0
    for i in 1:n
        @inbounds sum += A[i] * B[i]
    end
    return sum
end

# =============================================================================
# With CYCLIC Partitioning
# =============================================================================

"""
Dot product with cyclic partitioning.

CYCLIC distributes elements round-robin:
  Bank 0: A[1], A[5], A[9],  ...
  Bank 1: A[2], A[6], A[10], ...
  Bank 2: A[3], A[7], A[11], ...
  Bank 3: A[4], A[8], A[12], ...

This allows accessing A[1], A[2], A[3], A[4] simultaneously!
"""
@fpga_kernel function dot_product_cyclic(
    A::PartitionedArray{Float32, 1, 4, CYCLIC},
    B::PartitionedArray{Float32, 1, 4, CYCLIC},
    n::Int
)
    sum = 0.0f0

    # Unroll by 4 to match partition factor
    # Each unrolled iteration accesses a different BRAM bank
    @unroll factor=4 for i in 1:4:n
        @inbounds sum += A[i]   * B[i]
        @inbounds sum += A[i+1] * B[i+1]
        @inbounds sum += A[i+2] * B[i+2]
        @inbounds sum += A[i+3] * B[i+3]
    end

    return sum
end

# =============================================================================
# With BLOCK Partitioning
# =============================================================================

"""
Array sum with block partitioning.

BLOCK assigns contiguous chunks to each bank:
  Bank 0: A[1:256]
  Bank 1: A[257:512]
  Bank 2: A[513:768]
  Bank 3: A[769:1024]

Best for algorithms that process array sections independently.
"""
@fpga_kernel function parallel_sum_blocks(
    A::PartitionedArray{Float32, 1, 4, BLOCK},
    n::Int
)
    # Process each block in parallel
    chunk_size = n ÷ 4

    sum0 = 0.0f0
    sum1 = 0.0f0
    sum2 = 0.0f0
    sum3 = 0.0f0

    # Each sum accumulates from a different bank (parallel access)
    @pipeline II=1 for i in 1:chunk_size
        @inbounds sum0 += A[i]
        @inbounds sum1 += A[i + chunk_size]
        @inbounds sum2 += A[i + 2*chunk_size]
        @inbounds sum3 += A[i + 3*chunk_size]
    end

    return sum0 + sum1 + sum2 + sum3
end

# =============================================================================
# With COMPLETE Partitioning
# =============================================================================

"""
Small array with complete partitioning.

COMPLETE turns the array into individual registers.
Every element can be accessed simultaneously.

Only suitable for small arrays (< ~64 elements typically).
"""
@fpga_kernel function convolve_small(
    input::Vector{Float32},
    # Coefficients fully partitioned into registers
    coeffs::PartitionedArray{Float32, 1, 8, COMPLETE},
    output::Vector{Float32},
    n::Int
)
    # 8-tap FIR filter with all coefficients accessible in parallel
    @pipeline II=1 for i in 8:n
        acc = 0.0f0

        # Fully unroll - all 8 coefficients read simultaneously
        @unroll for j in 1:8
            @inbounds acc += input[i - j + 1] * coeffs[j]
        end

        @inbounds output[i] = acc
    end
end

# =============================================================================
# 2D Array Partitioning
# =============================================================================

"""
Matrix-vector multiply with row-wise partitioning.

Partitioning the matrix rows enables parallel accumulation.
"""
@fpga_kernel function matvec_partitioned(
    A::PartitionedArray{Float32, 1, 4, CYCLIC},  # M×N matrix, row-partitioned
    x::Vector{Float32},                           # N vector
    y::Vector{Float32},                           # M result vector
    M::Int, N::Int
)
    # Process 4 rows in parallel due to CYCLIC partitioning
    @unroll factor=4 for i in 1:4:M
        # Each row's dot product
        for row_offset in 0:3
            row = i + row_offset
            if row <= M
                sum = 0.0f0
                @pipeline II=1 for j in 1:N
                    @inbounds sum += A[(row-1)*N + j] * x[j]
                end
                @inbounds y[row] = sum
            end
        end
    end
end

# =============================================================================
# Test Functions
# =============================================================================

function test_dot_products()
    n = 1024

    # Create test data
    A_data = rand(Float32, n)
    B_data = rand(Float32, n)

    # Reference result
    expected = sum(A_data .* B_data)

    # Test basic
    result_basic = dot_product_basic(A_data, B_data, n)
    @assert abs(result_basic - expected) < 1e-3 "Basic dot product failed"
    println("✓ Basic dot product: $result_basic")

    # Test cyclic partitioned
    A_cyclic = PartitionedArray{Float32, 1, 4, CYCLIC}(A_data)
    B_cyclic = PartitionedArray{Float32, 1, 4, CYCLIC}(B_data)
    result_cyclic = dot_product_cyclic(A_cyclic, B_cyclic, n)
    @assert abs(result_cyclic - expected) < 1e-3 "Cyclic dot product failed"
    println("✓ Cyclic partitioned dot product: $result_cyclic")

    # Test block partitioned sum
    A_block = PartitionedArray{Float32, 1, 4, BLOCK}(A_data)
    result_block = parallel_sum_blocks(A_block, n)
    expected_sum = sum(A_data)
    @assert abs(result_block - expected_sum) < 1e-2 "Block sum failed"
    println("✓ Block partitioned sum: $result_block")

    println("\nAll tests passed!")
end

function test_complete_partition()
    n = 64
    input = rand(Float32, n)
    output = zeros(Float32, n)
    coeffs_data = rand(Float32, 8)
    coeffs = PartitionedArray{Float32, 1, 8, COMPLETE}(coeffs_data)

    convolve_small(input, coeffs, output, n)

    # Reference convolution
    for i in 8:n
        expected = sum(input[i-j+1] * coeffs_data[j] for j in 1:8)
        @assert abs(output[i] - expected) < 1e-5 "Convolution mismatch at $i"
    end

    println("✓ Complete partition convolution passed")
end

# =============================================================================
# Compile Examples
# =============================================================================

function compile_partitioned_examples()
    println("\nCompiling partitioned memory examples...")

    # Cyclic dot product
    types_cyclic = Tuple{
        PartitionedArray{Float32, 1, 4, CYCLIC},
        PartitionedArray{Float32, 1, 4, CYCLIC},
        Int
    }

    try
        output = fpga_code_native(dot_product_cyclic, types_cyclic,
                                  format=:ll, output="dot_cyclic_fpga.ll")
        println("  Generated: $output")
    catch e
        println("  Error compiling cyclic: $e")
    end

    # Block sum
    types_block = Tuple{PartitionedArray{Float32, 1, 4, BLOCK}, Int}

    try
        output = fpga_code_native(parallel_sum_blocks, types_block,
                                  format=:ll, output="sum_block_fpga.ll")
        println("  Generated: $output")
    catch e
        println("  Error compiling block: $e")
    end
end

# =============================================================================
# Main
# =============================================================================

if abspath(PROGRAM_FILE) == @__FILE__
    println("FPGACompiler.jl - Memory Partitioning Example")
    println("=" ^ 60)

    println("\n1. Testing PartitionedArray operations...")
    test_dot_products()

    println("\n2. Testing complete partition...")
    test_complete_partition()

    println("\n3. Compiling for FPGA...")
    try
        compile_partitioned_examples()
    catch e
        println("Compilation requires GPUCompiler and LLVM setup")
    end

    println("\n4. Partitioning Summary:")
    println("   CYCLIC:   Best for strided access (unrolled loops)")
    println("   BLOCK:    Best for independent array sections")
    println("   COMPLETE: Best for small arrays (< 64 elements)")
end
