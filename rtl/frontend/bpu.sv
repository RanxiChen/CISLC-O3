/** L7a BPU: one fast action per allocation, BTB/TAGE checked at N+2.
 * Slow outputs depend only on the aligned query registers, never on kill_i.
 * Tests: sim/cocotb/bpu/ and sim/cocotb/bpu_slow_check/.
 */
module bpu
    import o3_types_pkg::*;
#(parameter o3_cfg_pkg::frontend_cfg_t CFG) (
    input logic clk_i, rst_i,
    input  vaddr_t          boot_pc_i,

    // 分配到 FTQ：快预测、入口历史快照、RAS 块前标记
    output logic                          alloc_valid_o,
    input  logic                          alloc_ready_i,
    input  ftq_id_t         alloc_ftq_id_i,     // FTQ 下一次分配的身份
    output bpu_pred_t       alloc_pred_o,
    output hist_snapshot_t  alloc_snapshot_o,
    output ras_ckpt_t       alloc_ras_ckpt_o,

    // 慢预测
    output bpu_slow_t       slow_o,
    output redirect_req_t   override_o,

    // D24 赢家与恢复
    input  logic                          arb_redirect_valid_i,
    input  vaddr_t          arb_redirect_pc_i,
    input  logic                          recover_busy_i,
    input  fe_kill_t        kill_i,
    input  logic                          hist_restore_valid_i,
    input  hist_snapshot_t  hist_restore_snapshot_i,
    input  logic                          hist_restore_inject_i,
    input  vaddr_t          hist_restore_branch_pc_i,
    input  vaddr_t          hist_restore_target_pc_i,
    output logic                          hist_restore_done_o,
    // D29：RAS 入口索引/占用数/栈顶快速修复；无 undo log，无提交释放端口。
    input  logic                          ras_recover_valid_i,
    input  ftq_id_t         ras_recover_id_i,
    input  ras_ckpt_t       ras_recover_ckpt_i,
    input  ras_action_e     ras_fix_i,
    input  vaddr_t          ras_fix_push_addr_i,
    output logic                          ras_recover_done_o,
    output ftq_id_t         ras_recover_done_id_o,

    // 同步期间暂停预测（frontend_sync_ctrl）
    input  logic                          hold_i,

    // 提交训练
    input  logic                          train_valid_i,
    output logic                          train_ready_o,
    input  bpu_train_t      train_i,

    output fe_perf_t        perf_o
);


    typedef struct packed {
        logic valid;
        ftq_id_t id;
        bpu_pred_t fast;
        ras_ckpt_t ras_before;
    } query_t;
    query_t p1_q, p2_q;
    vaddr_t pred_pc_q;
    bpu_pred_t fast;
    btb_resp_t btb_resp, btb_q;
    tage_resp_t tage_resp;
    logic alloc_fire, ubtb_hit, btb_valid, btb_valid_q, tage_valid;
    logic ubtb_train_ready, btb_train_ready, tage_train_ready, train_fire;
    vaddr_t ras_top;
    logic ras_top_valid;
    fe_perf_t perf_ras, perf_slow;

    assign alloc_valid_o = !rst_i && !hold_i && !recover_busy_i && !kill_i.valid;
    assign alloc_fire = alloc_valid_o && alloc_ready_i;
    assign train_ready_o = ubtb_train_ready && btb_train_ready && tage_train_ready;
    assign train_fire = train_valid_i && train_ready_o;

    ubtb #(.CFG(CFG)) u_ubtb (
        .clk_i(clk_i), .rst_i(rst_i), .lookup_valid_i(1'b1),
        .lookup_pc_i(pred_pc_q), .stall_i(1'b0), .hit_o(ubtb_hit), .pred_o(fast),
        .train_valid_i(train_fire), .train_ready_o(ubtb_train_ready),
        .train_i(train_i), .perf_o()
    );
    always_comb begin
        alloc_pred_o = fast;
        if (ubtb_hit && fast.cfi_valid &&
            (fast.ras_action == RAS_POP || fast.ras_action == RAS_POP_PUSH)
            && ras_top_valid) begin
            alloc_pred_o.cfi_target = ras_top;
            alloc_pred_o.next_pc = ras_top;
        end
    end

    branch_history #(.CFG(CFG)) u_history (
        .clk_i(clk_i), .rst_i(rst_i),
        .push_valid_i(alloc_fire && alloc_pred_o.cfi_valid &&
                      alloc_pred_o.cfi_type == CFI_BR && !alloc_pred_o.target_missing),
        .push_branch_pc_i((alloc_pred_o.is_edge ? alloc_pred_o.region_base-vaddr_t'(2)
            : alloc_pred_o.region_base+vaddr_t'(2*int'(alloc_pred_o.cfi_slot)))),
        .push_target_pc_i(alloc_pred_o.cfi_target), .cur_o(alloc_snapshot_o),
        .restore_valid_i(hist_restore_valid_i), .restore_snapshot_i(hist_restore_snapshot_i),
        .restore_inject_i(hist_restore_inject_i),
        .restore_branch_pc_i(hist_restore_branch_pc_i),
        .restore_target_pc_i(hist_restore_target_pc_i), .restore_done_o(hist_restore_done_o)
    );
    ras #(.CFG(CFG)) u_ras (
        .clk_i(clk_i), .rst_i(rst_i),
        .op_valid_i(alloc_fire && alloc_pred_o.cfi_valid && alloc_pred_o.ras_action != RAS_NONE),
        .op_action_i(alloc_pred_o.ras_action),
        .op_push_addr_i((alloc_pred_o.is_edge ? alloc_pred_o.region_base-vaddr_t'(2)
            : alloc_pred_o.region_base+vaddr_t'(2*int'(alloc_pred_o.cfi_slot)))
            +vaddr_t'(alloc_pred_o.cfi_is_rvc ? 2:4)),
        .top_o(ras_top), .top_valid_o(ras_top_valid), .ckpt_o(alloc_ras_ckpt_o),
        .recover_valid_i(ras_recover_valid_i), .recover_id_i(ras_recover_id_i),
        .recover_ckpt_i(ras_recover_ckpt_i), .recover_fix_i(ras_fix_i),
        .recover_push_addr_i(ras_fix_push_addr_i), .recover_done_o(ras_recover_done_o),
        .recover_done_id_o(ras_recover_done_id_o), .perf_o(perf_ras)
    );
    main_btb #(.CFG(CFG)) u_main_btb (
        .clk_i(clk_i), .rst_i(rst_i), .s0_valid_i(alloc_fire),
        .s0_region_base_i(alloc_pred_o.region_base), .stall_i(1'b0), .kill_i(1'b0),
        .resp_valid_o(btb_valid), .resp_o(btb_resp), .train_valid_i(train_fire),
        .train_ready_o(btb_train_ready), .train_i(train_i), .perf_o()
    );
    tage #(.CFG(CFG)) u_tage (
        .clk_i(clk_i), .rst_i(rst_i), .s0_valid_i(alloc_fire),
        .s0_region_base_i(alloc_pred_o.region_base), .s0_folds_i(alloc_snapshot_o.folds),
        .stall_i(1'b0), .kill_i(1'b0), .resp_valid_o(tage_valid), .resp_o(tage_resp),
        .train_valid_i(train_fire), .train_ready_o(tage_train_ready), .train_i(train_i), .perf_o()
    );
    bpu_slow_check #(.CFG(CFG)) u_slow_check (
        .clk_i(clk_i), .rst_i(rst_i), .fast_valid_i(p2_q.valid),
        .fast_ftq_id_i(p2_q.id), .fast_i(p2_q.fast), .fast_ras_ckpt_i(p2_q.ras_before),
        .btb_valid_i(btb_valid_q), .btb_i(btb_q), .tage_valid_i(tage_valid),
        .tage_i(tage_resp), .kill_i('0), .slow_o(slow_o),
        .override_o(override_o), .perf_o(perf_slow)
    );

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            pred_pc_q <= boot_pc_i;
            p1_q <= '0;
            p2_q <= '0;
            btb_q <= '0;
            btb_valid_q <= 1'b0;
        end else begin
            if (arb_redirect_valid_i) pred_pc_q <= arb_redirect_pc_i;
            else if (alloc_fire) pred_pc_q <= alloc_pred_o.next_pc;
            if (kill_i.valid) begin
                p1_q <= '0;
                p2_q <= '0;
                btb_q <= '0;
                btb_valid_q <= 1'b0;
            end else begin
                p1_q <= '{valid:alloc_fire, id:alloc_ftq_id_i,
                          fast:alloc_pred_o, ras_before:alloc_ras_ckpt_o};
                p2_q <= p1_q;
                btb_q <= btb_resp;
                btb_valid_q <= btb_valid;
            end
            if (p2_q.valid) begin
                assert (btb_valid_q && tage_valid)
                    else $fatal(1, "BPU slow-query alignment lost");
            end
        end
    end
    always_comb begin
        perf_o = '0;
        for (int evt=0; evt<PE_NUM; evt++)
            perf_o[evt] = perf_ras[evt] + perf_slow[evt];
        perf_o[PE_UBTB_LOOKUP] = PERF_INC_W'(alloc_fire);
        perf_o[PE_UBTB_HIT] = PERF_INC_W'(alloc_fire && ubtb_hit);
    end
endmodule
