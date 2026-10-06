module branch_recovery_tb_top
    import o3_pkg::*;
    import o3_types_pkg::*;
(
    input  logic clk_i,
    input  logic rst_i,

    input  logic [FTQ_IDX_W-1:0] head_idx_i,
    input  logic [FTQ_GEN_W-1:0] head_gen_i,
    output int ftq_depth_o,

    input  logic exec_valid_i,
    input  logic exec_mispredict_i,
    input  logic [FTQ_IDX_W-1:0] exec_ftq_idx_i,
    input  logic [FTQ_GEN_W-1:0] exec_ftq_gen_i,
    input  logic [2:0] exec_slot_i,
    input  logic [VADDR_W-1:0] exec_branch_pc_i,
    input  logic [2:0] exec_inst_len_i,
    input  logic [1:0] exec_cfi_type_i,
    input  logic [1:0] exec_ras_action_i,
    input  logic exec_actual_taken_i,
    input  logic [VADDR_W-1:0] exec_actual_target_i,
    input  logic [VADDR_W-1:0] exec_redirect_pc_i,
    input  logic history_done_i,
    input  logic ras_done_i,
    input  logic [FTQ_IDX_W-1:0] ras_done_idx_i,
    input  logic [FTQ_GEN_W-1:0] ras_done_gen_i,
    output logic kill_valid_o,
    output logic bpu_redirect_valid_o,
    output logic [VADDR_W-1:0] bpu_redirect_pc_o,
    output logic snap_req_o,
    output logic recover_busy_o,
    output logic [VADDR_W-1:0] winner_target_o,
    output logic winner_hist_inject_o,
    output logic [FTQ_IDX_W-1:0] snap_idx_o, recover_idx_o,
    output logic [FTQ_GEN_W-1:0] snap_gen_o, recover_gen_o,
    output logic [2:0] kill_slot_o,

    input  logic bu_issue_valid_i,
    input  logic bu_read_grant_i,
    input  logic [VADDR_W-1:0] bu_pc_i,
    input  logic [VADDR_W-1:0] bu_pred_next_i,
    input  logic [2:0] bu_inst_len_i,
    input  logic [FTQ_IDX_W-1:0] bu_ftq_idx_i,
    input  logic [FTQ_GEN_W-1:0] bu_ftq_gen_i,
    input  logic [2:0] bu_slot_i,
    input  logic bu_is_branch_i,
    input  logic bu_is_jal_i,
    input  logic [2:0] bu_cond_i,
    input  logic [2:0] bu_imm_type_i,
    input  logic [20:0] bu_imm_raw_i,
    input  logic bu_rs1_en_i,
    input  logic bu_rs2_en_i,
    input  logic [4:0] bu_rd_i,
    input  logic bu_rd_write_i,
    input  logic [63:0] bu_src1_i,
    input  logic [63:0] bu_src2_i,
    input  logic bu_result_consume_i,
    output logic bu_resolve_valid_o,
    output logic bu_resolve_mispredict_o,
    output logic [2:0] bu_resolve_slot_o,
    output logic [1:0] bu_resolve_cfi_o,
    output logic [1:0] bu_resolve_ras_o,
    output logic [VADDR_W-1:0] bu_resolve_target_o,
    output logic [VADDR_W-1:0] bu_resolve_redirect_o,

    input  logic fb_enq_valid_i,
    input  logic fb_kill_i,
    output logic fb_deq_valid_o,

    input  logic alu_read_grant_i,
    input  logic alu_result_consume_i,
    input  logic [BACKEND_NUM_BRANCH_CHECKPOINTS-1:0] alu_issue_branch_mask_i,
    input  logic [ROB_IDX_W-1:0] alu_issue_rob_i,
    input  logic alu_resolution_valid_i,
    input  logic alu_resolution_mispredict_i,
    input  logic [BR_TAG_W-1:0] alu_resolution_tag_i,
    output logic alu_regread_valid_o, alu_ready_o,
    output logic [ROB_IDX_W-1:0] alu_regread_rob_o,
    output logic [BACKEND_NUM_BRANCH_CHECKPOINTS-1:0] alu_regread_mask_o, alu_result_mask_o,
    output logic alu_result_valid_o,
    output logic [ROB_IDX_W-1:0] alu_result_rob_o
);
    bru_resolve_t exec;
    redirect_req_t winner, redirect_unused;
    fe_kill_t kill;
    ftq_id_t snap_id_unused, ras_id_unused;
    ras_ckpt_t ras_ckpt_unused;
    fe_perf_t redirect_perf_unused;

    always_comb begin
        exec = '0;
        exec.valid = exec_valid_i;
        exec.mispredict = exec_mispredict_i;
        exec.ftq_id = '{gen:exec_ftq_gen_i, idx:exec_ftq_idx_i};
        exec.slot = fetch_slot_t'(exec_slot_i);
        exec.branch_pc = exec_branch_pc_i;
        exec.inst_len = exec_inst_len_i;
        exec.cfi_type = cfi_type_e'(exec_cfi_type_i);
        exec.ras_action = ras_action_e'(exec_ras_action_i);
        exec.actual_taken = exec_actual_taken_i;
        exec.actual_target = exec_actual_target_i;
        exec.redirect_pc = exec_redirect_pc_i;
    end

    redirect_arbiter #(.CFG(o3_cfg_pkg::O3_CFG.fe)) u_redirect (
        .clk_i(clk_i), .rst_i(rst_i),
        .sys_i('0), .exec_i(exec), .predecode_i('0), .slow_i('0),
        .ftq_head_i('{gen:head_gen_i, idx:head_idx_i}),
        .winner_o(winner), .kill_o(kill),
        .bpu_redirect_valid_o(bpu_redirect_valid_o), .bpu_redirect_pc_o(bpu_redirect_pc_o),
        .snap_rd_req_o(snap_req_o), .snap_rd_ftq_id_o(snap_id_unused),
        .history_done_i(history_done_i), .ras_done_i(ras_done_i),
        .recover_busy_o(recover_busy_o), .ras_recover_ckpt_o(ras_ckpt_unused),
        .ftq_ras_ckpt_i('0), .ras_recover_id_o(ras_id_unused),
        .ras_done_id_i('{gen:ras_done_gen_i, idx:ras_done_idx_i}),
        .redirect_o(redirect_unused), .perf_o(redirect_perf_unused)
    );
    assign kill_valid_o = kill.valid;
    assign winner_target_o = winner.target_pc;
    assign winner_hist_inject_o = winner.hist_inject;
    assign ftq_depth_o = FTQ_DEPTH;
    assign snap_idx_o = snap_id_unused.idx;
    assign snap_gen_o = snap_id_unused.gen;
    assign recover_idx_o = ras_id_unused.idx;
    assign recover_gen_o = ras_id_unused.gen;
    assign kill_slot_o = kill.slot;

    renamed_uop_t bu_issue;
    branch_result_t bu_result_unused;
    branch_resolution_t bu_legacy_unused;
    bru_resolve_t bu_resolve;
    logic bu_ready_unused;
    always_comb begin
        bu_issue = '0;
        bu_issue.valid = bu_issue_valid_i;
        bu_issue.pc = bu_pc_i;
        bu_issue.predicted_next_pc = bu_pred_next_i;
        bu_issue.inst_len = bu_inst_len_i;
        bu_issue.ftq_id = '{gen:bu_ftq_gen_i, idx:bu_ftq_idx_i};
        bu_issue.ext.ftq_slot = fetch_slot_t'(bu_slot_i);
        bu_issue.is_branch = bu_is_branch_i;
        bu_issue.is_jal = bu_is_jal_i;
        bu_issue.branch_cond = branch_cond_t'(bu_cond_i);
        bu_issue.imm_type = imm_type_t'(bu_imm_type_i);
        bu_issue.imm_raw = bu_imm_raw_i;
        bu_issue.rs1_read_en = bu_rs1_en_i;
        bu_issue.rs2_read_en = bu_rs2_en_i;
        bu_issue.rd = bu_rd_i;
        bu_issue.rd_write_en = bu_rd_write_i;
        bu_issue.dst_preg = PREG_W'(7);
    end
    branch_unit #(.CFG(o3_cfg_pkg::O3_CFG.be)) u_branch (
        .clk(clk_i), .rst(rst_i), .issue_uop_i(bu_issue),
        .read_grant_i(bu_read_grant_i), .src1_data_i(bu_src1_i), .src2_data_i(bu_src2_i),
        .result_consume_i(bu_result_consume_i), .regread_ready_o(bu_ready_unused),
        .result_o(bu_result_unused), .resolution_o(bu_legacy_unused), .resolve_o(bu_resolve)
    );
    assign bu_resolve_valid_o = bu_resolve.valid;
    assign bu_resolve_mispredict_o = bu_resolve.mispredict;
    assign bu_resolve_slot_o = bu_resolve.slot;
    assign bu_resolve_cfi_o = bu_resolve.cfi_type;
    assign bu_resolve_ras_o = bu_resolve.ras_action;
    assign bu_resolve_target_o = bu_resolve.actual_target;
    assign bu_resolve_redirect_o = bu_resolve.redirect_pc;

    fetch_entry_t fb_enq [o3_cfg_pkg::O3_CFG.fe.fetch.f1_width];
    logic [o3_cfg_pkg::O3_CFG.fe.fetch.f1_width-1:0] fb_enq_valid;
    fetch_entry_t fb_deq [o3_cfg_pkg::O3_CFG.fe.fetch.deliver_width];
    logic fb_enq_ready_unused, fb_icache_unused;
    fe_perf_t fb_perf_unused;
    always_comb begin
        fb_enq = '{default:'0};
        fb_enq_valid = '0;
        fb_enq[0].valid = fb_enq_valid_i;
        fb_enq[0].pc = vaddr_t'(39'h8000_0040);
        fb_enq[0].ftq_id.idx = FTQ_IDX_W'(1);
        fb_enq_valid[0] = fb_enq_valid_i;
    end
    fetch_buffer #(.CFG(o3_cfg_pkg::O3_CFG.fe)) u_fetch_buffer (
        .clk_i(clk_i), .rst_i(rst_i), .flush_i(1'b0),
        .enq_entry_i(fb_enq), .enq_valid_i(fb_enq_valid), .enq_ready_o(fb_enq_ready_unused),
        .deq_entry_o(fb_deq), .deq_valid_o(fb_deq_valid_o), .deq_ready_i(1'b0),
        .icache_req_allowed_o(fb_icache_unused),
        .kill_i('{valid:fb_kill_i, all:1'b0, ftq_id:'0, slot:'0, kill_self:1'b0}),
        .ftq_head_i('0), .perf_o(fb_perf_unused)
    );

    renamed_uop_t alu_issue;
    branch_resolution_t alu_resolution;
    int_execute_result_t alu_result;
    int_regread_pipe_uop_t alu_obs;
    logic alu_ready_unused;
    logic [63:0] alu_exec_unused;
    always_comb begin
        alu_issue = '0;
        alu_issue.valid = alu_read_grant_i;
        alu_issue.instruction_id = 64'(alu_issue_rob_i);
        alu_issue.rob_idx = alu_issue_rob_i;
        alu_issue.rd = 5'd3;
        alu_issue.rd_write_en = 1'b1;
        alu_issue.dst_preg = PREG_W'(3);
        alu_issue.use_imm = 1'b1;
        alu_issue.imm_type = IMM_TYPE_I;
        alu_issue.imm_raw = 21'd1;
        alu_issue.int_alu_op = INT_ALU_OP_ADD;
        alu_issue.branch_mask = alu_issue_branch_mask_i;
        alu_resolution = '0;
        alu_resolution.valid = alu_resolution_valid_i;
        alu_resolution.mispredict = alu_resolution_mispredict_i;
        alu_resolution.branch_tag = alu_resolution_tag_i;
    end
    alu_pipe #(.CFG(o3_cfg_pkg::O3_CFG.be)) u_alu (
        .clk(clk_i), .rst(rst_i), .issue_uop_i(alu_issue),
        .read_grant_i(alu_read_grant_i), .src1_data_i('0), .src2_data_i('0),
        .resolution_i(alu_resolution), .result_consume_i(alu_result_consume_i),
        .regread_ready_o(alu_ready_unused), .result_o(alu_result),
        .obs_regread_o(alu_obs), .obs_exec_result_o(alu_exec_unused)
    );
    assign alu_ready_o = alu_ready_unused;
    assign alu_regread_rob_o = alu_obs.rob_idx;
    assign alu_regread_mask_o = alu_obs.branch_mask;
    assign alu_result_mask_o = alu_result.branch_mask;
    assign alu_regread_valid_o = alu_obs.valid;
    assign alu_result_valid_o = alu_result.valid;
    assign alu_result_rob_o = alu_result.rob_idx;
endmodule
