/**
 * Rename to Dispatch Queue
 *
 * 按单条renamed uop连续保存，解耦Rename资源分配和后续Dispatch/IQ背压。
 * 正确解析分支时清除对应branch bit；误预测时压缩删除所有依赖该分支的年轻uop。
 * 当前只由旧整数Dispatch消费全整数队头前缀，LSU/BRU Dispatch留到下一阶段。
 * 周期N组合阶段展示最老前缀并形成压缩后的next状态；上升沿原子读写或恢复；
 * 周期N+1对外看到更新后的连续队列。
 */
module rename_dispatch_queue
    import o3_pkg::*;
#(
    parameter int ENQ_WIDTH = BACKEND_MACHINE_WIDTH,
    parameter int DEQ_WIDTH = BACKEND_DISPATCH_WIDTH,
    parameter int DEPTH = BACKEND_RENAME_DISPATCH_QUEUE_DEPTH
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
    renamed_uop_t queue_q [DEPTH-1:0];
    renamed_uop_t queue_next [DEPTH-1:0];
    logic [COUNT_WIDTH-1:0] count_q, count_next;

    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q;
    assign deq_count_o = (count_q >= COUNT_WIDTH'(DEQ_WIDTH))
                       ? DEQ_COUNT_WIDTH'(DEQ_WIDTH)
                       : DEQ_COUNT_WIDTH'(count_q);

    always_comb begin
        deq_uop_o = '{default: '0};
        for (int lane = 0; lane < DEQ_WIDTH; lane++) begin
            if (lane < int'(deq_count_o)) deq_uop_o[lane] = queue_q[lane];
        end
    end

    always_comb begin
        int unsigned write_idx;
        queue_next = '{default: '0};
        write_idx = 0;

        if (resolution_valid_i && resolution_mispredict_i) begin
            for (int idx = 0; idx < DEPTH; idx++) begin
                if (queue_q[idx].valid && !queue_q[idx].branch_mask[resolution_tag_i]) begin
                    queue_next[write_idx] = queue_q[idx];
                    write_idx++;
                end
            end
        end else begin
            for (int idx = 0; idx < DEPTH; idx++) begin
                if ((idx >= int'(deq_accept_count_i)) && queue_q[idx].valid) begin
                    queue_next[write_idx] = queue_q[idx];
                    if (resolution_valid_i) queue_next[write_idx].branch_mask[resolution_tag_i] = 1'b0;
                    write_idx++;
                end
            end

            if (enq_fire_i) begin
                for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                    if (lane < int'(enq_count_i)) begin
                        queue_next[write_idx] = enq_uop_i[lane];
                        write_idx++;
                    end
                end
            end
        end

        count_next = COUNT_WIDTH'(write_idx);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            queue_q <= '{default: '0};
            count_q <= '0;
        end else begin
            queue_q <= queue_next;
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
