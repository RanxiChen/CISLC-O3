/** Standalone FTQ edge test; compile with -DO3_FRONTEND_DEBUG. */
module ftq_tb;
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;

    parameter int TEST_DEPTH = 32;
    function automatic frontend_cfg_t test_cfg();
        frontend_cfg_t c;
        c = O3_CFG.fe;
        c.ftq.depth = TEST_DEPTH;
        return c;
    endfunction
    localparam frontend_cfg_t CFG = test_cfg();

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst, alloc_valid, alloc_ready, rq_ready, demand_valid, demand_ready;
    logic pf_valid, pf_ready, brief_rd_valid, snap_req, snap_resp_valid;
    logic bpu_train_valid, bpu_train_ready, hold;
    ftq_id_t alloc_id, pf_id, brief_id, ras_id, head_id, snap_id;
    ftq_id_t id0, id1, id2, id3, id4;
    bpu_pred_t alloc_pred;
    bpu_slow_t slow;
    ras_ckpt_t alloc_ras, ras_read;
    rq_idx_t rq_idx;
    icache_req_t demand;
    xlate_epoch_t epoch;
    vaddr_t pf_base;
    ftq_pred_brief_t brief;
    bru_resolve_t resolve;
    ftq_commit_t commit [COMMIT_W];
    fe_kill_t kill;
    hist_snapshot_t snapshot;
    bpu_train_t train;
    fe_perf_t perf;
    logic [FTQ_IDX_W-1:0] dbg_alloc, dbg_demand, dbg_head;
    logic [$clog2(TEST_DEPTH+1)-1:0] dbg_count;

    ftq #(.CFG(CFG)) dut (
        .clk_i(clk), .rst_i(rst),
        .alloc_valid_i(alloc_valid), .alloc_ready_o(alloc_ready),
        .alloc_ftq_id_o(alloc_id), .alloc_pred_i(alloc_pred),
        .alloc_ras_ckpt_i(alloc_ras), .slow_i(slow),
        .rq_rsv_ready_i(rq_ready), .rq_rsv_idx_i(rq_idx),
        .demand_valid_o(demand_valid), .demand_ready_i(demand_ready),
        .demand_o(demand), .epoch_i(epoch),
        .pf_valid_o(pf_valid), .pf_ready_i(pf_ready),
        .pf_region_base_o(pf_base), .pf_ftq_id_o(pf_id),
        .brief_rd_valid_i(brief_rd_valid), .brief_rd_id_i(brief_id),
        .brief_o(brief), .resolve_i(resolve), .commit_i(commit),
        .kill_i(kill), .head_id_o(head_id),
        .ras_ckpt_rd_id_i(ras_id), .ras_ckpt_rd_o(ras_read),
        .snap_train_rd_req_o(snap_req), .snap_train_rd_id_o(snap_id),
        .snap_train_resp_valid_i(snap_resp_valid), .snap_train_i(snapshot),
        .bpu_train_valid_o(bpu_train_valid), .bpu_train_ready_i(bpu_train_ready),
        .bpu_train_o(train), .hold_i(hold), .perf_o(perf),
        .dbg_alloc_tail_o(dbg_alloc), .dbg_ifu_head_o(dbg_demand),
        .dbg_release_head_o(dbg_head), .dbg_allocated_count_o(dbg_count)
    );

    function automatic bpu_pred_t prediction(input vaddr_t pc);
        bpu_pred_t p;
        p = '0;
        p.region_base = pc;
        p.next_pc = pc + 16;
        return p;
    endfunction

    task automatic tick();
        @(posedge clk);
        #1;
    endtask

    task automatic allocate(input vaddr_t pc, output ftq_id_t id);
        @(negedge clk);
        alloc_valid = 1'b1;
        alloc_pred = prediction(pc);
        alloc_ras.top_idx = '0;
        alloc_ras.count = RAS_CNT_W'(1);
        alloc_ras.top_addr = pc + 4;
        #1;
        assert (alloc_ready) else $fatal(1, "allocation blocked at pc=%h", pc);
        id = alloc_id;
        tick();
        alloc_valid = 1'b0;
    endtask

    task automatic train_head(input ftq_id_t id, input slot_mask_t br_mask);
        #1;
        assert (snap_req && snap_id == id) else $fatal(1, "snapshot request identity");
        tick(); // snapshot store samples the request; FTQ enters WAIT
        @(negedge clk);
        snap_resp_valid = 1'b1;
        snapshot = '0;
        snapshot.events[0] = HIST_EVENT_W'('h5a);
        tick(); // FTQ captures snapshot and forms a stable training request
        snap_resp_valid = 1'b0;
        assert (bpu_train_valid && train.br_commit_mask == br_mask &&
                train.ctx.events[0] == HIST_EVENT_W'('h5a))
            else $fatal(1, "training payload mismatch");
        tick(); // BPU not ready: head and payload must remain
        assert (bpu_train_valid && head_id == id) else $fatal(1, "training backpressure");
        @(negedge clk);
        bpu_train_ready = 1'b1;
        tick();
        bpu_train_ready = 1'b0;
    endtask

    initial begin
        rst = 1'b1;
        alloc_valid = 1'b0;
        alloc_pred = '0;
        alloc_ras = '0;
        slow = '0;
        rq_ready = 1'b0;
        rq_idx = '0;
        demand_ready = 1'b0;
        pf_ready = 1'b0;
        epoch = '0;
        brief_rd_valid = 1'b0;
        brief_id = '0;
        ras_id = '0;
        resolve = '0;
        kill = '0;
        snap_resp_valid = 1'b0;
        snapshot = '0;
        bpu_train_ready = 1'b0;
        hold = 1'b0;
        for (int lane = 0; lane < COMMIT_W; lane++) commit[lane] = '0;
        tick();
        @(negedge clk);
        rst = 1'b0;
        #1;
        assert (dbg_count == 0 && alloc_ready && !demand_valid)
            else $fatal(1, "reset state");

        allocate('h1000, id0);
        allocate('h1010, id1);
        assert (id0.idx != id1.idx && head_id == id0 && dbg_count == 2)
            else $fatal(1, "allocation order");
        ras_id = id0;
        #1;
        assert (ras_read.top_addr == 'h1004) else $fatal(1, "RAS checkpoint read");

        @(negedge clk);
        rq_ready = 1'b1;
        rq_idx = rq_idx_t'(2);
        #1;
        assert (demand_valid && demand.ftq_id == id0 && demand.rq_idx == 2)
            else $fatal(1, "first demand request");
        tick(); // stalled: capture the exact request
        @(negedge clk);
        rq_idx = rq_idx_t'(3);
        #1;
        assert (demand_valid && demand.rq_idx == 2)
            else $fatal(1, "demand changed under backpressure");
        demand_ready = 1'b1;
        tick();
        demand_ready = 1'b0;
        assert (demand_valid && demand.ftq_id == id1 && dbg_count == 2)
            else $fatal(1, "demand must not release FTQ slot");

        @(negedge clk);
        pf_ready = 1'b1;
        #1;
        assert (pf_valid && pf_id == id0) else $fatal(1, "prefetch cursor start");
        tick();
        assert (pf_valid && pf_id == id1) else $fatal(1, "prefetch cursor advance");
        pf_ready = 1'b0;

        @(negedge clk);
        slow.valid = 1'b1;
        slow.ftq_id = id0;
        slow.pred = prediction('h1000);
        slow.pred.next_pc = 'h5000;
        slow.tage_meta = tage_meta_t'('h55);
        tick();
        slow = '0;
        brief_rd_valid = 1'b1;
        brief_id = id0;
        #1;
        assert (brief.slow_done && brief.pred.next_pc == 'h5000)
            else $fatal(1, "slow result not visible");

        @(negedge clk);
        resolve.valid = 1'b1;
        resolve.ftq_id = id0;
        resolve.slot = fetch_slot_t'(2);
        resolve.cfi_type = CFI_BR;
        resolve.actual_taken = 1'b1;
        resolve.actual_target = 'h5000;
        commit[0].valid = 1'b1;
        commit[0].ftq_id = id0;
        commit[0].slot = fetch_slot_t'(2);
        commit[0].region_last = 1'b1;
        commit[1].valid = 1'b1;
        commit[1].ftq_id = id1;
        commit[1].region_last = 1'b1;
        tick();
        resolve = '0;
        for (int lane = 0; lane < COMMIT_W; lane++) commit[lane] = '0;
        train_head(id0, slot_mask_t'(1 << 2));
        assert (head_id == id1 && dbg_count == 1) else $fatal(1, "first train release");
        train_head(id1, '0);
        assert (dbg_count == 0 && alloc_ready) else $fatal(1, "second train release");

        allocate('h1020, id2);
        allocate('h1030, id3);
        allocate('h1040, id4);
        @(negedge clk);
        kill.valid = 1'b1;
        kill.ftq_id = id3;
        kill.slot = fetch_slot_t'(1);
        alloc_valid = 1'b1; // kill must suppress this same-edge allocation
        #1;
        assert (!alloc_ready && !demand_valid) else $fatal(1, "kill priority");
        tick();
        kill = '0;
        alloc_valid = 1'b0;
        brief_id = id4;
        #1;
        assert (dbg_count == 2 && !brief.slow_done && brief.ftq_id == '0 &&
                alloc_id.idx == id4.idx && alloc_id.gen != id4.gen)
            else $fatal(1, "younger kill or generation reuse");

        @(negedge clk);
        kill.valid = 1'b1;
        kill.all = 1'b1;
        tick();
        kill = '0;
        #1;
        assert (dbg_count == 0 && alloc_ready) else $fatal(1, "kill all");
        for (int n = 0; n < TEST_DEPTH; n++) begin
            ftq_id_t unused_id;
            allocate(vaddr_t'('h2000 + 16*n), unused_id);
        end
        #1;
        assert (dbg_count == $clog2(TEST_DEPTH+1)'(TEST_DEPTH) && !alloc_ready)
            else $fatal(1, "full capacity");
        $display("FTQ_PASS depth=%0d", TEST_DEPTH);
        $finish;
    end
endmodule
