module wfi_ctrl_tb_top import o3_types_pkg::*;(
 input logic clk,rst,retire_i,input logic [63:0] mip_i,mie_i,
 output logic sleeping_o,stall_o);
 wfi_ctrl #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.clk(clk),.rst(rst),.wfi_retire_i(retire_i),
  .irq_i('{mip:mip_i,mie:mie_i}),.debug_req_i(1'b0),.sleeping_o(sleeping_o),.stall_o(stall_o));
endmodule
