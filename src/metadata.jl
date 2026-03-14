# LLVM Metadata Injection for FPGA HLS
# Implements Phase 3: Hardware-Specific Transformations via Metadata

"""
    apply_pipeline_metadata!(loop_block::LLVM.BasicBlock, target_ii::Int)

Attach loop pipelining metadata to a loop's terminating branch instruction.
This tells the HLS tool to overlap loop iterations with the specified
Initiation Interval (II).

# Arguments
- `loop_block`: The LLVM BasicBlock containing the loop latch (back-edge)
- `target_ii`: Target Initiation Interval (1 = new iteration every clock cycle)

# Hardware Effect
The HLS tool's pipeline pass will insert shift registers and FIFOs to
overlap iterations, achieving II clock cycles between iteration starts.
"""
function apply_pipeline_metadata!(loop_block::LLVM.BasicBlock, target_ii::Int)
    ctx = LLVM.context(loop_block)

    # Create metadata nodes for pipeline configuration
    # Format follows vendor conventions (Intel/AMD HLS tools)
    md_pipeline = LLVM.MDString("llvm.loop.pipeline.enable"; ctx)
    md_ii_key = LLVM.MDString("llvm.loop.pipeline.initiationinterval"; ctx)
    md_ii_val = LLVM.ConstantInt(Int32(target_ii); ctx)

    # Build the metadata tuple
    md_enable = LLVM.MDNode([md_pipeline]; ctx)
    md_ii = LLVM.MDNode([md_ii_key, md_ii_val]; ctx)

    # Create the loop metadata node
    # Self-referential structure required by LLVM loop metadata
    loop_id = LLVM.MDNode(LLVM.Metadata[]; ctx)  # Placeholder
    loop_md = LLVM.MDNode([loop_id, md_enable, md_ii]; ctx)

    # Replace placeholder with actual reference
    LLVM.replace_operand!(loop_md, 1, loop_md)  # Self-reference

    # Attach to the loop's terminating instruction (branch back to header)
    terminator = LLVM.terminator(loop_block)
    if terminator !== nothing
        LLVM.metadata!(terminator, LLVM.MD_loop, loop_md)
    end

    return loop_md
end

"""
    apply_unroll_metadata!(loop_block::LLVM.BasicBlock, factor::Int; full::Bool=false)

Attach loop unrolling metadata to enable spatial parallelism.

# Arguments
- `loop_block`: The LLVM BasicBlock containing the loop
- `factor`: Unroll factor (number of iterations to duplicate)
- `full`: If true, fully unroll the loop (factor is ignored)

# Hardware Effect
Duplicates loop body hardware `factor` times, allowing parallel execution
of multiple iterations. Trades silicon area for throughput.
"""
function apply_unroll_metadata!(loop_block::LLVM.BasicBlock, factor::Int; full::Bool=false)
    ctx = LLVM.context(loop_block)

    if full
        md_unroll = LLVM.MDString("llvm.loop.unroll.full"; ctx)
        loop_md = LLVM.MDNode([LLVM.MDNode(LLVM.Metadata[]; ctx),
                               LLVM.MDNode([md_unroll]; ctx)]; ctx)
    else
        md_unroll = LLVM.MDString("llvm.loop.unroll.count"; ctx)
        md_count = LLVM.ConstantInt(Int32(factor); ctx)
        loop_md = LLVM.MDNode([LLVM.MDNode(LLVM.Metadata[]; ctx),
                               LLVM.MDNode([md_unroll, md_count]; ctx)]; ctx)
    end

    terminator = LLVM.terminator(loop_block)
    if terminator !== nothing
        LLVM.metadata!(terminator, LLVM.MD_loop, loop_md)
    end

    return loop_md
end

"""
    apply_partition_metadata!(alloca_inst::LLVM.AllocaInst, factor::Int, style::PartitionStyle)

Attach memory partitioning metadata to an array allocation.
Signals the HLS tool to split the array across multiple BRAM banks.

# Arguments
- `alloca_inst`: The LLVM AllocaInst for the array
- `factor`: Number of BRAM banks to partition across
- `style`: Partitioning strategy (CYCLIC, BLOCK, or COMPLETE)

# Hardware Effect
Instead of mapping to a single BRAM (2 ports), the array is split across
`factor` BRAMs, providing `factor * 2` read/write ports for parallel access.
"""
function apply_partition_metadata!(alloca_inst::LLVM.Instruction, factor::Int, style::PartitionStyle)
    ctx = LLVM.context(alloca_inst)

    # Create partition metadata (vendor-specific format)
    md_partition = LLVM.MDString("fpga.memory.partition"; ctx)
    md_style = LLVM.MDString(string(style); ctx)
    md_factor = LLVM.ConstantInt(Int32(factor); ctx)

    partition_md = LLVM.MDNode([md_partition, md_style, md_factor]; ctx)

    # Attach to the allocation instruction
    LLVM.metadata!(alloca_inst, "fpga.memory", partition_md)

    return partition_md
end

"""
    apply_interface_metadata!(func::LLVM.Function, arg_idx::Int, interface_type::Symbol)

Attach interface metadata to function arguments for HLS port generation.

# Arguments
- `func`: The LLVM Function
- `arg_idx`: Index of the argument (1-based)
- `interface_type`: Type of hardware interface (:axi_master, :axi_lite, :stream, :bram)

# Hardware Effect
Controls how the HLS tool generates physical I/O ports for the kernel.
"""
function apply_interface_metadata!(func::LLVM.Function, arg_idx::Int, interface_type::Symbol)
    ctx = LLVM.context(func)

    interface_map = Dict(
        :axi_master => "m_axi",      # Memory-mapped AXI master (DDR access)
        :axi_lite => "s_axilite",     # AXI-Lite slave (control registers)
        :stream => "axis",            # AXI Stream (FIFO interface)
        :bram => "bram"               # Direct BRAM interface
    )

    interface_str = get(interface_map, interface_type, "default")

    md_interface = LLVM.MDString("fpga.interface"; ctx)
    md_type = LLVM.MDString(interface_str; ctx)
    md_idx = LLVM.ConstantInt(Int32(arg_idx); ctx)

    interface_md = LLVM.MDNode([md_interface, md_idx, md_type]; ctx)

    # Attach to function metadata
    existing = LLVM.metadata(func, "fpga.interfaces")
    if existing === nothing
        LLVM.metadata!(func, "fpga.interfaces", interface_md)
    else
        # Append to existing interfaces (would need proper implementation)
        LLVM.metadata!(func, "fpga.interfaces", interface_md)
    end

    return interface_md
end

"""
    apply_noalias_metadata!(mod::LLVM.Module)

Add noalias attributes to kernel arguments to enable parallel memory access.
This tells LLVM that array arguments do not overlap in memory.
"""
function apply_noalias_metadata!(mod::LLVM.Module)
    for func in LLVM.functions(mod)
        # Skip declarations (no body)
        isempty(LLVM.blocks(func)) && continue

        # Add noalias to pointer arguments
        for (i, arg) in enumerate(LLVM.parameters(func))
            if LLVM.isptrty(LLVM.value_type(arg))
                # Add noalias attribute
                LLVM.add_attribute!(arg, LLVM.EnumAttribute("noalias", 0))
            end
        end
    end
end
