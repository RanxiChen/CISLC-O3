/**
 * Rename R1/R2 级间暂存 —— 固定槽位保存一组 uop 与依赖
 *
 * 作用（已定，B02 3.3）：
 * - 第一版用固定槽位与有效位保存一组；R2 部分接受后保留原槽位编号，不与下一组立即合并。
 * - R2 接受前缀离开后，剩余指令若其已记录生产者已离开，就改用当前 RAT（producer_gone_o）；
 *   生产者仍在暂存中则继续由本组新 preg 旁路。
 * - 本组全部离开时，可以同拍末接收 R1 的下一组；全部停顿或部分接受时回压 R1。
 * - 等待不得重复分配；R1 无预分配资源，取消时无需归还事务。
 * - 重定向：暂存中的指令都比执行/提交端出错指令年轻，取消时整体清除，并禁止 R2 同拍年轻副作用。
 *
 * 当前实现状态：目标实现。固定槽位寄存器；仅本组清空时接下一组，无组合直通。
 *
 * 逐周期说明（目标）：
 * - 周期 N 组合：slot_valid_o / slot_uop_o / slot_dep_o 给 R2；enq_ready_o = 本组全部离开或为空。
 * - 周期 N 上升沿：R2 accept_mask_i 的槽清 valid；enq 握手时整组装入；flush_i 清空。
 * - 周期 N+1：R2 看到剩余槽或新组。
 *
 * 验证要点（B02 3.4，未执行）：资源不足部分接受、长停顿不重复分配、恢复同拍取消。
 *
 * 验证待后端重构后统一进行。
 */
module rename_stage_buffer
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int WIDTH = CFG.rename.width
) (
    input  logic                                clk,
    input  logic                                rst,
    input  logic                                flush_i,      // 取消边界：暂存内全部比出错指令年轻

    // 来自 R1
    input  logic                                enq_valid_i,
    output logic                                enq_ready_o,
    input  logic [$clog2(WIDTH+1)-1:0]           enq_count_i,
    input  decoded_uop_t [WIDTH-1:0]            enq_uop_i,
    input  o3_types_pkg::r1_lane_dep_t          enq_dep_i [WIDTH-1:0],

    // 给 R2
    output logic [WIDTH-1:0]                    slot_valid_o,
    output decoded_uop_t [WIDTH-1:0]            slot_uop_o,
    output o3_types_pkg::r1_lane_dep_t          slot_dep_o [WIDTH-1:0],
    output logic [WIDTH-1:0]                    producer_gone_o [3],   // 每源：生产者已离开，改用 RAT
    input  logic [WIDTH-1:0]                    accept_mask_i          // R2 本拍接受的槽
);
    logic [WIDTH-1:0] valid_q;
    decoded_uop_t [WIDTH-1:0] uop_q;
    o3_types_pkg::r1_lane_dep_t dep_q [WIDTH-1:0];

    assign enq_ready_o = !flush_i && ((valid_q & ~accept_mask_i) == '0);
    assign slot_valid_o = valid_q;
    always_comb begin
        slot_uop_o = uop_q;
        producer_gone_o = '{default:'0};
        for (int lane = 0; lane < WIDTH; lane++) begin
            slot_uop_o[lane].valid = valid_q[lane];
            slot_dep_o[lane] = dep_q[lane];
            producer_gone_o[0][lane] = valid_q[lane] && dep_q[lane].src1.valid
                                    && !valid_q[dep_q[lane].src1.slot];
            producer_gone_o[1][lane] = valid_q[lane] && dep_q[lane].src2.valid
                                    && !valid_q[dep_q[lane].src2.slot];
            producer_gone_o[2][lane] = valid_q[lane] && dep_q[lane].src3.valid
                                    && !valid_q[dep_q[lane].src3.slot];
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush_i) begin
            valid_q <= '0;
            uop_q <= '0;
            for (int lane = 0; lane < WIDTH; lane++) dep_q[lane] <= '0;
        end else if (enq_valid_i && enq_ready_o) begin
            uop_q <= enq_uop_i;
            for (int lane = 0; lane < WIDTH; lane++) begin
                valid_q[lane] <= lane < int'(enq_count_i) && enq_uop_i[lane].valid;
                dep_q[lane] <= enq_dep_i[lane];
            end
        end else begin
            valid_q <= valid_q & ~accept_mask_i;
        end
    end
endmodule
