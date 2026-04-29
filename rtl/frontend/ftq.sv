/**
 * Fetch Target Queue Types
 *
 * 当前已经定义的内容：
 * - FTQ 第一版表项字段类型
 * - block 级分支类型枚举
 * - FTQ index、branch slot、exception cause 等基础宽度常量
 *
 * 当前已经实现的内容：
 * - 只实现 IFU 消费端 ready/valid 接口
 * - reset 时预置一组有效、无分支、无异常的 32B block
 * - IFU 消费 entry 后只标记 consumed 并推进 ifu_head_q，不清 entry 内容
 *
 * 当前没有实现的内容：
 * - 暂时不实现 BPU 写入端
 * - 暂时不实现 release / invalidate / flush / redirect
 * - 暂时不实现后端或 branch execute 的 FTQ 回查端口
 * - 暂时不写测试代码和仿真代码
 *
 * 后续扩展入口：
 * - 后续在本模块补充 alloc_tail_q / release_head_q 对应的端口和状态推进
 * - 后续如果 FTQ_DEPTH / FTQ_BLOCK_BYTES 需要由顶层参数化，再把这些类型迁移到公共 package
 *
 * 逐周期说明：
 * - 周期 N 组合阶段：
 *   1) ifu_head_q 指向下一条准备提供给 IFU 的 FTQ entry
 *   2) 若该 entry 已分配、entry.valid=1 且尚未 consumed，则 ifu_valid_o=1
 *   3) ifu_entry_o / ifu_ftq_idx_o 直接反映 ifu_head_q 指向的 entry 和 index
 * - 周期 N 上升沿：
 *   1) reset 时预置 FTQ_DEPTH 个 32B 顺序 block，并把 ifu_head_q 置 0
 *   2) 若 ifu_valid_o && ifu_ready_i，则只置 consumed_q[ifu_head_q]=1，并推进 ifu_head_q
 *   3) 消费不会清 entries_q，不会清 entries_q.valid，也不会清 allocated_q
 * - 周期 N+1：
 *   看到更新后的 ifu_head_q；如果下一条 entry 仍可消费，则继续向 IFU 拉高 valid
 */

package ftq_pkg;
    import o3_pkg::*;

    localparam int FTQ_DEPTH                 = 16;
    localparam int FTQ_BLOCK_BYTES           = 32;
    localparam int FTQ_FETCH_WINDOW_BYTES    = 16;
    localparam int FTQ_BRANCH_SLOT_WIDTH     = 3;
    localparam int FTQ_INDEX_WIDTH           = (FTQ_DEPTH > 1) ? $clog2(FTQ_DEPTH) : 1;
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

    output logic       ifu_valid_o,
    input  logic       ifu_ready_i,
    output ftq_entry_t ifu_entry_o,
    output ftq_idx_t   ifu_ftq_idx_o
);

    ftq_entry_t entries_q [FTQ_DEPTH];
    logic [FTQ_DEPTH-1:0] allocated_q;
    logic [FTQ_DEPTH-1:0] consumed_q;
    ftq_idx_t             ifu_head_q;
    logic                 ifu_fire;

    function automatic ftq_idx_t next_ptr(input ftq_idx_t ptr);
        if (FTQ_DEPTH == 1) begin
            next_ptr = '0;
        end else if (ptr == ftq_idx_t'(FTQ_DEPTH - 1)) begin
            next_ptr = '0;
        end else begin
            next_ptr = ptr + ftq_idx_t'(1);
        end
    endfunction

    function automatic ftq_entry_t make_reset_entry(input int unsigned entry_idx);
        ftq_pc_t start_pc;
        ftq_pc_t end_pc;

        start_pc = ftq_pc_t'(entry_idx * FTQ_BLOCK_BYTES);
        end_pc   = start_pc + ftq_pc_t'(FTQ_BLOCK_BYTES);

        make_reset_entry = '{
            valid:           1'b1,
            start_pc:        start_pc,
            end_pc:          end_pc,
            has_branch:      1'b0,
            branch_pc:       '0,
            branch_slot:     '0,
            branch_type:     FTQ_BRANCH_NONE,
            pred_taken:      1'b0,
            target_pc:       '0,
            fallthrough_pc:  end_pc,
            next_pc:         end_pc,
            exception:       1'b0,
            exception_cause: '0
        };
    endfunction

    // 消费端只观察 ifu_head_q 指向的 entry。消费成功后不会释放槽位，
    // 只用 consumed_q 防止同一个预置 entry 被 IFU 重复消费。
    assign ifu_valid_o   = allocated_q[ifu_head_q]
                         && entries_q[ifu_head_q].valid
                         && !consumed_q[ifu_head_q];
    assign ifu_entry_o   = entries_q[ifu_head_q];
    assign ifu_ftq_idx_o = ifu_head_q;
    assign ifu_fire      = ifu_valid_o && ifu_ready_i;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int i = 0; i < FTQ_DEPTH; i++) begin
                entries_q[i]   <= make_reset_entry(i);
                allocated_q[i] <= 1'b1;
                consumed_q[i]  <= 1'b0;
            end

            ifu_head_q <= '0;
        end else if (ifu_fire) begin
            consumed_q[ifu_head_q] <= 1'b1;
            ifu_head_q             <= next_ptr(ifu_head_q);
        end
    end

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
