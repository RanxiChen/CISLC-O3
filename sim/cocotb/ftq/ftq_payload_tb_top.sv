module ftq_payload_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i, alloc_valid_i,
    input bpu_pred_t alloc_pred_i,
    input ras_ckpt_t alloc_ras_i,
    input bpu_slow_t slow_i,
    input bru_resolve_t resolve_i,
    input redirect_req_t winner_i,
    input fe_kill_t kill_i,
    input ftq_commit_t commit_i,
    input ftq_id_t read_id_i,
    input logic demand_ready_i, pf_ready_i,
    output ftq_id_t alloc_id_o,
    output logic alloc_ready_o,
    output logic [$bits(bpu_slow_t)-1:0] slow_id_mask_o, slow_valid_mask_o,
    output logic [$bits(bru_resolve_t)-1:0] resolve_id_mask_o, resolve_valid_mask_o,
    output logic [$bits(ftq_commit_t)-1:0] commit_id_mask_o, commit_valid_mask_o
);
    ftq_commit_t commits [COMMIT_W];
    logic snap_req, snap_valid;
    ftq_id_t snap_id, response_id;
    for (genvar i = 0; i < COMMIT_W; i++) assign commits[i] = i == 0 ? commit_i : ftq_commit_t'(0);
    always_ff @(posedge clk_i) begin
        if (rst_i) begin snap_valid <= 1'b0; response_id <= '0; end
        else begin snap_valid <= snap_req; response_id <= snap_id; end
    end
    always_comb begin
        bpu_slow_t s;
        bru_resolve_t r;
        ftq_commit_t c;
        s = '0; s.ftq_id = '1; slow_id_mask_o = s;
        s = '0; s.valid = 1; slow_valid_mask_o = s;
        r = '0; r.ftq_id = '1; resolve_id_mask_o = r;
        r = '0; r.valid = 1; resolve_valid_mask_o = r;
        c = '0; c.ftq_id = '1; commit_id_mask_o = c;
        c = '0; c.valid = 1; commit_valid_mask_o = c;
    end
    ftq #(.CFG(O3_CFG.fe)) dut (
        .clk_i, .rst_i, .flush_i(1'b0),
        .bpu_valid_i(1'b0), .bpu_entry_i('0), .ifu_ready_i(1'b0), .release_count_i('0), .resolution_i('0),
        .alloc_valid_i, .alloc_ready_o, .alloc_ftq_id_o(alloc_id_o), .alloc_pred_i,
        .alloc_ras_ckpt_i(alloc_ras_i), .slow_i,
        .rq_rsv_ready_i(1'b1), .rq_rsv_idx_i('0), .demand_ready_i, .epoch_i('0), .pf_ready_i,
        .brief_rd_valid_i(1'b1), .brief_rd_id_i(read_id_i), .resolve_i, .commit_i(commits),
        .kill_i, .winner_i, .age_head_idx_o(), .ras_ckpt_rd_id_i(read_id_i),
        .snap_train_rd_req_o(snap_req), .snap_train_rd_id_o(snap_id),
        .snap_train_resp_valid_i(snap_valid), .snap_train_resp_id_i(response_id),
        .train_free_i(TRAIN_CREDIT_W'(4)), .snap_train_i('0), .bpu_train_ready_i(1'b1), .hold_i(1'b0)
    );
endmodule
