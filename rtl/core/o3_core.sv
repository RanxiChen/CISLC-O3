/**
 * O3 Core —— 前端、后端、L2 的 core 级连接（2026-10-02 框架）
 *
 * 作用：
 * - 例化 frontend（CFG=O3_CFG.fe）、backend（CFG=O3_CFG.be）、l2_cache（CFG=O3_CFG.be）。
 *   全工程参数只来自 o3_cfg_pkg::O3_CFG，本层不写数值。
 * - 连接前后端合同：fetch_entry_t 交付、bru_resolve_t 执行解析、sys_redirect_t、ftq_commit_t、
 *   系统同步握手、CSR 派生状态、ITLB→共享 PTW。
 * - L7a B48：前端事件增量经 fe_perf 连入后端 CSR/HPM，新增行为未验证。
 * - 连接 L1I/L1D ↔ L2、L2 ↔ DDR AXI、SD DMA 行事务入口。
 *
 * 当前实现状态：闭环简化（L10 T08a）：平台 IRQ/mtime 接 CSR，中断与 WFI 在核内处理。
 * - ICache → L2 → AXI 的直线整数取指路径能经后端退休；ITCM 已移除。
 * - L2 对当前有效的 L1I 行保持 inclusive；L1D 尚无数据阵列或有效行。
 * - DMA、并发 L2 miss、实际 L1D 数据路径及其他系统机制仍待后级。
 * - 测试：sim/cocotb/backend/；sim/o3/。
 * - 系统同步由后端 commit_ctrl 统一编排（2026-10-02 确认）：commit_ctrl 的 fe_sync 接前端同步入口；
 *   FENCE.I 的 SQ drain 与 L1D 脏行扫描写回由 commit_ctrl 在后端内完成，前端不再发起 dclean。
 * - L2 inclusive 回收（B41）：L2 的 L1I 定向失效接前端 ICache 维护入口；L1D 定向失效与 DMA 探测
 *   共用 l1d_probe_*。L2 写回 DDR 失败经 l2_fatal 进入后端 fatal_err_ctrl（B39）。
 * - 旧接口（ICache refill 软件响应、LSU dmem_*、flush_i、branch_resolution/ftq_release_count）
 *   已删除；sim/o3 已迁移到当前端口。
 *   DTCM 装载口暂沿用现状。
 * - SD 控制器本身、启动 ROM、MMIO 外设与整机地址图未设计（不在 core 内）。
 *
 * 逐周期说明：本模块无状态，周期行为见各子模块。
 *
 */
module o3_core
    import o3_types_pkg::*;
#(
    localparam o3_cfg_pkg::o3_cfg_t CFG = o3_cfg_pkg::O3_CFG,
    localparam int AXI_ID_W   = CFG.be.l2.axi_id_bits,
    localparam int AXI_DATA_W = CFG.be.l2.axi_data_bits
) (
    input  logic            clk_i,
    input  logic            rst_i,
    input  vaddr_t          reset_pc_i,

    // ---------------- DDR AXI4 主口（经 L2） ----------------
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [AXI_ID_W-1:0]   m_axi_awid,
    output logic [PADDR_W-1:0]    m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [AXI_DATA_W-1:0] m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [AXI_ID_W-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [AXI_ID_W-1:0]   m_axi_arid,
    output logic [PADDR_W-1:0]    m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [AXI_ID_W-1:0]   m_axi_rid,
    input  logic [AXI_DATA_W-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,

    // ---------------- SD DMA 行事务（B08） ----------------
    input  logic            dma_req_valid_i,
    output logic            dma_req_ready_o,
    input  dma_req_t        dma_req_i,
    output dma_resp_t       dma_resp_o,

    // ---------------- 中断（进入后端 csr_file 的 mip，B26/B29/B38） ----------------
    input logic [63:0] mtime_i,
    input  logic            irq_m_ext_i,
    input  logic            irq_m_timer_i,
    input  logic            irq_m_soft_i,
    input  logic            irq_s_ext_i,

    // ---------------- TCM 装载（现状沿用） ----------------
    input  logic                         dtcm_init_valid_i,
    input  logic [o3_isa_pkg::XLEN-1:0]  dtcm_init_addr_i,
    input  logic [o3_isa_pkg::XLEN-1:0]  dtcm_init_wdata_i,
    input  logic [7:0]                   dtcm_init_wmask_i,

    // ---------------- 错误观测（B39/B41） ----------------
    output logic            fatal_o,               // sticky fatal（保持到复位）
    output logic            inclusion_err_o,       // L2 包含关系错误（不自动重新分配掩盖）

    output logic            done_o,
    output logic [63:0]     retired_inst_count_o
`ifdef ENABLE_RETIRE_INFO
    ,output o3_pkg::retire_info_t retire_info_o [CFG.core.commit_width-1:0]
`endif
`ifdef O3_SIM_SINGLE_INST_TRACE
    ,output logic single_inst_retired_o
`endif
);

    // 前端 ↔ 后端
    fetch_entry_t   fe_deliver [DELIVER_W];
    fetch_entry_t [DELIVER_W-1:0] be_fetch_entry;
    logic           fe_deliver_valid, be_fetch_ready;
    logic [DELIVER_W-1:0] fe_deliver_mask_unused;
    bru_resolve_t   exec_resolve;
    sys_redirect_t  sys_redirect;
    ftq_commit_t    ftq_commit [COMMIT_W];
    redirect_req_t  fe_redirect;
    fe_perf_t       fe_perf;
    logic           sync_valid, sync_ready, sync_done;
    fe_sync_req_t   sync_req;
    logic           ptw_idle;
    fe_csr_t        fe_csr;
    pmp_state_t     fe_pmp;
    logic           itlb_ptw_req_valid, itlb_ptw_req_ready;
    ptw_req_t       itlb_ptw_req;
    ptw_resp_t      itlb_ptw_resp;

    // L1 ↔ L2
    logic           l1i_req_valid, l1i_req_ready, l1i_resp_ready;
    l2_req_t        l1i_req;
    l2_resp_t       l1i_resp;
    logic           l1d_req_valid, l1d_req_ready, l1d_resp_ready;
    l2_req_t        l1d_req;
    l2_resp_t       l1d_resp;
    logic           l1d_wb_valid, l1d_wb_ready;
    paddr_t         l1d_wb_paddr;
    logic [DC_LINE_BYTES*8-1:0] l1d_wb_data;
    logic           l1d_probe_valid, l1d_probe_ready;
    dc_probe_req_t  l1d_probe;
    dc_probe_resp_t l1d_probe_resp;
    logic           l1d_wb_error;
    logic           l1i_recall_valid, l1i_recall_ready;
    l1_recall_req_t l1i_recall;
    l1i_recall_resp_t l1i_recall_resp;
    fatal_evt_t     l2_fatal;

    // 前端 deliver 是 unpacked array，后端 fetch 输入是 packed array：逐 lane 搬运，不改顺序。
    always_comb begin
        for (int lane = 0; lane < DELIVER_W; lane++) begin
            be_fetch_entry[lane] = fe_deliver[lane];
        end
    end

    frontend #(.CFG(CFG.fe)) u_frontend (
        .clk_i(clk_i), .rst_i(rst_i), .boot_pc_i(reset_pc_i),
        .deliver_o(fe_deliver), .deliver_valid_o(fe_deliver_valid),
        .deliver_valid_mask_o(fe_deliver_mask_unused), .deliver_ready_i(be_fetch_ready),
        .exec_resolve_i(exec_resolve), .sys_redirect_i(sys_redirect), .commit_i(ftq_commit),
        .redirect_o(fe_redirect),
        .sync_req_valid_i(sync_valid), .sync_req_ready_o(sync_ready),
        .sync_req_i(sync_req), .sync_done_o(sync_done),
        .ptw_idle_i(ptw_idle),
        .csr_i(fe_csr), .pmp_i(fe_pmp),
        .ptw_req_valid_o(itlb_ptw_req_valid), .ptw_req_ready_i(itlb_ptw_req_ready),
        .ptw_req_o(itlb_ptw_req), .ptw_resp_i(itlb_ptw_resp),
        .l2_req_valid_o(l1i_req_valid), .l2_req_ready_i(l1i_req_ready), .l2_req_o(l1i_req),
        .l2_resp_i(l1i_resp), .l2_resp_ready_o(l1i_resp_ready),
        .l1i_recall_valid_i(l1i_recall_valid), .l1i_recall_ready_o(l1i_recall_ready),
        .l1i_recall_i(l1i_recall), .l1i_recall_resp_o(l1i_recall_resp),
        .fe_perf_o(fe_perf),
        .perf_rd_valid_i(1'b0), .perf_rd_idx_i('0), .perf_rd_data_o(),
        .perf_clear_i(1'b0), .perf_snapshot_i(1'b0)
    );

    backend #(.CFG(CFG.be)) u_backend (
        .clk(clk_i), .rst(rst_i), .boot_pc_i(reset_pc_i),
        .fetch_entry_i(be_fetch_entry), .fetch_valid_i(fe_deliver_valid), .fetch_ready_o(be_fetch_ready),
        .exec_resolve_o(exec_resolve), .sys_redirect_o(sys_redirect), .ftq_commit_o(ftq_commit),
        .fe_redirect_i(fe_redirect),
        .fe_perf_i(fe_perf),
        .fe_sync_valid_o(sync_valid), .fe_sync_ready_i(sync_ready),
        .fe_sync_o(sync_req), .fe_sync_done_i(sync_done),
        .ptw_idle_o(ptw_idle),
        .fe_csr_o(fe_csr), .fe_pmp_o(fe_pmp),
        .itlb_ptw_req_valid_i(itlb_ptw_req_valid), .itlb_ptw_req_ready_o(itlb_ptw_req_ready),
        .itlb_ptw_req_i(itlb_ptw_req), .itlb_ptw_resp_o(itlb_ptw_resp),
        .l2_req_valid_o(l1d_req_valid), .l2_req_ready_i(l1d_req_ready), .l2_req_o(l1d_req),
        .l2_resp_i(l1d_resp), .l2_resp_ready_o(l1d_resp_ready),
        .l2_wb_valid_o(l1d_wb_valid), .l2_wb_ready_i(l1d_wb_ready),
        .l2_wb_line_paddr_o(l1d_wb_paddr), .l2_wb_data_o(l1d_wb_data),
        .l2_wb_error_i(l1d_wb_error),
        .l1d_probe_valid_i(l1d_probe_valid), .l1d_probe_ready_o(l1d_probe_ready),
        .l1d_probe_i(l1d_probe), .l1d_probe_resp_o(l1d_probe_resp),
        .mtime_i(mtime_i),.irq_m_ext_i(irq_m_ext_i), .irq_m_timer_i(irq_m_timer_i),
        .irq_m_soft_i(irq_m_soft_i), .irq_s_ext_i(irq_s_ext_i),
        .l2_fatal_i(l2_fatal), .fatal_o(fatal_o),
        .dtcm_init_valid_i(dtcm_init_valid_i), .dtcm_init_addr_i(dtcm_init_addr_i),
        .dtcm_init_wdata_i(dtcm_init_wdata_i), .dtcm_init_wmask_i(dtcm_init_wmask_i),
        .perf_rd_valid_i(1'b0), .perf_rd_idx_i('0), .perf_rd_data_o(),
        .perf_clear_i(1'b0), .perf_snapshot_i(1'b0),
        .done(done_o), .retired_inst_count_o(retired_inst_count_o)
`ifdef ENABLE_RETIRE_INFO
        ,.retire_info_o(retire_info_o)
`endif
`ifdef O3_SIM_SINGLE_INST_TRACE
        ,.single_inst_retired_o(single_inst_retired_o)
`endif
    );

    l2_cache #(.CFG(CFG.be)) u_l2_cache (
        .clk(clk_i), .rst(rst_i),
        .l1i_req_valid_i(l1i_req_valid), .l1i_req_ready_o(l1i_req_ready), .l1i_req_i(l1i_req),
        .l1i_resp_o(l1i_resp), .l1i_resp_ready_i(l1i_resp_ready),
        .l1d_req_valid_i(l1d_req_valid), .l1d_req_ready_o(l1d_req_ready), .l1d_req_i(l1d_req),
        .l1d_resp_o(l1d_resp), .l1d_resp_ready_i(l1d_resp_ready),
        .l1d_wb_valid_i(l1d_wb_valid), .l1d_wb_ready_o(l1d_wb_ready),
        .l1d_wb_line_paddr_i(l1d_wb_paddr), .l1d_wb_data_i(l1d_wb_data),
        .l1d_wb_error_o(l1d_wb_error),
        .l1i_recall_valid_o(l1i_recall_valid), .l1i_recall_ready_i(l1i_recall_ready),
        .l1i_recall_o(l1i_recall), .l1i_recall_resp_i(l1i_recall_resp),
        .l1d_probe_valid_o(l1d_probe_valid), .l1d_probe_ready_i(l1d_probe_ready),
        .l1d_probe_o(l1d_probe), .l1d_probe_resp_i(l1d_probe_resp),
        .dma_req_valid_i(dma_req_valid_i), .dma_req_ready_o(dma_req_ready_o),
        .dma_req_i(dma_req_i), .dma_resp_o(dma_resp_o),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready), .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready), .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready), .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready), .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .inclusion_err_o(inclusion_err_o), .fatal_o(l2_fatal),
        .perf_o()
    );

endmodule
