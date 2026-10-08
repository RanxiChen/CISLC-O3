/** L7c commit-trained loop predictor. Lookup index is registered by BPU;
 * direction validation and an 80-bit pre-update checkpoint are at slow exit.
 * Allocation overrides recovery/speculation for the allocated entry only. */
module loop_predictor import o3_types_pkg::*; #(
 parameter o3_cfg_pkg::frontend_cfg_t CFG
)(input logic clk_i,rst_i,input vaddr_t lookup_pc_i,
 output logic lookup_hit_o,output logic [LOOP_IDX_W-1:0] lookup_idx_o,
 input logic query_hit_i,input logic [LOOP_IDX_W-1:0] query_idx_i,
 input vaddr_t query_pc_i,input fetch_slot_t entry_slot_i,input btb_resp_t btb_i,input fe_feat_t fe_feat_i,
 output loop_train_t prediction_o,output loop_ckpt_t ckpt_o,
 input logic spec_valid_i,spec_taken_i,
 input logic recover_valid_i,input loop_meta_t recover_meta_i,input redirect_req_t winner_i,
 input logic train_valid_i,input bpu_train_t train_i);
 localparam int N=CFG.loop.entries,TB=CFG.loop.tag_bits,IB=CFG.loop.iter_bits,CB=CFG.loop.conf_bits,AB=CFG.loop.age_bits;
 typedef logic [IB-1:0] iter_t;
 typedef struct packed {
  logic valid;logic [TB-1:0] tag;fetch_slot_t slot;logic dir;
  iter_t past_iter,commit_iter,spec_iter;
  logic [CB-1:0] conf;logic [AB-1:0] age;
 } entry_t;
 entry_t rows_q[N],rows_d[N];
 logic [LOOP_IDX_W-1:0] victim_q,victim_d;
 function automatic logic [TB-1:0] tag_of(input vaddr_t pc);
  logic [TB-1:0] tag;tag='0;
  for(int b=$clog2(CFG.fetch.region_bytes);b<VADDR_W;b++) tag[(b-$clog2(CFG.fetch.region_bytes))%TB]^=pc[b];
  return tag;
 endfunction
 function automatic iter_t apply_iter(input iter_t value,input logic taken,input logic dir);
  return taken==dir ? (value=='1 ? value:value+1'b1) : iter_t'(0);
 endfunction
 always_comb begin
  lookup_hit_o=0;lookup_idx_o=0;prediction_o='0;ckpt_o='0;
  for(int n=N-1;n>=0;n--) begin
   ckpt_o[n]=rows_q[n].spec_iter;
   if(rows_q[n].valid && rows_q[n].tag==tag_of(lookup_pc_i)) begin lookup_hit_o=1;lookup_idx_o=LOOP_IDX_W'(n);end
  end
  if(query_hit_i && rows_q[query_idx_i].valid && rows_q[query_idx_i].tag==tag_of(query_pc_i) &&
   rows_q[query_idx_i].slot>=entry_slot_i && btb_i.hit && btb_i.br_mask[rows_q[query_idx_i].slot]) begin
   prediction_o.hit=1;prediction_o.idx=query_idx_i;prediction_o.slot=rows_q[query_idx_i].slot;
   prediction_o.pred=rows_q[query_idx_i].spec_iter==rows_q[query_idx_i].past_iter ? !rows_q[query_idx_i].dir : rows_q[query_idx_i].dir;
   prediction_o.used=rows_q[query_idx_i].conf=='1 && !fe_feat_i.loop_dis;
  end
 end
 always_comb begin : next_state
  int idx,victim,slot;
  logic matched,taken,reapply,wrong;
  idx=0;victim=-1;slot=-1;matched=0;taken=0;reapply=0;wrong=0;
  rows_d=rows_q;victim_d=victim_q;
  if(recover_valid_i) begin
   for(int n=0;n<N;n++) rows_d[n].spec_iter=recover_meta_i.ckpt[n];
   idx=int'(recover_meta_i.train.idx);
   if(recover_meta_i.upd_valid) begin
    reapply=recover_meta_i.train.slot<winner_i.slot ||
        (recover_meta_i.train.slot==winner_i.slot && !winner_i.kill_self && winner_i.src!=REDIR_EXEC);
    taken=recover_meta_i.upd_taken;
    if(recover_meta_i.train.slot==winner_i.slot && !winner_i.kill_self && winner_i.src==REDIR_EXEC && winner_i.exec_br_valid) begin
     reapply=1;taken=winner_i.exec_br_taken;
    end
    if(reapply) rows_d[idx].spec_iter=apply_iter(recover_meta_i.ckpt[idx],taken,rows_q[idx].dir);
   end
  end else if(spec_valid_i && prediction_o.hit) begin
   idx=int'(prediction_o.idx);rows_d[idx].spec_iter=apply_iter(rows_q[idx].spec_iter,spec_taken_i,rows_q[idx].dir);
  end
  if(train_valid_i) begin
   idx=int'(train_i.loop_train.idx);
   matched=train_i.loop_train.hit && rows_q[idx].valid && rows_q[idx].tag==tag_of(train_i.region_base) && rows_q[idx].slot==train_i.loop_train.slot;
   if(matched && train_i.br_commit_mask[train_i.loop_train.slot]) begin
    taken=train_i.br_taken_mask[train_i.loop_train.slot];wrong=tage_final(train_i.tage_meta,int'(train_i.loop_train.slot))!=taken;
    if(taken==rows_q[idx].dir) begin
     if(rows_q[idx].commit_iter=='1) rows_d[idx].valid=0;
     else rows_d[idx].commit_iter=rows_q[idx].commit_iter+1'b1;
    end else begin
     if(rows_q[idx].commit_iter==rows_q[idx].past_iter) begin
      if(rows_q[idx].conf!='1) rows_d[idx].conf=rows_q[idx].conf+1'b1;
     end else begin rows_d[idx].past_iter=rows_q[idx].commit_iter;rows_d[idx].conf=0;end
     rows_d[idx].commit_iter=0;
    end
    if(train_i.loop_train.used) begin
     if(train_i.loop_train.pred!=taken) begin
      rows_d[idx].conf=0;
      // An initial TAGE miss can allocate the opposite orientation. A
      // confident zero-length pattern then predicts only the common exit
      // direction and cannot learn the real backedge count. Relearn on its
      // first contrary outcome; ordinary nonzero loops only lose confidence.
      if(rows_q[idx].past_iter==0 && rows_q[idx].commit_iter==0 && taken==rows_q[idx].dir)
          rows_d[idx].valid=0;
      if(rows_q[idx].age!=0) rows_d[idx].age=rows_q[idx].age-1'b1;
     end else if(wrong && rows_q[idx].age!='1) rows_d[idx].age=rows_q[idx].age+1'b1;
    end
   end else if(!matched) begin
    for(int s=REGION_SLOTS-1;s>=0;s--) if(train_i.br_commit_mask[s] && tage_final(train_i.tage_meta,s)!=train_i.br_taken_mask[s]) slot=s;
    if(slot>=0) begin
     for(int n=N-1;n>=0;n--) if(rows_q[n].age==0) victim=n;
     for(int n=N-1;n>=0;n--) if(!rows_q[n].valid) victim=n;
     if(victim>=0) rows_d[victim]='{valid:1'b1,tag:tag_of(train_i.region_base),slot:fetch_slot_t'(slot),dir:!train_i.br_taken_mask[slot],age:AB'(1<<(AB-1)),default:'0};
     else begin
      if(rows_q[victim_q].age!=0) rows_d[victim_q].age=rows_q[victim_q].age-1'b1;
      victim_d=LOOP_IDX_W'((int'(victim_q)+1)%N);
     end
    end
   end
  end
 end
 always_ff @(posedge clk_i) begin
  if(rst_i) begin rows_q<='{default:'0};victim_q<=0;end
  else begin rows_q<=rows_d;victim_q<=victim_d;end
 end
 initial assert(N==LOOP_ENTRIES && IB==LOOP_ITER_BITS);
endmodule
