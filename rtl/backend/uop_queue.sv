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
 * - DEPTH 按单条 uop 计数，由 CFG.decode.queue_depth 给出（待定）。
 * - 入队宽度 ENQ_WIDTH = decode 宽度 4；出队宽度 DEQ_WIDTH = 现有 rename 宽度。
 *   目标：出队给 R1 依赖预处理，宽度为 rename 宽度（B01 暂定 6，B02）。
 * - 存储按 NUM_BANKS = max(ENQ_WIDTH, DEQ_WIDTH) 个 bank 组织；逻辑位置对 bank 数取模决定物理 bank。
 *   （2026-10-02 框架阶段把原单一 MACHINE_WIDTH 拆成两侧宽度，仅作参数拆分，未运行测试。）
 * - 输入和输出均要求 lane0 最老、有效 lane 为连续前缀。
 * - 下游用 deq_accept_count_i 表示本拍接受的最老前缀长度。
 * - 入队 ready 只使用本拍开始时已有的空位，不借用本拍即将出队的空间，
 *   从而避免把未来 Rename 的资源判断组合地反传到 Decode。
 *
 * 当前不负责：
 * - 不计算 Rename 能接受多少条；ROB、Free List、IQ 等资源不属于本模块。
 * - 不做指令融合、任意 lane 压缩、按年龄选择、wakeup 或 issue。MULH+MUL 融合（B34）在本队列出口之后、
 *   R1 之前由 mul_fusion_detect 标记；本队列不为凑配对而等待。
 * - 不保存checkpoint；mispredict时由flush_i整体清空，因为其中所有指令都比分支年轻。
 *   目标：同一 D24 取消边界下仍然整体清空即可（队中指令都比执行/提交端出错指令年轻）。
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
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int ENQ_WIDTH = CFG.decode.width,          // 前端每拍最多交付 4 条
    localparam int DEQ_WIDTH = BACKEND_MACHINE_WIDTH,     // 现有 rename 前缀宽度；目标为 R1 宽度 CFG.rename.width
    localparam int DEPTH = CFG.decode.queue_depth,
    // 存储 bank 数取两侧宽度较大者，使任一侧连续 lane 落在不同 bank。
    localparam int NUM_BANKS = (ENQ_WIDTH > DEQ_WIDTH) ? ENQ_WIDTH : DEQ_WIDTH
) (
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              flush_i,

    input  decoded_uop_t [ENQ_WIDTH-1:0]      enq_uop_i,
    input  logic                              enq_valid_i,
    output logic                              enq_ready_o,

    output decoded_uop_t [DEQ_WIDTH-1:0]      deq_uop_o,
    output logic [$clog2(DEQ_WIDTH+1)-1:0]    deq_count_o,
    input  logic [$clog2(DEQ_WIDTH+1)-1:0]    deq_accept_count_i
);

    localparam int PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int LANE_COUNT_WIDTH = $clog2(DEQ_WIDTH + 1);
    localparam int ROWS_PER_BANK = DEPTH / NUM_BANKS;

    decoded_uop_t bank_mem [NUM_BANKS-1:0][ROWS_PER_BANK-1:0];
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
        for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
            if (enq_uop_i[lane].valid) begin
                enq_count = enq_count + COUNT_WIDTH'(1);
            end
        end
    end

    assign free_count = COUNT_WIDTH'(DEPTH) - count_q;
    assign enq_ready_o = !enq_valid_i || (free_count >= enq_count);
    assign enq_fire = enq_valid_i && (enq_count != '0) && enq_ready_o;

    assign visible_count = (count_q >= COUNT_WIDTH'(DEQ_WIDTH))
                         ? COUNT_WIDTH'(DEQ_WIDTH)
                         : count_q;
    assign deq_count_o = LANE_COUNT_WIDTH'(visible_count);
    assign accepted_count = COUNT_WIDTH'(deq_accept_count_i);

    always_comb begin
        deq_uop_o = '0;
        for (int lane = 0; lane < DEQ_WIDTH; lane++) begin
            int unsigned logical_pos;
            int unsigned bank_idx;
            int unsigned row_idx;
            logical_pos = (int'(head_q) + lane) % DEPTH;
            bank_idx = logical_pos % NUM_BANKS;
            row_idx = logical_pos / NUM_BANKS;
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
                for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                    if (COUNT_WIDTH'(lane) < enq_count) begin
                        int unsigned logical_pos;
                        int unsigned bank_idx;
                        int unsigned row_idx;
                        logical_pos = (int'(tail_q) + lane) % DEPTH;
                        bank_idx = logical_pos % NUM_BANKS;
                        row_idx = logical_pos / NUM_BANKS;
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
                for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
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
        if ((ENQ_WIDTH <= 0) || (DEQ_WIDTH <= 0)) begin
            $error("uop_queue requires positive ENQ_WIDTH/DEQ_WIDTH");
        end
        if (DEPTH < NUM_BANKS) begin
            $error("uop_queue requires DEPTH >= NUM_BANKS");
        end
        if ((DEPTH % NUM_BANKS) != 0) begin
            $error("uop_queue requires DEPTH to be divisible by NUM_BANKS");
        end
    end

endmodule
