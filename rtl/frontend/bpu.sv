/**
 * BPU —— 预测器总装：uBTB 快预测 + 主 BTB/TAGE 慢预测 + 历史 + RAS
 *
 * 作用（目标）：
 * - 每拍为一个 16B 对齐区域给出快预测，并在 FTQ 接受时分配 entry（D01、D02、D03）。
 * - 同时把该区域的入口历史快照（D23）与 RAS 块前标记（第 6.2 节）交给 FTQ/快照存储。
 * - 主 BTB 两拍、TAGE 三拍的结果在 bpu_slow_check 对齐，写回慢预测并在路径改变时
 *   发出慢覆盖请求（第 6.3 节）。
 * - 接受 redirect_arbiter 的赢家：恢复历史 E/C 与 RAS，再从 target_pc 继续预测（D24）。
 * - 接受 FTQ 提交训练请求，分发给 uBTB/主 BTB/TAGE（D08）。
 *
 * 子模块：ubtb、main_btb、tage、branch_history、ras、bpu_slow_check。
 *
 * 需要补充实现的机制：
 * - 预测 PC 寄存器：分配握手推进到快预测 next_pc；恢复期间（recover_busy_i）暂停；
 *   arb_redirect 时改为赢家 target_pc。
 * - 快预测随 FTQ 身份进入两/三拍对齐寄存，与 BTB/TAGE 结果同时到达 bpu_slow_check。
 * - 只对实际选中且成功分配的区域推进历史与 RAS 一次（第 6.2、14 节）；
 *   taken 条件分支且有可用目标时才 push 历史（D09）；target_missing 时不推进。
 * - 慢覆盖发生时：错误路径在途查询被 kill，按 D24 恢复。
 * - 训练端口的分发与反压（三张表的训练排程待定，第 6.1 节）。
 * - 子模块 perf 增量合并。
 *
 * 细节待定：寄存边界统一口径（第 4.1 节）；各表容量见 o3_cfg_pkg。
 * 不在第一版：SC、loop predictor、ITTAGE。
 *
 * 当前实现状态：闭环简化（L1）
 * - 为 L1 实现：目标端口每次 FTQ 分配产生顺序 16B 区域与身份确认；训练直接接受。
 * - 闭环简化：不查询 uBTB/主 BTB/TAGE，不推进历史/RAS；偏离 D01/D03/D09/D23，
 *   预测目标、快慢覆盖和恢复待 L2。每个已分配区域在下一拍向 FTQ 回写同一预测，
 *   使所有 L1 demand 对应的 slow_done 在返回队列读取 brief 前恒为已完成；
 *   只有 L2 启用主 BTB/TAGE 的真实多拍结果后，完成时刻才会变复杂。
 * - 仍未实现：慢覆盖和性能事件（显式 tie-off）；旧 32B 合同保留但未连接。
 * - 测试：sim/cocotb/bpu/
 *
 * 目标周期行为：
 * - 周期 N 组合：uBTB 用 pred_pc 给出 alloc_pred_o；alloc_valid_o=!recover_busy_i。
 * - 周期 N 上升沿：alloc 握手时 pred_pc 推进，branch_history/ras 按本区域动作更新，
 *   主 BTB/TAGE 以该区域启动查询。
 * - 周期 N+2：同一区域的慢结果到达 bpu_slow_check，N+2 末写回 FTQ。
 *
 */

module bpu
    import o3_pkg::*;
    import ftq_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic clk_i,
    input  logic rst_i,

    // ---------------- 旧合同（迁移后删除） ----------------
    input  logic [PC_WIDTH-1:0] reset_pc_i,
    input  logic                flush_i,
    input  logic                redirect_valid_i,
    input  logic [PC_WIDTH-1:0] redirect_pc_i,

    output logic       ftq_valid_o,
    input  logic       ftq_ready_i,
    output ftq_entry_t ftq_entry_o,

    // ---------------- 目标合同 ----------------
    input  o3_types_pkg::vaddr_t          boot_pc_i,

    // 分配到 FTQ：快预测、入口历史快照、RAS 块前标记
    output logic                          alloc_valid_o,
    input  logic                          alloc_ready_i,
    input  o3_types_pkg::ftq_id_t         alloc_ftq_id_i,     // FTQ 下一次分配的身份
    output o3_types_pkg::bpu_pred_t       alloc_pred_o,
    output o3_types_pkg::hist_snapshot_t  alloc_snapshot_o,
    output o3_types_pkg::ras_ckpt_t       alloc_ras_ckpt_o,

    // 慢预测
    output o3_types_pkg::bpu_slow_t       slow_o,
    output o3_types_pkg::redirect_req_t   override_o,

    // D24 赢家与恢复
    input  logic                          arb_redirect_valid_i,
    input  o3_types_pkg::vaddr_t          arb_redirect_pc_i,
    input  logic                          recover_busy_i,
    input  o3_types_pkg::fe_kill_t        kill_i,
    input  logic                          hist_restore_valid_i,
    input  o3_types_pkg::hist_snapshot_t  hist_restore_snapshot_i,
    input  logic                          hist_restore_inject_i,
    input  o3_types_pkg::vaddr_t          hist_restore_branch_pc_i,
    input  o3_types_pkg::vaddr_t          hist_restore_target_pc_i,
    output logic                          hist_restore_done_o,
    // D29：RAS 入口索引/占用数/栈顶快速修复；无 undo log，无提交释放端口。
    input  logic                          ras_recover_valid_i,
    input  o3_types_pkg::ftq_id_t         ras_recover_id_i,
    input  o3_types_pkg::ras_ckpt_t       ras_recover_ckpt_i,
    input  o3_types_pkg::ras_action_e     ras_fix_i,
    input  o3_types_pkg::vaddr_t          ras_fix_push_addr_i,
    output logic                          ras_recover_done_o,
    output o3_types_pkg::ftq_id_t         ras_recover_done_id_o,

    // 同步期间暂停预测（frontend_sync_ctrl）
    input  logic                          hold_i,

    // 提交训练
    input  logic                          train_valid_i,
    output logic                          train_ready_o,
    input  o3_types_pkg::bpu_train_t      train_i,

    output o3_types_pkg::fe_perf_t        perf_o
);

    // L1: one sequential 16B prediction per successful FTQ allocation.
    // The region identity is supplied by FTQ on the allocation handshake.
    o3_types_pkg::vaddr_t pred_pc_target_q;
    o3_types_pkg::bpu_slow_t completion_q;
    logic alloc_fire;

    assign alloc_valid_o = !rst_i && !hold_i && !recover_busy_i && !kill_i.valid;
    assign alloc_fire = alloc_valid_o && alloc_ready_i;
    always_comb begin
        alloc_pred_o = '0;
        alloc_pred_o.region_base = pred_pc_target_q & ~o3_types_pkg::vaddr_t'(15);
        alloc_pred_o.entry_slot = o3_types_pkg::fetch_slot_t'(pred_pc_target_q[3:1]);
        alloc_pred_o.next_pc = alloc_pred_o.region_base + o3_types_pkg::vaddr_t'(16);
    end
    // No speculative branch/RAS action exists in L1. The entry snapshots are
    // constant, and accepted training cannot hold the FTQ release pointer.
    assign alloc_snapshot_o = '0;
    assign alloc_ras_ckpt_o = '0;
    assign train_ready_o = 1'b1;
    assign hist_restore_done_o = hist_restore_valid_i;
    assign ras_recover_done_o = ras_recover_valid_i;
    assign ras_recover_done_id_o = ras_recover_id_i;
    assign override_o = '0;
    assign perf_o = '0;
    assign slow_o = completion_q;

    // N: FTQ accepts the prediction and records its identity. At edge N, the
    // PC advances and the same prediction is registered as completed. N+1:
    // FTQ consumes that completion and sets slow_done. No slow table is queried.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            pred_pc_target_q <= boot_pc_i;
            completion_q <= '0;
        end else begin
            completion_q <= '0;
            if (alloc_fire) begin
                completion_q.valid <= 1'b1;
                completion_q.ftq_id <= alloc_ftq_id_i;
                completion_q.pred <= alloc_pred_o;
            end
            if (arb_redirect_valid_i) pred_pc_target_q <= arb_redirect_pc_i;
            else if (alloc_fire) pred_pc_target_q <= alloc_pred_o.next_pc;
        end
    end

    // ============================================================
    // 旧合同：HEAD 06462b0 顺序 32B 生成器（占位，迁移后删除）
    // ============================================================
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
        actual_valid:    1'b0,
        actual_branch_pc:'0,
        actual_branch_type: FTQ_BRANCH_NONE,
        actual_taken:    1'b0,
        actual_target:   '0,
        exception:       1'b0,
        exception_cause: '0
    };

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            pred_pc_q <= reset_pc_i;
        end else if (redirect_valid_i) begin
            pred_pc_q <= redirect_pc_i;
        end else if (flush_i) begin
            pred_pc_q <= reset_pc_i;
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
