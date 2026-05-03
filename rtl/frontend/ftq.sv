/**
 * Fetch Target Queue — BPU 入队三指针骨架
 *
 * 当前已经实现的内容：
 * - BPU 入队端口（bpu_valid_i / bpu_ready_o / bpu_entry_i）
 * - IFU 消费端口（ifu_valid_o / ifu_ready_i / ifu_entry_o / ifu_ftq_idx_o）
 * - 三指针骨架：alloc_tail_q / ifu_head_q / release_head_q
 * - allocated_count_q：已分配但尚未 release 的 entry 计数
 * - reset 后 FTQ 为空，运行时由 BPU 写入、IFU 消费
 *
 * 当前没有实现的内容：
 * - 不实现 release / commit 回收（release_head_q 只保留状态，不推进）
 * - 不实现 flush / redirect / invalidate
 * - 不实现后端或 branch execute 的 FTQ 回查端口
 * - 不实现 BPU-to-IFU bypass（BPU 入队的 entry 下一拍才可见于 IFU）
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
    output ftq_idx_t   ifu_ftq_idx_o

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

    // BPU enqueue
    assign bpu_ready_o = (allocated_count_q < FTQ_DEPTH);
    assign bpu_fire    = bpu_valid_i && bpu_ready_o;

    // IFU consume
    assign ifu_valid_o   = allocated_q[ifu_head_q]
                         && entries_q[ifu_head_q].valid
                         && !consumed_q[ifu_head_q];
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

            // BPU enqueue
            if (bpu_fire) begin
                entries_q[alloc_tail_q]   <= bpu_entry_i;
                allocated_q[alloc_tail_q] <= 1'b1;
                consumed_q[alloc_tail_q]  <= 1'b0;
                alloc_tail_q              <= next_ptr(alloc_tail_q);
                allocated_count_q         <= allocated_count_q + 1'b1;
            end

            // IFU consume — does not release capacity
            if (ifu_fire) begin
                consumed_q[ifu_head_q] <= 1'b1;
                ifu_head_q             <= next_ptr(ifu_head_q);
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
