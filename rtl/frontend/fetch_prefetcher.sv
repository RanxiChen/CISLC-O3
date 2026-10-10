/** L7c FTQ-driven prefetch: one candidate, consecutive-line deduplication,
 * executable translation reuse or an idle-port ITLB hit probe, never a PTW.
 * No queue is needed: FTQ retains each candidate until consumed. */
module fetch_prefetcher import o3_types_pkg::*; #(
 parameter o3_cfg_pkg::frontend_cfg_t CFG
)(input logic clk_i,rst_i,
 input logic ftq_pf_valid_i,output logic ftq_pf_ready_o,
 input vaddr_t ftq_pf_region_base_i,input ftq_id_t ftq_pf_ftq_id_i,
 output logic pf_req_valid_o,input logic pf_req_ready_i,output pf_req_t pf_req_o,input pf_resp_t pf_resp_i,
 output logic xprobe_valid_o,output vaddr_t xprobe_vaddr_o,input logic xprobe_grant_i,input xprobe_resp_t xprobe_resp_i,
 input xlate_fill_t xlate_fill_i,input fe_csr_t csr_i,input sfence_req_t sfence_i,input fe_kill_t kill_i,input logic hold_i,
 output fe_perf_t perf_o);
 logic last_valid_q,waiting_q,reuse_hit,active,xlate_on,probe_match,consume;
 vaddr_t last_line_q,probe_line_q,line;
 ftq_id_t probe_id_q;
 xlate_epoch_t probe_epoch_q,last_epoch_q;
 paddr_t reuse_pa;
 xlate_fill_t probe_fill;
 assign line={ftq_pf_region_base_i[VADDR_W-1:6],6'b0};
 assign active=!rst_i && ftq_pf_valid_i && !kill_i.valid && !hold_i && !sfence_i.valid;
 assign xlate_on=csr_i.satp_mode==8 && csr_i.priv!=3;
 assign probe_match=waiting_q && probe_id_q==ftq_pf_ftq_id_i && probe_line_q==line && probe_epoch_q==csr_i.epoch;
 prefetch_xlate_cache #(.CFG(CFG)) reuse(.clk_i(clk_i),.rst_i(rst_i),.lookup_vaddr_i(line),
  .lookup_hit_o(reuse_hit),.lookup_paddr_o(reuse_pa),.demand_fill_i(xlate_fill_i),.probe_fill_i(probe_fill),.csr_i(csr_i),.sfence_i(sfence_i));
 always_comb begin
  ftq_pf_ready_o=0;pf_req_valid_o=0;pf_req_o='0;xprobe_valid_o=0;xprobe_vaddr_o=line;probe_fill='0;perf_o='0;
  if(active) begin
   if(csr_i.fe_feat.pf_dis) ftq_pf_ready_o=1;
   else if(last_valid_q && line==last_line_q) begin ftq_pf_ready_o=1;perf_o[PE_PF_FILTERED]=1;end
   else if(!xlate_on && (line>>MEM_PADDR_W)!=0) begin ftq_pf_ready_o=1;perf_o[PE_PF_XLATE_MISS]=1;end
   else if(!xlate_on || reuse_hit) begin
    pf_req_valid_o=1;pf_req_o='{line_vaddr:line,paddr_valid:1'b1,line_paddr:(xlate_on ? reuse_pa:paddr_t'(line)),asid:csr_i.satp_asid,epoch:csr_i.epoch};
    ftq_pf_ready_o=pf_req_ready_i;
    if(pf_req_ready_i) begin
     perf_o[PE_XLATE_REUSE]=PERF_INC_W'(xlate_on);
    end
   end else if(probe_match) begin
    if(xprobe_resp_i.valid) begin
     if(xprobe_resp_i.hit) probe_fill='{valid:1'b1,vpn:line[38:12],ppn:xprobe_resp_i.ppn,level:xprobe_resp_i.level,g:xprobe_resp_i.g,asid:csr_i.satp_asid,epoch:csr_i.epoch};
     else begin ftq_pf_ready_o=1;perf_o[PE_PF_XLATE_MISS]=1;end
    end
   end else begin
    xprobe_valid_o=1;
    perf_o[PE_PF_XLATE_PROBE]=PERF_INC_W'(xprobe_grant_i);
   end
   if(ftq_pf_ready_o && !csr_i.fe_feat.pf_dis) perf_o[PE_PF_CANDIDATE]=1;
  end
  // ICache acknowledges buffer admission first, and reports its eventual
  // hit/inflight/permission/MSHR decision independently in a later cycle.
  if(!rst_i && pf_resp_i.valid) begin
   if(pf_resp_i.status==PF_ISSUED) perf_o[PE_PF_ISSUED]=1;
   else perf_o[PE_PF_FILTERED]+=PERF_INC_W'(1);
  end
 end
 assign consume=active && ftq_pf_ready_o;
 always_ff @(posedge clk_i) begin
  if(rst_i) begin last_valid_q<=0;last_line_q<=0;waiting_q<=0;probe_line_q<=0;probe_id_q<='0;probe_epoch_q<=0;last_epoch_q<=0;end
  else begin
   last_epoch_q<=csr_i.epoch;
   if(!active || !probe_match || xprobe_resp_i.valid) waiting_q<=0;
   if(xprobe_valid_o && xprobe_grant_i) begin waiting_q<=1;probe_line_q<=line;probe_id_q<=ftq_pf_ftq_id_i;probe_epoch_q<=csr_i.epoch;end
   if(consume && !csr_i.fe_feat.pf_dis) begin last_line_q<=line;last_valid_q<=1;end
   if(kill_i.valid || csr_i.epoch!=last_epoch_q || sfence_i.valid) last_valid_q<=0;
  end
 end
endmodule
