// Backend-only OOC: every interface remains an unconstrained external signal
// before XDC boundary delays; no tie-offs or omitted functional units.
module backend_ooc_wrapper
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    // 旧代码使用的名字，全部由 CFG 推导
    localparam int P=CFG.lsu.agu_pipes,
    localparam int DECODE_WIDTH = CFG.decode.width,
    localparam int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,      // 现有 rename/ROB 分配 lane 数
    localparam int RETIRE_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    localparam int NUM_PHYS_REGS = CFG.rename.int_phys_regs,
    localparam int NUM_ARCH_REGS = o3_isa_pkg::NUM_ARCH_REGS,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int DECODE_QUEUE_DEPTH = CFG.decode.queue_depth,
    localparam int DISPATCH_WIDTH = CFG.dispatch.width,
    localparam int INT_ISSUE_QUEUE_DEPTH = CFG.dispatch.int_iq_depth,
    localparam int MEM_ISSUE_QUEUE_DEPTH = CFG.dispatch.mem_iq_depth,
    localparam int BRANCH_ISSUE_QUEUE_DEPTH = CFG.dispatch.br_iq_depth,
    localparam int NUM_INT_ALUS = CFG.exec.num_alu,
    localparam int INT_ISSUE_WIDTH = CFG.exec.int_issue_width,
    localparam int FP_FUS = 5,
    localparam int NUM_BRANCH_CHECKPOINTS = CFG.rename.checkpoints,
    localparam int LOAD_QUEUE_DEPTH = CFG.lsu.lq_depth,
    localparam int STORE_QUEUE_DEPTH = CFG.lsu.sq_depth,
    localparam int RENAME_DISPATCH_QUEUE_DEPTH = CFG.rename.rdq_depth,
    localparam int AGU_PIPES = CFG.lsu.agu_pipes
)
(
    input  logic clk,
    input  logic rst,
    input  o3_types_pkg::vaddr_t             boot_pc_i,            // committed_next_pc 复位值（B37）

    // ---------------- 前端交付（前端 16.2 节） ----------------
    input  o3_types_pkg::fetch_entry_t [DECODE_WIDTH-1:0] fetch_entry_i,
    input  logic                             fetch_valid_i,
    output logic                             fetch_ready_o,

    // ---------------- 送前端 ----------------
    output o3_types_pkg::bru_resolve_t       exec_resolve_o,       // BRU one-shot 解析（B12）
    output o3_types_pkg::sys_redirect_t      sys_redirect_o,       // L3 tie-off；L5 由 commit_ctrl 驱动
    output o3_types_pkg::ftq_commit_t        ftq_commit_o [RETIRE_WIDTH],
    input  o3_types_pkg::redirect_req_t      fe_redirect_i,        // 前端 D24 赢家观测口（归属未设计）
    output logic                             fe_sync_valid_o,
    input  logic                             fe_sync_ready_i,
    output o3_types_pkg::fe_sync_req_t       fe_sync_o,
    input  logic                             fe_sync_done_i,
    output logic                             ptw_idle_o,
    output o3_types_pkg::fe_csr_t            fe_csr_o,
    output o3_types_pkg::pmp_state_t         fe_pmp_o,

    // ---------------- 前端 ITLB → 共享 PTW（B07） ----------------
    input  logic                             itlb_ptw_req_valid_i,
    output logic                             itlb_ptw_req_ready_o,
    input  o3_types_pkg::ptw_req_t           itlb_ptw_req_i,
    output o3_types_pkg::ptw_resp_t          itlb_ptw_resp_o,

    // ---------------- L1D ↔ L2（L2 在 o3_core） ----------------
    output logic                             l2_req_valid_o,
    input  logic                             l2_req_ready_i,
    output o3_types_pkg::coh_req_t l2_req_o,
    input logic l2_resp_valid_i,input o3_types_pkg::coh_rsp_down_t l2_resp_i,
    output logic l2_resp_ready_o,
    output logic rsp_up_valid_o,input logic rsp_up_ready_i,output o3_types_pkg::coh_rsp_up_t rsp_up_o,
    input logic snp_valid_i,output logic snp_ready_o,input o3_types_pkg::coh_snp_t snp_i,
    input o3_types_pkg::be_perf_t l2_perf_i,

    output logic mmio_valid_o,input logic mmio_ready_i,output o3_types_pkg::dcache_req_t mmio_req_o,
    input o3_types_pkg::dcache_resp_t mmio_resp_i,input logic mmio_irreversible_i,
    // ---------------- 中断（B26/B29：进入 csr_file 的 mip；WFI 唤醒见 B38） ----------------
    input logic [63:0] mtime_i,
    input  logic                             irq_m_ext_i,
    input  logic                             irq_m_timer_i,
    input  logic                             irq_m_soft_i,
    input  logic                             irq_s_ext_i,

    // ---------------- fatal（B39） ----------------
    input  o3_types_pkg::fatal_evt_t         l2_fatal_i,           // L2 写回 DDR 失败
    output logic                             fatal_o,

    // ---------------- B48 前端事件输入；计数状态在 CSR/HPM ----------------
    input  o3_types_pkg::fe_perf_t            fe_perf_i,

    // ---------------- 旧性能观测兼容口（读值为 0，使用架构 CSR） ----------------
    input  logic                             perf_rd_valid_i,
    input  logic [$clog2(o3_types_pkg::BE_PERF_NUM)-1:0] perf_rd_idx_i,
    output logic [CFG.perf.counter_bits-1:0] perf_rd_data_o,
    input  logic                             perf_clear_i,
    input  logic                             perf_snapshot_i,
    output logic                             done,
    output logic [63:0]                      retired_inst_count_o
`ifdef ENABLE_RETIRE_INFO
    ,output retire_info_t                    retire_info_o [RETIRE_WIDTH-1:0]
`endif
`ifdef O3_SIM_SINGLE_INST_TRACE
    ,output logic                            single_inst_retired_o
`endif
);
    backend #(.CFG(CFG)) u_backend (.*);
endmodule
