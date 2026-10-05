module jalr_tb_top import o3_pkg::*; (
    input logic clk,rst,grant_i,consume_i,
    input logic [63:0] src_i,
    input logic [11:0] imm_i,
    input logic [4:0] rd_i,rs_i,
    input logic [PC_WIDTH-1:0] pc_i,pred_i,
    input logic [ROB_IDX_WIDTH-1:0] rob_i,
    input branch_mask_t mask_i,
    output logic ready_o,valid_o,resolve_o,mispredict_o,exc_o,
    output logic [PC_WIDTH-1:0] target_o,
    output logic [63:0] link_o,tval_o,
    output logic [1:0] ras_o
);
    renamed_uop_t u;branch_result_t r;branch_resolution_t res;
    always_comb begin
        u='0;u.valid=grant_i;u.pc=pc_i;u.predicted_next_pc=pred_i;u.inst_len=4;u.is_jalr=1;
        u.rs1_read_en=1;u.rs1=rs_i;u.rd=rd_i;u.rd_write_en=rd_i!=0;u.dst_preg=33;
        u.imm_type=IMM_TYPE_I;u.imm_raw=21'(imm_i);u.rob_idx=rob_i;u.branch_mask=mask_i;
    end
    branch_unit #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.clk(clk),.rst(rst),.issue_uop_i(u),.read_grant_i(grant_i),
        .src1_data_i(src_i),.src2_data_i('0),.result_consume_i(consume_i),.regread_ready_o(ready_o),
        .result_o(r),.resolution_o(res),.resolve_o());
    assign valid_o=r.valid;assign resolve_o=res.valid;assign mispredict_o=res.mispredict;
    assign target_o=r.actual_target;assign link_o=r.link_value;assign ras_o=r.ras_action;
    assign exc_o=r.exc.valid;assign tval_o=r.exc.tval;
endmodule
