/**
 * IFU F1 —— 预解码、直接目标核对、预测修正
 *
 * 作用：
 * - 对 F0 输出的指令预解码控制流类型，计算 branch/JAL 的直接目标，与 FTQ 最终预测
 *   （选中 CFI 槽位、类型、目标、RAS 动作）核对。
 * - 发现预测错误（类型错误、目标错误、预测了不存在的分支、漏掉 JAL 等）时发出
 *   D24 预解码修正请求，并截断本块中被修正出口之后的指令。
 * - 生成 fetch_entry_t（含 ftq_id、slot、pred_taken、predicted_next_pc）写入指令 buffer。
 *
 * 目标机制：
 * - 已定：BTB 中的类型信息是预测信息，最终需要预解码验证（第 3.2 节）。
 * - 已定：后续预解码可计算 branch/JAL 的直接目标并修正（第 4.3 节）；普通 JALR
 *   无可用目标时等待执行得出真实目标。
 * - 已定：同位置优先级执行 > 预解码 > 慢预测（D24）。
 * - 已定：有效目标必须属于当前选中 CFI；一个 BTB target 不能冒充其他槽位（第 14 节）。
 * - 修正请求的历史动作遵守 D09：只有修正后为 taken 条件分支才 hist_inject。
 *
 * 细节待定：
 * - 每拍输出条数 F1_W（第 10 节）。
 * - ftq_last 的产生规则：目标为“区域内最后一条有效指令”，与 ROB 回收合同核对。
 * - 预测类型经预解码改变时 RAS 的精确修复（第 6.2 节待定）。
 *
 * 当前实现状态：闭环简化（L1）
 * - 为 L1 实现：把 F0 的 32 位指令压紧成 fetch_entry_t，预测摘要来自
 *   FTQ 经返回队列送来的 brief；块内最后一条标记 ftq_last。
 * - 闭环简化：不发预解码修正，predecode_o 恒无效（偏离 D24；
 *   预解码修正待 L2 起效）。
 * - 仍未实现：控制流核对、RAS 修复、异常路径和性能事件（显式 tie-off）。
 * - 测试：sim/cocotb/ifu_f1/
 *
 * 目标周期行为：
 * - 周期 N 组合：in_valid_i 时预解码并核对；需要修正时 predecode_o.valid=1。
 * - 周期 N 上升沿：out 握手后写入指令 buffer；修正请求由 redirect_arbiter 仲裁。
 * - 周期 N+1：若本请求获胜，kill_i 清除比修正位置年轻的项（包括 F0、返回队列）。
 *
 */
module ifu_f1
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic            clk_i,
    input  logic            rst_i,

    input  logic [F0_SLOTS-1:0] in_valid_i,
    output logic            in_ready_o,
    input  f0_inst_t        in_i [F0_SLOTS],
    input  ftq_pred_brief_t in_brief_i,

    output fetch_entry_t    out_o [F1_W],
    output logic [F1_W-1:0] out_valid_o,
    input  logic            out_ready_i,

    output redirect_req_t   predecode_o,

    input  fe_kill_t        kill_i,

    output fe_perf_t        perf_o
);
    assign in_ready_o = !rst_i && !kill_i.valid && out_ready_i;
    assign predecode_o = '0;
    assign perf_o = '0;

    // N: compact the valid halfword-start positions into consecutive output
    // lanes. The fetch buffer samples them at edge N when ready. N+1: there
    // is no retained F1 state; the next block may be presented.
    always_comb begin
        int unsigned count;
        count = 0;
        out_valid_o = '0;
        for (int lane = 0; lane < F1_W; lane++) out_o[lane] = '0;
        if (!rst_i && !kill_i.valid) begin
            for (int slot = 0; slot < F0_SLOTS; slot++) begin
                if (in_valid_i[slot] && count < F1_W) begin
                    out_o[count].valid = 1'b1;
                    out_o[count].pc = in_i[slot].pc;
                    out_o[count].raw_instruction = in_i[slot].raw_instruction;
                    out_o[count].instruction = in_i[slot].instruction;
                    out_o[count].inst_len = in_i[slot].inst_len;
                    out_o[count].is_rvc = in_i[slot].is_rvc;
                    out_o[count].exception_valid = in_i[slot].exc_valid;
                    out_o[count].exception_cause = in_i[slot].exc_cause;
                    out_o[count].exception_tval = in_i[slot].exc_tval;
                    out_o[count].ftq_id = in_i[slot].ftq_id;
                    out_o[count].slot = in_i[slot].slot;
                    out_o[count].pred_taken = in_brief_i.pred.cfi_valid
                                           && in_brief_i.pred.raw_pred_taken
                                           && in_i[slot].slot == in_brief_i.pred.cfi_slot;
                    out_o[count].predicted_next_pc = out_o[count].pred_taken
                                                   ? in_brief_i.pred.next_pc
                                                   : in_i[slot].pc + vaddr_t'(in_i[slot].inst_len);
                    out_valid_o[count] = 1'b1;
                    count++;
                end
            end
            if (count != 0) out_o[count-1].ftq_last = 1'b1;
        end
    end
endmodule
