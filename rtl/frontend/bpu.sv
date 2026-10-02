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
 * 当前实现状态：
 * - 保留 HEAD 06462b0 的顺序 32B not-taken 生成器及其旧端口（ftq_*、redirect_*、
 *   flush_i），标为“旧合同”。它不符合 D03 的 16B 区域，目标总装 frontend 不再连接
 *   这些旧端口；迁移完成后删除。
 * - 目标端口与子模块例化已列出；子模块均为空壳，本模块内的预测 PC、对齐流水、
 *   动作唯一性控制均未实现，目标输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N 组合：uBTB 用 pred_pc 给出 alloc_pred_o；alloc_valid_o=!recover_busy_i。
 * - 周期 N 上升沿：alloc 握手时 pred_pc 推进，branch_history/ras 按本区域动作更新，
 *   主 BTB/TAGE 以该区域启动查询。
 * - 周期 N+2：同一区域的慢结果到达 bpu_slow_check，N+2 末写回 FTQ。
 *
 * 本阶段不写测试代码和仿真代码。
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

    // ============================================================
    // 目标结构：子模块例化。内部信号的驱动（预测 PC、对齐流水）未实现。
    // ============================================================
    o3_types_pkg::vaddr_t         pred_pc;           // 未实现：预测 PC 寄存器
    logic                         stall;             // 未实现：= !alloc_ready_i || recover_busy_i || hold_i
    logic                         ubtb_hit;
    o3_types_pkg::bpu_pred_t      ubtb_pred;
    logic                         btb_resp_valid, tage_resp_valid;
    o3_types_pkg::btb_resp_t      btb_resp;
    o3_types_pkg::tage_resp_t     tage_resp;
    o3_types_pkg::hist_snapshot_t hist_cur;
    logic                         hist_push_valid;   // 未实现：taken 条件分支且目标可用（D09）
    o3_types_pkg::vaddr_t         hist_push_branch_pc, hist_push_target_pc;
    logic                         ras_op_valid;      // 未实现：成功分配且有 RAS 动作
    o3_types_pkg::vaddr_t         ras_top;
    logic                         ras_top_valid;
    // 未实现：快预测对齐寄存，使 fast_* 与慢结果对应同一区域
    logic                         fast_aligned_valid;
    o3_types_pkg::ftq_id_t        fast_aligned_ftq_id;
    o3_types_pkg::bpu_pred_t      fast_aligned_pred;
    o3_types_pkg::ras_ckpt_t      fast_aligned_ras_ckpt;
    logic                         slow_pipe_kill;    // 未实现：由 kill_i/慢覆盖得到
    o3_types_pkg::fe_perf_t       perf_ubtb, perf_btb, perf_tage, perf_ras, perf_slow;

    ubtb #(.CFG(CFG)) u_ubtb (
        .clk_i(clk_i), .rst_i(rst_i),
        .lookup_valid_i(!stall), .lookup_pc_i(pred_pc), .stall_i(stall),
        .hit_o(ubtb_hit), .pred_o(ubtb_pred),
        .train_valid_i(train_valid_i), .train_ready_o(), .train_i(train_i),
        .perf_o(perf_ubtb)
    );

    main_btb #(.CFG(CFG)) u_main_btb (
        .clk_i(clk_i), .rst_i(rst_i),
        .s0_valid_i(alloc_valid_o && alloc_ready_i), .s0_region_base_i(pred_pc),
        .stall_i(stall), .kill_i(slow_pipe_kill),
        .resp_valid_o(btb_resp_valid), .resp_o(btb_resp),
        .train_valid_i(train_valid_i), .train_ready_o(), .train_i(train_i),
        .perf_o(perf_btb)
    );

    tage #(.CFG(CFG)) u_tage (
        .clk_i(clk_i), .rst_i(rst_i),
        .s0_valid_i(alloc_valid_o && alloc_ready_i), .s0_region_base_i(pred_pc),
        .s0_folds_i(hist_cur.folds),
        .stall_i(stall), .kill_i(slow_pipe_kill),
        .resp_valid_o(tage_resp_valid), .resp_o(tage_resp),
        .train_valid_i(train_valid_i), .train_ready_o(), .train_i(train_i),
        .perf_o(perf_tage)
    );

    branch_history #(.CFG(CFG)) u_branch_history (
        .clk_i(clk_i), .rst_i(rst_i),
        .push_valid_i(hist_push_valid),
        .push_branch_pc_i(hist_push_branch_pc), .push_target_pc_i(hist_push_target_pc),
        .cur_o(hist_cur),
        .restore_valid_i(hist_restore_valid_i), .restore_snapshot_i(hist_restore_snapshot_i),
        .restore_inject_i(hist_restore_inject_i),
        .restore_branch_pc_i(hist_restore_branch_pc_i),
        .restore_target_pc_i(hist_restore_target_pc_i),
        .restore_done_o(hist_restore_done_o)
    );

    ras #(.CFG(CFG)) u_ras (
        .clk_i(clk_i), .rst_i(rst_i),
        .op_valid_i(ras_op_valid), .op_action_i(ubtb_pred.ras_action),
        .op_push_addr_i(/* 未实现：选中 CFI 的 PC + 长度 */),
        .top_o(ras_top), .top_valid_o(ras_top_valid),
        .ckpt_o(alloc_ras_ckpt_o),
        .recover_valid_i(ras_recover_valid_i), .recover_id_i(ras_recover_id_i),
        .recover_ckpt_i(ras_recover_ckpt_i),
        .recover_fix_i(ras_fix_i), .recover_push_addr_i(ras_fix_push_addr_i),
        .recover_done_o(ras_recover_done_o), .recover_done_id_o(ras_recover_done_id_o),
        .perf_o(perf_ras)
    );

    bpu_slow_check #(.CFG(CFG)) u_bpu_slow_check (
        .clk_i(clk_i), .rst_i(rst_i),
        .fast_valid_i(fast_aligned_valid), .fast_ftq_id_i(fast_aligned_ftq_id),
        .fast_i(fast_aligned_pred), .fast_ras_ckpt_i(fast_aligned_ras_ckpt),
        .btb_valid_i(btb_resp_valid), .btb_i(btb_resp),
        .tage_valid_i(tage_resp_valid), .tage_i(tage_resp),
        .kill_i(kill_i),
        .slow_o(slow_o), .override_o(override_o),
        .perf_o(perf_slow)
    );

    // 未实现：alloc_valid_o / alloc_pred_o / alloc_snapshot_o 由 pred_pc、ubtb_pred、
    // hist_cur 形成；perf 合并；boot_pc_i 复位装载 pred_pc。D29 后 RAS 不再回压分配。

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
