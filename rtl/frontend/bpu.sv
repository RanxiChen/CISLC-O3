/** L7a BPU: one fast action per allocation, BTB/TAGE checked at N+2, result/control registered for N+3.
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
    input  ftq_id_t         ftq_head_i = '0,
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

    input fe_feat_t fe_feat_i='0,
    input loop_meta_t loop_recover_meta_i='0,
    input redirect_req_t loop_winner_i='0,
    // 提交训练
    input  logic                          train_valid_i,
    output logic                          train_ready_o,
    output logic [TRAIN_CREDIT_W-1:0] train_free_o,
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
    logic loop_hit,loop_hit_q,loop_spec_valid,loop_path_valid;
    logic [LOOP_IDX_W-1:0] loop_idx,loop_idx_q;
    loop_train_t loop_prediction;
    loop_ckpt_t loop_ckpt;
    bpu_slow_t slow_raw, slow_complete, slow_result_q;
    redirect_req_t override_raw, override_q;
    fe_perf_t slow_perf_q;
    logic p1_killed, p2_killed;
    assign p1_killed = fe_killed_by(kill_i,p1_q.id,fetch_slot_t'(REGION_SLOTS-1),ftq_head_i);
    assign p2_killed = fe_killed_by(kill_i,p2_q.id,fetch_slot_t'(REGION_SLOTS-1),ftq_head_i);
    assign loop_path_valid=p2_q.valid && loop_prediction.hit &&
        (!slow_raw.pred.cfi_valid || loop_prediction.slot<=slow_raw.pred.cfi_slot);
    assign loop_spec_valid=loop_path_valid && !kill_i.valid;
    loop_predictor #(.CFG(CFG)) u_loop(.clk_i(clk_i),.rst_i(rst_i),.lookup_pc_i(p1_q.fast.region_base),
        .lookup_hit_o(loop_hit),.lookup_idx_o(loop_idx),.query_hit_i(loop_hit_q),.query_idx_i(loop_idx_q),
        .query_pc_i(p2_q.fast.region_base),.entry_slot_i(p2_q.fast.entry_slot),.btb_i(btb_q),.fe_feat_i(fe_feat_i),
        .prediction_o(loop_prediction),.ckpt_o(loop_ckpt),.spec_valid_i(loop_spec_valid),
        .spec_taken_i(slow_raw.pred.cfi_valid && slow_raw.pred.cfi_slot==loop_prediction.slot),
        .recover_valid_i(ras_recover_valid_i),.recover_meta_i(loop_recover_meta_i),.winner_i(loop_winner_i),
        .train_valid_i(t1_train_valid_q),.train_i(t1_train_q));
    always_comb begin
        slow_complete=slow_raw;
        slow_complete.loop_meta='{train:loop_prediction,upd_valid:loop_path_valid,
            upd_taken:(slow_raw.pred.cfi_valid && slow_raw.pred.cfi_slot==loop_prediction.slot),ckpt:loop_ckpt};
    end
    // A complete result owns its identity and loop action across this stage.
    // Registered outputs are never combinationally gated by the kill they
    // cause. At capture, discard killed owners while preserving older queries.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin slow_result_q<='0; override_q<='0; slow_perf_q<='0; end
        else begin
            slow_result_q <= p2_killed ? bpu_slow_t'('0) : slow_complete;
            override_q <= p2_killed ? redirect_req_t'('0) : override_raw;
            slow_perf_q <= p2_killed ? fe_perf_t'('0) : perf_slow;
        end
    end
    assign slow_o = rst_i ? bpu_slow_t'('0) : slow_result_q;
    assign override_o = rst_i ? redirect_req_t'('0) : override_q;
    always_ff @(posedge clk_i) begin
        if(rst_i || p1_killed) begin loop_hit_q<=0;loop_idx_q<=0;end
        else begin loop_hit_q<=loop_hit;loop_idx_q<=loop_idx;end
    end
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
    localparam int TD=CFG.ftq.train_queue_depth,TW=$clog2(TD),TCW=$clog2(TD+1);
    bpu_train_t train_queue_q[TD],t1_train_q;
    logic [TW-1:0] train_head_q,train_tail_q;
    logic [TCW-1:0] train_count_q;
    logic train_pop,t1_train_valid_q;
    assign train_ready_o=!rst_i && int'(train_count_q)<TD;
    assign train_free_o=TRAIN_CREDIT_W'(TD-int'(train_count_q));
    assign train_pop=!rst_i && train_count_q!=0 && tage_train_ready && btb_train_ready && ubtb_train_ready;
    always_ff @(posedge clk_i) begin
        if(rst_i) begin train_head_q<=0;train_tail_q<=0;train_count_q<=0;t1_train_valid_q<=0;t1_train_q<='0;end
        else begin
            t1_train_valid_q<=train_pop;
            if(train_pop) begin t1_train_q<=train_queue_q[train_head_q];train_head_q<=TW'((int'(train_head_q)+1)%TD);end
            if(train_fire) begin train_queue_q[train_tail_q]<=train_i;train_tail_q<=TW'((int'(train_tail_q)+1)%TD);end
            case({train_fire,train_pop})
                2'b10:train_count_q<=train_count_q+1'b1;
                2'b01:train_count_q<=train_count_q-1'b1;
                default: ;
            endcase
            assert(!train_pop || (btb_train_ready && tage_train_ready && ubtb_train_ready));
        end
    end
    assign train_fire = train_valid_i && train_ready_o;

    ubtb #(.CFG(CFG)) u_ubtb (
        .clk_i(clk_i), .rst_i(rst_i), .lookup_valid_i(1'b1),
        .lookup_pc_i(pred_pc_q), .stall_i(1'b0), .hit_o(ubtb_hit), .pred_o(fast),
        .train_valid_i(t1_train_valid_q), .train_ready_o(ubtb_train_ready),
        .train_i(t1_train_q), .perf_o()
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

    // PC arithmetic is independent of the CAM hit. Compute each physical
    // slot's branch/return PC from the registered prediction PC, then select.
    vaddr_t fast_region,fast_branch_pc,fast_push_pc,fast_edge_pc;
    vaddr_t branch_at[REGION_SLOTS],push_short_at[REGION_SLOTS],push_long_at[REGION_SLOTS];
    assign fast_region=(pred_pc_q >> $clog2(REGION_BYTES)) << $clog2(REGION_BYTES);
    assign fast_edge_pc=fast_region-vaddr_t'(2);
    for(genvar slot=0;slot<REGION_SLOTS;slot++) begin : g_fast_pc
        assign branch_at[slot]=fast_region+vaddr_t'(2*slot);
        assign push_short_at[slot]=fast_region+vaddr_t'(2*slot+2);
        assign push_long_at[slot]=fast_region+vaddr_t'(2*slot+4);
    end
    always_comb begin
        fast_branch_pc='0;fast_push_pc='0;
        for(int slot=0;slot<REGION_SLOTS;slot++) begin
            fast_branch_pc |= branch_at[slot] & {VADDR_W{alloc_pred_o.cfi_slot==fetch_slot_t'(slot)}};
            fast_push_pc |= (alloc_pred_o.cfi_is_rvc ? push_short_at[slot]:push_long_at[slot])
                & {VADDR_W{alloc_pred_o.cfi_slot==fetch_slot_t'(slot)}};
        end
        if(alloc_pred_o.is_edge) begin
            fast_branch_pc=fast_edge_pc;
            fast_push_pc=alloc_pred_o.cfi_is_rvc ? fast_region:fast_region+vaddr_t'(2);
        end
    end

    branch_history #(.CFG(CFG)) u_history (
        .clk_i(clk_i), .rst_i(rst_i),
        .push_valid_i(alloc_fire && alloc_pred_o.cfi_valid &&
                      alloc_pred_o.cfi_type == CFI_BR && !alloc_pred_o.target_missing),
        .push_branch_pc_i(fast_branch_pc),
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
        .op_push_addr_i(fast_push_pc),
        .top_o(ras_top), .top_valid_o(ras_top_valid), .ckpt_o(alloc_ras_ckpt_o),
        .recover_valid_i(ras_recover_valid_i), .recover_id_i(ras_recover_id_i),
        .recover_ckpt_i(ras_recover_ckpt_i), .recover_fix_i(ras_fix_i),
        .recover_push_addr_i(ras_fix_push_addr_i), .recover_done_o(ras_recover_done_o),
        .recover_done_id_o(ras_recover_done_id_o), .perf_o(perf_ras)
    );
    main_btb #(.CFG(CFG)) u_main_btb (
        .clk_i(clk_i), .rst_i(rst_i), .s0_valid_i(alloc_fire),
        .s0_region_base_i(alloc_pred_o.region_base), .stall_i(1'b0), .kill_i(1'b0),
        .resp_valid_o(btb_valid), .resp_o(btb_resp), .train_valid_i(train_pop),
        .train_ready_o(btb_train_ready), .train_i(train_queue_q[train_head_q]), .perf_o()
    );
    tage #(.CFG(CFG)) u_tage (
        .clk_i(clk_i), .rst_i(rst_i), .s0_valid_i(alloc_fire),
        .s0_region_base_i(alloc_pred_o.region_base), .s0_folds_i(alloc_snapshot_o.folds),
        .stall_i(1'b0), .kill_i(1'b0), .resp_valid_o(tage_valid), .resp_o(tage_resp),
        .train_valid_i(train_pop), .train_ready_o(tage_train_ready), .train_i(train_queue_q[train_head_q]), .perf_o()
    );
    bpu_slow_check #(.CFG(CFG)) u_slow_check (
        .clk_i(clk_i), .rst_i(rst_i), .fast_valid_i(p2_q.valid),
        .fast_ftq_id_i(p2_q.id), .fast_i(p2_q.fast), .fast_ras_ckpt_i(p2_q.ras_before),
        .btb_valid_i(btb_valid_q), .btb_i(btb_q), .tage_valid_i(tage_valid),
        .tage_i(tage_resp),.loop_i(loop_prediction), .kill_i('0), .slow_o(slow_raw),
        .override_o(override_raw), .perf_o(perf_slow)
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
            p1_q <= '{valid:alloc_fire, id:alloc_ftq_id_i,
                      fast:alloc_pred_o, ras_before:alloc_ras_ckpt_o};
            p2_q <= p1_killed ? query_t'('0) : p1_q;
            btb_q <= btb_resp;
            btb_valid_q <= btb_valid && !p1_killed;
            if (p2_q.valid) begin
                assert (btb_valid_q && tage_valid)
                    else $fatal(1, "BPU slow-query alignment lost");
            end
        end
    end
    always_comb begin
        perf_o = '0;
        for (int evt=0; evt<PE_NUM; evt++)
            perf_o[evt] = rst_i ? PERF_INC_W'(0) : perf_ras[evt] + slow_perf_q[evt];
        perf_o[PE_UBTB_LOOKUP] = PERF_INC_W'(alloc_fire);
        perf_o[PE_UBTB_HIT] = PERF_INC_W'(alloc_fire && ubtb_hit);
    end
endmodule
