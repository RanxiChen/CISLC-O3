/** L7c: recent executable translations; demand fill wins a concurrent probe.
 * FF entries are context-qualified, including superpage coverage and G/ASID.
 * No walk or architectural exception can originate from this cache. */
module prefetch_xlate_cache import o3_types_pkg::*; #(
 parameter o3_cfg_pkg::frontend_cfg_t CFG
)(input logic clk_i,rst_i,input vaddr_t lookup_vaddr_i,
 output logic lookup_hit_o,output paddr_t lookup_paddr_o,
 input xlate_fill_t demand_fill_i,probe_fill_i,
 input fe_csr_t csr_i,input sfence_req_t sfence_i);
 localparam int N=CFG.prefetch.xlate_reuse_entries,IW=$clog2(N);
 xlate_fill_t rows_q[N],fill;
 logic [IW-1:0] victim_q;
 int selected;logic duplicate;
 always_comb begin
  lookup_hit_o=0;lookup_paddr_o='0;
  for(int n=N-1;n>=0;n--)
   if(rows_q[n].valid && rows_q[n].epoch==csr_i.epoch &&
      (rows_q[n].g || rows_q[n].asid==csr_i.satp_asid) &&
      sv39_covers(rows_q[n].vpn,lookup_vaddr_i[38:12],rows_q[n].level)) begin
    lookup_hit_o=1;lookup_paddr_o=sv39_pa(rows_q[n].ppn,lookup_vaddr_i,rows_q[n].level);
   end
  fill=demand_fill_i.valid ? demand_fill_i:probe_fill_i;
  duplicate=0;selected=int'(victim_q);
  for(int n=N-1;n>=0;n--) begin
   if(!rows_q[n].valid || rows_q[n].epoch!=csr_i.epoch) selected=n;
   if(rows_q[n].valid && rows_q[n].epoch==fill.epoch &&
      (rows_q[n].g || rows_q[n].asid==fill.asid) &&
      sv39_covers(rows_q[n].vpn,fill.vpn,rows_q[n].level)) duplicate=1;
  end
 end
 always_ff @(posedge clk_i) begin
  if(rst_i) begin rows_q<='{default:'0};victim_q<=0;end
  else if(sfence_i.valid) begin
   for(int n=0;n<N;n++) if(sfence_match(sfence_i,rows_q[n].vpn,rows_q[n].level,rows_q[n].g,rows_q[n].asid)) rows_q[n].valid<=0;
  end else if(fill.valid && fill.epoch==csr_i.epoch && !duplicate) begin
   rows_q[selected]<=fill;victim_q<=IW'((selected+1)%N);
  end
 end
endmodule
