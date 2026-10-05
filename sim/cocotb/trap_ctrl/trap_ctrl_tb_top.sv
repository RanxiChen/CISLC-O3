module trap_ctrl_tb_top import o3_types_pkg::*; (
 input logic clk,rst,valid_i,done_i,input logic [63:0] target_i,
 output logic update_o,redirect_o,output logic [63:0] pc_o);
 trap_req_t req,update;
 always_comb begin req='0;req.valid=valid_i;end
 trap_ctrl #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.clk(clk),.rst(rst),.req_i(req),
 .csr_update_valid_o(update_o),.csr_update_o(update),.csr_target_pc_i(target_i),.csr_update_done_i(done_i),
 .redirect_valid_o(redirect_o),.redirect_pc_o(pc_o));
endmodule
