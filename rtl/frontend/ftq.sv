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
 * 当前实现状态与缺口：
 * - 保留 HEAD 06462b0 的三指针实现及旧端口（bpu_*、ifu_*、release_count_i、
 *   resolution_i、train_*），标为“旧合同”，目标总装不再连接；迁移完成后删除。
 * - 旧实现缺口：只有 4 位 ftq_idx，无代际；按 32B [start_pc,end_pc) 表示块，不符合 D03；
 *   IFU consumed 位应改为 demand 游标；没有 prefetch 游标、slow_done、快照/RAS 引用；
 *   误预测只按 ftq_idx 截断，不是 D24 统一边界；释放由 release_count 驱动，训练输出
 *   未接预测表；ftq_pkg 的 FTQ_DEPTH/FTQ_BLOCK_BYTES 为固定 localparam，目标改由 CFG。
 * - 目标端口均未驱动。
 *
 * 目标周期行为：
 * - 周期 N 组合：alloc_ready_o 反映容量；demand_valid_o 在 demand 游标项有效、
 *   未 killed、rq_rsv_ready_i 且 !hold_i 时为 1；brief_o 组合读出。
 * - 周期 N 上升沿：alloc/demand/prefetch 握手各自推进对应游标；slow_i、resolve_i
 *   写入对应 entry；kill_i 使年轻项失效并回退分配/demand/prefetch 游标（优先于同拍分配）。
 * - 周期 N+1：可见新的游标与容量；提交训练被接受后的区域在下一拍可再分配。
 *
 * 旧实现逐周期说明保留如下（仅描述旧合同）：
 * 逐周期说明：
 * - 周期 N 组合阶段：
 *   1) alloc_tail_q 指向 BPU 下一次写入位置
 *   2) ifu_head_q 指向下一条准备提供给 IFU 的 FTQ entry
 *   3) bpu_ready_o = (allocated_count_q < FTQ_DEPTH)，FTQ 未满时可接收 BPU entry
 *   4) ifu_valid_o = allocated_q[ifu_head_q] && entries_q[ifu_head_q].valid
 *                    && !consumed_q[ifu_head_q]
 *   5) ifu_entry_o / ifu_ftq_idx_o 直接反映 ifu_head_q 指向的 entry 和 index
 * - 周期 N 上升沿：
 *   1) reset 时清零所有状态，FTQ 为空
 *   2) 若 bpu_fire（bpu_valid_i && bpu_ready_o）：
 *      - 写 entries_q[alloc_tail_q]，置 allocated_q=1、consumed_q=0
 *      - alloc_tail_q 前进，allocated_count_q 加 1
 *   3) 若 ifu_fire（ifu_valid_o && ifu_ready_i）：
 *      - 置 consumed_q[ifu_head_q]=1，ifu_head_q 前进
 *      - 不清 entries_q，不清 allocated_q，不减少 allocated_count_q
 *   4) bpu_fire 与 ifu_fire 可同拍成立，各自独立推进
 *   5) release_count清除最老连续entry；mispredict优先保留目标块并截断年轻项
 * - 周期 N+1：
 *   看到更新后的三指针、容量和恢复后的正确路径分配位置
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
    ,output ftq_idx_t   dbg_alloc_tail_o
    ,output ftq_idx_t   dbg_ifu_head_o
    ,output ftq_idx_t   dbg_release_head_o
    ,output logic [$clog2(FTQ_DEPTH+1)-1:0] dbg_allocated_count_o
    `endif
);

    // ============================================================
    // 目标合同：未实现。以下全部为旧合同实现（HEAD 06462b0）。
    // ============================================================

    // Storage
    ftq_entry_t entries_q [FTQ_DEPTH];
    logic [FTQ_DEPTH-1:0] allocated_q;
    logic [FTQ_DEPTH-1:0] consumed_q;

    // Three pointers
    ftq_idx_t alloc_tail_q;
    ftq_idx_t ifu_head_q;
    ftq_idx_t release_head_q;

    // Count of allocated-but-not-yet-released entries
    logic [$clog2(FTQ_DEPTH+1)-1:0] allocated_count_q;

    // Internal fire signals
    logic bpu_fire;
    logic ifu_fire;

    `ifdef O3_FRONTEND_DEBUG
    logic dbg_bpu_fire_q;
    logic dbg_ifu_fire_q;
    `endif

    function automatic ftq_idx_t next_ptr(input ftq_idx_t ptr);
        if (FTQ_DEPTH == 1) begin
            next_ptr = '0;
        end else if (ptr == ftq_idx_t'(FTQ_DEPTH - 1)) begin
            next_ptr = '0;
        end else begin
            next_ptr = ptr + ftq_idx_t'(1);
        end
    endfunction

    function automatic ftq_idx_t ptr_add(input ftq_idx_t ptr, input int unsigned offset);
        ptr_add = ftq_idx_t'((int'(ptr) + offset) % FTQ_DEPTH);
    endfunction

    // BPU enqueue
    assign bpu_ready_o = (allocated_count_q < $clog2(FTQ_DEPTH+1)'(FTQ_DEPTH));
    assign bpu_fire    = bpu_valid_i && bpu_ready_o;

    // IFU consume
    assign ifu_valid_o   = allocated_q[ifu_head_q]
                         && entries_q[ifu_head_q].valid
                         && !consumed_q[ifu_head_q];
    assign ifu_entry_o   = entries_q[ifu_head_q];
    assign ifu_ftq_idx_o = ifu_head_q;
    assign ifu_fire      = ifu_valid_o && ifu_ready_i;

    always_comb begin
        train_valid_o = '0;
        train_entry_o = '{default: '0};
        for (int lane = 0; lane < RELEASE_WIDTH; lane++) begin
            if (lane < int'(release_count_i)) begin
                train_entry_o[lane] = entries_q[ptr_add(release_head_q, lane)];
                train_valid_o[lane] = entries_q[ptr_add(release_head_q, lane)].actual_valid;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_i) begin
            entries_q         <= '{default: '0};
            allocated_q       <= '0;
            consumed_q        <= '0;
            alloc_tail_q      <= '0;
            ifu_head_q        <= '0;
            release_head_q    <= '0;
            allocated_count_q <= '0;
            `ifdef O3_FRONTEND_DEBUG
            dbg_bpu_fire_q    <= 1'b0;
            dbg_ifu_fire_q    <= 1'b0;
            `endif
        end else if (resolution_i.valid && resolution_i.mispredict) begin
            int unsigned branch_age;
            branch_age = (int'(resolution_i.ftq_id.idx) + FTQ_DEPTH - int'(release_head_q)) % FTQ_DEPTH;
            for (int entry = 0; entry < FTQ_DEPTH; entry++) begin
                int unsigned entry_age;
                entry_age = (entry + FTQ_DEPTH - int'(release_head_q)) % FTQ_DEPTH;
                if (allocated_q[entry] && (entry_age > branch_age)) begin
                    entries_q[entry]   <= '0;
                    allocated_q[entry] <= 1'b0;
                    consumed_q[entry]  <= 1'b0;
                end
            end
            entries_q[resolution_i.ftq_id.idx].actual_valid  <= 1'b1;
            entries_q[resolution_i.ftq_id.idx].actual_branch_pc <= resolution_i.branch_pc;
            entries_q[resolution_i.ftq_id.idx].actual_branch_type <= resolution_i.is_jalr
                ? FTQ_BRANCH_JALR : (resolution_i.is_jal ? FTQ_BRANCH_JAL : FTQ_BRANCH_COND);
            entries_q[resolution_i.ftq_id.idx].actual_taken  <= resolution_i.actual_taken;
            entries_q[resolution_i.ftq_id.idx].actual_target <= resolution_i.actual_target;
            alloc_tail_q      <= next_ptr(ftq_idx_t'(resolution_i.ftq_id.idx));
            ifu_head_q        <= next_ptr(ftq_idx_t'(resolution_i.ftq_id.idx));
            allocated_count_q <= $clog2(FTQ_DEPTH+1)'(branch_age + 1);
        end else begin
            `ifdef O3_FRONTEND_DEBUG
            dbg_bpu_fire_q <= bpu_fire;
            dbg_ifu_fire_q <= ifu_fire;
            `endif

            // BPU enqueue
            if (bpu_fire) begin
                entries_q[alloc_tail_q]   <= bpu_entry_i;
                allocated_q[alloc_tail_q] <= 1'b1;
                consumed_q[alloc_tail_q]  <= 1'b0;
                alloc_tail_q              <= next_ptr(alloc_tail_q);
            end

            // IFU consume — does not release capacity
            if (ifu_fire) begin
                consumed_q[ifu_head_q] <= 1'b1;
                ifu_head_q             <= next_ptr(ifu_head_q);
            end

            // Commit按程序顺序给出可释放FTQ项数；训练观察值在清除前组合输出。
            for (int released = 0; released < RELEASE_WIDTH; released++) begin
                if (released < int'(release_count_i)) begin
                    entries_q[ptr_add(release_head_q, released)]   <= '0;
                    allocated_q[ptr_add(release_head_q, released)] <= 1'b0;
                    consumed_q[ptr_add(release_head_q, released)]  <= 1'b0;
                end
            end
            if (release_count_i != '0) begin
                release_head_q <= ptr_add(release_head_q, int'(release_count_i));
            end

            if (resolution_i.valid) begin
                entries_q[resolution_i.ftq_id.idx].actual_valid  <= 1'b1;
                entries_q[resolution_i.ftq_id.idx].actual_branch_pc <= resolution_i.branch_pc;
                entries_q[resolution_i.ftq_id.idx].actual_branch_type <= resolution_i.is_jalr
                    ? FTQ_BRANCH_JALR : (resolution_i.is_jal ? FTQ_BRANCH_JAL : FTQ_BRANCH_COND);
                entries_q[resolution_i.ftq_id.idx].actual_taken  <= resolution_i.actual_taken;
                entries_q[resolution_i.ftq_id.idx].actual_target <= resolution_i.actual_target;
            end

            allocated_count_q <= allocated_count_q
                               + $clog2(FTQ_DEPTH+1)'(bpu_fire)
                               - $clog2(FTQ_DEPTH+1)'(release_count_i);
        end
    end

    `ifdef O3_FRONTEND_DEBUG
    assign dbg_ifu_fire_o         = dbg_ifu_fire_q;
    assign dbg_bpu_fire_o         = dbg_bpu_fire_q;
    assign dbg_alloc_tail_o       = alloc_tail_q;
    assign dbg_ifu_head_o         = ifu_head_q;
    assign dbg_release_head_o     = release_head_q;
    assign dbg_allocated_count_o  = allocated_count_q;
    `endif

    initial begin
        if (FTQ_DEPTH <= 0) begin
            $error("ftq requires FTQ_DEPTH > 0");
        end

        if (FTQ_BLOCK_BYTES <= 0) begin
            $error("ftq requires FTQ_BLOCK_BYTES > 0");
        end

        if (FTQ_FETCH_WINDOW_BYTES <= 0) begin
            $error("ftq requires FTQ_FETCH_WINDOW_BYTES > 0");
        end
    end

endmodule
