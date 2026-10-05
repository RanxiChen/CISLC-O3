/**
 * IFU F0 —— 长度识别、跨块拼接、RVC 展开
 *
 * 作用：
 * - 消费返回队列出队的 16B 原始块，按 FTQ 最终预测的有效范围（入口槽位到选中出口）
 *   识别每条指令起始与长度，RVC 展开为规范 32 位指令。
 * - 区域末尾开始的 32 位指令跨块时，保存前半字，等待顺序地址的下一块后半字再拼接。
 * - 保留原 PC、原始长度、归属 FTQ 身份与起始槽位（第 3.3、10 节）。
 *
 * 目标机制：
 * - 已定：32 位指令的后半字不能被当作独立指令或分支槽位（第 3.1 节）。
 * - 已定：跨块只拼接顺序地址的后半字；即使该指令预测会跳转，也不能用预测目标处的
 *   数据代替（第 3.3 节）。
 * - 已定：选中跳转之后的槽位不属于本次动态路径。
 * - 已定（D25）：FENCE.I 等同步时清除残留半字；kill_i 按 D24 边界清除。
 * - 正常跨块拼接由本级保存前半字并消费下一顺序块完成，不是待发明机制（第 13 节）。
 *
 * 细节待定：
 * - 每拍最多处理槽位数 F0_SLOTS；超过下游宽度时的保存方式（第 10 节）。
 * - 跨块补半字的辅助请求（预测出口在本块，但后半字需要顺序下一块）如何占用
 *   返回队列和 FTQ 资源、与普通顺序请求合并的规则（第 3.3 节）。
 * - 后半字取指异常如何携带原指令 PC 与故障地址（第 3.3 节）。
 * - 非法 RVC 编码的异常 tval 内容。
 *
 * 当前实现状态：闭环简化（L5）
 * - RV64I 的 IALIGN=32：每个对齐指令位置都交给 F1，非法短编码不能被丢弃。
 * - 取指错误携带故障 PC/cause，原始字节不可用时 instruction=0。
 * - 闭环简化：RVC 与跨块拼接待 L2 后补（偏离第 3.3 节目标）；
 *   L1 镜像只有 32 位指令。当前为组合直通，受 F1 ready 回压。
 * - 仍未实现：RVC 展开、跨块半字暂存和性能事件（显式 tie-off）。
 * - 测试：sim/cocotb/ifu_f0/
 *
 * 目标周期行为：
 * - 周期 N 组合：in_valid_i 时识别本块指令，生成 out_*；跨块时不输出该指令。
 * - 周期 N 上升沿：out 握手后接受下一块；保存跨块前半字。
 * - 周期 N+1：F1 看到 F0 输出寄存（寄存边界待定）。
 *
 */
module ifu_f0
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic            clk_i,
    input  logic            rst_i,

    input  logic            in_valid_i,
    output logic            in_ready_o,
    input  rq_out_t         in_i,
    input  ftq_pred_brief_t in_brief_i,

    output logic [F0_SLOTS-1:0] out_valid_o,
    input  logic            out_ready_i,
    output f0_inst_t        out_o [F0_SLOTS],
    output ftq_pred_brief_t out_brief_o,

    input  fe_kill_t        kill_i,
    input  logic            sync_clear_i,   // D25：清除残留半字

    output fe_perf_t        perf_o
);
    assign in_ready_o = !rst_i && !kill_i.valid && !sync_clear_i && out_ready_i;
    assign out_brief_o = in_valid_i ? in_brief_i : '0;
    assign perf_o = '0;

    // L1 has four aligned 32-bit instructions per 16B block. A halfword is
    // an instruction start only when it is at or after entry_slot, matches
    // the entry's 32-bit phase, and has both halfwords in this region.
    // Unsupported short encodings occupy an IALIGN=32 position and trap;
    // dropping them would let a younger instruction retire across the fault.
    always_comb begin
        out_valid_o = '0;
        for (int slot = 0; slot < F0_SLOTS; slot++) begin
            out_o[slot] = '0;
            if (!rst_i && !kill_i.valid && !sync_clear_i && in_valid_i
                && slot >= int'(in_brief_i.pred.entry_slot)
                && ((slot - int'(in_brief_i.pred.entry_slot)) % 2 == 0)
                && slot + 1 < REGION_SLOTS
                && (!in_brief_i.pred.cfi_valid
                    || slot <= int'(in_brief_i.pred.cfi_slot))) begin
                out_valid_o[slot] = 1'b1;
                out_o[slot].pc = in_i.region_base + vaddr_t'(2 * slot);
                out_o[slot].raw_instruction = in_i.data[16*slot +: ILEN];
                out_o[slot].instruction = in_i.data[16*slot +: ILEN];
                out_o[slot].inst_len = 3'd4;
                out_o[slot].is_rvc = 1'b0;
                out_o[slot].crosses_region = 1'b0;
                out_o[slot].ftq_id = in_i.ftq_id;
                out_o[slot].slot = fetch_slot_t'(slot);
                if (in_i.exc_valid) begin
                    out_o[slot].raw_instruction = '0;
                    out_o[slot].instruction = '0;
                    out_o[slot].exc_valid = 1'b1;
                    out_o[slot].exc_cause = in_i.exc_cause;
                    out_o[slot].exc_tval = XLEN'(out_o[slot].pc);
                end else if (in_i.data[16*slot +: 2] != 2'b11) begin
                    // Raw instruction length is encoded even when C is absent.
                    // No RVC expansion or execution; preserve the illegal halfword.
                    out_o[slot].raw_instruction = ILEN'(in_i.data[16*slot +: 16]);
                    out_o[slot].instruction = out_o[slot].raw_instruction;
                    out_o[slot].exc_valid = 1'b1;
                    out_o[slot].exc_cause = o3_isa_pkg::EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION;
                    out_o[slot].exc_tval = XLEN'(out_o[slot].raw_instruction);
                end
            end
        end
    end
endmodule
