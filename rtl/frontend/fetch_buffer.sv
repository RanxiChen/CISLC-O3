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

    fetch_entry_t entries_q [DEPTH];
    logic [PTR_WIDTH-1:0]   head_q;
    logic [PTR_WIDTH-1:0]   tail_q;
    logic [COUNT_WIDTH-1:0] count_q;

    logic [COUNT_WIDTH-1:0] free_count;
    logic [COUNT_WIDTH-1:0] enq_count;
    logic [COUNT_WIDTH-1:0] deq_count;
    logic                   enq_fire;
    logic                   deq_fire;

    function automatic logic [PTR_WIDTH-1:0] ptr_add(
        input logic [PTR_WIDTH-1:0] ptr,
        input int unsigned          offset
    );
        int unsigned next_ptr;
        begin
            if (DEPTH == 1) begin
                ptr_add = '0;
            end else begin
                next_ptr = int'(ptr) + offset;
                ptr_add = PTR_WIDTH'(next_ptr % DEPTH);
            end
        end
    endfunction

    always_comb begin
        enq_count = '0;
        for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
            if (enq_valid_i[lane]) begin
                enq_count = enq_count + COUNT_WIDTH'(1);
            end
        end
    end

    assign free_count = COUNT_WIDTH'(DEPTH) - count_q;
    assign enq_ready_o = !rst_i && !flush_i && !kill_i.valid
                         && free_count >= COUNT_WIDTH'(ENQ_WIDTH);
    assign icache_req_allowed_o = free_count >= COUNT_WIDTH'(ICACHE_REQ_FREE_THRESHOLD);
    assign deq_valid_o = !rst_i && !flush_i && !kill_i.valid && count_q != '0;
    assign perf_o = '0;
    assign deq_count = (count_q >= COUNT_WIDTH'(DEQ_WIDTH))
                     ? COUNT_WIDTH'(DEQ_WIDTH)
                     : count_q;
    assign enq_fire = (enq_count != '0) && enq_ready_o;
    assign deq_fire = deq_valid_o && deq_ready_i;

    always_comb begin
        for (int lane = 0; lane < DEQ_WIDTH; lane++) begin
            if (COUNT_WIDTH'(lane) < deq_count) begin
                deq_entry_o[lane] = entries_q[ptr_add(head_q, lane)];
            end else begin
                deq_entry_o[lane] = '0;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_i) begin
            head_q  <= '0;
            tail_q  <= '0;
            count_q <= '0;
        end else if (kill_i.valid) begin
            int unsigned kept;
            kept = 0;
            // Compact survivors in program order; no enqueue/dequeue on kill.
            for (int offset = 0; offset < DEPTH; offset++) begin
                if (offset < int'(count_q)
                    && !fe_killed_by(kill_i, entries_q[ptr_add(head_q, offset)].ftq_id,
                                    entries_q[ptr_add(head_q, offset)].slot, ftq_head_i)) begin
                    entries_q[ptr_add(head_q, kept)] <= entries_q[ptr_add(head_q, offset)];
                    kept++;
                end
            end
            tail_q <= ptr_add(head_q, kept);
            count_q <= COUNT_WIDTH'(kept);
        end else begin
            if (enq_fire) begin
                int unsigned write_idx;
                write_idx = 0;
                for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                    if (enq_valid_i[lane]) begin
                        entries_q[ptr_add(tail_q, write_idx)] <= enq_entry_i[lane];
                        write_idx = write_idx + 1;
                    end
                end
                tail_q <= ptr_add(tail_q, int'(enq_count));
            end

            if (deq_fire) begin
                head_q <= ptr_add(head_q, int'(deq_count));
            end

            count_q <= count_q
                     + (enq_fire ? enq_count : '0)
                     - (deq_fire ? deq_count : '0);
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
