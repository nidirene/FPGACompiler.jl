# High-Level Compilation Interface
# Provides user-facing macros and functions to compile Julia code for FPGAs

# ============================================================================
# Global Registry for Macro Hints
# ============================================================================

"""
    HintRegistry

Thread-safe registry for storing compilation hints from macros.
Maps source location hashes to hint tuples.
"""
const PIPELINE_HINTS = Dict{UInt64, NamedTuple{(:ii,), Tuple{Int}}}()
const UNROLL_HINTS = Dict{UInt64, NamedTuple{(:factor, :full), Tuple{Int, Bool}}}()
const KERNEL_REGISTRY = Set{Symbol}()
const REGISTRY_LOCK = ReentrantLock()

"""
    register_pipeline_hint!(id::UInt64, ii::Int)

Register a pipeline hint for a loop identified by its hash.
"""
function register_pipeline_hint!(id::UInt64, ii::Int)
    lock(REGISTRY_LOCK) do
        PIPELINE_HINTS[id] = (ii=ii,)
    end
end

"""
    register_unroll_hint!(id::UInt64, factor::Int, full::Bool)

Register an unroll hint for a loop identified by its hash.
"""
function register_unroll_hint!(id::UInt64, factor::Int, full::Bool)
    lock(REGISTRY_LOCK) do
        UNROLL_HINTS[id] = (factor=factor, full=full)
    end
end

"""
    register_kernel!(name::Symbol)

Register a function as an FPGA kernel.
"""
function register_kernel!(name::Symbol)
    lock(REGISTRY_LOCK) do
        push!(KERNEL_REGISTRY, name)
    end
end

"""
    get_pipeline_hint(id::UInt64)

Retrieve pipeline hint for a loop, or nothing if not found.
"""
function get_pipeline_hint(id::UInt64)
    lock(REGISTRY_LOCK) do
        get(PIPELINE_HINTS, id, nothing)
    end
end

"""
    get_unroll_hint(id::UInt64)

Retrieve unroll hint for a loop, or nothing if not found.
"""
function get_unroll_hint(id::UInt64)
    lock(REGISTRY_LOCK) do
        get(UNROLL_HINTS, id, nothing)
    end
end

"""
    is_registered_kernel(name::Symbol)

Check if a function is registered as an FPGA kernel.
"""
function is_registered_kernel(name::Symbol)
    lock(REGISTRY_LOCK) do
        name in KERNEL_REGISTRY
    end
end

"""
    clear_hints!()

Clear all registered hints (useful for testing).
"""
function clear_hints!()
    lock(REGISTRY_LOCK) do
        empty!(PIPELINE_HINTS)
        empty!(UNROLL_HINTS)
        empty!(KERNEL_REGISTRY)
    end
end

"""
    fpga_compile(f, types; params=FPGACompilerParams())

Compile a Julia function for FPGA synthesis, returning the LLVM module.

# Arguments
- `f`: The Julia function to compile
- `types`: Tuple of argument types
- `params`: Compilation parameters (optional)

# Returns
- `LLVM.Module`: The optimized LLVM module ready for HLS tools

# Example
```julia
function vadd(A, B, C, n)
    for i in 1:n
        @inbounds C[i] = A[i] + B[i]
    end
end

mod = fpga_compile(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})
```
"""
function fpga_compile(f, types::Type{<:Tuple}; params=FPGACompilerParams())
    # Create compilation job
    target = FPGATarget()
    job = GPUCompiler.CompilerJob(target, f, types; params=params)

    # Compile to LLVM IR
    mod, meta = GPUCompiler.compile(:llvm, job)

    return mod
end

"""
    fpga_code_llvm(f, types; params=FPGACompilerParams())

Return the LLVM IR as a string for inspection.

# Example
```julia
ir = fpga_code_llvm(vadd, Tuple{Vector{Float32}, Vector{Float32}, Vector{Float32}, Int})
println(ir)
```
"""
function fpga_code_llvm(f, types::Type{<:Tuple}; params=FPGACompilerParams())
    mod = fpga_compile(f, types; params=params)
    return string(mod)
end

"""
    fpga_code_native(f, types; format=:ll, output=nothing, params=FPGACompilerParams())

Write the compiled LLVM IR to a file for use with HLS tools.

# Arguments
- `f`: Function to compile
- `types`: Argument types
- `format`: Output format (`:ll` for text IR, `:bc` for bitcode)
- `output`: Output file path (auto-generated if not provided)
- `params`: Compilation parameters

# Returns
- Path to the output file

# Example
```julia
# Generate LLVM IR file
path = fpga_code_native(vadd, Tuple{Vector{Float32}...}, format=:ll)

# Feed to vendor HLS tool
run(`vitis_hls -f \$path`)  # AMD Vitis
run(`aoc \$path`)            # Intel oneAPI
```
"""
function fpga_code_native(f, types::Type{<:Tuple};
                          format::Symbol=:ll,
                          output::Union{String, Nothing}=nothing,
                          params=FPGACompilerParams())

    mod = fpga_compile(f, types; params=params)

    # Generate output filename if not provided
    if output === nothing
        fname = string(nameof(f))
        ext = format == :bc ? ".bc" : ".ll"
        output = fname * "_fpga" * ext
    end

    # Write to file
    if format == :bc
        LLVM.write_bitcode_to_file(mod, output)
    else
        open(output, "w") do io
            write(io, string(mod))
        end
    end

    return output
end

# ============================================================================
# Macro Interface (Future Work)
# ============================================================================

"""
    @fpga_kernel function_definition

Mark a function for FPGA compilation with automatic optimization hints.

This macro:
1. Registers the function as an FPGA kernel
2. Adds validation checks for FPGA compatibility
3. Enables optimization hints from nested @pipeline and @unroll macros

# Example
```julia
@fpga_kernel function matrix_mul(A, B, C, M, N, K)
    for i in 1:M
        for j in 1:N
            sum = 0.0f0
            for k in 1:K
                @inbounds sum += A[i, k] * B[k, j]
            end
            @inbounds C[i, j] = sum
        end
    end
end
```

# FPGA Kernel Constraints
- No dynamic memory allocation (push!, resize!, Array constructors)
- No exceptions (use @inbounds for array access)
- No recursion (all functions must inline)
- All types must be statically inferrable
"""
macro fpga_kernel(expr)
    # Validate that we have a function definition
    if !Meta.isexpr(expr, :function) && !Meta.isexpr(expr, :(=))
        error("@fpga_kernel expects a function definition")
    end

    # Extract function name
    func_name = if Meta.isexpr(expr, :function)
        if Meta.isexpr(expr.args[1], :call)
            expr.args[1].args[1]
        elseif Meta.isexpr(expr.args[1], :where)
            expr.args[1].args[1].args[1]
        else
            error("Could not extract function name from @fpga_kernel")
        end
    else
        # Short-form function: f(x) = ...
        if Meta.isexpr(expr.args[1], :call)
            expr.args[1].args[1]
        else
            error("Could not extract function name from @fpga_kernel")
        end
    end

    # Generate registration and wrapped function
    quote
        # Register this function as an FPGA kernel
        $FPGACompiler.register_kernel!($(QuoteNode(func_name)))

        # Define the function
        $(esc(expr))
    end
end

"""
    @pipeline [II=n] loop

Mark a loop for hardware pipelining with target initiation interval.

Pipelining overlaps loop iterations in hardware, allowing multiple iterations
to be "in flight" simultaneously. The Initiation Interval (II) specifies how
many clock cycles between starting consecutive iterations.

# Arguments
- `II=n`: Target Initiation Interval (default: 1)
  - II=1: Start a new iteration every clock cycle (maximum throughput)
  - II=2: Start a new iteration every 2 clock cycles (half throughput)

# Example
```julia
@fpga_kernel function pipelined_sum(A, n)
    sum = 0.0f0
    @pipeline II=1 for i in 1:n
        @inbounds sum += A[i]
    end
    return sum
end
```

# Hardware Effect
The HLS tool will insert pipeline registers and schedule operations to achieve
the target II. A lower II requires more hardware resources but provides higher
throughput.
"""
macro pipeline(args...)
    if length(args) == 0
        error("@pipeline requires a loop expression")
    end

    # Default II
    ii = 1
    loop_expr = nothing

    if length(args) == 1
        # No II specified, use default
        loop_expr = args[1]
    else
        # Parse II=n parameter
        for i in 1:(length(args)-1)
            arg = args[i]
            if Meta.isexpr(arg, :(=)) && arg.args[1] == :II
                ii = arg.args[2]
                if !(ii isa Integer)
                    error("@pipeline II must be an integer, got: $ii")
                end
            else
                error("@pipeline: unknown parameter: $arg. Expected II=n")
            end
        end
        loop_expr = args[end]
    end

    # Validate loop expression
    if !Meta.isexpr(loop_expr, :for) && !Meta.isexpr(loop_expr, :while)
        error("@pipeline expects a for or while loop, got: $(typeof(loop_expr))")
    end

    # Generate a unique ID for this loop based on its content
    loop_id = hash(loop_expr)

    # Generate code that registers the hint and executes the loop
    quote
        # Register the pipeline hint at runtime
        $FPGACompiler.register_pipeline_hint!($(UInt64(loop_id)), $ii)

        # Execute the loop (unchanged semantics in Julia)
        $(esc(loop_expr))
    end
end

"""
    @unroll [factor=n] [full=true] loop

Mark a loop for hardware unrolling.

Unrolling duplicates the loop body hardware, allowing parallel execution
of multiple loop iterations. This trades silicon area for throughput.

# Arguments
- `factor=n`: Number of iterations to unroll (default: depends on loop bounds)
- `full=true`: Fully unroll the loop (ignore factor)

# Example
```julia
@fpga_kernel function unrolled_dot(A, B, n)
    sum = 0.0f0
    @unroll factor=4 for i in 1:n
        @inbounds sum += A[i] * B[i]
    end
    return sum
end

# Full unroll for small loops
@unroll full=true for i in 1:8
    # Generates 8 parallel hardware units
end
```

# Hardware Effect
- `factor=4`: Loop body is replicated 4 times, processing 4 elements per iteration
- `full=true`: Entire loop is converted to parallel hardware (no loop counter)

# Best Practices
- Match unroll factor to memory partition factor for parallel access
- Use full unroll only for loops with small, compile-time known bounds
- Higher unroll factors increase resource usage
"""
macro unroll(args...)
    if length(args) == 0
        error("@unroll requires a loop expression")
    end

    # Defaults
    factor = 0  # 0 means "let HLS decide" or "full unroll if full=true"
    full = false
    loop_expr = nothing

    if length(args) == 1
        # No parameters specified
        loop_expr = args[1]
    else
        # Parse factor=n and/or full=true parameters
        for i in 1:(length(args)-1)
            arg = args[i]
            if Meta.isexpr(arg, :(=))
                param_name = arg.args[1]
                param_val = arg.args[2]

                if param_name == :factor
                    if !(param_val isa Integer)
                        error("@unroll factor must be an integer, got: $param_val")
                    end
                    factor = param_val
                elseif param_name == :full
                    if !(param_val isa Bool)
                        error("@unroll full must be a boolean, got: $param_val")
                    end
                    full = param_val
                else
                    error("@unroll: unknown parameter: $param_name. Expected factor=n or full=true")
                end
            else
                error("@unroll: expected parameter=value, got: $arg")
            end
        end
        loop_expr = args[end]
    end

    # Validate loop expression
    if !Meta.isexpr(loop_expr, :for) && !Meta.isexpr(loop_expr, :while)
        error("@unroll expects a for or while loop, got: $(typeof(loop_expr))")
    end

    # Generate a unique ID for this loop
    loop_id = hash(loop_expr)

    # Generate code that registers the hint and executes the loop
    quote
        # Register the unroll hint at runtime
        $FPGACompiler.register_unroll_hint!($(UInt64(loop_id)), $factor, $full)

        # Execute the loop (unchanged semantics in Julia)
        $(esc(loop_expr))
    end
end

# ============================================================================
# Utility Functions
# ============================================================================

"""
    validate_kernel(f, types)

Check if a function is valid for FPGA compilation.
Returns a list of warnings/errors about potential synthesis issues.

# Checks performed:
- Dynamic memory allocation (push!, resize!, Array constructors)
- Recursion (self-referential calls)
- Exception handling (try/catch blocks)
- Type inferrability (Any types in signature)
- Forbidden function calls (GC, I/O, etc.)
"""
function validate_kernel(f, types::Type{<:Tuple})
    issues = String[]

    # Get the method instance for the given types
    method_instance = try
        Base.method_instances(f, types)
    catch
        push!(issues, "Could not find method instance for $(nameof(f)) with types $types")
        return issues
    end

    if isempty(method_instance)
        push!(issues, "No matching method found for $(nameof(f)) with types $types")
        return issues
    end

    # Check for Any types in the signature (poor type inference)
    type_params = types.parameters
    for (i, t) in enumerate(type_params)
        if t === Any
            push!(issues, "Argument $i has type Any - FPGA requires concrete types")
        end
    end

    # Get the code info for analysis
    code_info = try
        code_typed(f, types; optimize=false)
    catch e
        push!(issues, "Type inference failed: $e")
        return issues
    end

    if !isempty(code_info)
        ci = code_info[1][1]  # CodeInfo

        # Analyze the typed code
        analyze_code_info!(issues, ci, nameof(f))
    end

    return issues
end

"""
    analyze_code_info!(issues, ci, func_name)

Analyze CodeInfo for FPGA-incompatible patterns.
"""
function analyze_code_info!(issues::Vector{String}, ci, func_name)
    # List of forbidden function patterns
    forbidden_patterns = [
        # Memory allocation
        r"push!" => "Dynamic array growth (push!) not supported",
        r"append!" => "Dynamic array growth (append!) not supported",
        r"resize!" => "Dynamic array resize not supported",
        r"sizehint!" => "Dynamic array hints not supported",
        r"Vector\{" => "Dynamic Vector construction not supported",
        r"Array\{.*\}\(undef" => "Dynamic Array allocation not supported",

        # Exception handling
        r"throw" => "Exception throwing not supported",
        r"error\(" => "Error calls not supported",
        r"@assert" => "Runtime assertions not supported (use compile-time checks)",

        # I/O operations
        r"print" => "I/O operations not supported",
        r"read\(" => "File I/O not supported",
        r"write\(" => "File I/O not supported (except array assignment)",
        r"open\(" => "File operations not supported",

        # Task/threading
        r"@spawn" => "Task spawning not supported",
        r"@threads" => "Threading not supported",
        r"@async" => "Async operations not supported",

        # GC-related
        r"finalize" => "Finalizers not supported",
        r"gc\(" => "Manual GC calls not supported",
    ]

    # Convert CodeInfo to string for pattern matching
    code_str = string(ci)

    for (pattern, message) in forbidden_patterns
        if occursin(pattern, code_str)
            push!(issues, "$message in $func_name")
        end
    end

    # Check for recursion by looking for calls to the same function
    func_str = string(func_name)
    if occursin(Regex("invoke.*$func_str"), code_str)
        push!(issues, "Potential recursion detected in $func_name - FPGAs require static call graphs")
    end

    # Check for try/catch blocks
    if occursin(r"enter.*try", code_str) || occursin("catch", code_str)
        push!(issues, "Exception handling (try/catch) not supported in $func_name")
    end
end

"""
    code_typed(f, types; optimize=false)

Get the typed code for a function with specific argument types.
Wrapper around Julia's code introspection.
"""
function code_typed(f, types::Type{<:Tuple}; optimize::Bool=false)
    return Base.code_typed(f, types; optimize=optimize)
end

"""
    estimate_resources(f, types)

Estimate FPGA resource usage (LUTs, FFs, DSPs, BRAMs) for a kernel.
This is a rough estimate based on IR analysis.
"""
function estimate_resources(f, types::Type{<:Tuple})
    mod = fpga_compile(f, types)

    resources = Dict{String, Int}(
        "estimated_luts" => 0,
        "estimated_ffs" => 0,
        "estimated_dsps" => 0,
        "estimated_brams" => 0
    )

    # Count operations in the IR to estimate resources
    for func in LLVM.functions(mod)
        for bb in LLVM.blocks(func)
            for inst in LLVM.instructions(bb)
                opcode = LLVM.opcode(inst)

                # Rough estimates based on operation type
                if opcode == LLVM.API.LLVMFMul || opcode == LLVM.API.LLVMMul
                    resources["estimated_dsps"] += 1
                elseif opcode == LLVM.API.LLVMAdd || opcode == LLVM.API.LLVMSub
                    resources["estimated_luts"] += 10
                elseif opcode == LLVM.API.LLVMLoad || opcode == LLVM.API.LLVMStore
                    resources["estimated_brams"] += 1
                end

                resources["estimated_ffs"] += 1  # Rough: each op needs some FFs
            end
        end
    end

    return resources
end
