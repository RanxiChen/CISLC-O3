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
 * 当前实现状态：闭环简化（L7a，RTL 已实现，新增行为未验证）。
 * - 按冻结 spec 4.2 的 a～f 扫描真实 32 位指令；第一处修正或异常截断交付。
 * - RAS 使用本区域入口 checkpoint，普通 JALR 目标与 BR 方向仍由执行级确定。
 * - 预解码请求仅在交付握手沿锁存，下一拍送仲裁器；赢家事件由仲裁器计数。
 * - RVC、跨块拼接和变长指令属于 L7b。
 * - 测试：sim/cocotb/ifu_f1/ 仍为旧合同，扩展与运行由后续测试阶段完成。
 *
 * 目标周期行为：
 * - 周期 N 组合：生成截断后的交付项与 pd_req；回压时不修改状态。
 * - 周期 N 上升沿：交付握手成功时锁存 pd_req_q，修正项保留且 kill_self=0。
 * - 周期 N+1：predecode_o=pd_req_q，不组合依赖 kill；仲裁后沿上无条件清请求。
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
    typedef struct packed {
        cfi_type_e type_id;
        ras_action_e ras_action;
        vaddr_t direct_target;
    } decoded_cfi_t;

    redirect_req_t pd_req, pd_req_q;

    // Decode the same legal BR/JAL/JALR encodings and x1/x5 hints as the
    // backend. Direct immediates are sign-extended to the configured PC width.
    function automatic decoded_cfi_t decode_cfi(input f0_inst_t inst);
        decoded_cfi_t decoded;
        logic rd_link, rs1_link;
        decoded = '0;
        rd_link = inst.instruction[11:7] inside {5'd1, 5'd5};
        rs1_link = inst.instruction[19:15] inside {5'd1, 5'd5};
        case (inst.instruction[6:0])
            7'b1100011: if (inst.instruction[14:12] inside
                           {3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111}) begin
                decoded.type_id = CFI_BR;
                decoded.direct_target = inst.pc + vaddr_t'($signed({
                    inst.instruction[31], inst.instruction[7],
                    inst.instruction[30:25], inst.instruction[11:8], 1'b0}));
            end
            7'b1101111: begin
                decoded.type_id = CFI_JAL;
                decoded.ras_action = rd_link ? RAS_PUSH : RAS_NONE;
                decoded.direct_target = inst.pc + vaddr_t'($signed({
                    inst.instruction[31], inst.instruction[19:12],
                    inst.instruction[20], inst.instruction[30:21], 1'b0}));
            end
            7'b1100111: if (inst.instruction[14:12] == 3'b000) begin
                decoded.type_id = CFI_JALR;
                if (rs1_link)
                    decoded.ras_action = rd_link
                        ? (inst.instruction[11:7] == inst.instruction[19:15]
                           ? RAS_PUSH : RAS_POP_PUSH)
                        : RAS_POP;
                else decoded.ras_action = rd_link ? RAS_PUSH : RAS_NONE;
            end
            default: ;
        endcase
        return decoded;
    endfunction

    assign in_ready_o = !rst_i && !kill_i.valid && out_ready_i;
    // Do not gate this registered request with kill_i: it is an arbiter input,
    // and that arbiter produces kill_i combinationally (spec 2.5).
    assign predecode_o = pd_req_q;
    // PE_PREDECODE_REDIRECT belongs to the arbiter's accept edge (U13).
    assign perf_o = '0;

    always_comb begin
        int unsigned count;
        logic stop_scan;
        decoded_cfi_t decoded;
        logic is_exit, covers_exit, earlier, return_target_valid;
        logic actual_target_valid, fix_valid, fix_taken, fix_hist;
        vaddr_t actual_target, fix_target;
        ras_action_e fix_ras;

        count = 0;
        stop_scan = 1'b0;
        pd_req = '0;
        decoded = '0;
        is_exit = 1'b0;
        covers_exit = 1'b0;
        earlier = 1'b0;
        return_target_valid = 1'b0;
        actual_target_valid = 1'b0;
        actual_target = '0;
        fix_valid = 1'b0;
        fix_taken = 1'b0;
        fix_hist = 1'b0;
        fix_target = '0;
        fix_ras = RAS_NONE;
        out_valid_o = '0;
        for (int lane = 0; lane < F1_W; lane++) out_o[lane] = '0;
        if (!rst_i && !kill_i.valid) begin
            for (int slot = 0; slot < F0_SLOTS; slot++) begin
                if (in_valid_i[slot] && count < F1_W && !stop_scan
                    && (!in_brief_i.pred.cfi_valid
                        || in_i[slot].slot <= in_brief_i.pred.cfi_slot)) begin
                    decoded = decode_cfi(in_i[slot]);
                    is_exit = in_brief_i.pred.cfi_valid
                              && in_i[slot].slot == in_brief_i.pred.cfi_slot;
                    covers_exit = is_exit || (in_brief_i.pred.cfi_valid
                        && int'(in_i[slot].slot) + 1 == int'(in_brief_i.pred.cfi_slot));
                    earlier = !in_brief_i.pred.cfi_valid
                              || in_i[slot].slot < in_brief_i.pred.cfi_slot;
                    return_target_valid = decoded.type_id == CFI_JALR
                        && decoded.ras_action inside {RAS_POP, RAS_POP_PUSH}
                        && in_brief_i.ras_ckpt.count != '0;
                    actual_target_valid = decoded.type_id == CFI_JAL || return_target_valid;
                    actual_target = return_target_valid ? in_brief_i.ras_ckpt.top_addr
                                                        : decoded.direct_target;
                    fix_valid = 1'b0;
                    fix_taken = 1'b0;
                    fix_hist = 1'b0;
                    fix_target = in_i[slot].pc + vaddr_t'(4);
                    fix_ras = RAS_NONE;

                    // Ordered a/b > c > d > e > f (U19). No rule examines an
                    // exception item, or an item following it (U10/U20).
                    if (!in_i[slot].exc_valid) begin
                        if (earlier && actual_target_valid) begin // a / b
                            fix_valid = 1'b1;
                            fix_taken = 1'b1;
                            fix_target = actual_target;
                            fix_ras = decoded.ras_action;
                        end else if (covers_exit && (!is_exit || decoded.type_id == CFI_NONE)) begin // c
                            fix_valid = 1'b1;
                        end else if (is_exit && decoded.type_id != in_brief_i.pred.cfi_type) begin // d
                            fix_valid = 1'b1;
                            // A(i) is recomputed without a/b's position condition.
                            if (actual_target_valid) begin
                                fix_taken = 1'b1;
                                fix_target = actual_target;
                                fix_ras = decoded.ras_action;
                            end
                        end else if (is_exit && decoded.type_id inside {CFI_BR, CFI_JAL}
                            && (in_brief_i.pred.cfi_target != decoded.direct_target
                                || (decoded.type_id == CFI_JAL
                                    && in_brief_i.pred.ras_action != decoded.ras_action))) begin // e
                            fix_valid = 1'b1;
                            fix_taken = 1'b1;
                            fix_target = decoded.direct_target;
                            fix_ras = decoded.ras_action;
                            fix_hist = decoded.type_id == CFI_BR;
                        end else if (is_exit && decoded.type_id == CFI_JALR
                            && in_brief_i.pred.ras_action != decoded.ras_action) begin // f
                            fix_valid = 1'b1;
                            fix_taken = 1'b1;
                            fix_target = return_target_valid ? actual_target : in_brief_i.pred.next_pc;
                            fix_ras = decoded.ras_action;
                        end
                    end

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
                    out_o[count].pred_taken = fix_valid ? fix_taken : is_exit;
                    out_o[count].predicted_next_pc = fix_valid ? fix_target
                        : (is_exit ? in_brief_i.pred.next_pc : in_i[slot].pc + vaddr_t'(4));
                    if (fix_valid) begin
                        pd_req.valid = 1'b1;
                        pd_req.src = REDIR_PREDECODE;
                        pd_req.ftq_id = in_i[slot].ftq_id;
                        pd_req.slot = in_i[slot].slot;
                        pd_req.kill_self = 1'b0;
                        pd_req.target_pc = fix_target;
                        pd_req.hist_inject = fix_hist;
                        pd_req.hist_branch_pc = in_i[slot].pc;
                        pd_req.hist_target_pc = fix_target;
                        pd_req.ras_fix = fix_ras;
                        pd_req.ras_push_addr = in_i[slot].pc + vaddr_t'(4);
                    end
                    out_valid_o[count] = 1'b1;
                    count++;
                    stop_scan = fix_valid || in_i[slot].exc_valid || covers_exit;
                end
            end
            if (count != 0) out_o[count-1].ftq_last = 1'b1;
        end
    end

    // N+1 requests are consumed once, independently of the next block's
    // backpressure. A killed block cannot handshake or create a request.
    always_ff @(posedge clk_i) begin
        if (rst_i) pd_req_q <= '0;
        else begin
            pd_req_q <= '0;
            if (in_ready_o && (|out_valid_o) && pd_req.valid) pd_req_q <= pd_req;
        end
    end
endmodule
