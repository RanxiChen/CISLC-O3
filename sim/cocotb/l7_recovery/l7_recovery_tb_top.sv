// Connected production F1/arbiter/FIFO/RQ/CSR. Only public inputs are driven.
module l7_recovery_tb_top import o3_types_pkg::*; import o3_cfg_pkg::*; (
 input logic clk_i,rst_i,input logic [1:0] count_i,
 input logic [63:0] base_i,input logic [31:0] word0_i,word1_i,
 input ftq_id_t id_i,head_i,input logic stall_i,deq_ready_i,
 input logic exec_valid_i,input ftq_id_t exec_id_i,input fetch_slot_t exec_slot_i,
 input logic [63:0] exec_target_i,input logic done_i,input ftq_id_t done_id_i,
 input logic rsv_i,resp_i,input ftq_id_t rq_id_i,input logic rq_ready_i,
 input logic csr_valid_i,csr_write_i,input logic [11:0] csr_addr_i,
 input logic [63:0] csr_data_i,
 output logic f1_ready_o,pd_valid_o,kill_o,busy_o,
 output logic [1:0] winner_src_o,output ftq_id_t winner_id_o,
 output logic [63:0] target_o,csr_read_o,
 output logic deq_valid_o,output logic [DELIVER_W-1:0] mask_o,last_o,taken_o,
 output logic [DELIVER_W-1:0][$bits(ftq_id_t)-1:0] ids_o,
 output logic [DELIVER_W-1:0][SLOT_W-1:0] slots_o,
 output logic [DELIVER_W-1:0][VADDR_W-1:0] next_o,
 output logic rq_valid_o,rq_reserve_ready_o,output ftq_id_t rq_out_id_o,
 output logic [31:0] depth_o,output logic [7:0] pd_inc_o,exec_inc_o,recover_inc_o
);
 f0_inst_t items[F0_SLOTS];fetch_entry_t f1_entries[F1_W],delivered[DELIVER_W];
 logic [F0_SLOTS-1:0] valid;logic [F1_W-1:0] f1_valid;
 logic fb_ready;redirect_req_t pd,winner;fe_kill_t boundary;
 bru_resolve_t exec_req;fe_perf_t arb_perf,fb_perf,f1_perf,sum_perf;
 icache_req_t rq_req;icache_resp_t rq_resp;ftq_pred_brief_t brief;
 rq_out_t rq_out;csr_req_t csr_req;csr_resp_t csr_resp;
 always_comb begin
  valid='0;
  for(int s=0;s<F0_SLOTS;s++) items[s]='0;
  for(int n=0;n<2;n++) begin
   valid[2*n]=n<int'(count_i);
   items[2*n]='{pc:base_i+64'(4*n),instruction:(n==0?word0_i:word1_i),
    raw_instruction:(n==0?word0_i:word1_i),inst_len:3'd4,
    ftq_id:id_i,slot:fetch_slot_t'(2*n),default:'0};
  end
  exec_req='{valid:exec_valid_i,mispredict:exec_valid_i,ftq_id:exec_id_i,
    slot:exec_slot_i,redirect_pc:exec_target_i,actual_target:exec_target_i,
    inst_len:3'd4,cfi_type:CFI_NONE,ras_action:RAS_NONE,default:'0};
  rq_req='{ftq_id:rq_id_i,region_base:base_i,default:'0};
  rq_resp='{valid:resp_i,ftq_id:rq_id_i,data:128'h12345678,default:'0};
  brief='{ftq_id:rq_out.ftq_id,slow_done:1'b1,default:'0};
  csr_req='{addr:csr_addr_i,wdata:csr_data_i,write_en:csr_write_i,op:CSROP_RW,default:'0};
  sum_perf='0;
  for(int e=0;e<PE_NUM;e++) sum_perf[e]=arb_perf[e]+fb_perf[e]+f1_perf[e];
 end
 ifu_f1 #(.CFG(O3_CFG.fe)) f1(.clk_i(clk_i),.rst_i(rst_i),.in_i(items),
  .in_valid_i(valid),.in_ready_o(f1_ready_o),.in_brief_i('0),.out_o(f1_entries),
  .out_valid_o(f1_valid),.out_ready_i(fb_ready&&!stall_i),.predecode_o(pd),
  .kill_i(boundary),.perf_o(f1_perf));
 redirect_arbiter #(.CFG(O3_CFG.fe)) arb(.clk_i(clk_i),.rst_i(rst_i),
  .sys_i('0),.exec_i(exec_req),.predecode_i(pd),.slow_i('0),.ftq_head_i(head_i),
  .winner_o(winner),.kill_o(boundary),.bpu_redirect_valid_o(),.bpu_redirect_pc_o(),
  .snap_rd_req_o(),.snap_rd_ftq_id_o(),.history_done_i(done_i),.ras_done_i(done_i),
  .recover_busy_o(busy_o),.ras_recover_ckpt_o(),.ftq_ras_ckpt_i('0),
  .ras_recover_id_o(),.ras_done_id_i(done_id_i),.redirect_o(),.perf_o(arb_perf));
 fetch_buffer #(.CFG(O3_CFG.fe)) fb(.clk_i(clk_i),.rst_i(rst_i),.flush_i(1'b0),
  .enq_entry_i(f1_entries),.enq_valid_i(stall_i?'0:f1_valid),.enq_ready_o(fb_ready),
  .deq_entry_o(delivered),.deq_valid_o(deq_valid_o),.deq_ready_i(deq_ready_i),
  .icache_req_allowed_o(),.kill_i(boundary),.ftq_head_i(head_i),.perf_o(fb_perf));
 fetch_return_queue #(.CFG(O3_CFG.fe)) rq(.clk_i(clk_i),.rst_i(rst_i),
  .rsv_ready_o(rq_reserve_ready_o),.rsv_idx_o(),.rsv_fire_i(rsv_i),.rsv_req_i(rq_req),
  .resp_i(rq_resp),.ftq_brief_rd_valid_o(),.ftq_brief_rd_id_o(),.ftq_brief_i(brief),
  .deq_valid_o(rq_valid_o),.deq_ready_i(rq_ready_i),.deq_o(rq_out),.deq_brief_o(),
  .kill_i(boundary),.ftq_head_i(head_i),.perf_o());
 csr_file #(.CFG(O3_CFG.be)) csr(.clk(clk_i),.rst(rst_i),.req_valid_i(csr_valid_i),
  .req_i(csr_req),.resp_o(csr_resp),.retire_count_i('0),.fe_perf_i(sum_perf),.be_perf_i('0),
  .write_value_o(),.fp_retire_i('0),.frm_o(),.fs_o(),.trap_update_valid_i(1'b0),
  .trap_update_i('0),.trap_target_pc_o(),.trap_update_done_o(),.irq_m_ext_i(1'b0),
  .irq_m_timer_i(1'b0),.irq_m_soft_i(1'b0),.irq_s_ext_i(1'b0),.irq_view_o(),
  .irq_take_o(),.irq_cause_o(),.fe_csr_o(),.pmp_o(),.dmmu_csr_o(),.priv_o());
 for(genvar n=0;n<DELIVER_W;n++) begin
  assign mask_o[n]=delivered[n].valid;assign ids_o[n]=delivered[n].ftq_id;
  assign slots_o[n]=delivered[n].slot;assign next_o[n]=delivered[n].predicted_next_pc;
  assign last_o[n]=delivered[n].ftq_last;assign taken_o[n]=delivered[n].pred_taken;
 end
 assign pd_valid_o=pd.valid;assign kill_o=boundary.valid;
 assign winner_src_o=winner.src;assign winner_id_o=winner.ftq_id;assign target_o=winner.target_pc;
 assign rq_out_id_o=rq_out.ftq_id;assign depth_o=FTQ_DEPTH;assign csr_read_o=csr_resp.rdata;
 assign pd_inc_o=8'(arb_perf[PE_PREDECODE_REDIRECT]);
 assign exec_inc_o=8'(arb_perf[PE_REDIRECT_EXEC]);assign recover_inc_o=8'(arb_perf[PE_RECOVER_CYCLE]);
endmodule
