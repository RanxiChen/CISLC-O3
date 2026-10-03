/**
 * 整数 ALU 管线 —— 一个 ALU 的 RegRead 槽、组合执行与 Result 保持槽
 *
 * 来源：2026-10-02 从 backend.sv 的 ALU 循环原样迁出，每个 ALU 一个实例，逻辑未改。
 *
 * 当前已经实现：
 * - 读口 grant 与 IQ 删除原子发生；组合 PRF 读值、PC（AUIPC）和扩展立即数锁存到 RegRead 槽。
 * - int_execute_unit 组合执行；Result 槽只有在旧结果被消费/杀死/为空时才能被覆盖。
 * - 结果未取得写口时保持并反压 RegRead（regread_ready_o=0）。
 * - 分支解析时清除对应 branch bit；误预测时进入 Result 的年轻结果被丢弃。
 *
 * B12 恢复补充：Result 背压期间若发生误预测，RegRead 槽按原 branch mask 先判断 kill；
 * 被杀项清 valid，不能只清 mask 后在旧 Result 消费时重新进入执行。
 *
 * 逐周期说明：
 * - 周期 N 组合：int_execute_unit 用 RegRead 槽操作数产生结果；regread_ready_o 反映
 *   Result 槽是否可前进。
 * - 周期 N 上升沿：result_consume_i 时 Result 装入执行结果；regread_ready_o 时 RegRead
 *   装入新 grant 的 uop（无 grant 时 valid=0）。
 * - 周期 N+1：写回仲裁看到新的 Result 槽。
 *
 * 测试：sim/cocotb/branch_recovery/ 覆盖 Result 背压下的年轻 RegRead kill。
 */
module alu_pipe
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic                  clk,
    input  logic                  rst,

    input  renamed_uop_t          issue_uop_i,
    input  logic                  read_grant_i,
    input  logic [XLEN-1:0]       src1_data_i,     // 已按分配的读口选出的 PRF 读值
    input  logic [XLEN-1:0]       src2_data_i,
    input  branch_resolution_t    resolution_i,
    input  logic                  result_consume_i,

    output logic                  regread_ready_o,
    output int_execute_result_t   result_o,

    // 观测口：仅供 backend 仿真日志使用
    output int_regread_pipe_uop_t obs_regread_o,
    output logic [XLEN-1:0]       obs_exec_result_o
);

    int_regread_pipe_uop_t alu_regread_q;
    int_execute_result_t   alu_result_q;
    logic                  exec_valid;
    logic [XLEN-1:0]       exec_result;
    logic                  exec_cmp_true;

    assign regread_ready_o   = !alu_regread_q.valid || result_consume_i;
    assign result_o          = alu_result_q;
    assign obs_regread_o     = alu_regread_q;
    assign obs_exec_result_o = exec_result;

    int_execute_unit u_int_execute_unit (
        .op_i(int_alu_op_t'(alu_regread_q.int_alu_op)),
        .valid_i(alu_regread_q.valid),
        .src1_value_i(alu_regread_q.src1_value),
        .src2_value_i(alu_regread_q.src2_value),
        .imm_value_i(alu_regread_q.imm_value),
        .use_imm_i(alu_regread_q.imm_valid),
        .is_word_op_i(alu_regread_q.is_word_op),
        .valid_o(exec_valid),
        .result_o(exec_result),
        .cmp_true_o(exec_cmp_true)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            alu_regread_q <= '0;
            alu_result_q  <= '0;
        end else begin
            // Result槽只有在旧结果被消费/杀死/为空时才能被Execute覆盖。
            if (result_consume_i) begin
                alu_result_q.valid <= exec_valid
                                      && !br_killed(alu_regread_q.branch_mask, resolution_i);
                alu_result_q.instruction_id <= alu_regread_q.instruction_id;
`ifdef O3_SIM
                alu_result_q.kanata_id <= alu_regread_q.kanata_id;
`endif
                alu_result_q.rob_idx <= alu_regread_q.rob_idx;
                alu_result_q.dst_preg <= alu_regread_q.dst_preg;
                alu_result_q.dst_write_en <= alu_regread_q.dst_write_en;
                alu_result_q.result <= exec_result;
                alu_result_q.branch_mask <= br_resolved_mask(alu_regread_q.branch_mask, resolution_i);
            end else if (resolution_i.valid) begin
                alu_result_q.branch_mask <= br_resolved_mask(alu_result_q.branch_mask, resolution_i);
            end

            // 读口grant与IQ删除原子发生；组合PRF读值直接锁存到RegRead槽。
            if (br_killed(alu_regread_q.branch_mask, resolution_i)) begin
                alu_regread_q.valid <= 1'b0;
            end else if (regread_ready_o) begin
                alu_regread_q.valid <= read_grant_i;
                alu_regread_q.instruction_id <= issue_uop_i.instruction_id;
`ifdef O3_SIM
                alu_regread_q.kanata_id <= issue_uop_i.kanata_id;
`endif
                alu_regread_q.rob_idx <= issue_uop_i.rob_idx;
                alu_regread_q.dst_preg <= issue_uop_i.dst_preg;
                alu_regread_q.dst_write_en <= issue_uop_i.rd_write_en
                                            && (issue_uop_i.rd != '0);
                alu_regread_q.src1_value <= issue_uop_i.src1_is_pc
                                          ? XLEN'(issue_uop_i.pc)
                                          : (issue_uop_i.rs1_read_en ? src1_data_i : '0);
                alu_regread_q.src2_value <= issue_uop_i.rs2_read_en && !issue_uop_i.use_imm
                                          ? src2_data_i : '0;
                alu_regread_q.imm_value <= issue_uop_i.use_imm
                                         ? expand_imm_value(issue_uop_i.imm_type, issue_uop_i.imm_raw)
                                         : '0;
                alu_regread_q.imm_valid <= issue_uop_i.use_imm;
                alu_regread_q.int_alu_op <= issue_uop_i.int_alu_op;
                alu_regread_q.is_word_op <= issue_uop_i.is_word_op;
                alu_regread_q.branch_mask <= br_resolved_mask(issue_uop_i.branch_mask, resolution_i);
            end else if (resolution_i.valid) begin
                alu_regread_q.branch_mask <= br_resolved_mask(alu_regread_q.branch_mask, resolution_i);
            end
        end
    end

endmodule
