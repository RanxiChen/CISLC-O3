module icache_mshr_tb_top import o3_types_pkg::*; (
input logic clk,rst,alloc_valid,req_ready,resp_valid,resp_error,fill_ready,
input paddr_t alloc_addr,
input coh_id_t resp_id,
input coh_data_t resp_data,
output logic alloc_ready,alloc_merged,req_valid,fill_valid,fill_error,
output paddr_t req_addr,fill_addr,
output coh_id_t req_id,
output coh_data_t fill_data,
output logic [31:0] free_count,depth
);
coh_req_t req;
coh_rsp_down_t resp;
logic [$clog2(o3_cfg_pkg::O3_CFG.fe.icache.mshrs+1)-1:0] count;
assign resp='{op:COH_READDATA,id:resp_id,data:resp_data,error:resp_error,default:'0};
assign req_addr=paddr_t'(req.addr)<<6;assign req_id=req.id;
assign free_count=count;assign depth=o3_cfg_pkg::O3_CFG.fe.icache.mshrs;
icache_mshr #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut(
.clk_i(clk),.rst_i(rst),.alloc_valid_i(alloc_valid),.alloc_ready_o(alloc_ready),.alloc_line_paddr_i(alloc_addr),
.alloc_kind_i(L2_DEMAND),.alloc_merged_o(alloc_merged),.demand_probe_line_i('0),.demand_probe_match_o(),
.demand_select_i(1'b0),.demand_line_i('0),.demand_match_i('0),.probe_line_paddr_i('0),.probe_inflight_o(),
.l2_req_valid_o(req_valid),.l2_req_ready_i(req_ready),.l2_req_o(req),.l2_resp_valid_i(resp_valid),.l2_resp_i(resp),.l2_resp_ready_o(),
.fill_wr_valid_o(fill_valid),.fill_wr_ready_i(fill_ready),.fill_wr_line_paddr_o(fill_addr),.fill_wr_data_o(fill_data),.fill_wr_error_o(fill_error),
.fill_done_o(),.fill_done_line_paddr_o(),.free_count_o(count),.fill_pf_o(),.idle_o(),.perf_o());
endmodule
