/**
 *
 * 【2026-10-02 框架：目标机制与缺口】
 * - 入队宽度为 rename 宽度（B42 为 4），出队宽度为 dispatch 宽度（待定）。
 * - 下文“当前只由旧整数Dispatch消费”已过时：现由 dispatch_stage 分流到三类 IQ。
 * Rename to Dispatch Queue
 *
 * 按单条renamed uop连续保存，解耦Rename资源分配和后续Dispatch/IQ背压。
 * 正确解析分支时清除对应branch bit；误预测时压缩删除所有依赖该分支的年轻uop。
 * dispatch_stage 按最老前缀向 INT/MEM/BR IQ 分流。
 * 周期N组合阶段展示最老前缀并形成压缩后的next状态；上升沿原子读写或恢复；
 * 周期N+1对外看到更新后的连续队列。
 */
// 当前实现状态：闭环简化（L3）；正确解析不停顿，四宽合同。测试：sim/cocotb/rename_dispatch_queue/。
module rename_dispatch_queue
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int ENQ_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int DEQ_WIDTH = CFG.dispatch.width,
    localparam int DEPTH = CFG.rename.rdq_depth
) (
    input logic clk,
    input logic rst,
    input renamed_uop_t [ENQ_WIDTH-1:0] enq_uop_i,
    input logic [$clog2(ENQ_WIDTH+1)-1:0] enq_count_i,
    input logic enq_fire_i,
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,
    output renamed_uop_t [DEQ_WIDTH-1:0] deq_uop_o,
    output logic [$clog2(DEQ_WIDTH+1)-1:0] deq_count_o,
    input logic [$clog2(DEQ_WIDTH+1)-1:0] deq_accept_count_i,
    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i
);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int DEQ_COUNT_WIDTH = $clog2(DEQ_WIDTH + 1);
    localparam int INDEX_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    typedef logic [INDEX_WIDTH-1:0] index_t;
    // Payload stays in its allocated slot. Only these narrow indices move
    // when consuming or selectively deleting instructions.
    renamed_uop_t payload_q [DEPTH];
    branch_mask_t mask_q [DEPTH];
    logic payload_valid_q [DEPTH];
    index_t order_q [DEPTH], order_next [DEPTH];
    logic [DEPTH-1:0] used_q, used_next;
    index_t alloc_index [ENQ_WIDTH];
    logic [ENQ_WIDTH-1:0] append;
    logic [COUNT_WIDTH-1:0] count_q, count_next;
    logic [DEPTH-1:0] keep;
    logic [COUNT_WIDTH-1:0] survivor_rank [DEPTH];
    logic [COUNT_WIDTH-1:0] survivor_count;
    localparam int UOP_BITS = $bits(renamed_uop_t);

    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q;
    assign deq_count_o = (count_q >= COUNT_WIDTH'(DEQ_WIDTH))
                       ? DEQ_COUNT_WIDTH'(DEQ_WIDTH)
                       : DEQ_COUNT_WIDTH'(count_q);

    always_comb begin
        deq_uop_o = '{default: '0};
        for (int lane = 0; lane < DEQ_WIDTH; lane++) begin
            if (lane < int'(deq_count_o)) begin
                deq_uop_o[lane] = payload_q[order_q[lane]];
                deq_uop_o[lane].branch_mask = mask_q[order_q[lane]];
            end
        end
    end

    always_comb begin
        survivor_count = '0;
        keep = '0;
        for (int src = 0; src < DEPTH; src++) begin
            survivor_rank[src] = survivor_count;
            keep[src] = src < int'(count_q) && payload_valid_q[order_q[src]] &&
                ((resolution_valid_i && resolution_mispredict_i)
                 ? !mask_q[order_q[src]][resolution_tag_i]
                 : src >= int'(deq_accept_count_i));
            survivor_count += COUNT_WIDTH'(keep[src]);
        end
        count_next = survivor_count;
        if (enq_fire_i && !(resolution_valid_i && resolution_mispredict_i))
            for (int lane = 0; lane < ENQ_WIDTH; lane++)
                if (lane < int'(enq_count_i)) count_next += COUNT_WIDTH'(1);
    end

    always_comb begin
        logic [DEPTH-1:0] available;
        available = ~used_q;
        append = '0;
        alloc_index = '{default:'0};
        for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
            logic found;
            found = 1'b0;
            append[lane] = enq_fire_i && !(resolution_valid_i && resolution_mispredict_i)
                && lane < int'(enq_count_i);
            for (int slot = 0; slot < DEPTH; slot++) begin
                if (append[lane] && available[slot] && !found) begin
                    found = 1'b1;
                    alloc_index[lane] = index_t'(slot);
                    available[slot] = 1'b0;
                end
            end
        end
    end

    always_comb begin
        order_next = '{default:'0};
        used_next = '0;
        for (int src = 0; src < DEPTH; src++)
            if (keep[src]) used_next[order_q[src]] = 1'b1;
        for (int lane = 0; lane < ENQ_WIDTH; lane++)
            if (append[lane]) used_next[alloc_index[lane]] = 1'b1;
        for (int dst = 0; dst < DEPTH; dst++) begin
            for (int src = 0; src < DEPTH; src++)
                order_next[dst] |= order_q[src] &
                    {INDEX_WIDTH{keep[src] && survivor_rank[src] == COUNT_WIDTH'(dst)}};
            for (int lane = 0; lane < ENQ_WIDTH; lane++)
                order_next[dst] |= alloc_index[lane] &
                    {INDEX_WIDTH{append[lane] && int'(survivor_count) + lane == dst}};
        end
    end

    for (genvar slot = 0; slot < DEPTH; slot++) begin : g_payload
        renamed_uop_t write_data;
        logic write_valid;
        always_comb begin
            write_data = '0;
            write_valid = 1'b0;
            for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                write_data |= renamed_uop_t'(UOP_BITS'(enq_uop_i[lane]) &
                    {UOP_BITS{append[lane] && alloc_index[lane] == index_t'(slot)}});
                write_valid |= append[lane] && alloc_index[lane] == index_t'(slot);
            end
        end
        always_ff @(posedge clk) begin
            if (!rst) begin
                if (resolution_valid_i) mask_q[slot][resolution_tag_i] <= 1'b0;
                if (write_valid) begin
                    payload_q[slot] <= write_data;
                    // Store the changing branch mask separately from payload.
                    payload_q[slot].branch_mask <= '0;
                    payload_valid_q[slot] <= write_data.valid;
                    mask_q[slot] <= resolution_valid_i
                        ? write_data.branch_mask & ~(branch_mask_t'(1) << resolution_tag_i)
                        : write_data.branch_mask;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            order_q <= '{default:'0};
            used_q <= '0;
            count_q <= '0;
        end else begin
            order_q <= order_next;
            used_q <= used_next;
            count_q <= count_next;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && (deq_accept_count_i > deq_count_o)) begin
            $fatal(1, "rename_dispatch_queue accepted more uops than visible");
        end
    end
`endif

    initial begin
        if ((ENQ_WIDTH <= 0) || (DEQ_WIDTH <= 0) || (DEPTH <= 0)) begin
            $error("rename_dispatch_queue parameters must be positive");
        end
        if ((ENQ_WIDTH > DEPTH) || (DEQ_WIDTH > DEPTH)) begin
            $error("rename_dispatch_queue port widths must not exceed DEPTH");
        end
    end
endmodule
