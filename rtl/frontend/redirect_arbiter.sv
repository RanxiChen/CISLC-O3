/** L7a D24: sys first, then oldest (FTQ head-relative age, slot),
 * ties EXEC > PREDECODE > SLOW. Acceptance broadcasts one whole request.
 * A held recovery is replaced only by sys, an older request, or a higher
 * priority request at the same position. Events count acceptance, not holds.
 * System redirects retain the L5 known-entry behavior (spec section 7).
 */
module redirect_arbiter
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic           clk_i,
    input  logic           rst_i,

    // 四类来源
    input  sys_redirect_t  sys_i,          // 提交端系统重定向
    input  bru_resolve_t   exec_i,         // 执行解析；mispredict=1 时形成请求
    input  redirect_req_t  predecode_i,    // F1 预解码修正
    input  redirect_req_t  slow_i,         // 慢预测覆盖

    // 年龄参照：FTQ 最老存活项身份
    input  ftq_id_t        ftq_head_i,

    // 赢家与取消边界
    output redirect_req_t  winner_o,
    output fe_kill_t       kill_o,
    output logic           bpu_redirect_valid_o,
    output vaddr_t         bpu_redirect_pc_o,

    // 恢复控制
    output logic           snap_rd_req_o,
    output ftq_id_t        snap_rd_ftq_id_o,
    input  logic           history_done_i,
    input  logic           ras_done_i,
    output logic           recover_busy_o, // 恢复期间停止新预测
    output ras_ckpt_t      ras_recover_ckpt_o, // 从 FTQ 读取的出错区域 ras_before（D29）
    input  ras_ckpt_t      ftq_ras_ckpt_i,
    output ftq_id_t        ras_recover_id_o,   // 当前恢复身份
    input  ftq_id_t        ras_done_id_i,      // RAS 完成通知所属身份

    // 后端观测口（归属待定，见文件头）
    output redirect_req_t  redirect_o,

    output fe_perf_t       perf_o
);
    redirect_req_t recover_q, exec_req, sys_req, candidate;
    logic recover_busy_q, accept;

    function automatic logic older_or_higher(input redirect_req_t lhs,
                                             input redirect_req_t rhs);
        return fe_age(lhs.ftq_id, lhs.slot, ftq_head_i) < fe_age(rhs.ftq_id, rhs.slot, ftq_head_i)
            || (lhs.ftq_id == rhs.ftq_id && lhs.slot == rhs.slot && lhs.src > rhs.src);
    endfunction

    always_comb begin
        sys_req = '0;
        sys_req.valid = sys_i.valid;
        sys_req.src = REDIR_SYS;
        sys_req.sys_kind = sys_i.kind;
        sys_req.ftq_id = sys_i.ftq_id;
        sys_req.slot = sys_i.slot;
        sys_req.kill_self = 1'b1;
        sys_req.target_pc = sys_i.target_pc;
        exec_req = '0;
        exec_req.valid = exec_i.valid && exec_i.mispredict;
        exec_req.src = REDIR_EXEC;
        exec_req.ftq_id = exec_i.ftq_id;
        exec_req.slot = exec_i.slot;
        exec_req.target_pc = exec_i.redirect_pc;
        exec_req.exec_br_valid=exec_i.cfi_type==CFI_BR;
        exec_req.exec_br_taken=exec_i.actual_taken;
        exec_req.hist_inject = exec_i.cfi_type == CFI_BR && exec_i.actual_taken;
        exec_req.hist_branch_pc = exec_i.branch_pc;
        exec_req.hist_target_pc = exec_i.actual_target;
        exec_req.ras_fix = exec_i.ras_action;
        exec_req.ras_push_addr = exec_i.branch_pc + vaddr_t'(exec_i.inst_len);
        candidate = '0;
        if (slow_i.valid) candidate = slow_i;
        if (predecode_i.valid && (!candidate.valid || older_or_higher(predecode_i, candidate)))
            candidate = predecode_i;
        if (exec_req.valid && (!candidate.valid || older_or_higher(exec_req, candidate)))
            candidate = exec_req;
        if (sys_req.valid) candidate = sys_req;
        accept = !rst_i && candidate.valid && (candidate.src == REDIR_SYS
                  || !recover_busy_q || older_or_higher(candidate, recover_q));
    end
    assign winner_o = accept ? candidate : recover_q;
    assign redirect_o = accept ? candidate : '0;
    assign kill_o = '{valid:accept, all:(accept && candidate.src == REDIR_SYS),
                      ftq_id:candidate.ftq_id, slot:candidate.slot,
                      kill_self:candidate.kill_self};
    assign bpu_redirect_valid_o = accept;
    assign bpu_redirect_pc_o = candidate.target_pc;
    assign snap_rd_req_o = accept && candidate.src != REDIR_SYS;
    assign snap_rd_ftq_id_o = snap_rd_req_o ? candidate.ftq_id : recover_q.ftq_id;
    assign recover_busy_o = recover_busy_q;
    assign ras_recover_ckpt_o = ftq_ras_ckpt_i;
    assign ras_recover_id_o = recover_q.ftq_id;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            recover_q <= '0;
            recover_busy_q <= 1'b0;
        end else if (accept) begin
            if (candidate.src == REDIR_SYS) begin
                recover_q <= '0;
                recover_busy_q <= 1'b0;
            end else begin
                recover_q <= candidate;
                recover_busy_q <= 1'b1;
            end
        end else if (recover_busy_q && history_done_i && ras_done_i
                     && ras_done_id_i == recover_q.ftq_id) begin
            recover_q <= '0;
            recover_busy_q <= 1'b0;
        end
    end
    always_comb begin
        perf_o = '0;
        if (!rst_i) begin
            perf_o[PE_RECOVER_CYCLE] = PERF_INC_W'(recover_busy_o);
            if (accept) begin
                case (candidate.src)
                    REDIR_SLOW: perf_o[PE_SLOW_OVERRIDE] = 1;
                    REDIR_PREDECODE: perf_o[PE_PREDECODE_REDIRECT] = 1;
                    REDIR_EXEC: perf_o[PE_REDIRECT_EXEC] = 1;
                    REDIR_SYS: perf_o[PE_REDIRECT_SYS] = 1;
                endcase
            end
        end
    end
endmodule
