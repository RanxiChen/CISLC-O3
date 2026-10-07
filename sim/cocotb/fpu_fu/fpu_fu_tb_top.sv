module fpu_fu_tb_top import o3_pkg::*; import o3_types_pkg::*; (
 input logic clk,rst,flush_i,req_valid_i,resp_ready_i,
 input logic [1:0] unit_i,input logic [4:0] op_i,
 input logic src_fmt_i,dst_fmt_i,int_fmt_i,op_mod_i,input logic [2:0] rm_i,
 input logic [63:0] a_i,b_i,c_i,input logic [7:0] id_i,mask_i,
 input logic resolve_i,mispredict_i,input logic [2:0] branch_i,
 output logic req_ready_o,resp_valid_o,busy_o,
 output logic [63:0] result_o,output logic [4:0] flags_o,
 output logic [7:0] id_o,mask_o);
 fpu_req_t req;branch_resolution_t resolution;
 fpu_resp_t resp[4];logic [3:0] ready,valid,busy;
 always_comb begin
   req='0;req.op=fp_op_e'(op_i);req.src_fmt=fp_fmt_e'(src_fmt_i);
   req.dst_fmt=fp_fmt_e'(dst_fmt_i);req.int_fmt=fp_int_fmt_e'(int_fmt_i);
   req.rm=rm_i;req.op_mod=op_mod_i;req.src1=a_i;req.src2=b_i;req.src3=c_i;
   req.tag.rob_idx=rob_idx_t'(id_i);req.tag.br_mask=br_mask_t'(mask_i);
   req.tag.dst_dom=RD_FP;req.tag.dst_preg=preg_t'(id_i);req.tag.dst_write_en=1;
   resolution='0;resolution.valid=resolve_i;resolution.mispredict=mispredict_i;
   resolution.branch_tag=branch_tag_t'(branch_i);
 end
 fpu_fma_fu #(.CFG(o3_cfg_pkg::O3_CFG.be)) fma(.clk,.rst,.flush_all_i(flush_i),.req_i(req),.resolution_i(resolution),
 .req_valid_i(req_valid_i && unit_i==0),.req_ready_o(ready[0]),.resp_valid_o(valid[0]),.resp_o(resp[0]),.resp_ready_i(resp_ready_i && unit_i==0),.busy_o(busy[0]));
 fpu_divsqrt_fu #(.CFG(o3_cfg_pkg::O3_CFG.be)) divsqrt(.clk,.rst,.flush_all_i(flush_i),.req_i(req),.resolution_i(resolution),
 .req_valid_i(req_valid_i && unit_i==1),.req_ready_o(ready[1]),.resp_valid_o(valid[1]),.resp_o(resp[1]),.resp_ready_i(resp_ready_i && unit_i==1),.busy_o(busy[1]));
 fpu_misc_fu #(.CFG(o3_cfg_pkg::O3_CFG.be)) misc(.clk,.rst,.flush_all_i(flush_i),.req_i(req),.resolution_i(resolution),
 .req_valid_i(req_valid_i && unit_i==2),.req_ready_o(ready[2]),.resp_valid_o(valid[2]),.resp_o(resp[2]),.resp_ready_i(resp_ready_i && unit_i==2),.busy_o(busy[2]));
 fpu_conv_fu #(.CFG(o3_cfg_pkg::O3_CFG.be)) conv(.clk,.rst,.flush_all_i(flush_i),.req_i(req),.resolution_i(resolution),
 .req_valid_i(req_valid_i && unit_i==3),.req_ready_o(ready[3]),.resp_valid_o(valid[3]),.resp_o(resp[3]),.resp_ready_i(resp_ready_i && unit_i==3),.busy_o(busy[3]));
 assign req_ready_o=ready[unit_i];assign resp_valid_o=valid[unit_i];assign busy_o=|busy;
 assign result_o=resp[unit_i].result;assign flags_o=resp[unit_i].fflags;
 assign id_o=8'(resp[unit_i].tag.rob_idx);assign mask_o=8'(resp[unit_i].tag.br_mask);
endmodule
