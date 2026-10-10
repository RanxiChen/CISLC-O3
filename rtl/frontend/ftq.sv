/**
 * FTQ: single-writer payload memories and an ordered ring controller.
 *
 * Storage / write-port ownership:
 *   alloc_mem    <- BPU allocation: fast prediction and entry RAS checkpoint
 *   slow_mem     <- slow prediction: complete prediction and TAGE/loop metadata
 *   fix_pred_mem <- boundary correction: CFI patch for the retained region
 *   fix_next_mem <- redirect winner: final next PC used by commit statistics
 *   res_mem      <- taken execution resolution: actual CFI information
 * Each memory has one synchronous write address and asynchronous read taps.
 * Read-port replication is left to distributed-RAM inference; no address banks.
 * Payload memories are never reset or cleared on squash. Narrow per-row flags
 * select visible payloads and prevent a reused slot from exposing old contents.
 *
 * Controller: head + occupancy, committed-prefix length, demand/prefetch progress.
 * Allocation and each issuer handle one region/cycle; commit accepts COMMIT_W
 * notifications. A closed region is released only after training acceptance.
 * Kill uses the full boundary identity and ring distance, preserves the closed
 * prefix, and clamps issuer progress to the surviving tail. No age-ordered table
 * search or per-row commit_last/demand_issued/pf_issued state is needed.
 *
 * Read composition is field-specific: fast/slow prediction, optional CFI patch,
 * and narrow masks/validity. The winner's final next PC is a separate value;
 * it must not replace the prediction's next_pc indiscriminately.
 * Priority: release -> slow/winner/resolve -> commit -> kill; allocation/issue
 * occur only without kill. Interface latency and history-store handoff remain.
 * This structural refactor has not established simulation equivalence or PPA.
 */

// 旧合同类型包：固定 32B 块与 16 项深度，不符合 D03/参数化要求，迁移后删除。
package ftq_pkg;
    import o3_pkg::*;

    localparam int FTQ_DEPTH                 = 16;
    localparam int FTQ_BLOCK_BYTES           = 32;
    localparam int FTQ_FETCH_WINDOW_BYTES    = 16;
    localparam int FTQ_BRANCH_SLOT_WIDTH     = 3;
    localparam int FTQ_INDEX_WIDTH           = o3_types_pkg::FTQ_IDX_W;   // 旧合同：只用 idx，无代际
    localparam int FTQ_EXCEPTION_CAUSE_WIDTH = 8;

    typedef logic [PC_WIDTH-1:0]                  ftq_pc_t;
    typedef logic [FTQ_INDEX_WIDTH-1:0]           ftq_idx_t;
    typedef logic [FTQ_BRANCH_SLOT_WIDTH-1:0]     ftq_branch_slot_t;
    typedef logic [FTQ_EXCEPTION_CAUSE_WIDTH-1:0] ftq_exception_cause_t;

    typedef enum logic [2:0] {
        FTQ_BRANCH_NONE = 3'd0,
        FTQ_BRANCH_COND = 3'd1,
        FTQ_BRANCH_JAL  = 3'd2,
        FTQ_BRANCH_JALR = 3'd3,
        FTQ_BRANCH_CALL = 3'd4,
        FTQ_BRANCH_RET  = 3'd5
    } ftq_branch_type_t;

    typedef struct packed {
        logic                       valid;

        ftq_pc_t                    start_pc;
        ftq_pc_t                    end_pc;

        logic                       has_branch;
        ftq_pc_t                    branch_pc;
        ftq_branch_slot_t           branch_slot;
        ftq_branch_type_t           branch_type;

        logic                       pred_taken;
        ftq_pc_t                    target_pc;
        ftq_pc_t                    fallthrough_pc;
        ftq_pc_t                    next_pc;

        logic                       actual_valid;
        ftq_pc_t                    actual_branch_pc;
        ftq_branch_type_t           actual_branch_type;
        logic                       actual_taken;
        ftq_pc_t                    actual_target;

        logic                       exception;
        ftq_exception_cause_t       exception_cause;
    } ftq_entry_t;

endpackage

module ftq
    import ftq_pkg::*;
#(
    parameter  o3_cfg_pkg::frontend_cfg_t CFG,
    localparam int RELEASE_WIDTH = o3_pkg::BACKEND_MACHINE_WIDTH   // 旧合同
)
(
    input  logic       clk_i,
    input  logic       rst_i,
    input  logic       flush_i,

    // ---------------- 旧合同（迁移后删除） ----------------
    // BPU enqueue port
    input  logic       bpu_valid_i,
    output logic       bpu_ready_o,
    input  ftq_entry_t bpu_entry_i,

    // IFU consume port
    output logic       ifu_valid_o,
    input  logic       ifu_ready_i,
    output ftq_entry_t ifu_entry_o,
    output ftq_idx_t   ifu_ftq_idx_o,

    input  logic [$clog2(RELEASE_WIDTH+1)-1:0] release_count_i,
    input  o3_pkg::branch_resolution_t         resolution_i,
    output logic [RELEASE_WIDTH-1:0]           train_valid_o,
    output ftq_entry_t                         train_entry_o [RELEASE_WIDTH-1:0],

    // ---------------- 目标合同 ----------------
    // 分配（BPU 快预测）
    input  logic                            alloc_valid_i,
    output logic                            alloc_ready_o,
    output o3_types_pkg::ftq_id_t           alloc_ftq_id_o,
    input  o3_types_pkg::bpu_pred_t         alloc_pred_i,
    input  o3_types_pkg::ras_ckpt_t         alloc_ras_ckpt_i,

    // 慢预测确认/覆盖
    input  o3_types_pkg::bpu_slow_t         slow_i,

    // demand 游标 → ICache，同拍向返回队列确认预留
    input  logic                            rq_rsv_ready_i,
    input  o3_types_pkg::rq_idx_t           rq_rsv_idx_i,
    output logic                            demand_valid_o,
    input  logic                            demand_ready_i,
    output o3_types_pkg::icache_req_t       demand_o,
    input  o3_types_pkg::xlate_epoch_t      epoch_i,

    // prefetch 游标 → fetch_prefetcher
    output logic                            pf_valid_o,
    input  logic                            pf_ready_i,
    output o3_types_pkg::vaddr_t            pf_region_base_o,
    output o3_types_pkg::ftq_id_t           pf_ftq_id_o,

    // 返回队列出队时读取最终预测摘要
    input  logic                            brief_rd_valid_i,
    input  o3_types_pkg::ftq_id_t           brief_rd_id_i,
    output o3_types_pkg::ftq_pred_brief_t   brief_o,

    // 执行解析与提交
    input  o3_types_pkg::bru_resolve_t      resolve_i,
    input  o3_types_pkg::ftq_commit_t       commit_i [o3_types_pkg::COMMIT_W],

    // D24 取消边界与年龄参照；恢复 R0 读取出错区域的 ras_before={top_idx,count,top_addr}（D29）
    input  o3_types_pkg::fe_kill_t          kill_i,
    input  o3_types_pkg::redirect_req_t    winner_i,
    output o3_types_pkg::ftq_id_t           head_id_o,
    // Circular age origin is a cursor, including when the queue is empty.
    // Keep occupancy/generation qualification out of the global kill path.
    output logic [o3_types_pkg::FTQ_IDX_W-1:0] age_head_idx_o,
    input  o3_types_pkg::ftq_id_t           ras_ckpt_rd_id_i,
    output o3_types_pkg::ras_ckpt_t         ras_ckpt_rd_o,
    output o3_types_pkg::loop_meta_t loop_meta_rd_o,

    // 提交训练：读快照训练上下文，组装 bpu_train_t
    output logic                            snap_train_rd_req_o,
    output o3_types_pkg::ftq_id_t           snap_train_rd_id_o,
    input  logic                            snap_train_resp_valid_i,
    input  o3_types_pkg::ftq_id_t snap_train_resp_id_i,
    input logic [$clog2(CFG.ftq.train_queue_depth+1)-1:0] train_free_i,
    input  o3_types_pkg::hist_snapshot_t    snap_train_i,
    output logic                            bpu_train_valid_o,
    input  logic                            bpu_train_ready_i,
    output o3_types_pkg::bpu_train_t        bpu_train_o,

    input  logic                            hold_i,          // 系统同步期间暂停 demand/prefetch
    output o3_types_pkg::fe_perf_t          perf_o

    `ifdef O3_FRONTEND_DEBUG
    ,output logic       dbg_ifu_fire_o
    ,output logic       dbg_bpu_fire_o
    ,output logic [o3_types_pkg::FTQ_IDX_W-1:0] dbg_alloc_tail_o
    ,output logic [o3_types_pkg::FTQ_IDX_W-1:0] dbg_ifu_head_o
    ,output logic [o3_types_pkg::FTQ_IDX_W-1:0] dbg_release_head_o
    ,output logic [$clog2(CFG.ftq.depth+1)-1:0] dbg_allocated_count_o
    `endif
);

    import o3_types_pkg::*;
    localparam int DEPTH = CFG.ftq.depth;
    localparam int COUNT_W = $clog2(DEPTH + 1);
    typedef logic [FTQ_IDX_W-1:0] idx_t;
    typedef logic [COUNT_W-1:0] count_t;
    // External identities retain the global width; RAM addresses use only the
    // local depth's decoder bits, after the full identity/range check.
    localparam int MEM_IDX_W = DEPTH > 1 ? $clog2(DEPTH) : 1;
    typedef logic [MEM_IDX_W-1:0] mem_idx_t;

    // Ring arithmetic describes bounded add/subtract hardware only.
    function automatic idx_t ring_next(input idx_t idx);
        return idx == idx_t'(DEPTH - 1) ? '0 : idx + 1'b1;
    endfunction

    function automatic idx_t ring_add(input idx_t idx, input count_t offset);
        logic [COUNT_W:0] sum, wrapped;
        sum = (COUNT_W+1)'(idx) + (COUNT_W+1)'(offset);
        wrapped = sum >= (COUNT_W+1)'(DEPTH) ? sum - (COUNT_W+1)'(DEPTH) : sum;
        return idx_t'(wrapped);
    endfunction

    function automatic count_t ring_distance(input idx_t idx, input idx_t origin);
        return idx >= origin ? count_t'(idx) - count_t'(origin)
                             : count_t'(DEPTH) - count_t'(origin) + count_t'(idx);
    endfunction

    typedef struct packed {
        bpu_pred_t pred;
        ras_ckpt_t ras_ckpt;
    } alloc_payload_t;
    typedef struct packed {
        bpu_pred_t pred;
        tage_meta_t tage_meta;
        loop_meta_t loop_meta;
    } slow_payload_t;
    typedef struct packed {
        vaddr_t next_pc;
        vaddr_t target;
        fetch_slot_t slot;
        cfi_type_e cfi_type;
        ras_action_e ras_action;
        logic taken;
    } fix_payload_t;
    typedef struct packed {
        vaddr_t target;
        fetch_slot_t slot;
        cfi_type_e cfi_type;
        ras_action_e ras_action;
        logic is_rvc, is_edge;
    } res_payload_t;
    typedef struct packed {
        logic slow_done, cfi_fixed, next_fixed, res_written;
        logic pred_valid, actual_valid;
        fetch_slot_t pred_slot, actual_slot;
        slot_mask_t br_mask, jal_mask;
        slot_mask_t resolved_br, resolved_taken;
        slot_mask_t committed_br, committed_taken, mispred_mask;
    } row_state_t;

    // Five payload arrays, five independent single-write ports. The correction
    // driver has two field stores because winner and boundary identities can
    // differ; merging them would implicitly introduce a second write address.
    (* ram_style = "distributed" *) logic [$bits(alloc_payload_t)-1:0] alloc_mem [DEPTH];
    (* ram_style = "distributed" *) logic [$bits(slow_payload_t)-1:0] slow_mem [DEPTH];
    (* ram_style = "distributed" *) logic [$bits(fix_payload_t)-1:0] fix_pred_mem [DEPTH];
    (* ram_style = "distributed" *) vaddr_t fix_next_mem [DEPTH];
    (* ram_style = "distributed" *) logic [$bits(res_payload_t)-1:0] res_mem [DEPTH];
    row_state_t state_q [DEPTH];
    logic [FTQ_GEN_W-1:0] gen_q [DEPTH];
    logic [DEPTH-1:0] live_q;

    idx_t head_q, head_d, alloc_q, demand_q, pf_q;
    count_t count_q, count_d;
    // Progress values include the end position DEPTH, distinguishing a full
    // ring's exhausted issuer from its head despite equal physical indices.
    count_t closed_count_q, closed_count_d;
    count_t demand_pos_q, demand_pos_d, pf_pos_q, pf_pos_d;
    logic alloc_fire, demand_fire, pf_fire, train_fire;
    logic demand_hold_q;
    icache_req_t demand_hold_req_q;
    logic ho_busy_q;
    ftq_id_t ho_id_q;
    idx_t ho_sel;

    // Post-release controller wires. Commit and kill compare against this head,
    // matching the same-edge release priority without rotating a state array.
    idx_t work_head;
    count_t work_count, work_closed, work_demand, work_pf;
    count_t commit_age [COMMIT_W];
    logic [COMMIT_W-1:0] commit_accept;
    count_t kill_age, keep_count;
    logic kill_owner_live, boundary_cut;
    slot_mask_t cut_mask;

    logic slow_write, resolve_write, winner_write, fix_write;
    alloc_payload_t alloc_write_data, head_alloc, demand_alloc, pf_alloc, brief_alloc, ras_alloc;
    slow_payload_t slow_write_data, head_slow, brief_slow, ras_slow;
    fix_payload_t fix_write_data, brief_fix;
    res_payload_t resolve_write_data, head_res;
    bpu_pred_t brief_pred;
    vaddr_t head_final_next;
    logic brief_live, ras_live, demand_live, pf_live;
    vaddr_t resolve_region;

    initial begin
        assert (DEPTH > 0 && DEPTH <= (1 << FTQ_IDX_W))
            else $fatal(1, "FTQ depth exceeds ftq_id_t index width");
    end

    // ------------------------------------------------------------
    // Ring controller: cursors, commit frontier, squash boundary
    // ------------------------------------------------------------
    assign alloc_q = ring_add(head_q, count_q);
    assign demand_q = ring_add(head_q, demand_pos_q);
    assign pf_q = ring_add(head_q, pf_pos_q);
    assign alloc_ftq_id_o = '{gen:gen_q[mem_idx_t'(alloc_q)] + 1'b1, idx:alloc_q};
    assign alloc_ready_o = !rst_i && !kill_i.valid && count_q < count_t'(DEPTH);
    assign alloc_fire = alloc_valid_i && alloc_ready_o;
    assign head_id_o = count_q != 0 ? ftq_id_t'{gen:gen_q[mem_idx_t'(head_q)], idx:head_q} : ftq_id_t'(0);
    assign age_head_idx_o = head_q;

    assign work_head = train_fire ? ring_next(head_q) : head_q;
    assign work_count = count_q - count_t'(train_fire);
    assign work_demand = demand_pos_q - count_t'(train_fire && demand_pos_q != 0);
    assign work_pf = pf_pos_q - count_t'(train_fire && pf_pos_q != 0);
    for (genvar lane = 0; lane < COMMIT_W; lane++) begin : g_commit_port
        assign commit_age[lane] = ring_distance(commit_i[lane].ftq_id.idx, work_head);
        assign commit_accept[lane] = !rst_i && commit_i[lane].valid &&
            int'(commit_i[lane].ftq_id.idx) < DEPTH &&
            commit_age[lane] < work_count &&
            gen_q[mem_idx_t'(commit_i[lane].ftq_id.idx)] == commit_i[lane].ftq_id.gen &&
            int'(commit_i[lane].slot) < REGION_SLOTS;
    end
    always_comb begin : commit_frontier
        count_t lane_closed;
        work_closed = closed_count_q - count_t'(train_fire && closed_count_q != 0);
        lane_closed = '0;
        for (int lane = 0; lane < COMMIT_W; lane++) begin
            lane_closed = commit_age[lane] + count_t'(commit_i[lane].region_last);
            if (commit_accept[lane] && lane_closed > work_closed)
                work_closed = lane_closed;
        end
    end

    assign kill_age = ring_distance(kill_i.ftq_id.idx, work_head);
    assign kill_owner_live = int'(kill_i.ftq_id.idx) < DEPTH &&
        kill_age < work_count && gen_q[mem_idx_t'(kill_i.ftq_id.idx)] == kill_i.ftq_id.gen;
    always_comb begin : squash_boundary
        keep_count = work_count;
        if (kill_i.valid) begin
            if (kill_i.all) keep_count = work_closed;
            else if (kill_owner_live) keep_count = kill_age + count_t'(!kill_i.kill_self);
            if (keep_count < work_closed) keep_count = work_closed;
        end
    end
    assign boundary_cut = !rst_i && kill_i.valid && !kill_i.all &&
        !kill_i.kill_self && kill_owner_live && kill_age < keep_count;
    for (genvar slot = 0; slot < REGION_SLOTS; slot++) begin : g_cut_mask
        assign cut_mask[slot] = slot <= int'(kill_i.slot);
    end

    always_comb begin : cursor_control
        head_d = work_head;
        count_d = work_count;
        closed_count_d = work_closed;
        demand_pos_d = work_demand;
        pf_pos_d = work_pf;
        if (kill_i.valid) begin
            count_d = keep_count;
            if (demand_pos_d > keep_count) demand_pos_d = keep_count;
            if (pf_pos_d > keep_count) pf_pos_d = keep_count;
        end else begin
            if (alloc_fire) count_d = count_d + 1'b1;
            if (demand_fire) demand_pos_d = demand_pos_d + 1'b1;
            if (pf_fire) pf_pos_d = pf_pos_d + 1'b1;
        end
        // Prefetch skips regions whose demand request has already been issued.
        if (pf_pos_d < demand_pos_d) pf_pos_d = demand_pos_d;
    end

    always_ff @(posedge clk_i) begin : cursor_registers
        if (rst_i) begin
            head_q <= '0;
            count_q <= '0;
            closed_count_q <= '0;
            demand_pos_q <= '0;
            pf_pos_q <= '0;
        end else begin
            head_q <= head_d;
            count_q <= count_d;
            closed_count_q <= closed_count_d;
            demand_pos_q <= demand_pos_d;
            pf_pos_q <= pf_pos_d;
        end
    end

    // ------------------------------------------------------------
    // Single-writer payload drivers; data memories have no reset port
    // ------------------------------------------------------------
    assign alloc_write_data = '{pred:alloc_pred_i, ras_ckpt:alloc_ras_ckpt_i};
    assign slow_write_data = '{pred:slow_i.pred, tage_meta:slow_i.tage_meta, loop_meta:slow_i.loop_meta};
    assign slow_write = !rst_i && slow_i.valid && int'(slow_i.ftq_id.idx) < DEPTH &&
        live_q[mem_idx_t'(slow_i.ftq_id.idx)] && gen_q[mem_idx_t'(slow_i.ftq_id.idx)] == slow_i.ftq_id.gen &&
        !(train_fire && head_q == slow_i.ftq_id.idx);
    assign resolve_write = !rst_i && resolve_i.valid && int'(resolve_i.ftq_id.idx) < DEPTH &&
        live_q[mem_idx_t'(resolve_i.ftq_id.idx)] && gen_q[mem_idx_t'(resolve_i.ftq_id.idx)] == resolve_i.ftq_id.gen &&
        !(train_fire && head_q == resolve_i.ftq_id.idx) && int'(resolve_i.slot) < REGION_SLOTS;
    assign winner_write = !rst_i && kill_i.valid && winner_i.valid && !winner_i.kill_self &&
        int'(winner_i.ftq_id.idx) < DEPTH && live_q[mem_idx_t'(winner_i.ftq_id.idx)] &&
        gen_q[mem_idx_t'(winner_i.ftq_id.idx)] == winner_i.ftq_id.gen &&
        !(train_fire && head_q == winner_i.ftq_id.idx);
    assign fix_write = boundary_cut && resolve_i.valid &&
        resolve_i.ftq_id == kill_i.ftq_id && resolve_i.mispredict;
    assign fix_write_data = '{next_pc:resolve_i.redirect_pc, target:resolve_i.actual_target,
        slot:resolve_i.slot, cfi_type:resolve_i.cfi_type, ras_action:resolve_i.ras_action,
        taken:resolve_i.actual_taken};
    always_comb begin : resolution_payload
        alloc_payload_t original;
        original = '0;
        if (resolve_write) original = alloc_payload_t'(alloc_mem[mem_idx_t'(resolve_i.ftq_id.idx)]);
        resolve_region = original.pred.region_base;
        resolve_write_data = '{target:resolve_i.actual_target, slot:resolve_i.slot,
            cfi_type:resolve_i.cfi_type, ras_action:resolve_i.ras_action,
            is_rvc:(resolve_i.inst_len == 2),
            is_edge:(resolve_i.branch_pc == resolve_region - vaddr_t'(2))};
    end
    always_ff @(posedge clk_i) begin : allocation_memory_driver
        if (alloc_fire) alloc_mem[mem_idx_t'(alloc_q)] <= alloc_write_data;
    end
    always_ff @(posedge clk_i) begin : slow_memory_driver
        if (slow_write) slow_mem[mem_idx_t'(slow_i.ftq_id.idx)] <= slow_write_data;
    end
    always_ff @(posedge clk_i) begin : correction_memory_driver
        if (fix_write) fix_pred_mem[mem_idx_t'(kill_i.ftq_id.idx)] <= fix_write_data;
        if (winner_write) fix_next_mem[mem_idx_t'(winner_i.ftq_id.idx)] <= winner_i.target_pc;
    end
    always_ff @(posedge clk_i) begin : resolution_memory_driver
        if (resolve_write && resolve_i.actual_taken)
            res_mem[mem_idx_t'(resolve_i.ftq_id.idx)] <= resolve_write_data;
    end

    // ------------------------------------------------------------
    // Narrow per-row registers: fixed row enables, no wide entry feedback
    // ------------------------------------------------------------
    for (genvar row = 0; row < DEPTH; row++) begin : g_row_state
        localparam idx_t ROW = idx_t'(row);
        count_t age_q, age_work;
        logic release_row, drop_row, alloc_row, slow_row, winner_row, resolve_row, cut_row;
        row_state_t next_state;
        assign age_q = ring_distance(ROW, head_q);
        assign age_work = ring_distance(ROW, work_head);
        assign live_q[row] = age_q < count_q;
        assign release_row = train_fire && head_q == ROW;
        assign drop_row = kill_i.valid && age_work < work_count && age_work >= keep_count;
        assign alloc_row = alloc_fire && alloc_q == ROW;
        assign slow_row = slow_write && slow_i.ftq_id.idx == ROW;
        assign winner_row = winner_write && winner_i.ftq_id.idx == ROW;
        assign resolve_row = resolve_write && resolve_i.ftq_id.idx == ROW;
        assign cut_row = boundary_cut && kill_i.ftq_id.idx == ROW;

        always_comb begin : row_control
            next_state = state_q[row];
            if (slow_row) begin
                next_state.slow_done = 1'b1;
                next_state.cfi_fixed = 1'b0;
                next_state.next_fixed = 1'b0;
                next_state.pred_valid = slow_i.pred.cfi_valid;
                next_state.pred_slot = slow_i.pred.cfi_slot;
                next_state.br_mask = slow_i.pred.br_mask;
                next_state.jal_mask = slow_i.pred.jal_mask;
            end
            if (winner_row) next_state.next_fixed = 1'b1;
            if (resolve_row) begin
                if (resolve_i.cfi_type == CFI_BR) begin
                    next_state.resolved_br[resolve_i.slot] = 1'b1;
                    next_state.resolved_taken[resolve_i.slot] = resolve_i.actual_taken;
                end
                if (resolve_i.actual_taken) begin
                    next_state.res_written = 1'b1;
                    next_state.actual_valid = 1'b1;
                    next_state.actual_slot = resolve_i.slot;
                end
                if (resolve_i.mispredict) next_state.mispred_mask[resolve_i.slot] = 1'b1;
            end
            // At most four narrow commit updates to this physical row. A
            // same-edge resolution is visible, as in the original contract.
            for (int lane = 0; lane < COMMIT_W; lane++) begin
                if (commit_accept[lane] && commit_i[lane].ftq_id.idx == ROW &&
                    next_state.resolved_br[commit_i[lane].slot]) begin
                    next_state.committed_br[commit_i[lane].slot] = 1'b1;
                    next_state.committed_taken[commit_i[lane].slot] =
                        next_state.resolved_taken[commit_i[lane].slot];
                end
            end
            if (cut_row) begin
                next_state.resolved_br &= cut_mask;
                next_state.resolved_taken &= cut_mask;
                next_state.mispred_mask &= cut_mask;
                next_state.br_mask &= cut_mask;
                next_state.jal_mask &= cut_mask;
                if (next_state.pred_slot > kill_i.slot) next_state.pred_valid = 1'b0;
                if (next_state.actual_slot > kill_i.slot) next_state.actual_valid = 1'b0;
                if (fix_write) begin
                    next_state.cfi_fixed = 1'b1;
                    next_state.pred_valid = resolve_i.actual_taken;
                    next_state.pred_slot = resolve_i.slot;
                end
            end
            if (release_row || drop_row) next_state = '0;
            if (alloc_row) begin
                next_state = '0;
                next_state.pred_valid = alloc_pred_i.cfi_valid;
                next_state.pred_slot = alloc_pred_i.cfi_slot;
                next_state.br_mask = alloc_pred_i.br_mask;
                next_state.jal_mask = alloc_pred_i.jal_mask;
            end
        end
        always_ff @(posedge clk_i) begin : status_registers
            if (rst_i) state_q[row] <= '0;
            else state_q[row] <= next_state;
        end
        always_ff @(posedge clk_i) begin : generation_register
            if (rst_i) gen_q[row] <= '0;
            else if (alloc_row) gen_q[row] <= gen_q[row] + 1'b1;
        end
    end

    // ------------------------------------------------------------
    // Named asynchronous read taps, gated by live identity / payload flags
    // ------------------------------------------------------------
    assign demand_live = count_q != 0 && live_q[mem_idx_t'(demand_q)];
    assign pf_live = count_q != 0 && live_q[mem_idx_t'(pf_q)];
    assign brief_live = brief_rd_valid_i && int'(brief_rd_id_i.idx) < DEPTH &&
        live_q[mem_idx_t'(brief_rd_id_i.idx)] && gen_q[mem_idx_t'(brief_rd_id_i.idx)] == brief_rd_id_i.gen;
    assign ras_live = int'(ras_ckpt_rd_id_i.idx) < DEPTH &&
        live_q[mem_idx_t'(ras_ckpt_rd_id_i.idx)] && gen_q[mem_idx_t'(ras_ckpt_rd_id_i.idx)] == ras_ckpt_rd_id_i.gen;
    always_comb begin : payload_read_taps
        head_alloc = '0;
        head_slow = '0;
        head_res = '0;
        head_final_next = '0;
        demand_alloc = '0;
        pf_alloc = '0;
        brief_alloc = '0;
        brief_slow = '0;
        brief_fix = '0;
        ras_alloc = '0;
        ras_slow = '0;
        if (count_q != 0) begin
            head_alloc = alloc_payload_t'(alloc_mem[mem_idx_t'(head_q)]);
            head_final_next = head_alloc.pred.next_pc;
            if (state_q[mem_idx_t'(head_q)].slow_done) begin
                head_slow = slow_payload_t'(slow_mem[mem_idx_t'(head_q)]);
                head_final_next = head_slow.pred.next_pc;
            end
            if (state_q[mem_idx_t'(head_q)].next_fixed) head_final_next = fix_next_mem[mem_idx_t'(head_q)];
            if (state_q[mem_idx_t'(head_q)].res_written) head_res = res_payload_t'(res_mem[mem_idx_t'(head_q)]);
        end
        if (demand_live) demand_alloc = alloc_payload_t'(alloc_mem[mem_idx_t'(demand_q)]);
        if (pf_live) pf_alloc = alloc_payload_t'(alloc_mem[mem_idx_t'(pf_q)]);
        if (brief_live) begin
            brief_alloc = alloc_payload_t'(alloc_mem[mem_idx_t'(brief_rd_id_i.idx)]);
            if (state_q[mem_idx_t'(brief_rd_id_i.idx)].slow_done)
                brief_slow = slow_payload_t'(slow_mem[mem_idx_t'(brief_rd_id_i.idx)]);
            if (state_q[mem_idx_t'(brief_rd_id_i.idx)].cfi_fixed)
                brief_fix = fix_payload_t'(fix_pred_mem[mem_idx_t'(brief_rd_id_i.idx)]);
        end
        if (ras_live) begin
            ras_alloc = alloc_payload_t'(alloc_mem[mem_idx_t'(ras_ckpt_rd_id_i.idx)]);
            if (state_q[mem_idx_t'(ras_ckpt_rd_id_i.idx)].slow_done)
                ras_slow = slow_payload_t'(slow_mem[mem_idx_t'(ras_ckpt_rd_id_i.idx)]);
        end
    end

    always_comb begin : prediction_read_merge
        brief_pred = '0;
        brief_o = '0;
        if (brief_live) begin
            brief_pred = state_q[mem_idx_t'(brief_rd_id_i.idx)].slow_done ? brief_slow.pred : brief_alloc.pred;
            if (state_q[mem_idx_t'(brief_rd_id_i.idx)].cfi_fixed) begin
                brief_pred.next_pc = brief_fix.next_pc;
                brief_pred.cfi_target = brief_fix.target;
                brief_pred.cfi_slot = brief_fix.slot;
                brief_pred.cfi_type = brief_fix.cfi_type;
                brief_pred.ras_action = brief_fix.ras_action;
                brief_pred.raw_pred_taken = brief_fix.taken;
                brief_pred.target_missing = 1'b0;
            end
            brief_pred.cfi_valid = state_q[mem_idx_t'(brief_rd_id_i.idx)].pred_valid;
            brief_pred.br_mask = state_q[mem_idx_t'(brief_rd_id_i.idx)].br_mask;
            brief_pred.jal_mask = state_q[mem_idx_t'(brief_rd_id_i.idx)].jal_mask;
            brief_o.ftq_id = brief_rd_id_i;
            brief_o.slow_done = state_q[mem_idx_t'(brief_rd_id_i.idx)].slow_done;
            brief_o.pred = brief_pred;
            brief_o.ras_ckpt = brief_alloc.ras_ckpt;
        end
    end
    always_comb begin : recovery_read_merge
        ras_ckpt_rd_o = '0;
        loop_meta_rd_o = '0;
        if (ras_live) begin
            ras_ckpt_rd_o = ras_alloc.ras_ckpt;
            loop_meta_rd_o = ras_slow.loop_meta;
            // Same-edge slow metadata is forwarded before the RAM write.
            if (slow_i.valid && slow_i.ftq_id == ras_ckpt_rd_id_i)
                loop_meta_rd_o = slow_i.loop_meta;
        end
    end

    // ------------------------------------------------------------
    // Demand / prefetch interfaces and stable stalled request register
    // ------------------------------------------------------------
    assign demand_valid_o = !rst_i && !hold_i && !kill_i.valid && rq_rsv_ready_i &&
        demand_pos_q < count_q;
    always_comb begin : demand_request
        demand_o = '0;
        if (demand_hold_q) demand_o = demand_hold_req_q;
        else if (count_q != 0) begin
            demand_o.region_base = demand_alloc.pred.region_base;
            demand_o.ftq_id = demand_live ? ftq_id_t'{gen:gen_q[mem_idx_t'(demand_q)], idx:demand_q} : ftq_id_t'(0);
            demand_o.rq_idx = rq_rsv_idx_i;
            demand_o.epoch = epoch_i;
        end
    end
    assign demand_fire = demand_valid_o && demand_ready_i;
    always_ff @(posedge clk_i) begin : stalled_demand_register
        if (rst_i || kill_i.valid) begin
            demand_hold_q <= 1'b0;
            demand_hold_req_q <= '0;
        end else if (demand_fire) demand_hold_q <= 1'b0;
        else if (demand_valid_o && !demand_ready_i && !demand_hold_q) begin
            demand_hold_q <= 1'b1;
            demand_hold_req_q <= demand_o;
        end
    end
    assign pf_valid_o = !rst_i && !hold_i && !kill_i.valid && pf_pos_q < count_q &&
        state_q[mem_idx_t'(pf_q)].slow_done;
    assign pf_region_base_o = pf_alloc.pred.region_base;
    assign pf_ftq_id_o = pf_live ? ftq_id_t'{gen:gen_q[mem_idx_t'(pf_q)], idx:pf_q} : ftq_id_t'(0);
    assign pf_fire = pf_valid_o && pf_ready_i;

    // ------------------------------------------------------------
    // H0 snapshot request / H1 training handoff; acceptance releases head
    // ------------------------------------------------------------
    assign ho_sel = ring_add(head_q, count_t'(ho_busy_q));
    assign snap_train_rd_req_o = !rst_i && count_q > count_t'(ho_busy_q) &&
        closed_count_q > count_t'(ho_busy_q) && int'(train_free_i) > int'(ho_busy_q);
    assign snap_train_rd_id_o = live_q[mem_idx_t'(ho_sel)] ? ftq_id_t'{gen:gen_q[mem_idx_t'(ho_sel)], idx:ho_sel} : ftq_id_t'(0);
    assign bpu_train_valid_o = !rst_i && ho_busy_q;
    assign train_fire = bpu_train_valid_o && bpu_train_ready_i;
    always_comb begin : training_read_merge
        bpu_train_o = '0;
        bpu_train_o.region_base = head_alloc.pred.region_base;
        bpu_train_o.folds = snap_train_i.folds;
        bpu_train_o.loop_train = head_slow.loop_meta.train;
        bpu_train_o.tage_meta = head_slow.tage_meta;
        bpu_train_o.br_commit_mask = state_q[mem_idx_t'(head_q)].committed_br;
        bpu_train_o.br_taken_mask = state_q[mem_idx_t'(head_q)].committed_taken;
        bpu_train_o.cfi_valid = state_q[mem_idx_t'(head_q)].actual_valid;
        bpu_train_o.cfi_slot = head_res.slot;
        bpu_train_o.cfi_type = head_res.cfi_type;
        bpu_train_o.ras_action = head_res.ras_action;
        bpu_train_o.cfi_target = head_res.target;
        bpu_train_o.cfi_is_rvc = head_res.is_rvc;
        bpu_train_o.is_edge = head_res.is_edge;
        bpu_train_o.mispredicted = |state_q[mem_idx_t'(head_q)].mispred_mask;
    end
    always_ff @(posedge clk_i) begin : training_handoff_register
        if (rst_i) begin
            ho_busy_q <= 1'b0;
            ho_id_q <= '0;
        end else begin
            ho_busy_q <= snap_train_rd_req_o;
            if (snap_train_rd_req_o) ho_id_q <= snap_train_rd_id_o;
            if (ho_busy_q)
                assert (snap_train_resp_valid_i && snap_train_resp_id_i == ho_id_q &&
                    head_id_o == ho_id_q && bpu_train_ready_i)
                    else $fatal(1, "FTQ H1 identity or reserved training credit lost");
        end
    end

    // ------------------------------------------------------------
    // Performance observations use the same read taps as functional consumers
    // ------------------------------------------------------------
    always_comb begin : performance_events
        perf_o = '0;
        if (!rst_i) begin
            perf_o[PE_TRAIN_STALL_CYCLE] = PERF_INC_W'(count_q > count_t'(ho_busy_q) &&
                closed_count_q > count_t'(ho_busy_q) && int'(train_free_i) <= int'(ho_busy_q));
            perf_o[PE_RQ_FULL_CYCLE] = PERF_INC_W'(!hold_i && !kill_i.valid &&
                demand_pos_q < count_q && !rq_rsv_ready_i);
            perf_o[PE_FTQ_FULL_CYCLE] = PERF_INC_W'(alloc_valid_i && !alloc_ready_o);
            if (train_fire) begin
                perf_o[PE_CMT_REGION] = 1;
                perf_o[PE_CMT_LOOP_USED] = PERF_INC_W'(head_slow.loop_meta.train.used &&
                    state_q[mem_idx_t'(head_q)].committed_br[head_slow.loop_meta.train.slot]);
                perf_o[PE_CMT_LOOP_WRONG] = PERF_INC_W'(head_slow.loop_meta.train.used &&
                    state_q[mem_idx_t'(head_q)].committed_br[head_slow.loop_meta.train.slot] &&
                    head_slow.loop_meta.train.pred != state_q[mem_idx_t'(head_q)].committed_taken[head_slow.loop_meta.train.slot]);
                perf_o[PE_CMT_COND_BR] = PERF_INC_W'($countones(state_q[mem_idx_t'(head_q)].committed_br));
                perf_o[PE_CMT_COND_MISPRED] = PERF_INC_W'($countones(state_q[mem_idx_t'(head_q)].committed_br & state_q[mem_idx_t'(head_q)].mispred_mask));
                for (int slot = 0; slot < REGION_SLOTS; slot++) begin
                    if (state_q[mem_idx_t'(head_q)].committed_br[slot] &&
                        tage_final(head_slow.tage_meta, slot) != state_q[mem_idx_t'(head_q)].committed_taken[slot])
                        perf_o[PE_CMT_COND_TAGE_WRONG] += PERF_INC_W'(1);
                end
                if (state_q[mem_idx_t'(head_q)].actual_valid && head_res.cfi_type == CFI_JALR) begin
                    if (head_res.ras_action inside {RAS_POP, RAS_POP_PUSH}) begin
                        perf_o[PE_CMT_RET] = 1;
                        perf_o[PE_CMT_RET_MISPRED] = PERF_INC_W'(state_q[mem_idx_t'(head_q)].mispred_mask[head_res.slot]);
                    end else begin
                        perf_o[PE_CMT_JALR] = 1;
                        perf_o[PE_CMT_JALR_MISPRED] = PERF_INC_W'(state_q[mem_idx_t'(head_q)].mispred_mask[head_res.slot]);
                    end
                end
                case ({head_alloc.pred.next_pc == head_final_next,
                       head_slow.pred.next_pc == head_final_next})
                    2'b11: perf_o[PE_CMT_FAST_OK_SLOW_OK] = 1;
                    2'b10: perf_o[PE_CMT_FAST_OK_SLOW_BAD] = 1;
                    2'b01: perf_o[PE_CMT_FAST_BAD_SLOW_OK] = 1;
                    2'b00: perf_o[PE_CMT_FAST_BAD_SLOW_BAD] = 1;
                endcase
                perf_o[PE_CMT_MISPRED_REGION] = PERF_INC_W'(|state_q[mem_idx_t'(head_q)].mispred_mask);
            end
            perf_o[PE_FTQ_EMPTY_CYCLE] = PERF_INC_W'(count_q == 0);
        end
    end

    // Historical interface remains isolated; it never drives target state.
    assign bpu_ready_o = 1'b0;
    assign ifu_valid_o = 1'b0;
    assign ifu_entry_o = '0;
    assign ifu_ftq_idx_o = '0;
    assign train_valid_o = '0;
    for (genvar lane = 0; lane < RELEASE_WIDTH; lane++) begin : old_train_tieoff
        assign train_entry_o[lane] = '0;
    end

    `ifdef O3_FRONTEND_DEBUG
    assign dbg_ifu_fire_o = demand_fire;
    assign dbg_bpu_fire_o = alloc_fire;
    assign dbg_alloc_tail_o = alloc_q;
    assign dbg_ifu_head_o = demand_q;
    assign dbg_release_head_o = head_q;
    assign dbg_allocated_count_o = count_q;
    `endif
endmodule
