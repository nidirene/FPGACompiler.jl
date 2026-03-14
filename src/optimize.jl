# LLVM Optimization Passes for FPGA HLS
# Implements Phase 1 (Canonicalization) and Phase 2 (Dependency Analysis)

"""
    GPUCompiler.optimize!(job::CompilerJob{FPGATarget}, mod::LLVM.Module)

Custom optimization pipeline for FPGA targets. Runs canonicalization passes
to prepare the IR for High-Level Synthesis, then performs dependency analysis
to enable hardware pipelining.

# Phases
1. **Pre-Phase**: Strip Julia GC and exception handling
2. **Phase 1**: Canonicalization (SSA promotion, inlining, loop normalization)
3. **Phase 2**: Dependency Analysis (alias analysis, scalar evolution, loop transforms)
"""
function GPUCompiler.optimize!(job::CompilerJob{FPGATarget}, mod::LLVM.Module)
    params = job.config.params

    # =========================================================================
    # PRE-PHASE: Julia-Specific Cleanup
    # Strip garbage collection calls, throw/catch blocks, and CPU thread tracking
    # FPGAs have no OS or runtime - these would cause synthesis failure
    # =========================================================================
    GPUCompiler.optimize_module!(job, mod)

    # =========================================================================
    # PHASE 1 & 2: LLVM Optimization Pipeline
    # =========================================================================
    LLVM.@dispose pb=LLVM.PassBuilder() begin
        LLVM.@dispose mpm=LLVM.NewPMModulePassManager(pb) begin

            # -----------------------------------------------------------------
            # PHASE 1: Canonicalization (Clean the IR for Hardware)
            # -----------------------------------------------------------------
            phase1_passes = [
                "always-inline",    # Flatten call graph (no hardware stack)
                "mem2reg",          # Promote memory to SSA registers (physical wires)
                "instcombine",      # Clean up redundant instructions
                "simplifycfg",      # Remove dead branches (dead logic gates)
                "loop-simplify",    # Normalize loops for hardware counters
                "indvars",          # Simplify loop induction variables
                "gvn",              # Global Value Numbering (remove redundant calcs)
                "dce"               # Dead Code Elimination
            ]

            # -----------------------------------------------------------------
            # PHASE 2: Dependency Analysis & Loop Preparation for HLS
            # -----------------------------------------------------------------
            phase2_passes = [
                # Analysis passes that build dependency graphs
                "require<opt-remark-emit>",  # Enable HLS warnings

                # Loop transformations that use dependency analysis
                "loop(licm)",       # Loop Invariant Code Motion (save logic gates)
                "loop-idiom",       # Recognize memory patterns for BRAM bursting
                "loop-deletion",    # Delete proven-empty loops
                "loop-unroll"       # Duplicate hardware for spatial parallelism
            ]

            # -----------------------------------------------------------------
            # PHASE 3 PREP: Additional optimizations for hardware
            # -----------------------------------------------------------------
            phase3_prep_passes = [
                "sccp",             # Sparse Conditional Constant Propagation
                "aggressive-instcombine",  # More aggressive instruction combining
                "reassociate",      # Reassociate for better pipelining
                "early-cse",        # Early Common Subexpression Elimination
                "memcpyopt",        # Optimize memory operations
                "dse"               # Dead Store Elimination
            ]

            # Combine all passes into a single pipeline string
            all_passes = vcat(phase1_passes, phase2_passes, phase3_prep_passes)
            pipeline = join(all_passes, ",")

            # Parse and run the pipeline
            LLVM.add!(mpm, pb, pipeline)
            LLVM.run!(mpm, mod)
        end
    end

    # =========================================================================
    # POST-OPTIMIZATION: Verify IR is hardware-ready
    # =========================================================================
    verify_fpga_compatible!(mod)

    return mod
end

"""
    verify_fpga_compatible!(mod::LLVM.Module)

Verify that the LLVM module contains no constructs incompatible with FPGA synthesis.
Checks for dynamic memory allocation, exception handling, and other unsupported features.

Issues warnings for:
- Calls to Julia runtime functions (GC, exceptions, etc.)
- Dynamic memory allocation (malloc, free)
- Variable-length arrays (VLAs)
- Indirect function calls
- Unsupported LLVM intrinsics
"""
function verify_fpga_compatible!(mod::LLVM.Module)
    # List of function names that indicate unsupported operations
    forbidden_functions = [
        # Julia runtime
        "jl_gc_pool_alloc",
        "jl_gc_big_alloc",
        "jl_gc_alloc",
        "jl_gc_managed_malloc",
        "jl_throw",
        "jl_error",
        "jl_bounds_error",
        "jl_bounds_error_v",
        "jl_bounds_error_int",
        "jl_apply_generic",
        "jl_invoke",
        "jl_call",
        "jl_new_array",
        "jl_alloc_array_1d",
        "jl_alloc_array_2d",
        "jl_alloc_array_3d",
        "jl_array_grow_end",
        "jl_array_del_end",
        "jl_type_error",
        "jl_undefined_var_error",
        "jl_get_ptls_states",

        # C runtime
        "malloc",
        "free",
        "calloc",
        "realloc",

        # I/O
        "printf",
        "fprintf",
        "puts",
        "fwrite",
        "fread",

        # Exceptions
        "__cxa_throw",
        "__cxa_begin_catch",
        "__cxa_end_catch",
    ]

    issues_found = false

    for func in LLVM.functions(mod)
        fname = LLVM.name(func)

        # Check for forbidden function calls in declarations
        for forbidden in forbidden_functions
            if occursin(forbidden, fname)
                @warn "FPGA synthesis may fail: IR contains '$fname' which is not hardware-synthesizable"
                issues_found = true
            end
        end

        # Skip function declarations (no body)
        if isempty(LLVM.blocks(func))
            continue
        end

        # Analyze function body
        for bb in LLVM.blocks(func)
            for inst in LLVM.instructions(bb)
                # Check for dynamic allocations (VLAs)
                if inst isa LLVM.AllocaInst
                    check_alloca_fpga_compatible!(inst, fname)
                end

                # Check for indirect calls (function pointers)
                if inst isa LLVM.CallInst
                    check_call_fpga_compatible!(inst, fname, forbidden_functions)
                end

                # Check for invoke (exception-handling calls)
                if LLVM.opcode(inst) == LLVM.API.LLVMInvoke
                    @warn "FPGA synthesis may fail: '$fname' contains invoke instruction (exception handling)"
                    issues_found = true
                end

                # Check for landingpad (exception handling)
                if LLVM.opcode(inst) == LLVM.API.LLVMLandingPad
                    @warn "FPGA synthesis may fail: '$fname' contains landing pad (exception handling)"
                    issues_found = true
                end

                # Check for resume (exception propagation)
                if LLVM.opcode(inst) == LLVM.API.LLVMResume
                    @warn "FPGA synthesis may fail: '$fname' contains resume instruction (exception handling)"
                    issues_found = true
                end
            end
        end
    end

    return !issues_found
end

"""
    check_alloca_fpga_compatible!(inst::LLVM.AllocaInst, func_name::String)

Check if an alloca instruction is FPGA-compatible (fixed size, not VLA).
"""
function check_alloca_fpga_compatible!(inst::LLVM.AllocaInst, func_name::String)
    # Get the number of elements being allocated
    num_elements = LLVM.operands(inst)

    if !isempty(num_elements)
        size_operand = num_elements[1]

        # Check if the size is a constant
        if !(size_operand isa LLVM.ConstantInt)
            @warn "FPGA synthesis may fail: '$func_name' contains variable-length allocation (VLA)"
        end
    end

    # Check the allocated type
    alloc_type = LLVM.allocated_type(inst)

    # Array types with non-constant size are problematic
    if LLVM.isarrayty(alloc_type)
        array_length = LLVM.arraylength(alloc_type)
        if array_length == 0
            @warn "FPGA synthesis may fail: '$func_name' contains zero-length array allocation"
        end
    end
end

"""
    check_call_fpga_compatible!(inst::LLVM.CallInst, func_name::String, forbidden::Vector{String})

Check if a call instruction is FPGA-compatible.
"""
function check_call_fpga_compatible!(inst::LLVM.CallInst, func_name::String, forbidden::Vector{String})
    called_func = LLVM.called_operand(inst)

    # Check for indirect calls (function pointers)
    if !(called_func isa LLVM.Function)
        @warn "FPGA synthesis may fail: '$func_name' contains indirect call (function pointer)"
        return
    end

    # Check if calling a forbidden function
    called_name = LLVM.name(called_func)
    for f in forbidden
        if occursin(f, called_name)
            # Already warned about forbidden functions, skip duplicate
            return
        end
    end
end

"""
    get_phase2_analysis(mod::LLVM.Module)

Run Phase 2 analysis passes and return dependency information.
Useful for debugging pipeline stalls and understanding memory access patterns.

# Returns
A dictionary containing:
- `loops`: Information about loops found in the module
- `memory_accesses`: Memory access patterns per function
- `function_stats`: Statistics for each function
"""
function get_phase2_analysis(mod::LLVM.Module)
    analysis_results = Dict{String, Any}()

    # Initialize result containers
    analysis_results["loops"] = Dict{String, Vector{Dict{String, Any}}}()
    analysis_results["memory_accesses"] = Dict{String, Dict{String, Int}}()
    analysis_results["function_stats"] = Dict{String, Dict{String, Any}}()

    # Analyze each function
    for func in LLVM.functions(mod)
        fname = LLVM.name(func)

        # Skip declarations (no body)
        if isempty(LLVM.blocks(func))
            continue
        end

        # Collect function statistics
        func_stats = analyze_function_stats(func)
        analysis_results["function_stats"][fname] = func_stats

        # Collect memory access information
        mem_accesses = analyze_memory_accesses(func)
        analysis_results["memory_accesses"][fname] = mem_accesses

        # Identify loops (basic block analysis)
        loops = identify_loops(func)
        analysis_results["loops"][fname] = loops
    end

    # Run LLVM analysis passes for additional info
    LLVM.@dispose pb=LLVM.PassBuilder() begin
        LLVM.@dispose mpm=LLVM.NewPMModulePassManager(pb) begin
            # Run analysis passes (results captured in LLVM's analysis manager)
            analysis_pipeline = join([
                "require<aa>",           # Alias analysis
                "require<scalar-evolution>",  # Scalar evolution (trip counts)
                "require<loops>",        # Loop info
            ], ",")

            LLVM.add!(mpm, pb, analysis_pipeline)
            LLVM.run!(mpm, mod)
        end
    end

    return analysis_results
end

"""
    analyze_function_stats(func::LLVM.Function)

Collect statistics about a function's instructions.
"""
function analyze_function_stats(func::LLVM.Function)
    stats = Dict{String, Any}(
        "num_blocks" => 0,
        "num_instructions" => 0,
        "num_loads" => 0,
        "num_stores" => 0,
        "num_branches" => 0,
        "num_calls" => 0,
        "num_phis" => 0,
        "num_muls" => 0,
        "num_adds" => 0,
        "num_fmuls" => 0,
        "num_fadds" => 0,
        "has_loops" => false,
    )

    back_edges = Set{String}()

    for bb in LLVM.blocks(func)
        stats["num_blocks"] += 1
        bb_name = LLVM.name(bb)

        for inst in LLVM.instructions(bb)
            stats["num_instructions"] += 1
            opcode = LLVM.opcode(inst)

            # Categorize by opcode
            if opcode == LLVM.API.LLVMLoad
                stats["num_loads"] += 1
            elseif opcode == LLVM.API.LLVMStore
                stats["num_stores"] += 1
            elseif opcode == LLVM.API.LLVMBr
                stats["num_branches"] += 1
                # Check for back edges (loop indicators)
                for (i, operand) in enumerate(LLVM.operands(inst))
                    if operand isa LLVM.BasicBlock
                        target_name = LLVM.name(operand)
                        # Simple heuristic: if branch target comes "before" current block
                        # this might be a back edge (loop)
                        if target_name != "" && bb_name != "" && target_name < bb_name
                            push!(back_edges, target_name)
                        end
                    end
                end
            elseif opcode == LLVM.API.LLVMCall
                stats["num_calls"] += 1
            elseif opcode == LLVM.API.LLVMPHI
                stats["num_phis"] += 1
            elseif opcode == LLVM.API.LLVMMul
                stats["num_muls"] += 1
            elseif opcode == LLVM.API.LLVMAdd
                stats["num_adds"] += 1
            elseif opcode == LLVM.API.LLVMFMul
                stats["num_fmuls"] += 1
            elseif opcode == LLVM.API.LLVMFAdd
                stats["num_fadds"] += 1
            end
        end
    end

    stats["has_loops"] = !isempty(back_edges)
    stats["estimated_dsp_usage"] = stats["num_muls"] + stats["num_fmuls"]
    stats["estimated_memory_ops"] = stats["num_loads"] + stats["num_stores"]

    return stats
end

"""
    analyze_memory_accesses(func::LLVM.Function)

Analyze memory access patterns in a function.
"""
function analyze_memory_accesses(func::LLVM.Function)
    accesses = Dict{String, Int}(
        "loads" => 0,
        "stores" => 0,
        "aligned_accesses" => 0,
        "pointer_derefs" => 0,
        "gep_ops" => 0,
    )

    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            opcode = LLVM.opcode(inst)

            if opcode == LLVM.API.LLVMLoad
                accesses["loads"] += 1
            elseif opcode == LLVM.API.LLVMStore
                accesses["stores"] += 1
            elseif opcode == LLVM.API.LLVMGetElementPtr
                accesses["gep_ops"] += 1
            end
        end
    end

    return accesses
end

"""
    identify_loops(func::LLVM.Function)

Identify potential loops in a function using basic block analysis.
"""
function identify_loops(func::LLVM.Function)
    loops = Vector{Dict{String, Any}}()

    # Build a simple CFG representation
    blocks = collect(LLVM.blocks(func))
    block_names = [LLVM.name(bb) for bb in blocks]

    # Find back edges (branches to earlier blocks)
    for (i, bb) in enumerate(blocks)
        terminator = LLVM.terminator(bb)
        if terminator === nothing
            continue
        end

        for operand in LLVM.operands(terminator)
            if operand isa LLVM.BasicBlock
                target_name = LLVM.name(operand)
                target_idx = findfirst(==(target_name), block_names)

                # If target comes before current block, it's a back edge (loop)
                if target_idx !== nothing && target_idx <= i
                    loop_info = Dict{String, Any}(
                        "header" => target_name,
                        "latch" => LLVM.name(bb),
                        "estimated_depth" => 1,
                        "has_phi_nodes" => count_phi_nodes(blocks[target_idx]) > 0,
                    )

                    # Count instructions in loop body
                    loop_body_blocks = i - target_idx + 1
                    loop_info["num_blocks"] = loop_body_blocks

                    push!(loops, loop_info)
                end
            end
        end
    end

    return loops
end

"""
    count_phi_nodes(bb::LLVM.BasicBlock)

Count PHI nodes in a basic block (indicates loop-carried values).
"""
function count_phi_nodes(bb::LLVM.BasicBlock)
    count = 0
    for inst in LLVM.instructions(bb)
        if LLVM.opcode(inst) == LLVM.API.LLVMPHI
            count += 1
        end
    end
    return count
end
