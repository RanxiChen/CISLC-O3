module prefetch_tb_top import o3_types_pkg::*; (
 input logic clk_i,rst_i,valid_i,ready_i,hold_i,kill_i,pf_dis_i,
 input vaddr_t va_i,input ftq_id_t id_i,
 input logic [1:0] priv_i,input logic [3:0] mode_i,input asid_t asid_i,input xlate_epoch_t epoch_i,
 input logic [2:0] status_i,
 output logic consumed_o,request_o,probe_o,output paddr_t pa_o,
 input logic probe_grant_i,probe_valid_i,probe_hit_i,probe_g_i,input logic [43:0] probe_ppn_i,input logic [1:0] probe_level_i,
 input logic fill_valid_i,fill_g_i,input sv39_vpn_t fill_vpn_i,input logic [43:0] fill_ppn_i,input logic [1:0] fill_level_i,
 input asid_t fill_asid_i,input xlate_epoch_t fill_epoch_i,
 input logic sf_i,rs1_x0_i,rs2_x0_i,input vaddr_t sf_va_i,input asid_t sf_asid_i,
 output fe_perf_t perf_o
);
 pf_req_t pf;vaddr_t probe_va;
 fetch_prefetcher #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut(.clk_i(clk_i),.rst_i(rst_i),
 .ftq_pf_valid_i(valid_i),.ftq_pf_ready_o(consumed_o),.ftq_pf_region_base_i(va_i),.ftq_pf_ftq_id_i(id_i),
 .pf_req_valid_o(request_o),.pf_req_ready_i(ready_i),.pf_req_o(pf),.pf_resp_i('{valid:ready_i && request_o && consumed_o,status:pf_status_e'(status_i),default:'0}),
 .xprobe_valid_o(probe_o),.xprobe_vaddr_o(probe_va),.xprobe_grant_i(probe_grant_i),
 .xprobe_resp_i('{valid:probe_valid_i,hit:probe_hit_i,ppn:probe_ppn_i,level:probe_level_i,g:probe_g_i}),
 .xlate_fill_i('{valid:fill_valid_i,vpn:fill_vpn_i,ppn:fill_ppn_i,level:fill_level_i,g:fill_g_i,asid:fill_asid_i,epoch:fill_epoch_i}),
 .csr_i('{priv:priv_i,satp_mode:mode_i,satp_asid:asid_i,epoch:epoch_i,fe_feat:'{pf_dis:pf_dis_i,loop_dis:1'b0},default:'0}),
 .sfence_i('{valid:sf_i,rs1_is_x0:rs1_x0_i,rs2_is_x0:rs2_x0_i,vaddr:sf_va_i,asid:sf_asid_i}),
 .kill_i('{valid:kill_i,default:'0}),.hold_i(hold_i),.perf_o(perf_o));
 assign pa_o=pf.line_paddr;
endmodule
