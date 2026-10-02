/**
 * Frontend Top —— 目标前端总装（2026-10-02 框架）
 *
 * 目标数据流（前端基线第 1 节）：
 *
 *   BPU（uBTB 快预测 → 主 BTB/TAGE 慢预测，历史 E/C，RAS）
 *     │ 分配：快预测 + 入口快照 + RAS 标记        慢预测写回 / 慢覆盖请求
 *     v
 *   FTQ ──demand 游标──→ ICache S0→S1→S2→S3（ITLB / PMP / PMA / MSHR）──→ L2
 *    │  └─prefetch 游标─→ fetch_prefetcher ─────↗
 *    │                                     │ 乱序响应（按 rq_idx）
 *    │                                     v
 *    └─最终预测摘要──→ fetch_return_queue（data_ready && slow_done && !killed）
 *                                          v
 *                       ifu_f0（长度/拼接/RVC）→ ifu_f1（预解码/修正）
 *                                          v
 *                       fetch_buffer（指令 buffer）→ 后端，每拍最多 4 条
 *
 *   redirect_arbiter（D24）：系统重定向 / 执行纠错 / 预解码修正 / 慢覆盖 → 唯一赢家，
 *     广播 kill 边界、BPU 新 PC，读快照恢复历史、按 D29 栈顶快速修复 RAS（R0～R2）。
 *   frontend_sync_ctrl（D25～D28）：FENCE.I / SFENCE.VMA / satp / PMP 的前端部分；
 *     整个同步序列由后端 commit_ctrl 编排（2026-10-02 确认），前端不发起 DCache clean。
 *   L2 inclusive 回收（B41）：recall_* 直通 ICache 的维护入口，不经过 demand 流水。
 *   frontend_perf_events（D21）：事件计数。
 *
 * 本模块负责：子模块之间的连线、kill/hold 广播、对外端口。不承担任何状态。
 *
 * 需要补充实现的机制（本模块内）：
 * - 各子模块 perf 增量合并到 frontend_perf_events（当前未连接）。
 * - pmp_i.update 由 frontend_sync_ctrl 在 D28 同步序列中转发（当前组合替换，序列未实现）。
 *
 * 对外接口中“未设计”的部分（端口只是占位，不代表合同已定）：
 * - 与后端的重定向赢家归属与同一取消边界（redirect_o 作为观测口，见 redirect_arbiter）。
 * - 系统同步请求的具体握手编码（归属已定：commit_ctrl 编排，前端只做前端部分）。
 * - 异常入口、xRET、特权切换主流程已定（B26/B27）：前端只接收已形成的 sys_redirect。系统入口
 *   首笔取指可与历史/RAS 恢复解耦（16.4）；committed 预测上下文来源与入口取指元数据绑定待闭合。
 * - 性能计数读取 ABI（perf_rd_*）。
 * - ITCM（itcm_init_*）：基线未设计，现状沿用以便仿真装载，去留待定。
 *
 * 与旧实现的关系：
 * - HEAD 06462b0 的旧总装（顺序 BPU → 旧 FTQ → 串行 IFU → 阻塞 ICache → fetch_buffer，
 *   branch_resolution_t 直接驱动整体 kill）已被替换。各子模块保留的旧合同端口在此不连接。
 * - o3_core 仍按旧端口例化本模块，后端迁移时一起修改；当前不能编译，符合 agent.md
 *   的顺序重构约定。
 *
 * 当前实现状态：只有连线框架。子模块大多为空壳，整个前端不能编译、不能运行。
 *
 * 逐周期说明（目标，连线层面）：
 * - 周期 N 组合：redirect_arbiter 形成赢家，kill 同拍广播到 FTQ、返回队列、F0、F1、
 *   指令 buffer、预取器、慢预测检查；被清除的年轻路径本拍不得分配、交付或修改推测状态。
 * - 周期 N 上升沿：各子模块按各自握手更新。
 * - 周期 N+1：恢复期间 recover_busy=1，BPU 停止新预测，直到历史与 RAS 恢复完成。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module frontend
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic            clk_i,
    input  logic            rst_i,
    input  vaddr_t          boot_pc_i,

    // ---------------- 交付到后端（第 16.2 节） ----------------
    output fetch_entry_t    deliver_o [DELIVER_W],
    output logic            deliver_valid_o,
    output logic [DELIVER_W-1:0] deliver_valid_mask_o,
    input  logic            deliver_ready_i,

    // ---------------- 后端 → 前端 ----------------
    input  bru_resolve_t    exec_resolve_i,           // 单 BRU 解析（B12）
    input  sys_redirect_t   sys_redirect_i,           // 提交端系统重定向（D24 规则 2）
    input  ftq_commit_t     commit_i [COMMIT_W],      // 按序提交通知
    output redirect_req_t   redirect_o,               // 赢家观测口（归属未设计）

    // ---------------- 系统同步（D25～D28；握手未设计） ----------------
    input  logic            sync_req_valid_i,
    output logic            sync_req_ready_o,
    input  fe_sync_req_t    sync_req_i,
    output logic            sync_done_o,
    input  logic            ptw_idle_i,

    // ---------------- CSR 派生状态 ----------------
    input  fe_csr_t         csr_i,
    input  pmp_state_t      pmp_i,

    // ---------------- 共享 PTW（B07） ----------------
    output logic            ptw_req_valid_o,
    input  logic            ptw_req_ready_i,
    output ptw_req_t        ptw_req_o,
    input  ptw_resp_t       ptw_resp_i,

    // ---------------- L2（第 11.1 节） ----------------
    output logic            l2_req_valid_o,
    input  logic            l2_req_ready_i,
    output l2_req_t         l2_req_o,
    input  l2_resp_t        l2_resp_i,
    output logic            l2_resp_ready_o,

    // ---------------- L2 inclusive 回收的 L1I 定向失效（B41） ----------------
    input  logic            l1i_recall_valid_i,
    output logic            l1i_recall_ready_o,
    input  l1_recall_req_t  l1i_recall_i,
    output l1i_recall_resp_t l1i_recall_resp_o,

    // ---------------- ITCM 装载（现状沿用，基线未设计） ----------------
    input  logic            itcm_init_valid_i,
    input  logic [o3_pkg::PC_WIDTH-1:0] itcm_init_addr_i,
    input  logic [63:0]     itcm_init_data_i,
    input  logic [7:0]      itcm_init_wmask_i,

    // ---------------- 性能计数读取（ABI 未设计） ----------------
    input  logic            perf_rd_valid_i,
    input  logic [$clog2(PE_NUM)-1:0] perf_rd_idx_i,
    output logic [CFG.perf.counter_bits-1:0] perf_rd_data_o,
    input  logic            perf_clear_i,
    input  logic            perf_snapshot_i
);

    // ============================================================
    // 配置一致性：影响跨模块 struct 形状的字段必须与 o3_types_pkg 推导所用的
    // O3_CFG.fe 一致，否则端口位宽与内部规模不符。
    // ============================================================
    initial begin
        assert (CFG.fetch.region_bytes       == o3_cfg_pkg::O3_CFG.fe.fetch.region_bytes);
        assert (CFG.fetch.deliver_width      == o3_cfg_pkg::O3_CFG.fe.fetch.deliver_width);
        assert (CFG.fetch.return_queue_depth == o3_cfg_pkg::O3_CFG.fe.fetch.return_queue_depth);
        assert (CFG.fetch.f0_slots           == o3_cfg_pkg::O3_CFG.fe.fetch.f0_slots);
        assert (CFG.fetch.f1_width           == o3_cfg_pkg::O3_CFG.fe.fetch.f1_width);
        assert (CFG.ftq.depth                == o3_cfg_pkg::O3_CFG.fe.ftq.depth);
        assert (CFG.ftq.gen_bits             == o3_cfg_pkg::O3_CFG.fe.ftq.gen_bits);
        assert (CFG.tage.event_bits          == o3_cfg_pkg::O3_CFG.fe.tage.event_bits);
        assert (CFG.tage.event_window        == o3_cfg_pkg::O3_CFG.fe.tage.event_window);
        assert (CFG.tage.meta_bits           == o3_cfg_pkg::O3_CFG.fe.tage.meta_bits);
        for (int i = 0; i < o3_cfg_pkg::TAGE_TABLES; i++) begin
            assert (CFG.tage.index_bits[i] == o3_cfg_pkg::O3_CFG.fe.tage.index_bits[i]);
            assert (CFG.tage.tag_bits[i]   == o3_cfg_pkg::O3_CFG.fe.tage.tag_bits[i]);
        end
        assert (CFG.ras.depth                == o3_cfg_pkg::O3_CFG.fe.ras.depth);
        assert (CFG.icache.line_bytes        == o3_cfg_pkg::O3_CFG.fe.icache.line_bytes);
        assert (CFG.icache.refill_beat_bytes == o3_cfg_pkg::O3_CFG.fe.icache.refill_beat_bytes);
        assert (CFG.icache.l2_txn_id_bits    == o3_cfg_pkg::O3_CFG.fe.icache.l2_txn_id_bits);
    end

    // ============================================================
    // 内部连线
    // ============================================================
    // BPU ↔ FTQ / 快照存储
    logic            alloc_valid, alloc_ready;
    ftq_id_t         alloc_ftq_id;
    bpu_pred_t       alloc_pred;
    hist_snapshot_t  alloc_snapshot;
    ras_ckpt_t       alloc_ras_ckpt;
    bpu_slow_t       bpu_slow;
    redirect_req_t   bpu_override;
    logic            bpu_train_valid, bpu_train_ready;
    bpu_train_t      bpu_train;

    // 重定向与恢复
    redirect_req_t   arb_winner;
    fe_kill_t        fe_kill;
    logic            arb_bpu_redirect_valid;
    vaddr_t          arb_bpu_redirect_pc;
    logic            arb_snap_rd_req;
    ftq_id_t         arb_snap_rd_ftq_id;
    logic            hist_restore_done, ras_recover_done;
    logic            recover_busy;
    ras_ckpt_t       arb_ras_recover_ckpt, ftq_ras_ckpt_rd;
    ftq_id_t         arb_ras_recover_id, ras_done_id;
    ftq_id_t         ftq_head_id;
    logic            snap_recover_valid;
    hist_snapshot_t  snap_recover;
    logic            snap_train_req, snap_train_valid;
    ftq_id_t         snap_train_id;
    hist_snapshot_t  snap_train;
    redirect_req_t   f1_predecode;

    // FTQ → ICache / 返回队列 / 预取
    logic            rq_rsv_ready;
    rq_idx_t         rq_rsv_idx;
    logic            demand_valid, demand_ready;
    icache_req_t     demand_req;
    logic            ftq_pf_valid, ftq_pf_ready;
    vaddr_t          ftq_pf_region_base;
    ftq_id_t         ftq_pf_ftq_id;
    logic            brief_rd_valid;
    ftq_id_t         brief_rd_id;
    ftq_pred_brief_t ftq_brief;
    icache_resp_t    icache_resp;
    logic            pf_req_valid, pf_req_ready;
    pf_req_t         pf_req;
    pf_resp_t        pf_resp;

    // 返回队列 → F0 → F1 → 指令 buffer
    logic            rq_deq_valid, rq_deq_ready;
    rq_out_t         rq_deq;
    ftq_pred_brief_t rq_deq_brief;
    logic [F0_SLOTS-1:0] f0_valid;
    logic            f0_ready;
    f0_inst_t        f0_inst [F0_SLOTS];
    ftq_pred_brief_t f0_brief;
    fetch_entry_t    f1_out [F1_W];
    logic [F1_W-1:0] f1_valid;
    logic            f1_ready;
    fetch_entry_t    ibuf_deq [DELIVER_W];

    // 系统同步
    logic            sync_hold;
    logic            icache_idle, icache_inv_all, icache_inv_done;
    sfence_req_t     sync_sfence;
    logic            sfence_done;
    logic            pmp_update_sync, pmp_update_done;
    logic            f0_sync_clear;
    pmp_state_t      pmp_to_icache;

    // 性能事件（各子模块增量合并：未实现）
    fe_perf_t        perf_bpu, perf_ftq, perf_arb, perf_rq, perf_f0, perf_f1,
                     perf_ibuf, perf_icache, perf_pf, perf_sum;

    // ============================================================
    // BPU 与历史快照
    // ============================================================
    bpu #(.CFG(CFG)) u_bpu (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),
        // 旧合同端口不连接
        .boot_pc_i               (boot_pc_i),
        .alloc_valid_o           (alloc_valid),
        .alloc_ready_i           (alloc_ready),
        .alloc_ftq_id_i          (alloc_ftq_id),
        .alloc_pred_o            (alloc_pred),
        .alloc_snapshot_o        (alloc_snapshot),
        .alloc_ras_ckpt_o        (alloc_ras_ckpt),
        .slow_o                  (bpu_slow),
        .override_o              (bpu_override),
        .arb_redirect_valid_i    (arb_bpu_redirect_valid),
        .arb_redirect_pc_i       (arb_bpu_redirect_pc),
        .recover_busy_i          (recover_busy),
        .kill_i                  (fe_kill),
        .hist_restore_valid_i    (snap_recover_valid),
        .hist_restore_snapshot_i (snap_recover),
        .hist_restore_inject_i   (arb_winner.hist_inject),
        .hist_restore_branch_pc_i(arb_winner.hist_branch_pc),
        .hist_restore_target_pc_i(arb_winner.hist_target_pc),
        .hist_restore_done_o     (hist_restore_done),
        // D29：R1 拍装载 ras_before 并执行修正动作；有效拍由 redirect_arbiter 的恢复序列给出
        // （当前直接借用赢家有效脉冲，R0/R1 分拍未实现）。
        .ras_recover_valid_i     (arb_bpu_redirect_valid),
        .ras_recover_id_i        (arb_ras_recover_id),
        .ras_recover_ckpt_i      (arb_ras_recover_ckpt),
        .ras_fix_i               (arb_winner.ras_fix),
        .ras_fix_push_addr_i     (arb_winner.ras_push_addr),
        .ras_recover_done_o      (ras_recover_done),
        .ras_recover_done_id_o   (ras_done_id),
        .hold_i                  (sync_hold),
        .train_valid_i           (bpu_train_valid),
        .train_ready_o           (bpu_train_ready),
        .train_i                 (bpu_train),
        .perf_o                  (perf_bpu)
    );

    history_snapshot_store #(.CFG(CFG)) u_history_snapshot_store (
        .clk_i                  (clk_i),
        .rst_i                  (rst_i),
        .wr_valid_i             (alloc_valid && alloc_ready),
        .wr_ftq_id_i            (alloc_ftq_id),
        .wr_snapshot_i          (alloc_snapshot),
        .rd_recover_req_i       (arb_snap_rd_req),
        .rd_recover_ftq_id_i    (arb_snap_rd_ftq_id),
        .rd_recover_resp_valid_o(snap_recover_valid),
        .rd_recover_snapshot_o  (snap_recover),
        .rd_train_req_i         (snap_train_req),
        .rd_train_ftq_id_i      (snap_train_id),
        .rd_train_resp_valid_o  (snap_train_valid),
        .rd_train_snapshot_o    (snap_train)
    );

    // ============================================================
    // FTQ
    // ============================================================
    ftq #(.CFG(CFG)) u_ftq (
        .clk_i                 (clk_i),
        .rst_i                 (rst_i),
        // 旧合同端口（flush_i、bpu_*、ifu_*、release_count_i、resolution_i、train_*）不连接
        .alloc_valid_i         (alloc_valid),
        .alloc_ready_o         (alloc_ready),
        .alloc_ftq_id_o        (alloc_ftq_id),
        .alloc_pred_i          (alloc_pred),
        .alloc_ras_ckpt_i      (alloc_ras_ckpt),
        .slow_i                (bpu_slow),
        .rq_rsv_ready_i        (rq_rsv_ready),
        .rq_rsv_idx_i          (rq_rsv_idx),
        .demand_valid_o        (demand_valid),
        .demand_ready_i        (demand_ready),
        .demand_o              (demand_req),
        .epoch_i               (csr_i.epoch),
        .pf_valid_o            (ftq_pf_valid),
        .pf_ready_i            (ftq_pf_ready),
        .pf_region_base_o      (ftq_pf_region_base),
        .pf_ftq_id_o           (ftq_pf_ftq_id),
        .brief_rd_valid_i      (brief_rd_valid),
        .brief_rd_id_i         (brief_rd_id),
        .brief_o               (ftq_brief),
        .resolve_i             (exec_resolve_i),
        .commit_i              (commit_i),
        .kill_i                (fe_kill),
        .head_id_o             (ftq_head_id),
        .ras_ckpt_rd_id_i      (arb_snap_rd_ftq_id),
        .ras_ckpt_rd_o         (ftq_ras_ckpt_rd),
        .snap_train_rd_req_o   (snap_train_req),
        .snap_train_rd_id_o    (snap_train_id),
        .snap_train_resp_valid_i(snap_train_valid),
        .snap_train_i          (snap_train),
        .bpu_train_valid_o     (bpu_train_valid),
        .bpu_train_ready_i     (bpu_train_ready),
        .bpu_train_o           (bpu_train),
        .hold_i                (sync_hold),
        .perf_o                (perf_ftq)
    );

    // ============================================================
    // D24 统一重定向仲裁
    // ============================================================
    redirect_arbiter #(.CFG(CFG)) u_redirect_arbiter (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .sys_i               (sys_redirect_i),
        .exec_i              (exec_resolve_i),
        .predecode_i         (f1_predecode),
        .slow_i              (bpu_override),
        .ftq_head_i          (ftq_head_id),
        .winner_o            (arb_winner),
        .kill_o              (fe_kill),
        .bpu_redirect_valid_o(arb_bpu_redirect_valid),
        .bpu_redirect_pc_o   (arb_bpu_redirect_pc),
        .snap_rd_req_o       (arb_snap_rd_req),
        .snap_rd_ftq_id_o    (arb_snap_rd_ftq_id),
        .history_done_i      (hist_restore_done),
        .ras_done_i          (ras_recover_done),
        .recover_busy_o      (recover_busy),
        .ras_recover_ckpt_o  (arb_ras_recover_ckpt),
        .ftq_ras_ckpt_i      (ftq_ras_ckpt_rd),
        .ras_recover_id_o    (arb_ras_recover_id),
        .ras_done_id_i       (ras_done_id),
        .redirect_o          (redirect_o),
        .perf_o              (perf_arb)
    );

    // ============================================================
    // 取指：返回队列预留 + ICache
    // ============================================================
    fetch_return_queue #(.CFG(CFG)) u_fetch_return_queue (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .rsv_ready_o         (rq_rsv_ready),
        .rsv_idx_o           (rq_rsv_idx),
        .rsv_fire_i          (demand_valid && demand_ready),
        .rsv_req_i           (demand_req),
        .resp_i              (icache_resp),
        .ftq_brief_rd_valid_o(brief_rd_valid),
        .ftq_brief_rd_id_o   (brief_rd_id),
        .ftq_brief_i         (ftq_brief),
        .deq_valid_o         (rq_deq_valid),
        .deq_ready_i         (rq_deq_ready),
        .deq_o               (rq_deq),
        .deq_brief_o         (rq_deq_brief),
        .kill_i              (fe_kill),
        .perf_o              (perf_rq)
    );

    // D28：PMP 派生状态更新脉冲由同步序列给出（序列未实现）。
    assign pmp_to_icache = '{update: pmp_update_sync, entries: pmp_i.entries};

    ICache #(.CFG(CFG)) u_icache (
        .clk                 (clk_i),
        .rst                 (rst_i),
        // 旧合同端口（flush、kill、s0_*、refill_*、out_*）不连接
        .itcm_init_valid_i   (itcm_init_valid_i),
        .itcm_init_addr_i    (itcm_init_addr_i),
        .itcm_init_data_i    (itcm_init_data_i),
        .itcm_init_wmask_i   (itcm_init_wmask_i),
        .req_valid_i         (demand_valid && !sync_hold),
        .req_ready_o         (demand_ready),
        .req_i               (demand_req),
        .resp_o              (icache_resp),
        .pf_req_valid_i      (pf_req_valid),
        .pf_req_ready_o      (pf_req_ready),
        .pf_req_i            (pf_req),
        .pf_resp_o           (pf_resp),
        .ptw_req_valid_o     (ptw_req_valid_o),
        .ptw_req_ready_i     (ptw_req_ready_i),
        .ptw_req_o           (ptw_req_o),
        .ptw_resp_i          (ptw_resp_i),
        .l2_req_valid_o      (l2_req_valid_o),
        .l2_req_ready_i      (l2_req_ready_i),
        .l2_req_o            (l2_req_o),
        .l2_resp_i           (l2_resp_i),
        .l2_resp_ready_o     (l2_resp_ready_o),
        .csr_i               (csr_i),
        .pmp_i               (pmp_to_icache),
        .pmp_update_done_o   (pmp_update_done),
        .sfence_i            (sync_sfence),
        .sfence_done_o       (sfence_done),
        .inv_all_i           (icache_inv_all),
        .inv_done_o          (icache_inv_done),
        .idle_o              (icache_idle),
        .recall_valid_i      (l1i_recall_valid_i),
        .recall_ready_o      (l1i_recall_ready_o),
        .recall_i            (l1i_recall_i),
        .recall_resp_o       (l1i_recall_resp_o),
        .perf_o              (perf_icache)
    );

    fetch_prefetcher #(.CFG(CFG)) u_fetch_prefetcher (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .ftq_pf_valid_i      (ftq_pf_valid),
        .ftq_pf_ready_o      (ftq_pf_ready),
        .ftq_pf_region_base_i(ftq_pf_region_base),
        .ftq_pf_ftq_id_i     (ftq_pf_ftq_id),
        .pf_req_valid_o      (pf_req_valid),
        .pf_req_ready_i      (pf_req_ready),
        .pf_req_o            (pf_req),
        .pf_resp_i           (pf_resp),
        .csr_i               (csr_i),
        .sfence_i            (sync_sfence),
        .kill_i              (fe_kill),
        .hold_i              (sync_hold),
        .perf_o              (perf_pf)
    );

    // ============================================================
    // IFU：F0 → F1 → 指令 buffer
    // ============================================================
    ifu_f0 #(.CFG(CFG)) u_ifu_f0 (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .in_valid_i  (rq_deq_valid),
        .in_ready_o  (rq_deq_ready),
        .in_i        (rq_deq),
        .in_brief_i  (rq_deq_brief),
        .out_valid_o (f0_valid),
        .out_ready_i (f0_ready),
        .out_o       (f0_inst),
        .out_brief_o (f0_brief),
        .kill_i      (fe_kill),
        .sync_clear_i(f0_sync_clear),
        .perf_o      (perf_f0)
    );

    ifu_f1 #(.CFG(CFG)) u_ifu_f1 (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .in_valid_i  (f0_valid),
        .in_ready_o  (f0_ready),
        .in_i        (f0_inst),
        .in_brief_i  (f0_brief),
        .out_o       (f1_out),
        .out_valid_o (f1_valid),
        .out_ready_i (f1_ready),
        .predecode_o (f1_predecode),
        .kill_i      (fe_kill),
        .perf_o      (perf_f1)
    );

    fetch_buffer #(.CFG(CFG)) u_fetch_buffer (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        // 旧合同：flush_i 与 icache_req_allowed_o 不连接；kill_i 选择性失效未实现
        .enq_entry_i         (f1_out),
        .enq_valid_i         (f1_valid),
        .enq_ready_o         (f1_ready),
        .deq_entry_o         (ibuf_deq),
        .deq_valid_o         (deliver_valid_o),
        .deq_ready_i         (deliver_ready_i),
        .kill_i              (fe_kill),
        .perf_o              (perf_ibuf)
    );

    always_comb begin
        for (int i = 0; i < DELIVER_W; i++) begin
            deliver_o[i]            = ibuf_deq[i];
            deliver_valid_mask_o[i] = deliver_valid_o && ibuf_deq[i].valid;
        end
    end

    // ============================================================
    // 系统同步与性能计数
    // ============================================================
    frontend_sync_ctrl #(.CFG(CFG)) u_frontend_sync_ctrl (
        .clk_i             (clk_i),
        .rst_i             (rst_i),
        .sync_req_valid_i  (sync_req_valid_i),
        .sync_req_ready_o  (sync_req_ready_o),
        .sync_req_i        (sync_req_i),
        .sync_done_o       (sync_done_o),
        .hold_o            (sync_hold),
        .icache_idle_i     (icache_idle),
        .ptw_idle_i        (ptw_idle_i),
        .icache_inv_all_o  (icache_inv_all),
        .icache_inv_done_i (icache_inv_done),
        .sfence_o          (sync_sfence),
        .sfence_done_i     (sfence_done),
        .pmp_update_o      (pmp_update_sync),
        .pmp_update_done_i (pmp_update_done),
        .f0_clear_o        (f0_sync_clear)
    );

    // 未实现：perf_sum = 各子模块 perf 增量按事件相加。
    frontend_perf_events #(.CFG(CFG)) u_frontend_perf_events (
        .clk_i     (clk_i),
        .rst_i     (rst_i),
        .evt_i     (perf_sum),
        .rd_valid_i(perf_rd_valid_i),
        .rd_idx_i  (perf_rd_idx_i),
        .rd_data_o (perf_rd_data_o),
        .clear_i   (perf_clear_i),
        .snapshot_i(perf_snapshot_i)
    );

endmodule
