// Test the real common slot and all three new RegRead modules in parallel.
module fu_issue_pipeline_tb_top import o3_pkg::*; (
    input logic clk,rst,flush_i,enq_valid_i,read_permission_i,data_ready_i,fu_ready_i,
    input logic correct_i,kill_i,
    input logic [31:0] sequence_i,
    input logic [63:0] src1_i,src2_i,src3_i,
    input branch_mask_t mask_i,
    output logic enq_ready_o,buffer_valid_o,read_fire_o,
    output logic mdu_valid_o,fp_valid_o,mem_valid_o,
    output logic [63:0] mdu_src1_o,mdu_src2_o,fp_src1_o,fp_src2_o,fp_src3_o,mem_src1_o,mem_src2_o,
    output logic [31:0] buffer_sequence_o,
    output logic [o3_types_pkg::ROB_W-1:0] mdu_rob_o,fp_rob_o,mem_rob_o,
    output branch_mask_t buffer_mask_o,mdu_mask_o,fp_mask_o,mem_mask_o,
    output logic atomic_o,
    output logic [31:0] rob_entries_o,branch_bits_o
);
    import o3_types_pkg::*;
    renamed_uop_t incoming,head;
    branch_resolution_t res;
    mdu_req_t mdu_req;fpu_req_t fp_req;mem_execute_uop_t mem_req;
    logic mdu_ready,fp_ready;
    always_comb begin
        incoming='0;incoming.valid=1;incoming.instruction_id=sequence_i;
        incoming.rob_idx=ROB_W'(sequence_i);incoming.dst_preg=PREG_W'(sequence_i+32);
        incoming.branch_mask=mask_i;incoming.rd_write_en=1;incoming.ext.rd_dom=RD_INT;
        incoming.rs1_read_en=1;incoming.rs2_read_en=1;incoming.ext.rs3_read_en=1;
        incoming.ext.rs1_dom=RD_INT;incoming.ext.rs2_dom=RD_FP;incoming.ext.rs3_dom=RD_FP;
        incoming.ext.fu_class=FU_AMO;incoming.is_load=1;
        res='0;res.valid=correct_i || kill_i;res.mispredict=kill_i;res.branch_tag=0;
    end
    fu_issue_buffer #(.CFG(o3_cfg_pkg::O3_CFG.be)) u_buffer(
        .clk(clk),.rst(rst),.flush_i(flush_i),.enq_valid_i(enq_valid_i),.enq_ready_o(enq_ready_o),
        .enq_uop_i(incoming),.deq_valid_o(buffer_valid_o),.deq_ready_i(read_fire_o),.deq_uop_o(head),.resolution_i(res));
    // Emulate arbitration denial and the real-data recheck independently.
    assign read_fire_o=buffer_valid_o && read_permission_i && data_ready_i && mdu_ready && fp_ready;
    mdu_regread #(.CFG(o3_cfg_pkg::O3_CFG.be)) u_mdu(
        .clk(clk),.rst(rst),.flush_i(flush_i),.read_uop_i(head),.read_grant_i(read_fire_o),
        .src1_data_i(src1_i),.src2_data_i(src2_i),.read_ready_o(mdu_ready),
        .req_valid_o(mdu_valid_o),.req_ready_i(fu_ready_i),.req_o(mdu_req),.resolution_i(res));
    fp_regread #(.CFG(o3_cfg_pkg::O3_CFG.be)) u_fp(
        .clk(clk),.rst(rst),.flush_i(flush_i),.read_uop_i(head),.read_grant_i(read_fire_o),
        .src1_data_i(src1_i),.src2_data_i(src2_i),.src3_data_i(src3_i),.read_ready_o(fp_ready),
        .req_valid_o(fp_valid_o),.req_ready_i(fu_ready_i),.req_o(fp_req),.resolution_i(res));
    mem_regread #(.CFG(o3_cfg_pkg::O3_CFG.be)) u_mem(
        .clk(clk),.rst(rst),.flush_i(flush_i),.read_uop_i(head),.read_grant_i(read_fire_o),
        .src1_data_i(src1_i),.src2_data_i(src2_i),.execute_o(mem_req),.atomic_o(atomic_o),.resolution_i(res));
    assign buffer_sequence_o=32'(head.instruction_id);assign buffer_mask_o=head.branch_mask;
    assign mdu_src1_o=mdu_req.src1;assign mdu_src2_o=mdu_req.src2;
    assign fp_src1_o=fp_req.src1;assign fp_src2_o=fp_req.src2;assign fp_src3_o=fp_req.src3;
    assign mem_src1_o=mem_req.base_value;assign mem_src2_o=mem_req.store_value;
    assign mdu_rob_o=mdu_req.tag.rob_idx;assign fp_rob_o=fp_req.tag.rob_idx;assign mem_rob_o=mem_req.rob_idx;
    assign mdu_mask_o=mdu_req.tag.br_mask;assign fp_mask_o=fp_req.tag.br_mask;assign mem_mask_o=mem_req.branch_mask;
    assign mem_valid_o=mem_req.valid;
    assign rob_entries_o=o3_cfg_pkg::O3_CFG.be.rob.entries;
    assign branch_bits_o=$bits(branch_mask_t);
endmodule
