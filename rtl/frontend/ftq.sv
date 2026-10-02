/**
 * Fetch Target Queue —— 动态取指描述、游标与生命周期
 *
 * 作用（目标，第 7 节）：
 * - 每个 entry 是一次动态进入 16B 区域的取指描述：身份、地址范围、快/慢预测、状态、
 *   恢复引用、训练上下文。不存 cache 返回的指令数据。
 * - 独立推进分配、demand 发射、prefetch、提交回收等逻辑位置；cache 接受请求只推进
 *   发射位置，不代表 entry 可释放（第 7.2 节）。
 * - 区域有效指令全部提交后先完成训练信息交接，再回收；不等整个 ROB 清空（第 16.2 节）。
 *
 * 需要补充实现的机制（基线已定）：
 * 1) 动态身份 ftq_id_t = idx + 代际；同一区域多次进入是不同身份（第 3.1 节）。
 *    head_id_o 作为 D24 年龄比较参照。
 * 2) entry 字段（逻辑内容，可拆为 PC RAM / 预测 metadata RAM / 状态寄存器）：
 *    region_base、入口槽位、mask、快预测 next_pc、慢预测结果与 slow_done、fetch issued、
 *    killed、RAS 入口 ras_before={top_idx,count,top_addr}（D29，每项约 4+5+V bit）、
 *    TAGE 训练元数据、执行实际结果；
 *    D23 入口快照存于 history_snapshot_store，以 ftq_id 引用。
 * 3) demand 游标：FTQ 主动给出 valid 与请求，ICache 给 ready；只有 valid&&ready 且已
 *    获得返回队列槽（rq_rsv_*）才发射并推进；等待时请求与身份稳定（第 7.3 节）。
 * 4) prefetch 游标：走在 demand 之前，交给 fetch_prefetcher（D18）；领先距离待定。
 * 5) 慢预测写回 slow_i：更新预测元数据与有效范围，置 slow_done（第 6.3 节）。
 * 6) 返回队列出队时按 ftq_id 读最终预测摘要（brief_*）。
 * 7) 执行解析 resolve_i：记录实际结果（正确解析也记录），供提交训练。
 * 8) kill_i（D24 赢家边界）：使比边界年轻的 entry 失效，分配位置回到边界之后；
 *    出错区域自身保留并修正有效范围。
 * 9) 提交 commit_i：region_last 的区域读出训练上下文（含快照训练读口）形成 bpu_train_t，
 *    训练请求被接受后才回收。D29 取消 undo log，回收时不再有 RAS 释放动作。
 *    训练排队时必须先保住原查询元数据（第 16.2 节）。
 *
 * 细节待定：FTQ 深度、代际位宽与回绕安全条件、分区存储、训练 metadata 生存期、
 * 块内多分支训练排程与提交带宽（第 6.1 节、第 13 节第 3 条）。
 *
 * 当前实现：动态身份、四个独立游标、慢预测/解析写回、D24 边界清除、RAS 检查点读、
 * 快照训练握手和训练接受后释放。旧端口保留但隔离为常量，供仍引用 ftq_pkg 的旧 BPU
 * 在后续迁移；不能将旧接口当作本模块的可用数据路径。
 * 当前未实现：预解码纠错的完整预测字段写回（kill_i 只有边界，没有修正元数据）、
 * 跨块辅助请求、代际回绕生命周期证明、存储分区/物理端口优化。
 *
 * 目标周期行为：
 * - 周期 N 组合：alloc_ready_o 反映容量；demand_valid_o 在 demand 游标项有效、
 *   未 killed、rq_rsv_ready_i 且 !hold_i 时为 1；brief/ras 读口校验完整动态身份。
 * - 周期 N 上升沿：alloc/demand/prefetch 握手各自推进；slow/resolve/commit 更新原项；
 *   kill 优先于同拍分配和发射，并把游标回到存活项；训练被 BPU 接受才释放队头。
 * - 周期 N+1：可见新身份、游标和容量；已提交项依次等待读快照及 BPU 训练握手。
 * 本轮增加独立单模块测试；未做整机仿真、综合或 FPGA 时序。
 *
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
    output o3_types_pkg::ftq_id_t           head_id_o,
    input  o3_types_pkg::ftq_id_t           ras_ckpt_rd_id_i,
    output o3_types_pkg::ras_ckpt_t         ras_ckpt_rd_o,

    // 提交训练：读快照训练上下文，组装 bpu_train_t
    output logic                            snap_train_rd_req_o,
    output o3_types_pkg::ftq_id_t           snap_train_rd_id_o,
    input  logic                            snap_train_resp_valid_i,
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

    typedef struct packed {
        logic valid;
        ftq_id_t id;
        bpu_pred_t fast_pred, final_pred;
        ras_ckpt_t ras_ckpt;
        tage_meta_t tage_meta;
        logic slow_done, demand_issued, pf_issued, commit_last;
        slot_mask_t resolved_br, resolved_taken, committed_br, committed_taken;
        logic actual_cfi_valid, mispredicted;
        fetch_slot_t actual_cfi_slot;
        cfi_type_e actual_cfi_type;
        ras_action_e actual_ras_action;
        vaddr_t actual_cfi_target;
    } entry_t;

    typedef enum logic [1:0] {TRAIN_IDLE, TRAIN_WAIT, TRAIN_SEND} train_state_e;
    entry_t entries_q [DEPTH], entries_d [DEPTH];
    logic [FTQ_GEN_W-1:0] gen_q [DEPTH], gen_d [DEPTH];
    idx_t alloc_q, alloc_d, demand_q, demand_d, pf_q, pf_d, head_q, head_d;
    count_t count_q, count_d;
    train_state_e train_state_q, train_state_d;
    ftq_id_t train_id_q, train_id_d;
    bpu_train_t train_q, train_d;
    logic demand_hold_q, demand_hold_d;
    icache_req_t demand_hold_req_q, demand_hold_req_d;
    logic alloc_fire, demand_fire, pf_fire, train_fire;

    function automatic idx_t advance(input idx_t idx);
        return (idx == idx_t'(DEPTH - 1)) ? '0 : idx + 1'b1;
    endfunction

    function automatic idx_t add_idx(input idx_t idx, input int unsigned offset);
        int unsigned sum;
        sum = int'(idx) + offset;
        return idx_t'((sum >= DEPTH) ? sum - DEPTH : sum);
    endfunction

    function automatic ftq_id_t new_id(input idx_t idx,
                                       input logic [FTQ_GEN_W-1:0] old_gen);
        ftq_id_t id;
        id.idx = idx;
        id.gen = old_gen + 1'b1;
        return id;
    endfunction

    initial begin
        assert (DEPTH > 0 && DEPTH <= (1 << FTQ_IDX_W))
            else $fatal(1, "FTQ depth exceeds ftq_id_t index width");
    end

    // Legacy BPU/IFU ports remain only because bpu.sv imports ftq_pkg.
    // They never own target-FTQ state; the target frontend leaves them open.
    assign bpu_ready_o = 1'b0;
    assign ifu_valid_o = 1'b0;
    assign ifu_entry_o = '0;
    assign ifu_ftq_idx_o = '0;
    assign train_valid_o = '0;
    for (genvar lane = 0; lane < RELEASE_WIDTH; lane++) begin : old_train_tieoff
        assign train_entry_o[lane] = '0;
    end

    // The caller captures alloc_ftq_id_o only on alloc_valid && alloc_ready.
    // Reusing a killed slot increments its own generation, so stale responses
    // from the previous occupant fail the full-ID comparison.
    assign alloc_ftq_id_o = new_id(alloc_q, gen_q[alloc_q]);
    assign alloc_ready_o = !rst_i && !kill_i.valid && (count_q < count_t'(DEPTH));
    assign alloc_fire = alloc_valid_i && alloc_ready_o;
    assign head_id_o = (count_q != '0) ? entries_q[head_q].id : '0;

    // Demand requires an available return slot. Its index and epoch must stay
    // stable while an accepted valid request waits for ICache ready; the RQ
    // allocates that slot only on the same demand handshake.
    assign demand_valid_o = !rst_i && !hold_i && !kill_i.valid && rq_rsv_ready_i &&
                            (count_q != '0) && entries_q[demand_q].valid &&
                            !entries_q[demand_q].demand_issued;
    always_comb begin
        demand_o = '0;
        if (demand_hold_q) demand_o = demand_hold_req_q;
        else if (count_q != '0) begin
            demand_o.region_base = entries_q[demand_q].fast_pred.region_base;
            demand_o.ftq_id = entries_q[demand_q].id;
            demand_o.rq_idx = rq_rsv_idx_i;
            demand_o.epoch = epoch_i;
        end
    end
    assign demand_fire = demand_valid_o && demand_ready_i;

    assign pf_valid_o = !rst_i && !hold_i && !kill_i.valid &&
                        (count_q != '0) && entries_q[pf_q].valid &&
                        !entries_q[pf_q].pf_issued;
    assign pf_region_base_o = (count_q != '0) ? entries_q[pf_q].fast_pred.region_base : '0;
    assign pf_ftq_id_o = (count_q != '0) ? entries_q[pf_q].id : '0;
    assign pf_fire = pf_valid_o && pf_ready_i;

    // Both side reads validate the full dynamic identity. An old return or
    // recovery read cannot observe the new occupant of a reused ring slot.
    always_comb begin
        brief_o = '0;
        if (brief_rd_valid_i && int'(brief_rd_id_i.idx) < DEPTH &&
            entries_q[brief_rd_id_i.idx].valid &&
            entries_q[brief_rd_id_i.idx].id == brief_rd_id_i) begin
            brief_o.ftq_id = brief_rd_id_i;
            brief_o.slow_done = entries_q[brief_rd_id_i.idx].slow_done;
            brief_o.pred = entries_q[brief_rd_id_i.idx].final_pred;
        end
        ras_ckpt_rd_o = '0;
        if (int'(ras_ckpt_rd_id_i.idx) < DEPTH &&
            entries_q[ras_ckpt_rd_id_i.idx].valid &&
            entries_q[ras_ckpt_rd_id_i.idx].id == ras_ckpt_rd_id_i)
            ras_ckpt_rd_o = entries_q[ras_ckpt_rd_id_i.idx].ras_ckpt;
    end

    // A committed region stays at the head until its original history
    // snapshot arrives and the BPU accepts training. This uses FTQ capacity
    // as the lossless pending queue even when four regions commit together.
    assign snap_train_rd_req_o = !rst_i && train_state_q == TRAIN_IDLE &&
                                 (count_q != '0) && entries_q[head_q].commit_last;
    assign snap_train_rd_id_o = (train_state_q == TRAIN_IDLE) ? head_id_o : train_id_q;
    assign bpu_train_valid_o = !rst_i && train_state_q == TRAIN_SEND;
    assign bpu_train_o = train_q;
    assign train_fire = bpu_train_valid_o && bpu_train_ready_i;

    always_comb begin : next_state
        int unsigned keep_count, protected_count;
        int boundary_pos;
        logic prefix_open, found_demand, found_pf;
        idx_t slot_idx, old_head;
        slot_mask_t keep_mask;

        for (int n = 0; n < DEPTH; n++) begin
            entries_d[n] = entries_q[n];
            gen_d[n] = gen_q[n];
        end
        alloc_d = alloc_q;
        demand_d = demand_q;
        pf_d = pf_q;
        head_d = head_q;
        count_d = count_q;
        train_state_d = train_state_q;
        train_id_d = train_id_q;
        train_d = train_q;
        demand_hold_d = demand_hold_q;
        demand_hold_req_d = demand_hold_req_q;

        // Training acceptance is the only release event. Other committed
        // regions remain live and keep their snapshots until their turn.
        if (train_fire) begin
            old_head = head_d;
            entries_d[old_head] = '0;
            head_d = advance(old_head);
            count_d = count_d - 1'b1;
            train_state_d = TRAIN_IDLE;
            if (demand_d == old_head) demand_d = head_d;
            if (pf_d == old_head) pf_d = head_d;
        end

        if (slow_i.valid && int'(slow_i.ftq_id.idx) < DEPTH &&
            entries_d[slow_i.ftq_id.idx].valid &&
            entries_d[slow_i.ftq_id.idx].id == slow_i.ftq_id) begin
            entries_d[slow_i.ftq_id.idx].final_pred = slow_i.pred;
            entries_d[slow_i.ftq_id.idx].tage_meta = slow_i.tage_meta;
            entries_d[slow_i.ftq_id.idx].slow_done = 1'b1;
        end

        if (resolve_i.valid && int'(resolve_i.ftq_id.idx) < DEPTH &&
            entries_d[resolve_i.ftq_id.idx].valid &&
            entries_d[resolve_i.ftq_id.idx].id == resolve_i.ftq_id &&
            int'(resolve_i.slot) < REGION_SLOTS) begin
            if (resolve_i.cfi_type == CFI_BR) begin
                entries_d[resolve_i.ftq_id.idx].resolved_br[resolve_i.slot] = 1'b1;
                entries_d[resolve_i.ftq_id.idx].resolved_taken[resolve_i.slot] =
                    resolve_i.actual_taken;
            end
            if (resolve_i.actual_taken) begin
                entries_d[resolve_i.ftq_id.idx].actual_cfi_valid = 1'b1;
                entries_d[resolve_i.ftq_id.idx].actual_cfi_slot = resolve_i.slot;
                entries_d[resolve_i.ftq_id.idx].actual_cfi_type = resolve_i.cfi_type;
                entries_d[resolve_i.ftq_id.idx].actual_ras_action = resolve_i.ras_action;
                entries_d[resolve_i.ftq_id.idx].actual_cfi_target = resolve_i.actual_target;
            end
            entries_d[resolve_i.ftq_id.idx].mispredicted |= resolve_i.mispredict;
        end

        // All commit lanes can mark distinct regions in one edge. A region's
        // last committed instruction closes its training record, never frees
        // the slot directly. A same-edge resolve is visible to this marking.
        for (int lane = 0; lane < COMMIT_W; lane++) begin
            if (commit_i[lane].valid && int'(commit_i[lane].ftq_id.idx) < DEPTH &&
                entries_d[commit_i[lane].ftq_id.idx].valid &&
                entries_d[commit_i[lane].ftq_id.idx].id == commit_i[lane].ftq_id &&
                int'(commit_i[lane].slot) < REGION_SLOTS) begin
                if (entries_d[commit_i[lane].ftq_id.idx].resolved_br[commit_i[lane].slot]) begin
                    entries_d[commit_i[lane].ftq_id.idx].committed_br[commit_i[lane].slot] = 1'b1;
                    entries_d[commit_i[lane].ftq_id.idx].committed_taken[commit_i[lane].slot] =
                        entries_d[commit_i[lane].ftq_id.idx].resolved_taken[commit_i[lane].slot];
                end
                if (commit_i[lane].region_last)
                    entries_d[commit_i[lane].ftq_id.idx].commit_last = 1'b1;
            end
        end

        case (train_state_q)
            TRAIN_IDLE: if (snap_train_rd_req_o) begin
                train_id_d = head_id_o;
                train_state_d = TRAIN_WAIT;
            end
            TRAIN_WAIT: if (snap_train_resp_valid_i && count_d != '0 &&
                           entries_d[head_d].valid && entries_d[head_d].id == train_id_q) begin
                train_d = '0;
                train_d.region_base = entries_d[head_d].fast_pred.region_base;
                train_d.ctx = snap_train_i;
                train_d.tage_meta = entries_d[head_d].tage_meta;
                train_d.br_commit_mask = entries_d[head_d].committed_br;
                train_d.br_taken_mask = entries_d[head_d].committed_taken;
                train_d.cfi_valid = entries_d[head_d].actual_cfi_valid;
                train_d.cfi_slot = entries_d[head_d].actual_cfi_slot;
                train_d.cfi_type = entries_d[head_d].actual_cfi_type;
                train_d.ras_action = entries_d[head_d].actual_ras_action;
                train_d.cfi_target = entries_d[head_d].actual_cfi_target;
                train_d.mispredicted = entries_d[head_d].mispredicted;
                train_state_d = TRAIN_SEND;
            end
            default: ;
        endcase

        if (kill_i.valid) begin
            // D24's already-selected winner is authoritative. Preserve the
            // committed prefix even for kill-all so its training cannot be
            // dropped. Ignore a stale partial boundary with no live owner.
            protected_count = 0;
            prefix_open = 1'b1;
            boundary_pos = -1;
            for (int age = 0; age < DEPTH; age++) begin
                slot_idx = add_idx(head_d, age);
                if (age < int'(count_d)) begin
                    if (prefix_open && entries_d[slot_idx].commit_last)
                        protected_count++;
                    else prefix_open = 1'b0;
                    if (entries_d[slot_idx].valid && entries_d[slot_idx].id == kill_i.ftq_id)
                        boundary_pos = age;
                end
            end
            keep_count = int'(count_d);
            if (kill_i.all) keep_count = protected_count;
            else if (boundary_pos >= 0) begin
                keep_count = boundary_pos + (kill_i.kill_self ? 0 : 1);
                if (keep_count < protected_count) keep_count = protected_count;
            end
            for (int age = 0; age < DEPTH; age++) begin
                if (age >= keep_count && age < int'(count_d)) begin
                    slot_idx = add_idx(head_d, age);
                    entries_d[slot_idx] = '0;
                end
            end
            count_d = count_t'(keep_count);
            alloc_d = add_idx(head_d, keep_count);

            if (!kill_i.all && !kill_i.kill_self && boundary_pos >= 0 &&
                boundary_pos < keep_count) begin
                slot_idx = add_idx(head_d, boundary_pos);
                keep_mask = '0;
                for (int s = 0; s < REGION_SLOTS; s++)
                    if (s <= int'(kill_i.slot)) keep_mask[s] = 1'b1;
                entries_d[slot_idx].final_pred.br_mask &= keep_mask;
                entries_d[slot_idx].final_pred.jal_mask &= keep_mask;
                if (entries_d[slot_idx].final_pred.cfi_valid &&
                    entries_d[slot_idx].final_pred.cfi_slot > kill_i.slot)
                    entries_d[slot_idx].final_pred.cfi_valid = 1'b0;
                if (resolve_i.valid && resolve_i.ftq_id == kill_i.ftq_id &&
                    resolve_i.mispredict) begin
                    entries_d[slot_idx].final_pred.next_pc = resolve_i.redirect_pc;
                    entries_d[slot_idx].final_pred.cfi_target = resolve_i.actual_target;
                    entries_d[slot_idx].final_pred.cfi_slot = resolve_i.slot;
                    entries_d[slot_idx].final_pred.cfi_type = resolve_i.cfi_type;
                    entries_d[slot_idx].final_pred.ras_action = resolve_i.ras_action;
                    entries_d[slot_idx].final_pred.raw_pred_taken = resolve_i.actual_taken;
                    entries_d[slot_idx].final_pred.target_missing = 1'b0;
                    entries_d[slot_idx].final_pred.cfi_valid = resolve_i.actual_taken;
                end
            end

            // Rewind each issuer to its first surviving, not-yet-issued
            // entry. Already accepted wrong-path requests finish elsewhere.
            demand_d = alloc_d;
            pf_d = alloc_d;
            found_demand = 1'b0;
            found_pf = 1'b0;
            for (int age = 0; age < DEPTH; age++) begin
                if (age < keep_count) begin
                    slot_idx = add_idx(head_d, age);
                    if (!found_demand && !entries_d[slot_idx].demand_issued) begin
                        demand_d = slot_idx;
                        found_demand = 1'b1;
                    end
                    if (!found_pf && !entries_d[slot_idx].pf_issued) begin
                        pf_d = slot_idx;
                        found_pf = 1'b1;
                    end
                end
            end
            demand_hold_d = 1'b0;
        end else begin
            if (alloc_fire) begin
                entries_d[alloc_q] = '0;
                entries_d[alloc_q].valid = 1'b1;
                entries_d[alloc_q].id = alloc_ftq_id_o;
                entries_d[alloc_q].fast_pred = alloc_pred_i;
                entries_d[alloc_q].final_pred = alloc_pred_i;
                entries_d[alloc_q].ras_ckpt = alloc_ras_ckpt_i;
                gen_d[alloc_q] = alloc_ftq_id_o.gen;
                alloc_d = advance(alloc_q);
                count_d = count_d + 1'b1;
            end
            if (demand_fire) begin
                entries_d[demand_q].demand_issued = 1'b1;
                demand_d = advance(demand_q);
                demand_hold_d = 1'b0;
            end else if (demand_valid_o && !demand_ready_i && !demand_hold_q) begin
                demand_hold_d = 1'b1;
                demand_hold_req_d = demand_o;
            end
            if (pf_fire) begin
                entries_d[pf_q].pf_issued = 1'b1;
                pf_d = advance(pf_q);
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int n = 0; n < DEPTH; n++) begin
                entries_q[n] <= '0;
                gen_q[n] <= '0;
            end
            alloc_q <= '0;
            demand_q <= '0;
            pf_q <= '0;
            head_q <= '0;
            count_q <= '0;
            train_state_q <= TRAIN_IDLE;
            train_id_q <= '0;
            train_q <= '0;
            demand_hold_q <= 1'b0;
            demand_hold_req_q <= '0;
        end else begin
            for (int n = 0; n < DEPTH; n++) begin
                entries_q[n] <= entries_d[n];
                gen_q[n] <= gen_d[n];
            end
            alloc_q <= alloc_d;
            demand_q <= demand_d;
            pf_q <= pf_d;
            head_q <= head_d;
            count_q <= count_d;
            train_state_q <= train_state_d;
            train_id_q <= train_id_d;
            train_q <= train_d;
            demand_hold_q <= demand_hold_d;
            demand_hold_req_q <= demand_hold_req_d;
        end
    end

    always_comb begin
        perf_o = '0;
        if (!rst_i) begin
            perf_o[PE_FTQ_FULL_CYCLE] = PERF_INC_W'(count_q == count_t'(DEPTH));
            perf_o[PE_FTQ_EMPTY_CYCLE] = PERF_INC_W'(count_q == '0);
        end
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
