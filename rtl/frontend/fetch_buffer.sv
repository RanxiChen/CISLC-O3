/**
 * Compact FIFO between F1 and the backend. Enqueue skips invalid lanes;
 * dequeue delivers up to CFG.fetch.deliver_width entries in program order.
 * D24 kill blocks both handshakes for the cycle and retains only entries at
 * or before the boundary (kill_self includes the boundary; all clears all).
 * Survivors keep every fetch_entry_t field and are compacted at the edge.
 * flush_i clears all entries. Capacity and widths come from CFG.
 * Tests: sim/cocotb/fetch_buffer/ and sim/cocotb/branch_recovery/.
 */
module fetch_buffer
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::frontend_cfg_t CFG,
    localparam int ENQ_WIDTH = CFG.fetch.f1_width,
    localparam int DEQ_WIDTH = CFG.fetch.deliver_width,
    localparam int DEPTH = CFG.fetch.ibuf_depth,
    localparam int ICACHE_REQ_FREE_THRESHOLD = CFG.fetch.ibuf_req_free_threshold  // 旧合同
) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic flush_i,

    input  fetch_entry_t       enq_entry_i [ENQ_WIDTH],
    input  logic [ENQ_WIDTH-1:0] enq_valid_i,
    output logic               enq_ready_o,

    output fetch_entry_t       deq_entry_o [DEQ_WIDTH],
    output logic               deq_valid_o,
    input  logic               deq_ready_i,

    output logic               icache_req_allowed_o,   // 旧合同，迁移后删除

    // D24: selectively retain entries at or before the redirect boundary.
    input  fe_kill_t           kill_i,
    input  ftq_id_t            ftq_head_i,
    output fe_perf_t           perf_o
);

    localparam int PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int DATA_WIDTH = $bits(fetch_entry_t);
    typedef logic [PTR_WIDTH-1:0] index_t;

    // Keep wide payload stationary. Selective recovery compacts only slot
    // indices, so arbitrary surviving holes still have exactly the old order.
    fetch_entry_t entries_q [DEPTH];
    ftq_id_t entry_id_q [DEPTH];
    fetch_slot_t entry_slot_q [DEPTH];
    index_t order_q [DEPTH], order_d [DEPTH];
    index_t alloc_idx [ENQ_WIDTH];
    logic [DEPTH-1:0] used_q, used_d, keep;
    logic [ENQ_WIDTH-1:0] append;
    logic [COUNT_WIDTH-1:0] rank [DEPTH], append_rank [ENQ_WIDTH];
    logic [COUNT_WIDTH-1:0] count_q, count_d, survivors, incoming;
    logic [COUNT_WIDTH-1:0] free_count, deq_count;
    logic deq_fire;
    logic [COUNT_WIDTH-1:0] free_rank[DEPTH];
    // Parallel prefix adders: logarithmic depth for both arbitrary survivor
    // compaction and the physical free-row rank used by all enqueue lanes.
    localparam int PREFIX_LEVELS=$clog2(DEPTH);
    for(genvar level=0;level<=PREFIX_LEVELS;level++) begin : g_prefix
        logic [COUNT_WIDTH-1:0] live[DEPTH],free[DEPTH];
        for(genvar slot=0;slot<DEPTH;slot++) begin : g_slot
            if(level==0) begin
                assign live[slot]=COUNT_WIDTH'(keep[slot]);
                assign free[slot]=COUNT_WIDTH'(!used_q[slot]);
            end else if(slot>=(1<<(level-1))) begin
                assign live[slot]=g_prefix[level-1].live[slot]+g_prefix[level-1].live[slot-(1<<(level-1))];
                assign free[slot]=g_prefix[level-1].free[slot]+g_prefix[level-1].free[slot-(1<<(level-1))];
            end else begin
                assign live[slot]=g_prefix[level-1].live[slot];
                assign free[slot]=g_prefix[level-1].free[slot];
            end
        end
    end
    assign survivors=g_prefix[PREFIX_LEVELS].live[DEPTH-1];
    for(genvar slot=0;slot<DEPTH;slot++) begin : g_rank
        if(slot==0) begin assign rank[slot]='0;assign free_rank[slot]='0;end
        else begin
            assign rank[slot]=g_prefix[PREFIX_LEVELS].live[slot-1];
            assign free_rank[slot]=g_prefix[PREFIX_LEVELS].free[slot-1];
        end
    end

    assign free_count = COUNT_WIDTH'(DEPTH) - count_q;
    assign enq_ready_o = !rst_i && !flush_i && !kill_i.valid
                         && free_count >= COUNT_WIDTH'(ENQ_WIDTH);
    assign icache_req_allowed_o = free_count >= COUNT_WIDTH'(ICACHE_REQ_FREE_THRESHOLD);
    assign deq_valid_o = !rst_i && !flush_i && !kill_i.valid && count_q != '0;
    assign perf_o = '0;
    assign deq_count = (count_q >= COUNT_WIDTH'(DEQ_WIDTH))
                     ? COUNT_WIDTH'(DEQ_WIDTH) : count_q;
    assign deq_fire = deq_valid_o && deq_ready_i;

    always_comb begin
        for (int lane = 0; lane < DEQ_WIDTH; lane++)
            deq_entry_o[lane] = COUNT_WIDTH'(lane) < deq_count
                ? entries_q[order_q[lane]] : fetch_entry_t'(0);
    end

    always_comb begin
        keep = '0;
        for (int src = 0; src < DEPTH; src++) begin
            keep[src] = src < int'(count_q) &&
                (kill_i.valid ? !fe_killed_by(kill_i, entry_id_q[order_q[src]],
                                                entry_slot_q[order_q[src]], ftq_head_i)
                              : !(deq_fire && src < int'(deq_count)));
        end
        incoming = '0;
        append = '0;
        alloc_idx = '{default:'0};
        append_rank = '{default:'0};
        for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
            append_rank[lane] = incoming;
            append[lane] = enq_ready_o && enq_valid_i[lane];
            incoming += COUNT_WIDTH'(enq_valid_i[lane]);
            // The kth valid lane selects the kth already-free physical row.
            // Allocation depends only on registered occupancy and lane rank;
            // late ready/kill control gates the write, not a priority chain.
            for (int slot = 0; slot < DEPTH; slot++) begin
                if (!used_q[slot] && free_rank[slot]==append_rank[lane])
                    alloc_idx[lane] |= index_t'(slot);
            end
        end
        if(!enq_ready_o) incoming='0;
        count_d = survivors + incoming;
    end

    always_comb begin
        order_d = '{default:'0};
        used_d = '0;
        for (int src = 0; src < DEPTH; src++)
            if (keep[src]) used_d[order_q[src]] = 1'b1;
        for (int lane = 0; lane < ENQ_WIDTH; lane++)
            if (append[lane]) used_d[alloc_idx[lane]] = 1'b1;
        for (int dst = 0; dst < DEPTH; dst++) begin
            for (int src = 0; src < DEPTH; src++)
                order_d[dst] |= order_q[src] &
                    {PTR_WIDTH{keep[src] && rank[src] == COUNT_WIDTH'(dst)}};
            for (int lane = 0; lane < ENQ_WIDTH; lane++)
                order_d[dst] |= alloc_idx[lane] &
                    {PTR_WIDTH{append[lane] && survivors + append_rank[lane] == COUNT_WIDTH'(dst)}};
        end
    end

    for (genvar slot = 0; slot < DEPTH; slot++) begin : g_payload
        fetch_entry_t write_data;
        logic write_valid;
        always_comb begin
            write_data = '0;
            write_valid = 1'b0;
            for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                write_data |= fetch_entry_t'(DATA_WIDTH'(enq_entry_i[lane]) &
                    {DATA_WIDTH{append[lane] && alloc_idx[lane] == index_t'(slot)}});
                write_valid |= append[lane] && alloc_idx[lane] == index_t'(slot);
            end
        end
        always_ff @(posedge clk_i) begin
            if (!rst_i && !flush_i && write_valid) begin
                entries_q[slot] <= write_data;
                entry_id_q[slot] <= write_data.ftq_id;
                entry_slot_q[slot] <= write_data.slot;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_i) begin
            order_q <= '{default:'0};
            used_q <= '0;
            count_q <= '0;
        end else begin
            order_q <= order_d;
            used_q <= used_d;
            count_q <= count_d;
        end
    end

    initial begin
        if (ENQ_WIDTH <= 0) begin
            $error("fetch_buffer requires ENQ_WIDTH > 0");
        end

        if (DEQ_WIDTH <= 0) begin
            $error("fetch_buffer requires DEQ_WIDTH > 0");
        end

        if (DEPTH <= 0) begin
            $error("fetch_buffer requires DEPTH > 0");
        end

        if (ICACHE_REQ_FREE_THRESHOLD < 0) begin
            $error("fetch_buffer requires ICACHE_REQ_FREE_THRESHOLD >= 0");
        end

        if (ICACHE_REQ_FREE_THRESHOLD > DEPTH) begin
            $error("fetch_buffer requires ICACHE_REQ_FREE_THRESHOLD <= DEPTH");
        end
    end

endmodule
