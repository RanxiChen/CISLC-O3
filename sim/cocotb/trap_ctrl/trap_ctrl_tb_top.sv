module trap_ctrl_tb_top import o3_types_pkg::*; (
 input logic clk,rst,valid_i,done_i,input logic [63:0] target_i,epc_i,
 input logic [5:0] cause_i,
 output logic update_o,redirect_o,busy_o,output logic [63:0] pc_o,update_epc_o,
 output logic [5:0] update_cause_o);
 trap_req_t req,update;
 always_comb begin req='0;req.valid=valid_i;req.epc=epc_i;req.cause=exception_cause_t'(cause_i);end
 trap_ctrl #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.clk(clk),.rst(rst),.req_i(req),
 .csr_update_valid_o(update_o),.csr_update_o(update),.csr_target_pc_i(target_i),.csr_update_done_i(done_i),
 .redirect_valid_o(redirect_o),.redirect_pc_o(pc_o),.busy_o(busy_o));
 assign update_epc_o=update.epc;assign update_cause_o=update.cause;
endmodule
