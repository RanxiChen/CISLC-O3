/**
 * Fetch Target Queue — BPU 入队三指针骨架
 *
 * 当前已经实现的内容：
 * - BPU 入队端口（bpu_valid_i / bpu_ready_o / bpu_entry_i）
 * - IFU 消费端口（ifu_valid_o / ifu_ready_i / ifu_entry_o / ifu_ftq_idx_o）
 * - 三指针骨架：alloc_tail_q / ifu_head_q / release_head_q
 * - allocated_count_q：已分配但尚未 release 的 entry 计数
 * - reset 后 FTQ 为空，运行时由 BPU 写入、IFU 消费
 * - Redirect repair 接口与 entry 级修复（Task 3A + 3B）
 *
 * 当前没有实现的内容：
 * - 不实现 release / commit 回收（release_head_q 只保留状态，不推进）
 * - 不实现 redirect 后的 pointer rewind（alloc_tail_q / ifu_head_q / allocated_count_q 调整）
 * - 不实现后端或 branch execute 的 FTQ 回查端口
 * - 不实现 BPU-to-IFU bypass（BPU 入队的 entry 下一拍才可见于 IFU）
 *
 * Redirect Repair 说明（Task 3A + 3B）：
 * - redirect repair 输入端口接收 backend 的 branch mispredict 信号
 * - redirect repair 是 correctness event，优先级高于普通 enqueue / consume
 * - 当 redirect_valid_i=1 时，FTQ 优先处理 redirect，暂停正常更新
 * - Task 3B 实现了 entry 级 wrong-path 修复：
 *   - younger entries（redirect_ftq_idx_i 之后、alloc_tail_q 之前的 allocated entries）被 invalidated
 *   - branch entry 被修复：end_pc = branch_pc + 4，next_pc = redirect_pc
 *   - older entries 保持不变
 * - Task 3C 将实现 pointer rewind（alloc_tail_q / ifu_head_q / allocated_count_q）
 *
 * 后续扩展入口：
 * - release 逻辑会清 allocated_q / consumed_q / entry，推进 release_head_q，
 *   并将 allocated_count_q 减 1，从而释放 FTQ 容量
 * - flush / redirect 逻辑需要同时维护三指针和 allocated_count_q
 *
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
 *   5) 若 redirect_valid_i=1：
 *      - invalidated younger entries（redirect_ftq_idx_i 之后的 allocated entries）
 *      - 修复 branch entry（end_pc, next_pc）
 *      - bpu_fire 和 ifu_fire 被抑制
 * - 周期 N+1：
 *   看到更新后的指针；BPU 入队的 entry 此拍才可被 IFU 看到
 */

package ftq_pkg;
    import o3_pkg::*;

    localparam int FTQ_DEPTH                 = 16;
    localparam int FTQ_BLOCK_BYTES           = 32;
    localparam int FTQ_FETCH_WINDOW_BYTES    = 16;
    localparam int FTQ_BRANCH_SLOT_WIDTH     = 3;
    localparam int FTQ_INDEX_WIDTH           = o3_pkg::FTQ_INDEX_WIDTH;
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

        logic                       exception;
        ftq_exception_cause_t       exception_cause;
    } ftq_entry_t;

endpackage

module ftq
    import ftq_pkg::*;
(
    input  logic       clk_i,
    input  logic       rst_i,

    // BPU enqueue port
    input  logic       bpu_valid_i,
    output logic       bpu_ready_o,
    input  ftq_entry_t bpu_entry_i,

    // IFU consume port
    output logic       ifu_valid_o,
    input  logic       ifu_ready_i,
    output ftq_entry_t ifu_entry_o,
    output ftq_idx_t   ifu_ftq_idx_o,

    // Redirect repair port (correctness event, highest local priority)
    input  logic       redirect_valid_i,
    input  ftq_idx_t   redirect_ftq_idx_i,
    input  ftq_pc_t    redirect_branch_pc_i,
    input  ftq_pc_t    redirect_redirect_pc_i,
    input  logic       redirect_actual_taken_i

    `ifdef O3_FRONTEND_DEBUG
    ,output logic       dbg_ifu_fire_o
    ,output logic       dbg_bpu_fire_o
    ,output ftq_idx_t   dbg_alloc_tail_o
    ,output ftq_idx_t   dbg_ifu_head_o
    ,output ftq_idx_t   dbg_release_head_o
    ,output logic [$clog2(FTQ_DEPTH+1)-1:0] dbg_allocated_count_o
    `endif
);

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

    // Ring-buffer age predicate: is idx in the allocated window and younger than branch?
    // "Younger" means idx is in the open interval (branch_idx, alloc_tail) on the ring.
    // We use allocated_q[idx] to determine if idx is in the window, which correctly
    // handles both the empty-window and full-window cases where head == tail.
    function automatic logic is_younger(
        input ftq_idx_t idx,
        input ftq_idx_t branch_idx,
        input ftq_idx_t tail,
        input logic     is_allocated
    );
        // Quick reject: not allocated => not younger
        // idx == branch_idx is the branch itself, not younger
        if (!is_allocated || (idx == branch_idx)) begin
            is_younger = 1'b0;
        end
        // When branch_idx == tail, the interval wraps the entire ring except branch_idx,
        // so every other allocated entry is younger.
        else if (branch_idx == tail) begin
            is_younger = 1'b1;
        end
        // No wrap: idx is younger if branch_idx < idx < tail
        else if (branch_idx < tail) begin
            is_younger = (idx > branch_idx) && (idx < tail);
        end
        // Wrap around: idx is younger if idx > branch_idx OR idx < tail
        else begin
            is_younger = (idx > branch_idx) || (idx < tail);
        end
    endfunction

    // BPU enqueue — suppressed during redirect
    assign bpu_ready_o = (allocated_count_q < FTQ_DEPTH) && !redirect_valid_i;
    assign bpu_fire    = bpu_valid_i && bpu_ready_o;

    // IFU consume — suppressed during redirect
    assign ifu_valid_o = allocated_q[ifu_head_q]
                         && entries_q[ifu_head_q].valid
                         && !consumed_q[ifu_head_q]
                         && !redirect_valid_i;
    assign ifu_entry_o   = entries_q[ifu_head_q];
    assign ifu_ftq_idx_o = ifu_head_q;
    assign ifu_fire      = ifu_valid_o && ifu_ready_i;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
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
        end else begin
            `ifdef O3_FRONTEND_DEBUG
            dbg_bpu_fire_q <= bpu_fire;
            dbg_ifu_fire_q <= ifu_fire;
            `endif

            // ============================================================
            // Redirect repair — correctness event, highest local priority
            // ============================================================
            // When redirect_valid_i=1, FTQ must prioritize redirect repair
            // over normal enqueue/consume updates for affected slots.
            //
            // Priority order (highest to lowest):
            //   1. redirect_valid_i (correctness repair)
            //   2. bpu_fire (normal enqueue)
            //   3. ifu_fire (normal consume)
            //
            // Task 3B: redirect takes priority by suppressing bpu_fire and
            // ifu_fire when redirect is active, and performs entry-level repair:
            //   - invalidated younger entries (valid=0)
            //   - repairs branch entry (end_pc, next_pc)
            // Task 3C will add pointer rewind (alloc_tail_q, ifu_head_q, allocated_count_q).
            // ============================================================

            // BPU enqueue — suppressed during redirect
            if (bpu_fire && !redirect_valid_i) begin
                entries_q[alloc_tail_q]   <= bpu_entry_i;
                allocated_q[alloc_tail_q] <= 1'b1;
                consumed_q[alloc_tail_q]  <= 1'b0;
                alloc_tail_q              <= next_ptr(alloc_tail_q);
                allocated_count_q         <= allocated_count_q + 1'b1;
            end

            // IFU consume — suppressed during redirect
            if (ifu_fire && !redirect_valid_i) begin
                consumed_q[ifu_head_q] <= 1'b1;
                ifu_head_q             <= next_ptr(ifu_head_q);
            end

            // Redirect repair — Task 3B: entry-level wrong-path repair
            // When redirect_valid_i=1:
            //   1. Invalidate all younger allocated entries (after branch, before tail)
            //   2. Repair the branch entry itself (end_pc, next_pc)
            //   3. Older entries remain unchanged
            //
            // Task 3C will handle pointer rewind (alloc_tail_q, ifu_head_q, allocated_count_q).
            if (redirect_valid_i) begin
                // Step 1: Invalidate younger entries
                // Iterate over all FTQ slots; those that are allocated, in the
                // younger window (redirect_ftq_idx_i, alloc_tail_q), get invalidated.
                for (int i = 0; i < FTQ_DEPTH; i++) begin
                    if (is_younger(ftq_idx_t'(i), redirect_ftq_idx_i, alloc_tail_q, allocated_q[i])) begin
                        entries_q[i].valid <= 1'b0;
                        // Note: allocated_q and consumed_q are NOT cleared here.
                        // They remain set until Task 3C rewinds the pointers.
                        // This is correctness repair, not capacity release.
                    end
                end

                // Step 2: Repair the branch entry
                // Truncate the block to end at branch_pc + 4,
                // and redirect next_pc to the actual target.
                entries_q[redirect_ftq_idx_i].end_pc   <= redirect_branch_pc_i + ftq_pc_t'(4);
                entries_q[redirect_ftq_idx_i].next_pc   <= redirect_redirect_pc_i;
                // Update pred_taken to reflect actual outcome
                entries_q[redirect_ftq_idx_i].pred_taken <= redirect_actual_taken_i;
                // Update target_pc for consistency
                entries_q[redirect_ftq_idx_i].target_pc  <= redirect_redirect_pc_i;

                // Task 3C TODO: rewind alloc_tail_q to next_ptr(redirect_ftq_idx_i)
                // Task 3C TODO: adjust ifu_head_q if it points into invalidated region
                // Task 3C TODO: recompute allocated_count_q
            end

            // Release logic: not yet implemented.
            // Future behavior will:
            //   - clear allocated_q[release_head_q]
            //   - clear consumed_q[release_head_q]
            //   - clear entries_q[release_head_q]
            //   - advance release_head_q
            //   - allocated_count_q -= 1
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
