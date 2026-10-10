/** L7a combinational slow check. Input validity is owned by BPU p2;
 * kill_i never gates these outputs, avoiding BPU -> arbiter -> kill loops.
 * Ownerless candidates follow the sequential path (U1/U17).
 */
module bpu_slow_check
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic          clk_i,
    input  logic          rst_i,

    // 与慢结果对齐的同一区域快预测及其身份
    input  logic          fast_valid_i,
    input  ftq_id_t       fast_ftq_id_i,
    input  bpu_pred_t     fast_i,
    input  ras_ckpt_t     fast_ras_ckpt_i,

    input  logic          btb_valid_i,
    input  btb_resp_t     btb_i,
    input  logic          tage_valid_i,
    input  tage_resp_t    tage_i,

    input loop_train_t loop_i='0,
    input  fe_kill_t      kill_i,

    output bpu_slow_t     slow_o,
    output redirect_req_t override_o,

    output fe_perf_t      perf_o
);
    bpu_pred_t pred;
    slot_mask_t candidates, first_candidate;
    logic found, owner_selected, disagree, use_ras;
    vaddr_t owner_target, fallthrough_pc, owner_branch_pc, owner_push_pc;
    assign fallthrough_pc = fast_i.region_base + vaddr_t'(CFG.fetch.region_bytes);
    assign use_ras = (btb_i.ras_action == RAS_POP || btb_i.ras_action == RAS_POP_PUSH)
        && fast_ras_ckpt_i.count != '0;
    assign owner_target = use_ras ? fast_ras_ckpt_i.top_addr : btb_i.target;
    // These addresses depend only on aligned BTB/fast metadata. Compute them
    // in parallel with TAGE selection; late direction bits only select a mux.
    assign owner_branch_pc = btb_i.is_edge ? fast_i.region_base-vaddr_t'(2)
        : fast_i.region_base+vaddr_t'(2*int'(btb_i.cfi_slot));
    assign owner_push_pc = owner_branch_pc + vaddr_t'(btb_i.cfi_is_rvc ? 2 : 4);
    for (genvar slot=0; slot<REGION_SLOTS; slot++) begin : g_candidate
        logic in_range, taken;
        assign in_range = slot >= int'(fast_i.entry_slot);
        assign taken = loop_i.used && loop_i.slot==fetch_slot_t'(slot) ? loop_i.pred : tage_i.taken_mask[slot];
        assign candidates[slot] = btb_i.hit && in_range &&
            ((btb_i.br_mask[slot] && taken) || btb_i.jal_mask[slot]
             || (btb_i.cfi_type==CFI_JALR && btb_i.cfi_slot==fetch_slot_t'(slot)));
        if (slot==0) assign first_candidate[slot]=candidates[slot];
        else assign first_candidate[slot]=candidates[slot] && !(|candidates[slot-1:0]);
    end
    assign found = |candidates;
    assign owner_selected = first_candidate[btb_i.cfi_slot] && btb_i.cfi_type != CFI_NONE;
    always_comb begin
        pred = '0;
        pred.region_base = fast_i.region_base;
        pred.entry_slot = fast_i.entry_slot;
        pred.br_mask = btb_i.hit ? btb_i.br_mask : '0;
        pred.jal_mask = btb_i.hit ? btb_i.jal_mask : '0;
        for (int slot=0; slot<REGION_SLOTS; slot++) begin
            pred.br_mask[slot] &= slot >= int'(fast_i.entry_slot);
            pred.jal_mask[slot] &= slot >= int'(fast_i.entry_slot);
        end
        pred.raw_pred_taken = found;
        pred.target_missing = found && !owner_selected;
        pred.next_pc = fallthrough_pc;
        if (owner_selected) begin
            pred.cfi_valid = 1'b1;
            pred.cfi_slot = btb_i.cfi_slot;
            pred.cfi_type = btb_i.cfi_type;
            pred.ras_action = btb_i.ras_action;
            pred.cfi_is_rvc = btb_i.cfi_is_rvc;
            pred.is_edge = btb_i.is_edge;
            pred.cfi_target = owner_target;
            pred.next_pc = owner_target;
        end
        disagree = (pred.cfi_valid != fast_i.cfi_valid)
                 || (pred.cfi_valid && (pred.cfi_slot != fast_i.cfi_slot
                     || pred.cfi_type != fast_i.cfi_type || pred.ras_action != fast_i.ras_action
                     || pred.cfi_is_rvc != fast_i.cfi_is_rvc || pred.is_edge != fast_i.is_edge
                     || pred.next_pc != fast_i.next_pc))
                 || (!pred.cfi_valid && pred.next_pc != fast_i.next_pc);
        slow_o = '0;
        override_o = '0;
        perf_o = '0;
        if (fast_valid_i && !rst_i) begin
            slow_o.valid = 1'b1;
            slow_o.ftq_id = fast_ftq_id_i;
            slow_o.pred = pred;
            slow_o.tage_meta = tage_i.meta;
            slow_o.override = disagree;
            override_o.valid = disagree;
            override_o.src = REDIR_SLOW;
            override_o.ftq_id = fast_ftq_id_i;
            override_o.slot = pred.cfi_valid ? pred.cfi_slot : fetch_slot_t'(REGION_SLOTS-1);
            override_o.target_pc = pred.next_pc;
            override_o.hist_inject = pred.cfi_valid && pred.cfi_type == CFI_BR;
            override_o.hist_branch_pc = owner_selected ? owner_branch_pc : fast_i.region_base;
            override_o.hist_target_pc = pred.cfi_target;
            override_o.ras_fix = pred.cfi_valid ? pred.ras_action : RAS_NONE;
            override_o.ras_push_addr = owner_selected ? owner_push_pc : fast_i.region_base+vaddr_t'(4);
            perf_o[PE_BTB_HIT] = PERF_INC_W'(btb_i.hit);
            perf_o[PE_TARGET_MISSING] = PERF_INC_W'(pred.target_missing);
            perf_o[PE_FAST_SLOW_DISAGREE] = PERF_INC_W'(disagree);
        end
    end
endmodule
