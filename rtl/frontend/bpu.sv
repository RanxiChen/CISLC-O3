/**
 * Branch Prediction Unit — Sequential-Only with Redirect Reseed
 *
 * 当前 BPU 是 sequential-only BPU，不做真实分支预测。
 * 它从 reset_pc_i 开始，按 32B fetch block 顺序生成 ftq_entry_t，
 * 通过 ready/valid 接口提供给未来 FTQ 入队端。
 *
 * 当 reset_pc_i=0 时，生成的 block 序列与当前 FTQ reset 预置的 block 字段一致。
 *
 * 当前已经实现：
 * - 从 reset_pc_i 开始顺序生成 32B fetch block
 * - ready/valid 握手：backpressure 时冻结 PC，不跳过任何 block
 * - 已支持 redirect reseed：收到 redirect_valid_i 时立即将 pred_pc_q 重置为 redirect_pc_i
 *
 * 当前没有实现：
 * - 不做真实分支预测（BTB/BHT/RAS/history）
 * - 不实现 flush/训练接口
 *
 * 后续扩展入口：
 * - 后续可在此模块内逐步加入 BTB、BHT、RAS 等真实预测器
 * - 后续可扩展 flush 恢复逻辑和训练接口
 */

module bpu
    import o3_pkg::*;
    import ftq_pkg::*;
(
    input  logic clk_i,
    input  logic rst_i,

    input  logic [PC_WIDTH-1:0] reset_pc_i,

    input  logic                redirect_valid_i,
    input  logic [PC_WIDTH-1:0] redirect_pc_i,

    output logic       ftq_valid_o,
    input  logic       ftq_ready_i,
    output ftq_entry_t ftq_entry_o
);

    logic [PC_WIDTH-1:0] pred_pc_q;
    logic                ftq_fire;

    assign ftq_valid_o = 1'b1;
    assign ftq_fire    = ftq_valid_o && ftq_ready_i;

    // ftq_entry_o: combinational, reflects current pred_pc_q
    assign ftq_entry_o = '{
        valid:           1'b1,
        start_pc:        pred_pc_q,
        end_pc:          pred_pc_q + ftq_pc_t'(FTQ_BLOCK_BYTES),
        has_branch:      1'b0,
        branch_pc:       '0,
        branch_slot:     '0,
        branch_type:     FTQ_BRANCH_NONE,
        pred_taken:      1'b0,
        target_pc:       '0,
        fallthrough_pc:  pred_pc_q + ftq_pc_t'(FTQ_BLOCK_BYTES),
        next_pc:         pred_pc_q + ftq_pc_t'(FTQ_BLOCK_BYTES),
        exception:       1'b0,
        exception_cause: '0
    };

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            pred_pc_q <= reset_pc_i;
        end else if (redirect_valid_i) begin
            pred_pc_q <= redirect_pc_i;
        end else if (ftq_fire) begin
            pred_pc_q <= pred_pc_q + ftq_pc_t'(FTQ_BLOCK_BYTES);
        end
    end

    initial begin
        if (FTQ_BLOCK_BYTES <= 0) begin
            $error("bpu requires FTQ_BLOCK_BYTES > 0");
        end
    end

endmodule
