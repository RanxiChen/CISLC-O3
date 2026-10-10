// Full frontend boundary; every public input/output remains observable.
module frontend_ooc_wrapper
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG = o3_cfg_pkg::O3_CFG.fe
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
    output coh_req_t         l2_req_o,
    input logic l2_resp_valid_i,
    input coh_rsp_down_t l2_resp_i,
    output logic            l2_resp_ready_o,

    // ---------------- B48 每拍事件增量（架构计数状态由 CSR/HPM 持有） ----------------
    output fe_perf_t        fe_perf_o,

    // 旧观测接口保留为零值兼容口；计数读写通过架构 CSR 完成。
    input  logic            perf_rd_valid_i,
    input  logic [$clog2(PE_NUM)-1:0] perf_rd_idx_i,
    output logic [CFG.perf.counter_bits-1:0] perf_rd_data_o,
    input  logic            perf_clear_i,
    input  logic            perf_snapshot_i
);
    frontend #(.CFG(CFG)) u_frontend (.*);
endmodule
