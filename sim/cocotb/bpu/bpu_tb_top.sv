/** Flatten only public BPU records for cocotb; no DUT state access. */
module bpu_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i,
    input logic [VADDR_W-1:0] boot_pc_i,
    input logic alloc_ready_i,
    input logic [$bits(ftq_id_t)-1:0] alloc_ftq_id_i,
    input logic hold_i, recover_busy_i, kill_valid_i,
    input logic kill_all_i,
    input logic [$bits(ftq_id_t)-1:0] kill_id_i, head_id_i,
    input logic [SLOT_W-1:0] kill_slot_i,
    input logic arb_redirect_valid_i,
    input logic [VADDR_W-1:0] arb_redirect_pc_i,
    input logic train_valid_i,
    input logic [$bits(bpu_train_t)-1:0] train_bits_i,
    input logic hist_restore_valid_i, hist_restore_inject_i,
    input logic [$bits(hist_snapshot_t)-1:0] hist_restore_bits_i,
    input logic [VADDR_W-1:0] hist_branch_i, hist_target_i,
    input logic ras_recover_valid_i,
    input logic [$bits(ftq_id_t)-1:0] ras_recover_id_i,
    input logic [$bits(ras_ckpt_t)-1:0] ras_recover_bits_i,
    input logic [1:0] ras_fix_i,
    input logic [VADDR_W-1:0] ras_push_i,
    output logic [TRAIN_CREDIT_W-1:0] train_free_o,
    output logic alloc_valid_o, train_ready_o,
    output logic [$bits(bpu_pred_t)-1:0] pred_bits_o, slow_pred_bits_o,
    output logic [$bits(hist_snapshot_t)-1:0] snapshot_bits_o,
    output logic [$bits(ras_ckpt_t)-1:0] ras_bits_o,
    output logic slow_valid_o, slow_override_o,
    output logic [$bits(ftq_id_t)-1:0] slow_id_o,
    output logic [$bits(loop_meta_t)-1:0] slow_loop_bits_o,
    output logic [TAGE_META_W-1:0] slow_meta_o,
    output logic [$bits(redirect_req_t)-1:0] override_bits_o,
    output logic [PE_NUM-1:0][PERF_INC_W-1:0] perf_bits_o,
    output logic hist_done_o, ras_done_o,
    output logic [$bits(ftq_id_t)-1:0] ras_done_id_o,
    output logic [31:0] cfg_region_bytes_o, cfg_ras_depth_o,
    output logic [31:0] cfg_fold_w_o, cfg_history_w_o, cfg_perf_inc_w_o
);
    bpu_pred_t pred;
    bpu_slow_t slow;
    redirect_req_t override_req;
    hist_snapshot_t snapshot;
    ras_ckpt_t ras_ckpt;
    bpu #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i), .boot_pc_i(boot_pc_i),
        .alloc_valid_o(alloc_valid_o), .alloc_ready_i(alloc_ready_i),
        .alloc_ftq_id_i(ftq_id_t'(alloc_ftq_id_i)), .alloc_pred_o(pred),
        .alloc_snapshot_o(snapshot), .alloc_ras_ckpt_o(ras_ckpt),
        .slow_o(slow), .override_o(override_req),
        .arb_redirect_valid_i(arb_redirect_valid_i), .arb_redirect_pc_i(arb_redirect_pc_i),
        .recover_busy_i(recover_busy_i),
        .kill_i('{valid:kill_valid_i, all:kill_all_i, ftq_id:ftq_id_t'(kill_id_i), slot:kill_slot_i, kill_self:1'b0}),
        .ftq_head_i(ftq_id_t'(head_id_i)),
        .hist_restore_valid_i(hist_restore_valid_i),
        .hist_restore_snapshot_i(hist_snapshot_t'(hist_restore_bits_i)),
        .hist_restore_inject_i(hist_restore_inject_i),
        .hist_restore_branch_pc_i(hist_branch_i), .hist_restore_target_pc_i(hist_target_i),
        .hist_restore_done_o(hist_done_o), .ras_recover_valid_i(ras_recover_valid_i),
        .ras_recover_id_i(ftq_id_t'(ras_recover_id_i)),
        .ras_recover_ckpt_i(ras_ckpt_t'(ras_recover_bits_i)),
        .ras_fix_i(ras_action_e'(ras_fix_i)), .ras_fix_push_addr_i(ras_push_i),
        .ras_recover_done_o(ras_done_o), .ras_recover_done_id_o(ras_done_id_o),
        .hold_i(hold_i), .train_valid_i(train_valid_i), .train_ready_o(train_ready_o),
        .train_free_o(train_free_o),.train_i(bpu_train_t'(train_bits_i)), .perf_o(perf_bits_o)
    );
    assign pred_bits_o = pred;
    assign snapshot_bits_o = snapshot;
    assign ras_bits_o = ras_ckpt;
    assign slow_valid_o = slow.valid;
    assign slow_pred_bits_o = slow.pred;
    assign slow_id_o = slow.ftq_id;
    assign slow_loop_bits_o=slow.loop_meta;
    assign slow_meta_o = slow.tage_meta;
    assign slow_override_o = slow.override;
    assign override_bits_o = override_req;
    assign cfg_region_bytes_o = REGION_BYTES;
    assign cfg_ras_depth_o = RAS_DEPTH;
    assign cfg_fold_w_o = HIST_FOLD_W;
    assign cfg_history_w_o = HIST_WINDOW*HIST_EVENT_W;
    assign cfg_perf_inc_w_o = PERF_INC_W;
endmodule

/** FTQ public metadata/commit fixture, included in the BPU closure suite. */
module ftq_training_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i, alloc_valid_i,
    input logic [$bits(bpu_pred_t)-1:0] alloc_bits_i, slow_bits_i,
    input logic [$bits(ras_ckpt_t)-1:0] alloc_ras_bits_i,
    output logic alloc_ready_o,
    output logic [$bits(ftq_id_t)-1:0] alloc_id_o, head_id_o,
    input logic slow_valid_i,
    input logic [$bits(ftq_id_t)-1:0] slow_id_i, brief_id_i,
    input logic kill_valid_i, kill_all_i, kill_self_i,
    input logic [$bits(ftq_id_t)-1:0] kill_id_i,
    input logic [SLOT_W-1:0] kill_slot_i,
    input logic [$bits(redirect_req_t)-1:0] winner_bits_i,
    input logic [$bits(bru_resolve_t)-1:0] resolve_bits_i,
    input logic commit_valid_i, commit_last_i,
    input logic [$bits(ftq_id_t)-1:0] commit_id_i,
    input logic [SLOT_W-1:0] commit_slot_i,
    input logic train_ready_i,
    output logic train_valid_o,
    output logic [$bits(bpu_train_t)-1:0] train_bits_o,
    output logic brief_slow_o,
    output logic [$bits(bpu_pred_t)-1:0] brief_pred_bits_o,
    output logic [$bits(ras_ckpt_t)-1:0] brief_ras_bits_o,
    output logic [PE_NUM-1:0][PERF_INC_W-1:0] perf_bits_o,
    output logic [31:0] ftq_depth_o, perf_inc_w_o, fold_w_o, history_w_o, addr_w_o
);
    ftq_commit_t commits [COMMIT_W];
    bpu_slow_t slow;
    ftq_pred_brief_t brief;
    logic snap_req, snap_response_q;
    ftq_id_t snap_id,snap_id_q;
    always_comb begin
        for (int i=0; i<COMMIT_W; i++) commits[i] = '0;
        commits[0] = '{valid:commit_valid_i, ftq_id:ftq_id_t'(commit_id_i),
                       slot:commit_slot_i, region_last:commit_last_i};
        slow = '0;
        slow.valid = slow_valid_i;
        slow.ftq_id = ftq_id_t'(slow_id_i);
        slow.pred = bpu_pred_t'(slow_bits_i);
    end
    always_ff @(posedge clk_i)
        if (rst_i) begin snap_response_q<=0;snap_id_q<='0;end
        else begin snap_response_q<=snap_req;snap_id_q<=snap_id;end
    ftq #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i), .flush_i(1'b0),
        .bpu_valid_i(1'b0), .bpu_entry_i('0), .ifu_ready_i(1'b0),
        .release_count_i('0), .resolution_i('0),
        .alloc_valid_i(alloc_valid_i), .alloc_ready_o(alloc_ready_o),
        .alloc_ftq_id_o(alloc_id_o), .alloc_pred_i(bpu_pred_t'(alloc_bits_i)),
        .alloc_ras_ckpt_i(ras_ckpt_t'(alloc_ras_bits_i)), .slow_i(slow),
        .rq_rsv_ready_i(1'b0), .rq_rsv_idx_i('0), .demand_ready_i(1'b0),
        .epoch_i('0), .pf_ready_i(1'b0), .brief_rd_valid_i(1'b1),
        .brief_rd_id_i(ftq_id_t'(brief_id_i)), .brief_o(brief),
        .resolve_i(bru_resolve_t'(resolve_bits_i)), .commit_i(commits),
        .kill_i('{valid:kill_valid_i, all:kill_all_i, kill_self:kill_self_i,
                  ftq_id:ftq_id_t'(kill_id_i), slot:kill_slot_i}),
        .winner_i(redirect_req_t'(winner_bits_i)), .head_id_o(head_id_o), .age_head_idx_o(),
        .ras_ckpt_rd_id_i(ftq_id_t'(brief_id_i)), .ras_ckpt_rd_o(),
        .snap_train_rd_req_o(snap_req), .snap_train_rd_id_o(snap_id),
        .snap_train_resp_id_i(snap_id_q),.train_free_i(TRAIN_CREDIT_W'(train_ready_i ? 4 : 0)),.snap_train_resp_valid_i(snap_response_q), .snap_train_i('0),
        .bpu_train_valid_o(train_valid_o), .bpu_train_ready_i(train_ready_i),
        .bpu_train_o(train_bits_o), .hold_i(1'b0), .perf_o(perf_bits_o)
    );
    assign brief_slow_o = brief.slow_done;
    assign brief_pred_bits_o = brief.pred;
    assign brief_ras_bits_o = brief.ras_ckpt;
    assign ftq_depth_o = FTQ_DEPTH;
    assign perf_inc_w_o = PERF_INC_W;
    assign fold_w_o = HIST_FOLD_W;
    assign history_w_o = HIST_WINDOW*HIST_EVENT_W;
    assign addr_w_o = VADDR_W;
endmodule
