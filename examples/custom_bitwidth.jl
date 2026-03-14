# Custom Bit-Width Example
# Demonstrates FixedInt for resource-efficient FPGA designs

using FPGACompiler

# =============================================================================
# Why Custom Bit Widths?
# =============================================================================

#=
Standard CPUs use 8/16/32/64-bit integers, but FPGAs can use ANY bit width.

Benefits of custom bit widths:
1. Reduced Logic: 7-bit counter uses ~7 LUTs vs ~8 for 8-bit
2. Smaller Multipliers: 12×12 multiplication uses fewer DSP resources
3. Better Packing: Multiple narrow values fit in one BRAM word
4. Power Savings: Less switching activity

Common use cases:
- ADC/DAC interfaces (10, 12, 14, 24-bit)
- Address generators (log2(N) bits)
- Fixed-point DSP (arbitrary precision)
- State machines (ceil(log2(states)) bits)
=#

# =============================================================================
# Pre-defined Types
# =============================================================================

# FPGACompiler provides common aliases:
# Int7, Int12, Int14, Int24
# UInt7, UInt12, UInt14, UInt24

function demonstrate_predefined_types()
    println("Pre-defined FixedInt types:")

    # 7-bit signed (common for small counters)
    x7 = Int7(42)
    println("  Int7(42)  = $x7, bitwidth = $(bitwidth(x7))")

    # 12-bit unsigned (common for ADC values)
    adc = UInt12(2048)
    println("  UInt12(2048) = $adc, bitwidth = $(bitwidth(adc))")

    # 14-bit signed (common for audio)
    audio = Int14(-1000)
    println("  Int14(-1000) = $audio, bitwidth = $(bitwidth(audio))")

    # 24-bit signed (high-precision audio)
    audio24 = Int24(1_000_000)
    println("  Int24(1000000) = $audio24, bitwidth = $(bitwidth(audio24))")
end

# =============================================================================
# Custom Bit Widths
# =============================================================================

function demonstrate_custom_bitwidths()
    println("\nCustom bit widths:")

    # 3-bit for 8-state FSM
    state = FixedInt{3, UInt8}(5)
    println("  3-bit state: $state")

    # 10-bit for 1024-point FFT index
    fft_idx = FixedInt{10, UInt16}(512)
    println("  10-bit index: $fft_idx")

    # 18-bit for FPGA multiplier inputs (common DSP width)
    mult_in = FixedInt{18, Int32}(100000)
    println("  18-bit multiplier input: $mult_in")

    # 48-bit for accumulator (common DSP accumulator width)
    accum = FixedInt{48, Int64}(1_000_000_000_000)
    println("  48-bit accumulator: $accum")
end

# =============================================================================
# Arithmetic Operations
# =============================================================================

function demonstrate_arithmetic()
    println("\nArithmetic with FixedInt:")

    a = Int7(10)
    b = Int7(20)

    println("  a = Int7(10)")
    println("  b = Int7(20)")
    println("  a + b = $(a + b)")
    println("  a * b = $(a * b)  (wraps to 7 bits)")
    println("  b - a = $(b - a)")

    # Comparisons
    println("\n  a < b  = $(a < b)")
    println("  a == Int7(10) = $(a == Int7(10))")

    # Bitwise operations
    println("\n  a & b = $(a & b)")
    println("  a | b = $(a | b)")
    println("  a ⊻ b = $(a ⊻ b)")
end

# =============================================================================
# ADC Processing Example
# =============================================================================

"""
Process 12-bit ADC samples with gain and offset correction.

Uses 12-bit input (UInt12), 16-bit intermediate (Int16),
and 12-bit output (UInt12) for resource efficiency.
"""
@fpga_kernel function adc_process!(
    raw::Vector{UInt16},      # Raw 12-bit ADC samples (stored in UInt16)
    processed::Vector{UInt16}, # Processed 12-bit samples
    gain::Int16,              # Gain factor (1.0 = 4096)
    offset::Int16,            # DC offset correction
    n::Int
)
    @pipeline II=1 for i in 1:n
        # Read raw sample (12 bits)
        @inbounds sample = FixedInt{12, UInt16}(raw[i])

        # Apply offset (could go negative, use signed)
        corrected = Int16(sample.value) - offset

        # Apply gain (fixed-point: gain/4096)
        scaled = (corrected * gain) >> 12

        # Clamp to 12-bit range
        if scaled < 0
            result = UInt16(0)
        elseif scaled > 4095
            result = UInt16(4095)
        else
            result = UInt16(scaled)
        end

        @inbounds processed[i] = result
    end
end

# =============================================================================
# Counter with Minimal Bits
# =============================================================================

"""
Generate addresses for a memory of size N.
Uses only ceil(log2(N)) bits for the counter.
"""
function make_address_counter(memory_size::Int)
    # Calculate minimum bits needed
    bits_needed = ceil(Int, log2(memory_size))
    println("Memory size $memory_size requires $bits_needed-bit counter")

    # Create appropriate FixedInt type
    if bits_needed <= 8
        return FixedInt{bits_needed, UInt8}
    elseif bits_needed <= 16
        return FixedInt{bits_needed, UInt16}
    else
        return FixedInt{bits_needed, UInt32}
    end
end

# =============================================================================
# Fixed-Point DSP
# =============================================================================

"""
Fixed-point FIR filter using 18-bit coefficients and 18-bit data.

18-bit is chosen because many FPGA DSP blocks have 18×18 multipliers.
Using exactly 18 bits maximizes DSP utilization.
"""
@fpga_kernel function fir_fixed_point!(
    input::Vector{Int32},   # Input samples (18-bit in Int32)
    coeffs::Vector{Int32},  # Filter coefficients (18-bit in Int32)
    output::Vector{Int32},  # Output samples (18-bit in Int32)
    n_samples::Int,
    n_taps::Int
)
    @pipeline II=1 for i in n_taps:n_samples
        # 48-bit accumulator (standard DSP accumulator width)
        acc = FixedInt{48, Int64}(0)

        for j in 1:n_taps
            # 18-bit × 18-bit = 36-bit product, fits in accumulator
            @inbounds x = FixedInt{18, Int32}(input[i - j + 1])
            @inbounds c = FixedInt{18, Int32}(coeffs[j])

            # Multiply and accumulate
            product = Int64(x.value) * Int64(c.value)
            acc = FixedInt{48, Int64}(acc.value + product)
        end

        # Scale down and saturate to 18 bits
        result = acc.value >> 15  # Assuming Q15 format
        if result > 131071  # 2^17 - 1
            result = 131071
        elseif result < -131072
            result = -131072
        end

        @inbounds output[i] = Int32(result)
    end
end

# =============================================================================
# Resource Comparison
# =============================================================================

function compare_resources()
    println("\nResource comparison (theoretical):")
    println("=" ^ 50)

    comparisons = [
        ("8-bit counter vs 7-bit", 8, 7),
        ("16-bit counter vs 12-bit", 16, 12),
        ("32-bit multiplier vs 18-bit", 32, 18),
        ("64-bit accumulator vs 48-bit", 64, 48),
    ]

    for (desc, standard, optimized) in comparisons
        savings = round((1 - optimized/standard) * 100, digits=1)
        println("  $desc: ~$savings% reduction")
    end
end

# =============================================================================
# Test Functions
# =============================================================================

function test_adc_processing()
    n = 1024

    # Simulate 12-bit ADC samples (0-4095)
    raw = UInt16.(rand(0:4095, n))
    processed = zeros(UInt16, n)

    # Gain of 1.0 (4096 in fixed-point), offset of 100
    gain = Int16(4096)
    offset = Int16(100)

    adc_process!(raw, processed, gain, offset, n)

    # Verify processing
    passed = true
    for i in 1:n
        expected = clamp(Int(raw[i]) - offset, 0, 4095)
        if processed[i] != expected
            println("Mismatch at $i: got $(processed[i]), expected $expected")
            passed = false
        end
    end

    if passed
        println("✓ ADC processing test passed")
    else
        println("✗ ADC processing test failed")
    end
end

# =============================================================================
# Main
# =============================================================================

if abspath(PROGRAM_FILE) == @__FILE__
    println("FPGACompiler.jl - Custom Bit-Width Example")
    println("=" ^ 60)

    println("\n1. Pre-defined types...")
    demonstrate_predefined_types()

    println("\n2. Custom bit widths...")
    demonstrate_custom_bitwidths()

    println("\n3. Arithmetic operations...")
    demonstrate_arithmetic()

    println("\n4. Testing ADC processing...")
    test_adc_processing()

    println("\n5. Address counter example...")
    for size in [256, 1024, 4096, 65536]
        make_address_counter(size)
    end

    compare_resources()

    println("\n6. Compiling for FPGA...")
    try
        types = Tuple{Vector{UInt16}, Vector{UInt16}, Int16, Int16, Int}
        output = fpga_code_native(adc_process!, types,
                                  format=:ll, output="adc_process_fpga.ll")
        println("  Generated: $output")
    catch e
        println("  Compilation requires GPUCompiler and LLVM setup")
    end
end
