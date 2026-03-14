# Matrix Multiplication Example
# Demonstrates loop pipelining and optimization with FPGACompiler.jl

using FPGACompiler

# =============================================================================
# Basic Matrix Multiplication
# =============================================================================

"""
Standard matrix multiplication: C = A × B
where A is MxK, B is KxN, C is MxN

Uses row-major linearized arrays for FPGA compatibility.
"""
@fpga_kernel function matmul_basic!(
    A::Vector{Float32},  # M × K matrix (row-major)
    B::Vector{Float32},  # K × N matrix (row-major)
    C::Vector{Float32},  # M × N matrix (row-major)
    M::Int, N::Int, K::Int
)
    for i in 1:M
        for j in 1:N
            sum = 0.0f0
            for k in 1:K
                @inbounds sum += A[(i-1)*K + k] * B[(k-1)*N + j]
            end
            @inbounds C[(i-1)*N + j] = sum
        end
    end
end

# =============================================================================
# Pipelined Matrix Multiplication
# =============================================================================

"""
Matrix multiplication with pipelined inner loop.

The innermost loop (k) has no loop-carried dependencies on memory,
so it can achieve II=1 (one multiply-accumulate per clock cycle).
"""
@fpga_kernel function matmul_pipelined!(
    A::Vector{Float32},
    B::Vector{Float32},
    C::Vector{Float32},
    M::Int, N::Int, K::Int
)
    for i in 1:M
        for j in 1:N
            sum = 0.0f0

            # Pipeline the reduction loop
            # II=1 means new iteration every clock cycle
            @pipeline II=1 for k in 1:K
                @inbounds sum += A[(i-1)*K + k] * B[(k-1)*N + j]
            end

            @inbounds C[(i-1)*N + j] = sum
        end
    end
end

# =============================================================================
# Tiled Matrix Multiplication
# =============================================================================

"""
Tiled matrix multiplication for better memory locality.

Uses TILE_SIZE × TILE_SIZE blocks to maximize data reuse
and reduce memory bandwidth requirements.
"""
const TILE_SIZE = 16

@fpga_kernel function matmul_tiled!(
    A::Vector{Float32},
    B::Vector{Float32},
    C::Vector{Float32},
    M::Int, N::Int, K::Int
)
    # Iterate over tiles
    for i_tile in 1:TILE_SIZE:M
        for j_tile in 1:TILE_SIZE:N
            # Initialize output tile
            for i in 0:(TILE_SIZE-1)
                for j in 0:(TILE_SIZE-1)
                    if (i_tile + i) <= M && (j_tile + j) <= N
                        @inbounds C[(i_tile + i - 1)*N + (j_tile + j)] = 0.0f0
                    end
                end
            end

            # Accumulate over K tiles
            for k_tile in 1:TILE_SIZE:K
                # Compute tile contribution
                for i in 0:(TILE_SIZE-1)
                    for j in 0:(TILE_SIZE-1)
                        if (i_tile + i) <= M && (j_tile + j) <= N
                            sum = 0.0f0

                            @pipeline II=1 for k in 0:(TILE_SIZE-1)
                                if (k_tile + k) <= K
                                    ii = i_tile + i
                                    jj = j_tile + j
                                    kk = k_tile + k
                                    @inbounds sum += A[(ii-1)*K + kk] * B[(kk-1)*N + jj]
                                end
                            end

                            idx = (i_tile + i - 1)*N + (j_tile + j)
                            @inbounds C[idx] += sum
                        end
                    end
                end
            end
        end
    end
end

# =============================================================================
# Test Functions
# =============================================================================

function test_matmul(matmul_fn, M, N, K)
    # Create test data
    A = rand(Float32, M * K)
    B = rand(Float32, K * N)
    C = zeros(Float32, M * N)

    # Run kernel
    matmul_fn(A, B, C, M, N, K)

    # Compute reference using Julia's matrix multiplication
    A_mat = reshape(A, K, M)'  # M × K
    B_mat = reshape(B, N, K)'  # K × N
    C_ref = A_mat * B_mat      # M × N

    # Compare
    C_mat = reshape(C, N, M)'
    max_error = maximum(abs.(C_mat .- C_ref))

    if max_error < 1e-4
        println("✓ $(nameof(matmul_fn)) test passed (max error: $max_error)")
        return true
    else
        println("✗ $(nameof(matmul_fn)) test failed (max error: $max_error)")
        return false
    end
end

# =============================================================================
# Compile and Compare
# =============================================================================

function compile_matmul_variants()
    types = Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int, Int, Int}

    variants = [
        ("basic", matmul_basic!),
        ("pipelined", matmul_pipelined!),
        ("tiled", matmul_tiled!)
    ]

    for (name, fn) in variants
        println("\nCompiling matmul_$name...")
        try
            output = fpga_code_native(fn, types, format=:ll, output="matmul_$(name)_fpga.ll")
            println("  Generated: $output")

            # Estimate resources
            resources = estimate_resources(fn, types)
            println("  Estimated DSPs: $(resources["estimated_dsps"])")
        catch e
            println("  Error: $e")
        end
    end
end

# =============================================================================
# Main
# =============================================================================

if abspath(PROGRAM_FILE) == @__FILE__
    println("FPGACompiler.jl - Matrix Multiplication Example")
    println("=" ^ 60)

    M, N, K = 64, 64, 64

    println("\n1. Testing implementations in Julia ($(M)×$(K) × $(K)×$(N))...")
    test_matmul(matmul_basic!, M, N, K)
    test_matmul(matmul_pipelined!, M, N, K)
    test_matmul(matmul_tiled!, M, N, K)

    println("\n2. Compiling for FPGA...")
    try
        compile_matmul_variants()
    catch e
        println("Compilation requires GPUCompiler and LLVM setup")
        println("Error: $e")
    end

    println("\n3. Performance comparison:")
    println("   Basic:     ~M×N×K clock cycles (sequential)")
    println("   Pipelined: ~M×N×K clock cycles (overlapped, higher throughput)")
    println("   Tiled:     Better memory locality, fewer DRAM accesses")
end
