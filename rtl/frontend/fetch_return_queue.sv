/**
 * 原始取指返回队列 —— 按程序顺序预留、乱序写回、按序出队
 *
 * 作用：
 * - FTQ demand 请求发射前按程序顺序预留槽位；ICache 响应按 rq_idx 写回，允许后发先回。
 * - 队头满足条件才交给 F0：data_ready && slow_done && !killed（D16，第 6.3 节）。
 * - 指令字节存在这里和之后的指令 buffer，FTQ 不存取指数据（第 1 节）。
 *
 * 目标机制：
 * - 暂定 8 项，参数化（D15）。
 * - 已定（D14）：hit under miss，返回按前端程序顺序消费。
 * - 已定（D17）：错误路径已发出的 cache 请求可完成，返回数据丢弃。
 * - 已定（第 10 节）：killed 且仍 pending 的槽位保留至响应结束再回收；已返回的 killed
 *   项可回收；槽位不得提前复用后被旧响应覆盖。
 * - 已定：demand 未真正握手时，预留与取消规则不得泄漏或重复分配（rsv_* 与
 *   demand 握手同拍确认）。
 * - 异常响应同样完成队列项，不永久占住队头（第 14 节）。
 * - slow_done 与最终预测摘要在出队时按 ftq_id 从 FTQ 读取（ftq_brief_*），
 *   使慢覆盖修正的有效范围被 F0/F1 使用。
 *
 * 细节待定：
 * - 表项确切布局；killed 保守回收策略对有效深度的影响需测量。
 * - 代际身份回绕安全条件。
 * - 跨块补半字辅助请求如何占用本队列（第 3.3 节待定）。
 *
 * 当前实现状态：闭环简化（L1）
 * - 为 L1 实现：单槽预留，按 ftq_id/rq_idx 接收阻塞 ICache 响应，
 *   等 FTQ brief.slow_done 后按序交给 F0；第二笔 demand 被回压。
 * - 闭环简化：ICache 单未决；D15/D17 待 L4 ICache 非阻塞后补齐
 *   （8 项、killed 保留、代际回绕）。L7a 的 kill 按 FTQ 年龄选择性清槽，迟到响应靠身份比较丢弃。
 * - 仍未实现：多未决乱序回填和性能事件（显式 tie-off）。
 * - 测试：sim/cocotb/fetch_return_queue/
 *
 * 目标周期行为：
 * - 周期 N 组合：rsv_ready_o/rsv_idx_o 给出下一空槽；队头满足条件时 deq_valid_o=1。
 * - 周期 N 上升沿：rsv_fire_i 时分配槽并记录身份；resp_i.valid 时写入数据并置
 *   data_ready；kill_i 时把边界之后的项标记 killed；deq 握手时回收队头。
 * - 周期 N+1：可见新的占用、队头状态。
 *
 */
module fetch_return_queue
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic            clk_i,
    input  logic            rst_i,

    // 预留：与 FTQ→ICache demand 握手同拍确认
    output logic            rsv_ready_o,
    output rq_idx_t         rsv_idx_o,
    input  logic            rsv_fire_i,
    input  icache_req_t     rsv_req_i,

    // ICache 响应（乱序）
    input  icache_resp_t    resp_i,

    // 出队时读取 FTQ 最终预测摘要
    output logic            ftq_brief_rd_valid_o,
    output ftq_id_t         ftq_brief_rd_id_o,
    input  ftq_pred_brief_t ftq_brief_i,

    // 出队给 F0
    output logic            deq_valid_o,
    input  logic            deq_ready_i,
    output rq_out_t         deq_o,
    output ftq_pred_brief_t deq_brief_o,

    input  fe_kill_t        kill_i,
    input  ftq_id_t         ftq_head_i,

    output fe_perf_t        perf_o
);
    logic occupied_q, data_ready_q;
    ftq_id_t ftq_id_q;
    vaddr_t region_base_q;
    logic [REGION_BYTES*8-1:0] data_q;
    logic exc_valid_q;
    exception_cause_t exc_cause_q;
    logic deq_fire;

    assign rsv_ready_o = !rst_i && !kill_i.valid && !occupied_q;
    assign rsv_idx_o = '0;
    assign ftq_brief_rd_valid_o = occupied_q && data_ready_q;
    assign ftq_brief_rd_id_o = ftq_id_q;
    assign deq_valid_o = !rst_i && !kill_i.valid && occupied_q && data_ready_q
                       && ftq_brief_i.slow_done && ftq_brief_i.ftq_id == ftq_id_q;
    assign deq_fire = deq_valid_o && deq_ready_i;
    assign deq_o = '{
        ftq_id: ftq_id_q,
        region_base: region_base_q,
        data: data_q,
        exc_valid: exc_valid_q,
        exc_cause: exc_cause_q
    };
    assign deq_brief_o = deq_valid_o ? ftq_brief_i : '0;
    assign perf_o = '0;

    // N: reserve only with the FTQ/ICache demand handshake. A response can
    // fill that same slot at edge N or a later edge. N+1: the stored block is
    // visible to F0 once FTQ reports its prediction complete. The slot is
    // available again only on the edge after F0 accepts the block.
    always_ff @(posedge clk_i) begin
        if (rst_i || (occupied_q && fe_killed_by(kill_i, ftq_id_q, fetch_slot_t'(0), ftq_head_i))) begin
            occupied_q <= 1'b0;
            data_ready_q <= 1'b0;
            ftq_id_q <= '0;
            region_base_q <= '0;
            data_q <= '0;
            exc_valid_q <= 1'b0;
            exc_cause_q <= '0;
        end else begin
            if (deq_fire) begin
                occupied_q <= 1'b0;
                data_ready_q <= 1'b0;
            end
            if (rsv_fire_i && rsv_ready_o) begin
                occupied_q <= 1'b1;
                data_ready_q <= 1'b0;
                ftq_id_q <= rsv_req_i.ftq_id;
                region_base_q <= rsv_req_i.region_base;
            end
            if (resp_i.valid && resp_i.rq_idx == rq_idx_t'(0)
                && ((occupied_q && resp_i.ftq_id == ftq_id_q)
                 || (rsv_fire_i && rsv_ready_o
                     && resp_i.ftq_id == rsv_req_i.ftq_id))) begin
                data_q <= resp_i.data;
                exc_valid_q <= resp_i.exc_valid;
                exc_cause_q <= resp_i.exc_cause;
                data_ready_q <= 1'b1;
            end
        end
    end
endmodule
