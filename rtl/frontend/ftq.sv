/**
 * Fetch Target Queue — prediction/fetch/commit三指针队列
 *
 * 当前已经实现的内容：
 * - BPU 入队端口（bpu_valid_i / bpu_ready_o / bpu_entry_i）
 * - IFU 消费端口（ifu_valid_o / ifu_ready_i / ifu_entry_o / ifu_ftq_idx_o）
 * - 三指针骨架：alloc_tail_q / ifu_head_q / release_head_q
 * - allocated_count_q：已分配但尚未 release 的 entry 计数
 * - reset 后 FTQ 为空，运行时由 BPU 写入、IFU 消费
 *
 * 当前没有实现的内容：
 * - 训练观察输出尚未接入BTB/BHT/RAS
 * - 不实现 BPU-to-IFU bypass（BPU 入队的 entry 下一拍才可见于 IFU）
 *
 * 后续扩展入口：
 * - 真实预测器可消费train输出并生成带预测控制流边界的ftq_entry
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
 *   5) release_count清除最老连续entry；mispredict优先保留目标块并截断年轻项
 * - 周期 N+1：
 *   看到更新后的三指针、容量和恢复后的正确路径分配位置
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
    parameter int RELEASE_WIDTH = o3_pkg::BACKEND_MACHINE_WIDTH
)
(
    input  logic       clk_i,
    input  logic       rst_i,
    input  logic       flush_i,

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
    output ftq_entry_t                         train_entry_o [RELEASE_WIDTH-1:0]

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
            branch_age = (int'(resolution_i.ftq_idx) + FTQ_DEPTH - int'(release_head_q)) % FTQ_DEPTH;
            for (int entry = 0; entry < FTQ_DEPTH; entry++) begin
                int unsigned entry_age;
                entry_age = (entry + FTQ_DEPTH - int'(release_head_q)) % FTQ_DEPTH;
                if (allocated_q[entry] && (entry_age > branch_age)) begin
                    entries_q[entry]   <= '0;
                    allocated_q[entry] <= 1'b0;
                    consumed_q[entry]  <= 1'b0;
                end
            end
            entries_q[resolution_i.ftq_idx].actual_valid  <= 1'b1;
            entries_q[resolution_i.ftq_idx].actual_branch_pc <= resolution_i.branch_pc;
            entries_q[resolution_i.ftq_idx].actual_branch_type <= resolution_i.is_jalr
                ? FTQ_BRANCH_JALR : (resolution_i.is_jal ? FTQ_BRANCH_JAL : FTQ_BRANCH_COND);
            entries_q[resolution_i.ftq_idx].actual_taken  <= resolution_i.actual_taken;
            entries_q[resolution_i.ftq_idx].actual_target <= resolution_i.actual_target;
            alloc_tail_q      <= next_ptr(ftq_idx_t'(resolution_i.ftq_idx));
            ifu_head_q        <= next_ptr(ftq_idx_t'(resolution_i.ftq_idx));
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
                entries_q[resolution_i.ftq_idx].actual_valid  <= 1'b1;
                entries_q[resolution_i.ftq_idx].actual_branch_pc <= resolution_i.branch_pc;
                entries_q[resolution_i.ftq_idx].actual_branch_type <= resolution_i.is_jalr
                    ? FTQ_BRANCH_JALR : (resolution_i.is_jal ? FTQ_BRANCH_JAL : FTQ_BRANCH_COND);
                entries_q[resolution_i.ftq_idx].actual_taken  <= resolution_i.actual_taken;
                entries_q[resolution_i.ftq_idx].actual_target <= resolution_i.actual_target;
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
