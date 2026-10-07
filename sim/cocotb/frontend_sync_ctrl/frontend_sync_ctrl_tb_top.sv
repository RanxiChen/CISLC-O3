module frontend_sync_ctrl_tb_top import o3_types_pkg::*; (
 input logic [2:0] kind_i,
 input logic clk,rst,valid_i,idle_i,inv_done_i,
 output logic ready_o,hold_o,inv_o,done_o,clear_o);
 fe_sync_req_t req;
 assign req='{kind:sys_redirect_kind_e'(kind_i),default:'0};
 frontend_sync_ctrl #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut(
 .clk_i(clk),.rst_i(rst),.sync_req_valid_i(valid_i),.sync_req_ready_o(ready_o),.sync_req_i(req),
 .sync_done_o(done_o),.hold_o(hold_o),.icache_idle_i(idle_i),.ptw_idle_i(1'b1),
 .icache_inv_all_o(inv_o),.icache_inv_done_i(inv_done_i),.sfence_o(),.sfence_done_i(1'b0),
 .pmp_update_o(),.pmp_update_done_i(1'b0),.f0_clear_o(clear_o));
endmodule
