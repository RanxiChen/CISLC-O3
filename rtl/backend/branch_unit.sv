/**
 * 分支单元 —— 单发射 BRU 的 RegRead 槽、组合执行、Result 保持槽与解析广播
 *
 * 来源：2026-10-02 从 backend.sv 的 Branch 流水与 resolution 组装逻辑原样迁出，逻辑未改。
 *
 * 已确认组织（B12，2026-10-01）：
 * - 独立单发射 BRU，“RegRead → 组合执行 → Result 保持”；解析/重定向与 JAL/JALR 链接值
 *   写回解耦。暂不增加第二条分支执行管线，也不增加比较器内部流水级。
 *
 * 当前已经实现：
 * - Branch 候选取得全部读口后锁存操作数；branch_execute_unit 组合比较并计算目标、
 *   实际下一 PC 与链接值；结果在下一边沿进入 Result 槽。
 * - Result 槽有效时广播一次 resolution（sent 标志防止链接值背压期间重复解析）；
 *   解析不等链接值写口，也不等提交。
 * - 误预测条件：实际下一 PC 与 predicted_next_pc 不同。
 * - 误预测时自身 RegRead 中依赖该分支的年轻项被清 valid。
 *
 * 当前缺口与需要补充的机制（B12）：
 * 1) 解析造成全局暂停：resolution_o.valid（包括预测正确）被 backend 用来阻止 IQ 选择、
 *    读口授予、rename/dispatch 和 ROB 退休。这是保守控制，不是前端合同要求；
 *    O3-T01 已改为仅 M 阻塞；C 正常推进并清依赖。
 * 2) resolve_o（o3_types_pkg::bru_resolve_t）已由 Result 槽组装，携带完整动态 FTQ 身份、
 *    槽位、cfi_type、ras_action 与 inst_len，送前端 FTQ 和 redirect_arbiter。L2 闭环只启用
 *    执行纠错来源；旧 resolution_o 仍同步驱动后端 checkpoint 恢复。
 * 3) 后端恢复与前端 D24 赢家需使用同一取消边界，接口归属未设计。
 * 4) 目标地址：现以 PC_WIDTH(=VADDR_W) 计算；RV64GC 下 IALIGN=16，JALR 清 bit0 后目标不会
 *    出现指令地址不对齐，因此 BRU 可能不需要异常输出；非规范/不可访问目标由前端取指时报告。
 *    B12 第 4 条将“异常/完整目标边界”列为待闭合，此处只记录判断依据，未定。
 *
 * 逐周期说明：
 * - 周期 N：仲裁 grant 后上升沿锁存 RegRead。
 * - 周期 N+1：组合执行；若 Result 可前进，上升沿进入 Result。
 * - 周期 N+2：Result 有效且未发过则 resolution_o.valid=1；链接值同时竞争写口，
 *   取得写口（result_consume_i）后离开。
 *
 * 测试：sim/cocotb/branch_recovery/；整核门禁为 sim/o3/run-rv64i-instructions。
 */
// 当前实现状态：闭环简化（L3）；正确解析不停顿，四宽合同。测试：sim/cocotb/branch_unit/。
module branch_unit
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic                       clk,
    input  logic                       rst,

    input  renamed_uop_t               issue_uop_i,
    input  logic                       read_grant_i,
    input  logic [XLEN-1:0]            src1_data_i,
    input  logic [XLEN-1:0]            src2_data_i,
    input  logic                       result_consume_i,   // 链接值取得写口或无需写回

    output logic                       regread_ready_o,
    output branch_result_t             result_o,           // 送写回仲裁
    output branch_resolution_t         resolution_o,       // 旧合同：后端恢复驱动源

    // 目标合同：送前端 FTQ / redirect_arbiter（已由 Result 驱动）
    output o3_types_pkg::bru_resolve_t resolve_o
);

    branch_execute_uop_t branch_regread_q;
    branch_result_t      branch_execute_result;
    branch_result_t      branch_result_q;
    logic                branch_resolution_sent_q;
    logic                branch_execute_ready;

    assign branch_execute_ready = !branch_result_q.valid || result_consume_i;
    assign regread_ready_o      = !branch_regread_q.valid || branch_execute_ready;
    assign result_o             = branch_result_q;

    assign resolution_o.valid          = branch_result_q.valid && !branch_resolution_sent_q;
    assign resolution_o.mispredict     = branch_result_q.mispredict;
    assign resolution_o.branch_tag     = branch_result_q.branch_tag;
    assign resolution_o.branch_rob_idx = branch_result_q.rob_idx;
    assign resolution_o.ftq_id         = branch_result_q.ftq_id;
    assign resolution_o.branch_pc      = branch_result_q.branch_pc;
    assign resolution_o.is_branch      = branch_result_q.is_branch;
    assign resolution_o.is_jal         = branch_result_q.is_jal;
    assign resolution_o.is_jalr        = branch_result_q.is_jalr;
    assign resolution_o.actual_taken   = branch_result_q.actual_taken;
    assign resolution_o.actual_target  = branch_result_q.actual_target;
    assign resolution_o.redirect_pc    = branch_result_q.actual_next_pc;
    assign resolution_o.completes_rob  = !branch_result_q.dst_write_en;

    // 解析广播与目标前端合同来自同一个 Result 槽，并共享 sent one-shot。
    // 正确解析也送 FTQ 记录实际结果；redirect_arbiter 只对 mispredict 形成重定向。
    assign resolve_o.valid         = resolution_o.valid;
    assign resolve_o.mispredict    = branch_result_q.mispredict;
    assign resolve_o.ftq_id        = branch_result_q.ftq_id;
    assign resolve_o.slot          = branch_result_q.ftq_slot;
    assign resolve_o.branch_pc     = branch_result_q.branch_pc;
    assign resolve_o.inst_len      = branch_result_q.inst_len;
    assign resolve_o.cfi_type      = branch_result_q.cfi_type;
    assign resolve_o.ras_action    = branch_result_q.ras_action;
    assign resolve_o.actual_taken  = branch_result_q.actual_taken;
    assign resolve_o.actual_target = branch_result_q.actual_target;
    assign resolve_o.redirect_pc   = branch_result_q.actual_next_pc;

    branch_execute_unit u_branch_execute_unit (
        .uop_i(branch_regread_q),
        .result_o(branch_execute_result)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            branch_regread_q         <= '0;
            branch_result_q          <= '0;
            branch_resolution_sent_q <= 1'b0;
        end else begin
            // BRU结果槽把解析广播与JAL/JALR链接值写回解耦。解析只发一次；
            // 链接值未取得共享写口时，结果槽继续保持并反压Branch流水线。
            if (branch_execute_ready) begin
                branch_result_q <= branch_execute_result;
                branch_result_q.valid <= branch_execute_result.valid
                                      && !br_killed(branch_execute_result.branch_mask, resolution_o);
                branch_result_q.branch_mask <= br_resolved_mask(branch_execute_result.branch_mask,
                                                                resolution_o);
                branch_resolution_sent_q <= 1'b0;
            end else if (resolution_o.valid) begin
                branch_result_q.branch_mask <= br_resolved_mask(branch_result_q.branch_mask, resolution_o);
                branch_resolution_sent_q <= 1'b1;
            end

            // Branch候选只有同时获得全部所需PRF读口后才从IQ删除并锁存。
            if (resolution_o.valid && resolution_o.mispredict
             && branch_regread_q.branch_mask[resolution_o.branch_tag]) begin
                branch_regread_q.valid <= 1'b0;
            end else if (regread_ready_o) begin
                branch_regread_q.valid <= read_grant_i;
                branch_regread_q.instruction_id <= issue_uop_i.instruction_id;
                branch_regread_q.rob_idx <= issue_uop_i.rob_idx;
                branch_regread_q.ftq_id <= issue_uop_i.ftq_id;
                branch_regread_q.ftq_slot <= issue_uop_i.ext.ftq_slot;
                branch_regread_q.branch_tag <= issue_uop_i.branch_tag;
                branch_regread_q.branch_mask <= br_resolved_mask(issue_uop_i.branch_mask, resolution_o);
                branch_regread_q.pc <= issue_uop_i.pc;
                branch_regread_q.inst_len <= issue_uop_i.inst_len;
                branch_regread_q.predicted_next_pc <= issue_uop_i.predicted_next_pc;
                branch_regread_q.cfi_type <= issue_uop_i.is_branch ? o3_types_pkg::CFI_BR
                                              : (issue_uop_i.is_jal ? o3_types_pkg::CFI_JAL
                                                                    : o3_types_pkg::CFI_JALR);
                // 本闭环只验收直接 JAL；为后续训练仍按 RISC-V link-register hint
                // 记录 JAL push。JALR 的完整 pop/pop-push 分类留到其单独闭环。
                branch_regread_q.ras_action <= issue_uop_i.is_jal
                                             && ((issue_uop_i.rd == 5'd1)
                                              || (issue_uop_i.rd == 5'd5))
                                              ? o3_types_pkg::RAS_PUSH
                                              : o3_types_pkg::RAS_NONE;
                branch_regread_q.is_branch <= issue_uop_i.is_branch;
                branch_regread_q.is_jal <= issue_uop_i.is_jal;
                branch_regread_q.is_jalr <= issue_uop_i.is_jalr;
                branch_regread_q.branch_cond <= issue_uop_i.branch_cond;
                branch_regread_q.src1_value <= issue_uop_i.rs1_read_en ? src1_data_i : '0;
                branch_regread_q.src2_value <= issue_uop_i.rs2_read_en ? src2_data_i : '0;
                branch_regread_q.imm_value <= expand_imm_value(issue_uop_i.imm_type, issue_uop_i.imm_raw);
                branch_regread_q.dst_preg <= issue_uop_i.dst_preg;
                branch_regread_q.dst_write_en <= issue_uop_i.rd_write_en
                                               && (issue_uop_i.rd != '0);
            end else if (resolution_o.valid) begin
                branch_regread_q.branch_mask <= br_resolved_mask(branch_regread_q.branch_mask, resolution_o);
            end
        end
    end

endmodule
