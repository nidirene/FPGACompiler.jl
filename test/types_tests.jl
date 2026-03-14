# Type System Tests
# Tests for FixedInt and PartitionedArray types

@testset "FixedInt Types" begin

    @testset "Construction" begin
        # Test basic construction
        x = FixedInt{7, Int8}(42)
        @test x.value == 42
        @test bitwidth(x) == 7

        # Test with type aliases
        y = Int7(42)
        @test y.value == 42
        @test bitwidth(y) == 7

        z = UInt12(1000)
        @test z.value == 1000
        @test bitwidth(z) == 12

        # Test value masking (truncation to N bits)
        # 7-bit max unsigned is 127, so 200 & 0x7F = 72
        masked = FixedInt{7, UInt8}(200)
        @test masked.value == (200 & 0x7F)
    end

    @testset "Arithmetic Operations" begin
        a = Int7(10)
        b = Int7(20)

        # Addition
        c = a + b
        @test c isa FixedInt{7, Int8}
        @test c.value == 30

        # Subtraction
        d = b - a
        @test d.value == 10

        # Multiplication (with wrapping)
        e = a * b
        @test e isa FixedInt{7, Int8}
        # 10 * 20 = 200, but 200 & 0x7F = 72
        @test e.value == (200 & 0x7F)

        # Division
        f = Int7(20) ÷ Int7(4)
        @test f.value == 5

        # Modulo
        g = Int7(23) % Int7(5)
        @test g.value == 3
    end

    @testset "Bitwise Operations" begin
        a = UInt7(0b1010101)  # 85
        b = UInt7(0b0110011)  # 51

        # AND
        @test (a & b).value == (85 & 51)

        # OR
        @test (a | b).value == (85 | 51)

        # XOR
        @test (a ⊻ b).value == (85 ⊻ 51)
    end

    @testset "Comparison Operations" begin
        a = Int12(100)
        b = Int12(200)
        c = Int12(100)

        @test a < b
        @test a <= b
        @test b > a
        @test b >= a
        @test a == c
        @test a != b
    end

    @testset "Conversions" begin
        x = Int7(42)

        # Conversion to base type
        y = convert(Int8, x)
        @test y == 42
        @test y isa Int8

        # Conversion from integer
        z = convert(Int7, 50)
        @test z.value == 50
        @test z isa FixedInt{7, Int8}
    end

    @testset "Different Bit Widths" begin
        # Test all predefined widths
        @test bitwidth(Int7(0)) == 7
        @test bitwidth(Int12(0)) == 12
        @test bitwidth(Int14(0)) == 14
        @test bitwidth(Int24(0)) == 24

        @test bitwidth(UInt7(0)) == 7
        @test bitwidth(UInt12(0)) == 12
        @test bitwidth(UInt14(0)) == 14
        @test bitwidth(UInt24(0)) == 24
    end

    @testset "Edge Cases" begin
        # Maximum values
        max_7bit = Int7(63)  # 2^6 - 1 for signed
        @test max_7bit.value == 63

        max_u12 = UInt12(4095)  # 2^12 - 1
        @test max_u12.value == 4095

        # Overflow wrapping
        overflow = UInt7(127) + UInt7(1)
        @test overflow.value == 0  # Wraps around

        # Custom bit widths
        x = FixedInt{3, UInt8}(7)  # Max 3-bit unsigned
        @test x.value == 7

        y = FixedInt{5, Int8}(15)  # Max 5-bit signed
        @test y.value == 15
    end

    @testset "Display" begin
        x = Int7(42)
        s = sprint(show, x)
        @test occursin("FixedInt{7}", s)
        @test occursin("42", s)
    end
end

@testset "PartitionedArray Types" begin

    @testset "Construction" begin
        data = zeros(Float32, 1024)

        # Full type specification
        pa = PartitionedArray{Float32, 1, 4, CYCLIC}(data)
        @test pa isa PartitionedArray{Float32, 1, 4, CYCLIC}
        @test partition_factor(pa) == 4
        @test partition_style(pa) == CYCLIC

        # Convenience constructor
        pb = PartitionedArray(data; factor=8, style=BLOCK)
        @test partition_factor(pb) == 8
        @test partition_style(pb) == BLOCK

        # Default values
        pc = PartitionedArray(data)
        @test partition_factor(pc) == 2
        @test partition_style(pc) == CYCLIC
    end

    @testset "Array Interface" begin
        data = collect(Float32, 1:100)
        pa = PartitionedArray{Float32, 1, 4, CYCLIC}(data)

        # Size and length
        @test size(pa) == (100,)
        @test length(pa) == 100

        # Element type
        @test eltype(typeof(pa)) == Float32
        @test ndims(typeof(pa)) == 1

        # Indexing
        @test pa[1] == 1.0f0
        @test pa[50] == 50.0f0
        @test pa[100] == 100.0f0

        # Assignment
        pa[1] = 42.0f0
        @test pa[1] == 42.0f0
    end

    @testset "2D Arrays" begin
        data = zeros(Float64, 10, 10)
        pa = PartitionedArray{Float64, 2, 2, BLOCK}(data)

        @test size(pa) == (10, 10)
        @test length(pa) == 100
        @test ndims(typeof(pa)) == 2

        pa[5, 5] = 99.0
        @test pa[5, 5] == 99.0
    end

    @testset "Partition Styles" begin
        @test CYCLIC isa PartitionStyle
        @test BLOCK isa PartitionStyle
        @test COMPLETE isa PartitionStyle

        # Different styles
        data = zeros(Float32, 64)

        cyclic = PartitionedArray{Float32, 1, 4, CYCLIC}(data)
        @test partition_style(cyclic) == CYCLIC

        block = PartitionedArray{Float32, 1, 4, BLOCK}(data)
        @test partition_style(block) == BLOCK

        complete = PartitionedArray{Float32, 1, 64, COMPLETE}(data)
        @test partition_style(complete) == COMPLETE
    end

    @testset "Type Parameters" begin
        # Extract from type
        T = PartitionedArray{Float64, 2, 8, BLOCK}
        @test partition_factor(T) == 8
        @test partition_style(T) == BLOCK
        @test eltype(T) == Float64
        @test ndims(T) == 2
    end

    @testset "Invalid Construction" begin
        data = zeros(Float32, 100)

        # Factor must be positive
        @test_throws ArgumentError PartitionedArray{Float32, 1, 0, CYCLIC}(data)
        @test_throws ArgumentError PartitionedArray{Float32, 1, -1, CYCLIC}(data)
    end
end
