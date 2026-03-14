# Data Flow Graph Extraction
# Extracts DFG nodes from LLVM instructions

"""
    extract_dfg(llvm_func::LLVM.Function, states::Vector{FSMState})

Extract Data Flow Graph from an LLVM function.
Each instruction becomes a DFG node with edges representing data dependencies.

Returns a tuple of (nodes, edges, value_to_node mapping).
"""
function extract_dfg(llvm_func::LLVM.Function, states::Vector{FSMState})
    nodes = DFGNode[]
    edges = DFGEdge[]
    value_to_node = Dict{LLVM.Value, DFGNode}()
    block_to_state = Dict{String, FSMState}()

    # Map block names to states
    for state in states
        block_to_state[state.name] = state
    end

    node_id = 0

    # Process each basic block
    for block in LLVM.blocks(llvm_func)
        block_name = LLVM.name(block)
        if isempty(block_name)
            # Find state by ID match
            for (i, b) in enumerate(LLVM.blocks(llvm_func))
                if b == block
                    block_name = "bb_$i"
                    break
                end
            end
        end

        state = get(block_to_state, block_name, nothing)
        state_id = state !== nothing ? state.id : 0

        # Process each instruction
        for inst in LLVM.instructions(block)
            op_type = classify_llvm_opcode(LLVM.opcode(inst))

            # Skip terminators for DFG (they're handled by CFG)
            # But keep the comparison that feeds into a branch
            if op_type in (OP_BR, OP_RET)
                continue
            end

            node_id += 1
            node = DFGNode(node_id, op_type, get_instruction_name(inst, node_id))

            # Extract type information
            node.result_type, node.bit_width, node.is_signed = extract_type_info(inst)

            # Set latency
            node.latency = get_default_latency(op_type)

            # Set state membership
            node.state_id = state_id

            # Process operands and create edges
            process_operands!(node, inst, value_to_node, edges)

            push!(nodes, node)
            value_to_node[inst] = node

            # Add to state's operations
            if state !== nothing
                push!(state.operations, node)
            end
        end
    end

    # Handle function arguments as input nodes
    input_nodes = extract_function_arguments(llvm_func, value_to_node)
    prepend!(nodes, input_nodes)

    # Re-number nodes after prepending
    for (i, node) in enumerate(nodes)
        node.id = i
    end

    return nodes, edges, value_to_node
end

"""
    classify_llvm_opcode(opcode)

Map LLVM opcode to HLS operation type.
"""
function classify_llvm_opcode(opcode::LLVM.API.LLVMOpcode)::OperationType
    opcode_map = Dict{LLVM.API.LLVMOpcode, OperationType}(
        LLVM.API.LLVMAdd => OP_ADD,
        LLVM.API.LLVMFAdd => OP_FADD,
        LLVM.API.LLVMSub => OP_SUB,
        LLVM.API.LLVMFSub => OP_FSUB,
        LLVM.API.LLVMMul => OP_MUL,
        LLVM.API.LLVMFMul => OP_FMUL,
        LLVM.API.LLVMUDiv => OP_DIV,
        LLVM.API.LLVMSDiv => OP_DIV,
        LLVM.API.LLVMFDiv => OP_FDIV,
        LLVM.API.LLVMURem => OP_MOD,
        LLVM.API.LLVMSRem => OP_MOD,
        LLVM.API.LLVMFRem => OP_MOD,
        LLVM.API.LLVMAnd => OP_AND,
        LLVM.API.LLVMOr => OP_OR,
        LLVM.API.LLVMXor => OP_XOR,
        LLVM.API.LLVMShl => OP_SHL,
        LLVM.API.LLVMLShr => OP_SHR,
        LLVM.API.LLVMAShr => OP_ASHR,
        LLVM.API.LLVMLoad => OP_LOAD,
        LLVM.API.LLVMStore => OP_STORE,
        LLVM.API.LLVMGetElementPtr => OP_GEP,
        LLVM.API.LLVMAlloca => OP_ALLOCA,
        LLVM.API.LLVMICmp => OP_ICMP,
        LLVM.API.LLVMFCmp => OP_FCMP,
        LLVM.API.LLVMPHI => OP_PHI,
        LLVM.API.LLVMSelect => OP_SELECT,
        LLVM.API.LLVMCall => OP_CALL,
        LLVM.API.LLVMBr => OP_BR,
        LLVM.API.LLVMRet => OP_RET,
        LLVM.API.LLVMZExt => OP_ZEXT,
        LLVM.API.LLVMSExt => OP_SEXT,
        LLVM.API.LLVMTrunc => OP_TRUNC,
        LLVM.API.LLVMBitCast => OP_BITCAST,
        LLVM.API.LLVMPtrToInt => OP_BITCAST,
        LLVM.API.LLVMIntToPtr => OP_BITCAST,
        LLVM.API.LLVMFPToUI => OP_TRUNC,
        LLVM.API.LLVMFPToSI => OP_TRUNC,
        LLVM.API.LLVMUIToFP => OP_ZEXT,
        LLVM.API.LLVMSIToFP => OP_SEXT,
        LLVM.API.LLVMFPTrunc => OP_TRUNC,
        LLVM.API.LLVMFPExt => OP_ZEXT,
    )
    return get(opcode_map, opcode, OP_NOP)
end

"""
    get_instruction_name(inst, node_id)

Generate a name for the DFG node from the LLVM instruction.
"""
function get_instruction_name(inst::LLVM.Instruction, node_id::Int)::String
    name = LLVM.name(inst)
    if isempty(name)
        opcode = LLVM.opcode(inst)
        op_name = string(classify_llvm_opcode(opcode))
        return "$(op_name)_$node_id"
    end
    return name
end

"""
    extract_type_info(inst)

Extract Julia type, bit width, and signedness from LLVM instruction.
"""
function extract_type_info(inst::LLVM.Instruction)
    llvm_type = LLVM.value_type(inst)

    # Default values
    julia_type = Any
    bit_width = 32
    is_signed = true

    if LLVM.isintegertype(llvm_type)
        bit_width = LLVM.width(llvm_type)
        # Assume signed for now; could be determined by opcode context
        is_signed = true
        julia_type = bit_width <= 8 ? Int8 :
                     bit_width <= 16 ? Int16 :
                     bit_width <= 32 ? Int32 : Int64

    elseif LLVM.isfloatingpointtype(llvm_type)
        is_signed = true
        if LLVM.ishalftype(llvm_type)
            bit_width = 16
            julia_type = Float16
        elseif LLVM.isfloattype(llvm_type)
            bit_width = 32
            julia_type = Float32
        elseif LLVM.isdoubletype(llvm_type)
            bit_width = 64
            julia_type = Float64
        end

    elseif LLVM.ispointertype(llvm_type)
        bit_width = 64  # Assume 64-bit pointers
        julia_type = Ptr{Any}

    elseif LLVM.isvectortype(llvm_type)
        # Vector type
        elem_type = LLVM.element_type(llvm_type)
        elem_width = LLVM.isintegertype(elem_type) ? LLVM.width(elem_type) : 32
        num_elems = LLVM.vector_length(llvm_type)
        bit_width = elem_width * num_elems

    elseif LLVM.isarraytype(llvm_type)
        # Array type - not directly synthesizable as a value
        bit_width = 0
        julia_type = Array
    end

    return julia_type, bit_width, is_signed
end

"""
    process_operands!(node, inst, value_to_node, edges)

Process operands of an instruction, creating DFG edges.
"""
function process_operands!(node::DFGNode,
                          inst::LLVM.Instruction,
                          value_to_node::Dict{LLVM.Value, DFGNode},
                          edges::Vector{DFGEdge})

    for (i, operand) in enumerate(LLVM.operands(inst))
        # Skip block operands (for branches)
        if operand isa LLVM.BasicBlock
            continue
        end

        push!(node.operand_indices, i)

        if haskey(value_to_node, operand)
            # Reference to another DFG node
            src_node = value_to_node[operand]
            push!(node.operands, src_node)

            # Create edge
            edge = DFGEdge(src_node, node, i)
            push!(edges, edge)

        elseif operand isa LLVM.ConstantInt
            # Integer constant
            const_val = extract_constant_int(operand)
            push!(node.operands, const_val)

        elseif operand isa LLVM.ConstantFP
            # Floating-point constant
            const_val = extract_constant_fp(operand)
            push!(node.operands, const_val)

        elseif operand isa LLVM.Constant
            # Other constant (including undef, null, etc.)
            const_val = HLSConstant(0, 32, false)
            push!(node.operands, const_val)

        elseif operand isa LLVM.Argument
            # Function argument - should be in value_to_node after arg processing
            if haskey(value_to_node, operand)
                src_node = value_to_node[operand]
                push!(node.operands, src_node)
                edge = DFGEdge(src_node, node, i)
                push!(edges, edge)
            end
        end
    end
end

"""
    extract_constant_int(const_val)

Extract an HLSConstant from an LLVM ConstantInt.
"""
function extract_constant_int(const_val::LLVM.ConstantInt)::HLSConstant
    llvm_type = LLVM.value_type(const_val)
    bit_width = LLVM.width(llvm_type)
    value = LLVM.convert(Int, const_val)
    return HLSConstant(value, bit_width, true)
end

"""
    extract_constant_fp(const_val)

Extract an HLSConstant from an LLVM ConstantFP.
"""
function extract_constant_fp(const_val::LLVM.ConstantFP)::HLSConstant
    llvm_type = LLVM.value_type(const_val)
    bit_width = LLVM.isfloattype(llvm_type) ? 32 : 64
    value = LLVM.convert(Float64, const_val)
    return HLSConstant(value, bit_width, true)
end

"""
    extract_function_arguments(llvm_func, value_to_node)

Create DFG nodes for function arguments (inputs).
"""
function extract_function_arguments(llvm_func::LLVM.Function,
                                    value_to_node::Dict{LLVM.Value, DFGNode})::Vector{DFGNode}
    input_nodes = DFGNode[]

    for (i, arg) in enumerate(LLVM.parameters(llvm_func))
        node = DFGNode(i, OP_NOP, "arg_$i")

        # Extract type information
        arg_type = LLVM.value_type(arg)
        if LLVM.isintegertype(arg_type)
            node.bit_width = LLVM.width(arg_type)
            node.is_signed = true
        elseif LLVM.isfloatingpointtype(arg_type)
            node.bit_width = LLVM.isfloattype(arg_type) ? 32 : 64
            node.is_signed = true
        elseif LLVM.ispointertype(arg_type)
            node.bit_width = 64
            node.is_signed = false
        end

        # Input nodes have 0 latency and are scheduled at cycle 0
        node.latency = 0
        node.scheduled_cycle = 0
        node.state_id = 1  # Entry state

        push!(input_nodes, node)
        value_to_node[arg] = node
    end

    return input_nodes
end

"""
    find_output_nodes(nodes, llvm_func)

Find DFG nodes that produce output values (return values or stores).
"""
function find_output_nodes(nodes::Vector{DFGNode})::Vector{DFGNode}
    output_nodes = DFGNode[]

    for node in nodes
        # Store operations write to memory (outputs)
        if node.op == OP_STORE
            push!(output_nodes, node)
        end
    end

    return output_nodes
end

"""
    find_memory_nodes(nodes)

Find all memory access nodes (loads and stores).
"""
function find_memory_nodes(nodes::Vector{DFGNode})::Vector{DFGNode}
    return [n for n in nodes if n.op in (OP_LOAD, OP_STORE)]
end

"""
    dfg_to_graph(nodes, edges)

Convert DFG to a Graphs.jl DiGraph for analysis.
"""
function dfg_to_graph(nodes::Vector{DFGNode}, edges::Vector{DFGEdge})::SimpleDiGraph{Int}
    n = length(nodes)
    g = SimpleDiGraph{Int}(n)

    # Create a mapping from node to index
    node_to_idx = Dict{DFGNode, Int}()
    for (i, node) in enumerate(nodes)
        node_to_idx[node] = i
    end

    for edge in edges
        src_idx = get(node_to_idx, edge.src, 0)
        dst_idx = get(node_to_idx, edge.dst, 0)
        if src_idx > 0 && dst_idx > 0
            add_edge!(g, src_idx, dst_idx)
        end
    end

    return g
end

"""
    topological_sort_dfg(nodes, edges)

Perform topological sort on DFG nodes.
"""
function topological_sort_dfg(nodes::Vector{DFGNode}, edges::Vector{DFGEdge})::Vector{DFGNode}
    g = dfg_to_graph(nodes, edges)
    sorted_indices = topological_sort_by_dfs(g)
    return [nodes[i] for i in sorted_indices]
end

"""
    print_dfg(nodes, edges)

Print the DFG for debugging.
"""
function print_dfg(nodes::Vector{DFGNode}, edges::Vector{DFGEdge})
    println("Data Flow Graph:")
    println("=" ^ 50)

    for node in nodes
        op_str = string(node.op)
        type_str = "$(node.bit_width)-bit"
        println("Node $(node.id): $(node.name) [$op_str] ($type_str, lat=$(node.latency))")

        if !isempty(node.operands)
            for (i, op) in enumerate(node.operands)
                if op isa DFGNode
                    println("  Input $i: Node $(op.id) ($(op.name))")
                elseif op isa HLSConstant
                    println("  Input $i: Const $(op.value)")
                end
            end
        end
    end

    println("\nEdges:")
    for edge in edges
        println("  $(edge.src.name) -> $(edge.dst.name) [operand $(edge.operand_index)]")
    end
end
