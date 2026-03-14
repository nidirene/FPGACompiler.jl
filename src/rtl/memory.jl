# Memory Interface Generation
# Generates Verilog memory interfaces for loads and stores

"""
    generate_memory_interface(cdfg::CDFG, rtl::RTLModule)

Generate memory interface logic for load/store operations.
"""
function generate_memory_interface(cdfg::CDFG, rtl::RTLModule)::String
    lines = String[]

    # Check if there are any memory operations
    if isempty(cdfg.memory_nodes)
        return ""
    end

    push!(lines, "    // =========================================================")
    push!(lines, "    // Memory Interface")
    push!(lines, "    // =========================================================")
    push!(lines, "")

    # Generate memory address logic
    addr_logic = generate_memory_address_logic(cdfg, rtl)
    if !isempty(addr_logic)
        append!(lines, addr_logic)
        push!(lines, "")
    end

    # Generate memory write data logic
    wdata_logic = generate_memory_write_logic(cdfg, rtl)
    if !isempty(wdata_logic)
        append!(lines, wdata_logic)
        push!(lines, "")
    end

    # Generate memory read capture logic
    rdata_logic = generate_memory_read_logic(cdfg, rtl)
    if !isempty(rdata_logic)
        append!(lines, rdata_logic)
        push!(lines, "")
    end

    # Generate memory enable signals
    enable_logic = generate_memory_enable_logic(cdfg, rtl)
    if !isempty(enable_logic)
        append!(lines, enable_logic)
    end

    return join(lines, "\n")
end

"""
    generate_memory_address_logic(cdfg::CDFG, rtl::RTLModule)

Generate memory address selection logic.
"""
function generate_memory_address_logic(cdfg::CDFG, rtl::RTLModule)::Vector{String}
    lines = String[]

    # Get all memory operations
    mem_ops = cdfg.memory_nodes

    if isempty(mem_ops)
        return lines
    end

    push!(lines, "    // Memory address multiplexing")
    push!(lines, "    always @(*) begin")
    push!(lines, "        mem_addr = 32'd0;")
    push!(lines, "        ")
    push!(lines, "        case (current_state)")

    # Group by state
    ops_by_state = Dict{Int, Vector{DFGNode}}()
    for node in mem_ops
        if !haskey(ops_by_state, node.state_id)
            ops_by_state[node.state_id] = DFGNode[]
        end
        push!(ops_by_state[node.state_id], node)
    end

    for (state_id, ops) in sort(collect(ops_by_state), by=x->x[1])
        state = cdfg.states[state_id]
        state_name = "S_$(uppercase(sanitize_name(state.name)))"

        push!(lines, "            $state_name: begin")

        # Handle multiple memory ops in same state (would need arbitration)
        for (i, op) in enumerate(ops)
            addr_operand = get_address_operand(op, cdfg)
            if i == 1
                push!(lines, "                mem_addr = $addr_operand;")
            else
                # Multiple memory ops in same state - use cycle count for sequencing
                push!(lines, "                // Additional mem op (would need sequencing): $addr_operand")
            end
        end

        push!(lines, "            end")
    end

    push!(lines, "            default: mem_addr = 32'd0;")
    push!(lines, "        endcase")
    push!(lines, "    end")

    return lines
end

"""
    generate_memory_write_logic(cdfg::CDFG, rtl::RTLModule)

Generate memory write data selection logic.
"""
function generate_memory_write_logic(cdfg::CDFG, rtl::RTLModule)::Vector{String}
    lines = String[]

    # Get store operations
    stores = [n for n in cdfg.memory_nodes if n.op == OP_STORE]

    if isempty(stores)
        return lines
    end

    push!(lines, "    // Memory write data multiplexing")
    push!(lines, "    always @(*) begin")
    push!(lines, "        mem_wdata = 32'd0;")
    push!(lines, "        ")
    push!(lines, "        case (current_state)")

    # Group by state
    stores_by_state = Dict{Int, Vector{DFGNode}}()
    for node in stores
        if !haskey(stores_by_state, node.state_id)
            stores_by_state[node.state_id] = DFGNode[]
        end
        push!(stores_by_state[node.state_id], node)
    end

    for (state_id, ops) in sort(collect(stores_by_state), by=x->x[1])
        state = cdfg.states[state_id]
        state_name = "S_$(uppercase(sanitize_name(state.name)))"

        push!(lines, "            $state_name: begin")

        for op in ops
            data_operand = get_data_operand(op, cdfg)
            push!(lines, "                mem_wdata = $data_operand;")
        end

        push!(lines, "            end")
    end

    push!(lines, "            default: mem_wdata = 32'd0;")
    push!(lines, "        endcase")
    push!(lines, "    end")

    return lines
end

"""
    generate_memory_read_logic(cdfg::CDFG, rtl::RTLModule)

Generate memory read data capture logic.
"""
function generate_memory_read_logic(cdfg::CDFG, rtl::RTLModule)::Vector{String}
    lines = String[]

    # Get load operations
    loads = [n for n in cdfg.memory_nodes if n.op == OP_LOAD]

    if isempty(loads)
        return lines
    end

    push!(lines, "    // Memory read data capture")
    push!(lines, "    always @(posedge clk) begin")
    push!(lines, "        if (rst) begin")

    # Reset load destination registers
    for load in loads
        signal_name = sanitize_name(load.name)
        push!(lines, "            $signal_name <= $(load.bit_width)'d0;")
    end

    push!(lines, "        end else begin")

    # Capture read data based on state
    loads_by_state = Dict{Int, Vector{DFGNode}}()
    for node in loads
        if !haskey(loads_by_state, node.state_id)
            loads_by_state[node.state_id] = DFGNode[]
        end
        push!(loads_by_state[node.state_id], node)
    end

    for (state_id, ops) in sort(collect(loads_by_state), by=x->x[1])
        state = cdfg.states[state_id]
        state_name = "S_$(uppercase(sanitize_name(state.name)))"

        # Memory has 1-cycle latency, capture on next cycle
        push!(lines, "            if (current_state == $state_name && cycle_count == 8'd$(ops[1].latency - 1)) begin")

        for load in ops
            signal_name = sanitize_name(load.name)
            if load.bit_width < 32
                push!(lines, "                $signal_name <= mem_rdata[$(load.bit_width-1):0];")
            else
                push!(lines, "                $signal_name <= mem_rdata;")
            end
        end

        push!(lines, "            end")
    end

    push!(lines, "        end")
    push!(lines, "    end")

    return lines
end

"""
    generate_memory_enable_logic(cdfg::CDFG, rtl::RTLModule)

Generate memory read/write enable signals.
"""
function generate_memory_enable_logic(cdfg::CDFG, rtl::RTLModule)::Vector{String}
    lines = String[]

    loads = [n for n in cdfg.memory_nodes if n.op == OP_LOAD]
    stores = [n for n in cdfg.memory_nodes if n.op == OP_STORE]

    push!(lines, "    // Memory enable signals")
    push!(lines, "    always @(*) begin")
    push!(lines, "        mem_re = 1'b0;")
    push!(lines, "        mem_we = 1'b0;")
    push!(lines, "        ")
    push!(lines, "        case (current_state)")

    # Collect all states with memory operations
    mem_states = Dict{Int, Tuple{Bool, Bool}}()  # state_id -> (has_load, has_store)

    for load in loads
        cur = get(mem_states, load.state_id, (false, false))
        mem_states[load.state_id] = (true, cur[2])
    end

    for store in stores
        cur = get(mem_states, store.state_id, (false, false))
        mem_states[store.state_id] = (cur[1], true)
    end

    for (state_id, (has_load, has_store)) in sort(collect(mem_states), by=x->x[1])
        state = cdfg.states[state_id]
        state_name = "S_$(uppercase(sanitize_name(state.name)))"

        push!(lines, "            $state_name: begin")
        if has_load
            push!(lines, "                mem_re = 1'b1;")
        end
        if has_store
            push!(lines, "                mem_we = 1'b1;")
        end
        push!(lines, "            end")
    end

    push!(lines, "            default: begin end")
    push!(lines, "        endcase")
    push!(lines, "    end")

    return lines
end

"""
    get_address_operand(node::DFGNode, cdfg::CDFG)

Get the address operand for a load/store operation.
"""
function get_address_operand(node::DFGNode, cdfg::CDFG)::String
    # For loads, address is typically the first operand
    # For stores, address is typically the second operand (after value)
    if node.op == OP_LOAD
        if !isempty(node.operands)
            return get_operand_wire(node.operands[1])
        end
    elseif node.op == OP_STORE
        if length(node.operands) >= 2
            return get_operand_wire(node.operands[2])
        elseif length(node.operands) >= 1
            return get_operand_wire(node.operands[1])
        end
    end

    return "32'd0"
end

"""
    get_data_operand(node::DFGNode, cdfg::CDFG)

Get the data operand for a store operation.
"""
function get_data_operand(node::DFGNode, cdfg::CDFG)::String
    # For stores, data is typically the first operand
    if !isempty(node.operands)
        return get_operand_wire(node.operands[1])
    end
    return "32'd0"
end

"""
    generate_bram_interface(name::String, addr_width::Int, data_width::Int,
                           num_read_ports::Int, num_write_ports::Int)

Generate BRAM interface module for a specific memory.
"""
function generate_bram_interface(name::String, addr_width::Int, data_width::Int,
                                 num_read_ports::Int, num_write_ports::Int)::String
    lines = String[]

    push!(lines, "// BRAM Interface: $name")
    push!(lines, "// Address width: $addr_width, Data width: $data_width")
    push!(lines, "// Read ports: $num_read_ports, Write ports: $num_write_ports")
    push!(lines, "")

    push!(lines, "module $(name)_bram (")
    push!(lines, "    input wire clk,")

    # Read ports
    for i in 1:num_read_ports
        push!(lines, "    input wire [$(addr_width-1):0] raddr_$i,")
        push!(lines, "    input wire ren_$i,")
        push!(lines, "    output reg [$(data_width-1):0] rdata_$i,")
    end

    # Write ports
    for i in 1:num_write_ports
        push!(lines, "    input wire [$(addr_width-1):0] waddr_$i,")
        push!(lines, "    input wire wen_$i,")
        if i < num_write_ports
            push!(lines, "    input wire [$(data_width-1):0] wdata_$i,")
        else
            push!(lines, "    input wire [$(data_width-1):0] wdata_$i")
        end
    end

    push!(lines, ");")
    push!(lines, "")

    # Memory array
    depth = 2^addr_width
    push!(lines, "    // Memory array")
    push!(lines, "    reg [$(data_width-1):0] mem [0:$(depth-1)];")
    push!(lines, "")

    # Read logic
    for i in 1:num_read_ports
        push!(lines, "    // Read port $i")
        push!(lines, "    always @(posedge clk) begin")
        push!(lines, "        if (ren_$i)")
        push!(lines, "            rdata_$i <= mem[raddr_$i];")
        push!(lines, "    end")
        push!(lines, "")
    end

    # Write logic
    for i in 1:num_write_ports
        push!(lines, "    // Write port $i")
        push!(lines, "    always @(posedge clk) begin")
        push!(lines, "        if (wen_$i)")
        push!(lines, "            mem[waddr_$i] <= wdata_$i;")
        push!(lines, "    end")
        push!(lines, "")
    end

    push!(lines, "endmodule")

    return join(lines, "\n")
end

"""
    generate_partitioned_memory(name::String, partition_type::Symbol, factor::Int,
                                addr_width::Int, data_width::Int)

Generate partitioned memory for increased bandwidth.
"""
function generate_partitioned_memory(name::String, partition_type::Symbol, factor::Int,
                                     addr_width::Int, data_width::Int)::String
    lines = String[]

    push!(lines, "// Partitioned Memory: $name")
    push!(lines, "// Partition type: $partition_type, Factor: $factor")
    push!(lines, "")

    push!(lines, "module $(name)_partitioned (")
    push!(lines, "    input wire clk,")
    push!(lines, "    input wire [$(addr_width-1):0] addr,")
    push!(lines, "    input wire [$(data_width-1):0] wdata,")
    push!(lines, "    input wire we,")
    push!(lines, "    input wire re,")
    push!(lines, "    output wire [$(data_width-1):0] rdata")
    push!(lines, ");")
    push!(lines, "")

    # Calculate partition parameters
    partition_bits = ceil(Int, log2(factor))
    bank_addr_width = addr_width - partition_bits

    push!(lines, "    // Partition selection")
    if partition_type == :cyclic
        push!(lines, "    wire [$(partition_bits-1):0] bank_sel = addr[$(partition_bits-1):0];")
        push!(lines, "    wire [$(bank_addr_width-1):0] bank_addr = addr[$(addr_width-1):$partition_bits];")
    else  # block
        push!(lines, "    wire [$(partition_bits-1):0] bank_sel = addr[$(addr_width-1):$(addr_width-partition_bits)];")
        push!(lines, "    wire [$(bank_addr_width-1):0] bank_addr = addr[$(bank_addr_width-1):0];")
    end
    push!(lines, "")

    # Generate banks
    push!(lines, "    // Memory banks")
    for i in 0:(factor-1)
        push!(lines, "    reg [$(data_width-1):0] bank_$(i) [0:$((2^bank_addr_width)-1)];")
    end
    push!(lines, "")

    # Bank enable signals
    push!(lines, "    // Bank enables")
    for i in 0:(factor-1)
        push!(lines, "    wire bank_$(i)_en = (bank_sel == $(partition_bits)'d$i);")
    end
    push!(lines, "")

    # Write logic
    push!(lines, "    // Write logic")
    push!(lines, "    always @(posedge clk) begin")
    push!(lines, "        if (we) begin")
    for i in 0:(factor-1)
        push!(lines, "            if (bank_$(i)_en) bank_$(i)[bank_addr] <= wdata;")
    end
    push!(lines, "        end")
    push!(lines, "    end")
    push!(lines, "")

    # Read logic
    push!(lines, "    // Read logic")
    push!(lines, "    reg [$(data_width-1):0] rdata_reg;")
    push!(lines, "    always @(posedge clk) begin")
    push!(lines, "        if (re) begin")
    push!(lines, "            case (bank_sel)")
    for i in 0:(factor-1)
        push!(lines, "                $(partition_bits)'d$i: rdata_reg <= bank_$(i)[bank_addr];")
    end
    push!(lines, "                default: rdata_reg <= 0;")
    push!(lines, "            endcase")
    push!(lines, "        end")
    push!(lines, "    end")
    push!(lines, "    assign rdata = rdata_reg;")
    push!(lines, "")

    push!(lines, "endmodule")

    return join(lines, "\n")
end

"""
    generate_fifo_interface(name::String, data_width::Int, depth::Int)

Generate FIFO interface for streaming data.
"""
function generate_fifo_interface(name::String, data_width::Int, depth::Int)::String
    lines = String[]
    addr_width = ceil(Int, log2(depth))

    push!(lines, "// FIFO Interface: $name")
    push!(lines, "// Data width: $data_width, Depth: $depth")
    push!(lines, "")

    push!(lines, "module $(name)_fifo (")
    push!(lines, "    input wire clk,")
    push!(lines, "    input wire rst,")
    push!(lines, "    input wire [$(data_width-1):0] din,")
    push!(lines, "    input wire wr_en,")
    push!(lines, "    input wire rd_en,")
    push!(lines, "    output reg [$(data_width-1):0] dout,")
    push!(lines, "    output wire full,")
    push!(lines, "    output wire empty")
    push!(lines, ");")
    push!(lines, "")

    push!(lines, "    // FIFO memory")
    push!(lines, "    reg [$(data_width-1):0] mem [0:$(depth-1)];")
    push!(lines, "    reg [$(addr_width):0] wr_ptr, rd_ptr;")
    push!(lines, "    reg [$(addr_width):0] count;")
    push!(lines, "")

    push!(lines, "    assign full = (count == $(depth));")
    push!(lines, "    assign empty = (count == 0);")
    push!(lines, "")

    push!(lines, "    always @(posedge clk or posedge rst) begin")
    push!(lines, "        if (rst) begin")
    push!(lines, "            wr_ptr <= 0;")
    push!(lines, "            rd_ptr <= 0;")
    push!(lines, "            count <= 0;")
    push!(lines, "        end else begin")
    push!(lines, "            if (wr_en && !full) begin")
    push!(lines, "                mem[wr_ptr[$(addr_width-1):0]] <= din;")
    push!(lines, "                wr_ptr <= wr_ptr + 1;")
    push!(lines, "            end")
    push!(lines, "            if (rd_en && !empty) begin")
    push!(lines, "                dout <= mem[rd_ptr[$(addr_width-1):0]];")
    push!(lines, "                rd_ptr <= rd_ptr + 1;")
    push!(lines, "            end")
    push!(lines, "            ")
    push!(lines, "            if (wr_en && !full && !(rd_en && !empty))")
    push!(lines, "                count <= count + 1;")
    push!(lines, "            else if (rd_en && !empty && !(wr_en && !full))")
    push!(lines, "                count <= count - 1;")
    push!(lines, "        end")
    push!(lines, "    end")
    push!(lines, "")

    push!(lines, "endmodule")

    return join(lines, "\n")
end
