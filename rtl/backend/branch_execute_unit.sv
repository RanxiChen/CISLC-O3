/**
 * Branch Execute Unit
 *
 * 当前只负责 RV64I 条件分支比较与目标 PC 计算。
 * 分支预测默认 not-taken，因此 taken 即 mispredict。
 */
module branch_execute_unit
    import o3_pkg::*;
(
    input  logic                 valid_i,
    input  branch_op_t           branch_op_i,
    input  logic [PC_WIDTH-1:0]  pc_i,
    input  logic [XLEN-1:0]      src1_value_i,
    input  logic [XLEN-1:0]      src2_value_i,
    input  logic [XLEN-1:0]      imm_value_i,

    output logic                 valid_o,
    output logic                 taken_o,
    output logic                 mispredict_o,
    output logic [PC_WIDTH-1:0]  target_pc_o,
    output logic [PC_WIDTH-1:0]  fallthrough_pc_o
);

    logic signed [XLEN-1:0] src1_signed;
    logic signed [XLEN-1:0] src2_signed;
    logic signed [XLEN-1:0] pc_xlen;
    logic signed [XLEN-1:0] target_xlen;

    assign src1_signed = $signed(src1_value_i);
    assign src2_signed = $signed(src2_value_i);
    assign pc_xlen     = $signed(XLEN'(pc_i));
    assign target_xlen = pc_xlen + $signed(imm_value_i);

    always_comb begin
        taken_o = 1'b0;

        unique case (branch_op_i)
            BRANCH_OP_BEQ:  taken_o = (src1_value_i == src2_value_i);
            BRANCH_OP_BNE:  taken_o = (src1_value_i != src2_value_i);
            BRANCH_OP_BLT:  taken_o = (src1_signed < src2_signed);
            BRANCH_OP_BGE:  taken_o = (src1_signed >= src2_signed);
            BRANCH_OP_BLTU: taken_o = (src1_value_i < src2_value_i);
            BRANCH_OP_BGEU: taken_o = (src1_value_i >= src2_value_i);
            default:        taken_o = 1'b0;
        endcase
    end

    assign valid_o          = valid_i;
    assign mispredict_o     = valid_i && taken_o;
    assign target_pc_o      = PC_WIDTH'(target_xlen);
    assign fallthrough_pc_o = pc_i + PC_WIDTH'(4);

endmodule
