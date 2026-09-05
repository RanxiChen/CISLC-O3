/**
 * Decode Uop Queue
 *
 * 职责：
 * - 位于 Decode 与未来 Rename 之间，按单条 decoded uop 连续保存程序顺序。
 * - 每拍最多接收 MACHINE_WIDTH 条已经压紧的 uop。
 * - 每拍向下游展示最多 MACHINE_WIDTH 条最老 uop。
 * - 输入 bundle 的边界不进入存储语义；相邻两批 uop 在队列中连续排列。
 *
 * 当前实现：
 * - DEPTH 按单条 uop 计数，默认由顶层配置为 16 entries。
 * - 存储按 MACHINE_WIDTH 个 bank 组织；逻辑位置对 bank 数取模决定物理 bank。
 * - 输入和输出均要求 lane0 最老、有效 lane 为连续前缀。
 * - 下游用 deq_accept_count_i 表示本拍接受的最老前缀长度。
 * - 入队 ready 只使用本拍开始时已有的空位，不借用本拍即将出队的空间，
 *   从而避免把未来 Rename 的资源判断组合地反传到 Decode。
 *
 * 当前不负责：
 * - 不计算 Rename 能接受多少条；ROB、Free List、IQ 等资源不属于本模块。
 * - 不做指令融合、任意 lane 压缩、按年龄选择、wakeup 或 issue。
 * - 不保存checkpoint；mispredict时由flush_i整体清空，因为其中所有指令都比分支年轻。
 *
 * 周期行为：
 * - 周期 N 组合阶段：
 *   1) 统计 Decode 输入的有效前缀长度 enq_count。
 *   2) 若当前已有空位不少于 enq_count，则 enq_ready_o=1。
 *   3) 从 head_q 开始向下游展示最多 MACHINE_WIDTH 条最老 uop。
 * - 周期 N 上升沿：
 *   0) flush_i优先时清空head/tail/count，不接受正常读写。
 *   1) 入队握手成立时，从 tail_q 起连续写入 enq_count 条 uop。
 *   2) deq_accept_count_i 非零时，从队头删除对应数量的最老 uop。
 *   3) head/tail/count 按真实读写数量原子更新。
 * - 周期 N+1：
 *   下游看到新的最老前缀，Decode 看到更新后的空位状态。
 */

module uop_queue
    import o3_pkg::*;
#(
    parameter int MACHINE_WIDTH = 4,
    parameter int DEPTH = 16
) (
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              flush_i,

    input  decoded_uop_t [MACHINE_WIDTH-1:0]  enq_uop_i,
    input  logic                              enq_valid_i,
    output logic                              enq_ready_o,

    output decoded_uop_t [MACHINE_WIDTH-1:0]  deq_uop_o,
    output logic [$clog2(MACHINE_WIDTH+1)-1:0] deq_count_o,
    input  logic [$clog2(MACHINE_WIDTH+1)-1:0] deq_accept_count_i
);

    localparam int PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int LANE_COUNT_WIDTH = $clog2(MACHINE_WIDTH + 1);
    localparam int ROWS_PER_BANK = DEPTH / MACHINE_WIDTH;

    decoded_uop_t bank_mem [MACHINE_WIDTH-1:0][ROWS_PER_BANK-1:0];
    logic [PTR_WIDTH-1:0]   head_q;
    logic [PTR_WIDTH-1:0]   tail_q;
    logic [COUNT_WIDTH-1:0] count_q;

    logic [COUNT_WIDTH-1:0] free_count;
    logic [COUNT_WIDTH-1:0] enq_count;
    logic [COUNT_WIDTH-1:0] visible_count;
    logic [COUNT_WIDTH-1:0] accepted_count;
    logic                   enq_fire;

    function automatic logic [PTR_WIDTH-1:0] ptr_add(
        input logic [PTR_WIDTH-1:0] ptr,
        input int unsigned          offset
    );
        int unsigned next_ptr;
        begin
            next_ptr = int'(ptr) + offset;
            ptr_add = PTR_WIDTH'(next_ptr % DEPTH);
        end
    endfunction

    always_comb begin
        enq_count = '0;
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            if (enq_uop_i[lane].valid) begin
                enq_count = enq_count + COUNT_WIDTH'(1);
            end
        end
    end

    assign free_count = COUNT_WIDTH'(DEPTH) - count_q;
    assign enq_ready_o = !enq_valid_i || (free_count >= enq_count);
    assign enq_fire = enq_valid_i && (enq_count != '0) && enq_ready_o;

    assign visible_count = (count_q >= COUNT_WIDTH'(MACHINE_WIDTH))
                         ? COUNT_WIDTH'(MACHINE_WIDTH)
                         : count_q;
    assign deq_count_o = LANE_COUNT_WIDTH'(visible_count);
    assign accepted_count = COUNT_WIDTH'(deq_accept_count_i);

    always_comb begin
        deq_uop_o = '0;
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            int unsigned logical_pos;
            int unsigned bank_idx;
            int unsigned row_idx;
            logical_pos = (int'(head_q) + lane) % DEPTH;
            bank_idx = logical_pos % MACHINE_WIDTH;
            row_idx = logical_pos / MACHINE_WIDTH;
            if (COUNT_WIDTH'(lane) < visible_count) begin
                deq_uop_o[lane] = bank_mem[bank_idx][row_idx];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush_i) begin
            head_q  <= '0;
            tail_q  <= '0;
            count_q <= '0;
        end else begin
            if (enq_fire) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (COUNT_WIDTH'(lane) < enq_count) begin
                        int unsigned logical_pos;
                        int unsigned bank_idx;
                        int unsigned row_idx;
                        logical_pos = (int'(tail_q) + lane) % DEPTH;
                        bank_idx = logical_pos % MACHINE_WIDTH;
                        row_idx = logical_pos / MACHINE_WIDTH;
                        bank_mem[bank_idx][row_idx] <= enq_uop_i[lane];
                    end
                end
                tail_q <= ptr_add(tail_q, int'(enq_count));
            end

            if (accepted_count != '0) begin
                head_q <= ptr_add(head_q, int'(accepted_count));
            end

            count_q <= count_q
                     + (enq_fire ? enq_count : '0)
                     - accepted_count;

`ifndef SYNTHESIS
            if (enq_valid_i) begin
                bit saw_invalid_lane;
                saw_invalid_lane = 1'b0;
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (!enq_uop_i[lane].valid) begin
                        saw_invalid_lane = 1'b1;
                    end else if (saw_invalid_lane) begin
                        $fatal(1,
                               "[uop_queue] packed-lane violation: lane%0d valid after an invalid lane",
                               lane);
                    end
                end
                if (enq_count == '0) begin
                    $fatal(1,
                           "[uop_queue] enq_valid_i asserted with no valid uop");
                end
            end

            if (accepted_count > visible_count) begin
                $fatal(1,
                       "[uop_queue] deq_accept_count=%0d exceeds visible_count=%0d",
                       accepted_count,
                       visible_count);
            end
`endif
        end
    end

    initial begin
        if (MACHINE_WIDTH <= 0) begin
            $error("uop_queue requires MACHINE_WIDTH > 0");
        end
        if (DEPTH < MACHINE_WIDTH) begin
            $error("uop_queue requires DEPTH >= MACHINE_WIDTH");
        end
        if ((DEPTH % MACHINE_WIDTH) != 0) begin
            $error("uop_queue requires DEPTH to be divisible by MACHINE_WIDTH");
        end
    end

endmodule
