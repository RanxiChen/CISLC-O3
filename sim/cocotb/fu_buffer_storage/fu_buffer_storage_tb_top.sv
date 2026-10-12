module fu_buffer_storage_tb_top import o3_pkg::*; (
    input logic clk,rst,flush_i,enq_valid_i,deq_ready_i,
    input renamed_uop_t enq_uop_i,
    output logic enq_ready_o,deq_valid_o,
    output renamed_uop_t deq_uop_o,
    input logic resolve_i,mispredict_i,
    input branch_tag_t tag_i,
    output renamed_uop_t fmt_valid_o,fmt_mask_o,fmt_lo_mask_o
);
    branch_resolution_t resolution;
    always_comb begin
        resolution='0;resolution.valid=resolve_i;resolution.mispredict=mispredict_i;
        resolution.branch_tag=tag_i;
        fmt_valid_o='0;fmt_valid_o.valid=1;
        fmt_mask_o='0;fmt_mask_o.branch_mask='1;
        fmt_lo_mask_o='0;fmt_lo_mask_o.mdu_fuse.lo_tag.br_mask='1;
    end
    fu_issue_buffer #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(
        .clk(clk),.rst(rst),.flush_i(flush_i),.enq_valid_i(enq_valid_i),
        .enq_ready_o(enq_ready_o),.enq_uop_i(enq_uop_i),.deq_valid_o(deq_valid_o),
        .deq_ready_i(deq_ready_i),.deq_uop_o(deq_uop_o),.resolution_i(resolution));
endmodule
