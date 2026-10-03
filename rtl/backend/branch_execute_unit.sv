/**
 *
 * 【2026-10-02 框架：目标机制与缺口】
 * - 保留组合比较/目标计算（B12：不增加比较器内部流水级）；由 branch_unit 包装 RegRead/Result。
 * - 需要补充：结果携带 cfi_type、ras_action（x1/x5 提示）、inst_len 与 FTQ 槽位，供 bru_resolve_t。
 * - 已用 inst_len 计算顺序 PC/链接值，可承接 2/4 字节长度；RVC 整条集成未验证。
 * - 目标地址宽度 PC_WIDTH=VADDR_W；完整地址检查边界见 branch_unit 注释（待定）。
 * Single Branch Execute Unit
 *
 * 已实现RV64 B型条件比较、JAL/JALR目标和链接值计算。输入来自Branch RegRead
 * 寄存器，组合结果在Backend上升沿进入Branch Result保持寄存器。
 * 不负责IQ选择、PRF端口仲裁、checkpoint恢复、写回仲裁或预测器训练。
 * 当前不处理目标地址异常和 RVC；L2 执行重定向合同测试见
 * sim/cocotb/branch_recovery/。
 */
module branch_execute_unit
    import o3_pkg::*;
(
    input  branch_execute_uop_t uop_i,
    output branch_result_t      result_o
);
    logic condition_true;
    logic [PC_WIDTH-1:0] fallthrough_pc;
    logic [PC_WIDTH-1:0] direct_target;
    logic [PC_WIDTH-1:0] indirect_target;

    always_comb begin
        unique case (uop_i.branch_cond)
            BRANCH_COND_EQ:  condition_true = uop_i.src1_value == uop_i.src2_value;
            BRANCH_COND_NE:  condition_true = uop_i.src1_value != uop_i.src2_value;
            BRANCH_COND_LT:  condition_true = $signed(uop_i.src1_value) < $signed(uop_i.src2_value);
            BRANCH_COND_GE:  condition_true = $signed(uop_i.src1_value) >= $signed(uop_i.src2_value);
            BRANCH_COND_LTU: condition_true = uop_i.src1_value < uop_i.src2_value;
            BRANCH_COND_GEU: condition_true = uop_i.src1_value >= uop_i.src2_value;
            default:         condition_true = 1'b0;
        endcase
    end

    assign fallthrough_pc = uop_i.pc + PC_WIDTH'(uop_i.inst_len);
    assign direct_target = uop_i.pc + PC_WIDTH'(uop_i.imm_value);
    assign indirect_target = PC_WIDTH'((uop_i.src1_value + uop_i.imm_value) & ~XLEN'(1));

    always_comb begin
        result_o = '0;
        result_o.valid = uop_i.valid;
        result_o.instruction_id = uop_i.instruction_id;
        result_o.rob_idx = uop_i.rob_idx;
        result_o.ftq_id = uop_i.ftq_id;
        result_o.ftq_slot = uop_i.ftq_slot;
        result_o.branch_tag = uop_i.branch_tag;
        result_o.branch_mask = uop_i.branch_mask;
        result_o.branch_pc = uop_i.pc;
        result_o.inst_len = uop_i.inst_len;
        result_o.cfi_type = uop_i.cfi_type;
        result_o.ras_action = uop_i.ras_action;
        result_o.is_branch = uop_i.is_branch;
        result_o.is_jal = uop_i.is_jal;
        result_o.is_jalr = uop_i.is_jalr;
        result_o.actual_taken = uop_i.is_jal || uop_i.is_jalr
                              || (uop_i.is_branch && condition_true);
        result_o.actual_target = uop_i.is_jalr ? indirect_target : direct_target;
        result_o.actual_next_pc = result_o.actual_taken ? result_o.actual_target : fallthrough_pc;
        result_o.mispredict = uop_i.valid
                           && (result_o.actual_next_pc != uop_i.predicted_next_pc);
        result_o.dst_preg = uop_i.dst_preg;
        result_o.dst_write_en = uop_i.dst_write_en;
        result_o.link_value = XLEN'(fallthrough_pc);
    end
endmodule
