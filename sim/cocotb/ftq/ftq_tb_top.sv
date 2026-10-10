module ftq_tb_top import o3_types_pkg::*; (
 input logic clk_i,rst_i,alloc_valid_i,output logic alloc_ready_o,
 input vaddr_t alloc_pc_i,output ftq_id_t alloc_id_o,
 input logic slow_valid_i,input ftq_id_t slow_id_i,input vaddr_t slow_pc_i,
 input logic demand_ready_i,rq_ready_i,output logic demand_valid_o,output vaddr_t demand_pc_o,
 input logic resolve_valid_i,input ftq_id_t resolve_id_i,input fetch_slot_t resolve_slot_i,
 input logic resolve_taken_i,resolve_wrong_i,
 input logic [COMMIT_W-1:0] commit_valid_i,input logic [COMMIT_W*$bits(ftq_id_t)-1:0] commit_ids_i,
 input logic [COMMIT_W*SLOT_W-1:0] commit_slots_i,input logic [COMMIT_W-1:0] commit_last_i,
 input logic [TRAIN_CREDIT_W-1:0] train_free_i,
 input logic train_ready_i,output logic train_valid_o,output vaddr_t train_pc_o,
 output logic train_cfi_valid_o,output slot_mask_t train_mask_o,
 input logic kill_valid_i,kill_all_i,kill_self_i,input ftq_id_t kill_id_i,input fetch_slot_t kill_slot_i,
 input logic pf_ready_i,output logic pf_valid_o,output vaddr_t pf_pc_o,
 output logic [5:0] occupancy_o,
 output logic [FTQ_IDX_W-1:0] age_head_idx_o,
 output ftq_id_t head_id_o
);
 bpu_pred_t alloc_pred; bpu_slow_t slow;bru_resolve_t resolve;ftq_commit_t commits[COMMIT_W];fe_kill_t kill;
 icache_req_t demand;bpu_train_t train;ftq_id_t head,snap_id,snap_resp;hist_snapshot_t snap;logic snap_req,snap_valid;
 always_comb begin
  alloc_pred='0;alloc_pred.region_base=alloc_pc_i;alloc_pred.next_pc=alloc_pc_i+16;
  slow='0;slow.valid=slow_valid_i;slow.ftq_id=slow_id_i;slow.pred.region_base=slow_pc_i;slow.pred.next_pc=slow_pc_i+16;
  resolve='0;resolve.valid=resolve_valid_i;resolve.ftq_id=resolve_id_i;resolve.slot=resolve_slot_i;
  resolve.cfi_type=CFI_BR;resolve.actual_taken=resolve_taken_i;resolve.mispredict=resolve_wrong_i;
  resolve.actual_target=64'h80000100;resolve.branch_pc=alloc_pc_i+64'(resolve_slot_i)*2;resolve.inst_len=4;
  for(int n=0;n<COMMIT_W;n++) commits[n]='{valid:commit_valid_i[n],ftq_id:ftq_id_t'(commit_ids_i[n*$bits(ftq_id_t)+:$bits(ftq_id_t)]),slot:fetch_slot_t'(commit_slots_i[n*SLOT_W+:SLOT_W]),region_last:commit_last_i[n]};
  kill='{valid:kill_valid_i,all:kill_all_i,kill_self:kill_self_i,ftq_id:kill_id_i,slot:kill_slot_i};
 end
 history_snapshot_store #(.CFG(o3_cfg_pkg::O3_CFG.fe)) snapshots(.clk_i(clk_i),.rst_i(rst_i),
  .wr_valid_i(alloc_valid_i && alloc_ready_o),.wr_ftq_id_i(alloc_id_o),.wr_snapshot_i('0),
  .rd_recover_req_i(1'b0),.rd_recover_ftq_id_i('0),.rd_recover_resp_valid_o(),.rd_recover_snapshot_o(),
  .rd_train_req_i(snap_req),.rd_train_ftq_id_i(snap_id),.rd_train_resp_id_o(snap_resp),.rd_train_resp_valid_o(snap_valid),.rd_train_snapshot_o(snap));
 ftq #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut(.clk_i(clk_i),.rst_i(rst_i),
  .alloc_valid_i(alloc_valid_i),.alloc_ready_o(alloc_ready_o),.alloc_ftq_id_o(alloc_id_o),.alloc_pred_i(alloc_pred),.alloc_ras_ckpt_i('0),
  .slow_i(slow),.rq_rsv_ready_i(rq_ready_i),.rq_rsv_idx_i('0),.demand_valid_o(demand_valid_o),.demand_ready_i(demand_ready_i),.demand_o(demand),.epoch_i('0),
  .pf_valid_o(pf_valid_o),.pf_ready_i(pf_ready_i),.pf_region_base_o(pf_pc_o),.pf_ftq_id_o(),
  .brief_rd_valid_i(1'b0),.brief_rd_id_i('0),.brief_o(),.resolve_i(resolve),.commit_i(commits),.kill_i(kill),.winner_i('0),.head_id_o(head),.age_head_idx_o(),
  .ras_ckpt_rd_id_i('0),.ras_ckpt_rd_o(),.snap_train_rd_req_o(snap_req),.snap_train_rd_id_o(snap_id),
  .snap_train_resp_id_i(snap_resp),.train_free_i(train_free_i),.snap_train_resp_valid_i(snap_valid),.snap_train_i(snap),.bpu_train_valid_o(train_valid_o),.bpu_train_ready_i(train_ready_i),.bpu_train_o(train),.hold_i(1'b0),.perf_o());
 assign demand_pc_o=demand.region_base;assign train_pc_o=train.region_base;
 assign train_cfi_valid_o=train.cfi_valid;assign train_mask_o=train.br_commit_mask;assign occupancy_o=6'(dut.count_q);
 assign age_head_idx_o=dut.age_head_idx_o;assign head_id_o=head;
endmodule
