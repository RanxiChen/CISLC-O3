module loop_tb_top import o3_types_pkg::*; (
 input logic clk_i,rst_i,input vaddr_t lookup_pc_i,pc_i,
 output logic hit_o,output logic [LOOP_IDX_W-1:0] idx_o,
 input logic query_hit_i,input logic [LOOP_IDX_W-1:0] query_idx_i,input fetch_slot_t entry_slot_i,
 input logic [REGION_SLOTS-1:0] br_mask_i,input logic disable_i,
 output logic applicable_o,use_o,pred_o,output fetch_slot_t slot_o,output loop_ckpt_t ckpt_o,
 input logic spec_i,spec_taken_i,
 input logic recover_i,input loop_ckpt_t recover_ckpt_i,input logic [LOOP_IDX_W-1:0] recover_idx_i,
 input fetch_slot_t recover_slot_i,winner_slot_i,input logic recover_upd_i,recover_taken_i,kill_self_i,exec_valid_i,exec_taken_i,
 input logic [1:0] source_i,
 input logic train_i,input vaddr_t train_pc_i,input logic train_hit_i,input logic [LOOP_IDX_W-1:0] train_idx_i,
 input fetch_slot_t train_slot_i,input logic train_use_i,train_pred_i,input slot_mask_t commit_i,taken_i,input tage_meta_t tage_meta_i,
 output logic [LOOP_ENTRIES-1:0] mon_valid_o,
 output logic [LOOP_ENTRIES-1:0][LOOP_ITER_BITS-1:0] mon_past_o,mon_commit_o,
 output logic [LOOP_ENTRIES-1:0][1:0] mon_conf_o,output logic [LOOP_ENTRIES-1:0][2:0] mon_age_o
);
 loop_train_t pred;
 loop_predictor #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut(.clk_i(clk_i),.rst_i(rst_i),.lookup_pc_i(lookup_pc_i),.lookup_hit_o(hit_o),.lookup_idx_o(idx_o),
 .query_hit_i(query_hit_i),.query_idx_i(query_idx_i),.query_pc_i(pc_i),.entry_slot_i(entry_slot_i),.btb_i('{cfi_type:CFI_NONE,ras_action:RAS_NONE,hit:1'b1,br_mask:br_mask_i,default:'0}),.fe_feat_i('{loop_dis:disable_i,default:'0}),
 .prediction_o(pred),.ckpt_o(ckpt_o),.spec_valid_i(spec_i),.spec_taken_i(spec_taken_i),
 .recover_valid_i(recover_i),.recover_meta_i('{train:'{idx:recover_idx_i,slot:recover_slot_i,default:'0},upd_valid:recover_upd_i,upd_taken:recover_taken_i,ckpt:recover_ckpt_i}),
 .winner_i('{sys_kind:SYS_EXCEPTION,ras_fix:RAS_NONE,src:redirect_src_e'(source_i),slot:winner_slot_i,kill_self:kill_self_i,exec_br_valid:exec_valid_i,exec_br_taken:exec_taken_i,default:'0}),
 .train_valid_i(train_i),.train_i('{cfi_type:CFI_NONE,ras_action:RAS_NONE,region_base:train_pc_i,loop_train:'{hit:train_hit_i,idx:train_idx_i,slot:train_slot_i,used:train_use_i,pred:train_pred_i},br_commit_mask:commit_i,br_taken_mask:taken_i,tage_meta:tage_meta_i,default:'0}));
 assign applicable_o=pred.hit;assign use_o=pred.used;assign pred_o=pred.pred;assign slot_o=pred.slot;
 for(genvar n=0;n<LOOP_ENTRIES;n++) begin
  assign mon_valid_o[n]=dut.rows_q[n].valid;assign mon_past_o[n]=dut.rows_q[n].past_iter;
  assign mon_commit_o[n]=dut.rows_q[n].commit_iter;assign mon_conf_o[n]=dut.rows_q[n].conf;assign mon_age_o[n]=dut.rows_q[n].age;
 end
endmodule
