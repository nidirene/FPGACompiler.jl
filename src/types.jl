# Custom Types for FPGA Hardware Synthesis
# These types encode hardware constraints directly in Julia's type system

"""
    PartitionStyle

Enumeration of memory partitioning strategies for BRAM allocation.
"""
@enum PartitionStyle begin
    CYCLIC    # Round-robin distribution across banks
    BLOCK     # Contiguous chunks per bank
    COMPLETE  # Fully partition into registers (small arrays only)
end

"""
    PartitionedArray{T, N, Factor, Style}

A wrapper around Julia arrays that signals memory partitioning intent to the HLS compiler.
The array will be split across `Factor` BRAM banks using the specified `Style`.

# Type Parameters
- `T`: Element type
- `N`: Number of dimensions
- `Factor`: Number of memory banks to partition across
- `Style`: Partitioning strategy (CYCLIC, BLOCK, or COMPLETE)

# Example
```julia
# Partition a 1024-element array into 4 BRAM banks using cyclic distribution
A = PartitionedArray{Float32, 1, 4, CYCLIC}(zeros(Float32, 1024))
```
"""
struct PartitionedArray{T, N, Factor, Style}
    data::Array{T, N}

    function PartitionedArray{T, N, Factor, Style}(data::Array{T, N}) where {T, N, Factor, Style}
        Factor > 0 || throw(ArgumentError("Partition factor must be positive"))
        Style isa PartitionStyle || throw(ArgumentError("Style must be a PartitionStyle"))
        new{T, N, Factor, Style}(data)
    end
end

# Convenience constructor
function PartitionedArray(data::Array{T, N}; factor::Int=2, style::PartitionStyle=CYCLIC) where {T, N}
    PartitionedArray{T, N, factor, style}(data)
end

# Forward array interface to underlying data
Base.size(pa::PartitionedArray) = size(pa.data)
Base.length(pa::PartitionedArray) = length(pa.data)
Base.getindex(pa::PartitionedArray, i...) = getindex(pa.data, i...)
Base.setindex!(pa::PartitionedArray, v, i...) = setindex!(pa.data, v, i...)
Base.eltype(::Type{PartitionedArray{T, N, F, S}}) where {T, N, F, S} = T
Base.ndims(::Type{PartitionedArray{T, N, F, S}}) where {T, N, F, S} = N

# Extract partition metadata
partition_factor(::Type{PartitionedArray{T, N, F, S}}) where {T, N, F, S} = F
partition_factor(pa::PartitionedArray) = partition_factor(typeof(pa))
partition_style(::Type{PartitionedArray{T, N, F, S}}) where {T, N, F, S} = S
partition_style(pa::PartitionedArray) = partition_style(typeof(pa))

# ============================================================================
# Arbitrary Bit-Width Integer Types
# FPGAs can compute with any bit width, not just 8/16/32/64
# ============================================================================

# Julia primitive types must be byte-aligned (multiples of 8 bits).
# For non-byte-aligned bit widths, we use a wrapper type that carries
# the bit-width information in the type system. The actual LLVM lowering
# to arbitrary bit widths (i3, i7, etc.) happens during compilation.

"""
    FixedInt{N, T}

A fixed-width integer type that signals to the FPGA compiler to use
exactly N bits in hardware. The value is stored in a standard Julia
integer type T, but the compiler will truncate to N bits during synthesis.

# Type Parameters
- `N`: Number of bits (1-64)
- `T`: Storage type (Int8, Int16, Int32, Int64, or unsigned variants)

# Example
```julia
# 7-bit signed integer (stored in Int8, synthesized as i7)
x = FixedInt{7, Int8}(42)

# 12-bit unsigned integer
y = FixedInt{12, UInt16}(1000)
```
"""
struct FixedInt{N, T<:Integer} <: Integer
    value::T

    function FixedInt{N, T}(x::Integer) where {N, T<:Integer}
        @assert 1 <= N <= sizeof(T) * 8 "Bit width N must be between 1 and $(sizeof(T)*8)"
        # Mask to N bits (for unsigned) or allow sign extension (for signed)
        mask = (one(T) << N) - one(T)
        new{N, T}(T(x) & mask)
    end
end

# Convenience constructors for common bit widths
const Int7  = FixedInt{7, Int8}
const Int12 = FixedInt{12, Int16}
const Int14 = FixedInt{14, Int16}
const Int24 = FixedInt{24, Int32}

const UInt7  = FixedInt{7, UInt8}
const UInt12 = FixedInt{12, UInt16}
const UInt14 = FixedInt{14, UInt16}
const UInt24 = FixedInt{24, UInt32}

# Export the custom integer type aliases
export FixedInt, Int7, Int12, Int14, Int24
export UInt7, UInt12, UInt14, UInt24

# Get the bit width from the type
bitwidth(::Type{FixedInt{N, T}}) where {N, T} = N
bitwidth(x::FixedInt) = bitwidth(typeof(x))

# Basic conversions
Base.convert(::Type{FixedInt{N, T}}, x::Integer) where {N, T} = FixedInt{N, T}(x)
Base.convert(::Type{T}, x::FixedInt{N, T}) where {N, T} = x.value

# Promotion rules
Base.promote_rule(::Type{FixedInt{N, T}}, ::Type{<:Integer}) where {N, T} = T

# Arithmetic operations (operate on underlying value, result stays FixedInt)
for op in (:+, :-, :*, :÷, :%, :&, :|, :⊻)
    @eval function Base.$op(a::FixedInt{N, T}, b::FixedInt{N, T}) where {N, T}
        FixedInt{N, T}($op(a.value, b.value))
    end
end

# Comparison operations
for op in (:<, :<=, :>, :>=, :(==), :!=)
    @eval Base.$op(a::FixedInt{N, T}, b::FixedInt{N, T}) where {N, T} = $op(a.value, b.value)
end

# Display
Base.show(io::IO, x::FixedInt{N, T}) where {N, T} = print(io, "FixedInt{$N}($(x.value))")

# For the actual LLVM lowering to iN types, the compiler hooks into
# GPUCompiler's code generation to emit the correct LLVM IR.
# This happens in optimize.jl when we detect FixedInt usage.
