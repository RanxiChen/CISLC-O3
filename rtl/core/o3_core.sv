/** L8a core assembly: non-directory I Read, coherent D and AXI L2 Home.
 * Head-only atomic/MMIO/split execution and coherent DMA. No private DTCM initialization interface. */
module o3_core
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::o3_cfg_t CFG = o3_cfg_pkg::O3_CFG,
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

    // AXI4-Lite, one MMIO transaction in flight (64-bit data).
    output logic m_axil_awvalid,input logic m_axil_awready,output logic [31:0] m_axil_awaddr,output logic [2:0] m_axil_awprot,
    output logic m_axil_wvalid,input logic m_axil_wready,output logic [63:0] m_axil_wdata,output logic [7:0] m_axil_wstrb,
    input logic m_axil_bvalid,output logic m_axil_bready,input logic [1:0] m_axil_bresp,
    output logic m_axil_arvalid,input logic m_axil_arready,output logic [31:0] m_axil_araddr,output logic [2:0] m_axil_arprot,
    input logic m_axil_rvalid,output logic m_axil_rready,input logic [63:0] m_axil_rdata,input logic [1:0] m_axil_rresp,
    // ---------------- SD DMA 行事务（B08） ----------------
    input  logic            dma_req_valid_i,
    output logic            dma_req_ready_o,
    input  dma_req_t        dma_req_i,
    output dma_resp_t       dma_resp_o,
    output logic dma_resp_valid_o,input logic dma_resp_ready_i=1'b1,

    // ---------------- 中断（进入后端 csr_file 的 mip，B26/B29/B38） ----------------
    input logic [63:0] mtime_i,
    input  logic            irq_m_ext_i,
    input  logic            irq_m_timer_i,
    input  logic            irq_m_soft_i,
    input  logic            irq_s_ext_i,

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

    initial assert(CFG.core.mem_paddr_bits==32);
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

    logic l1i_req_valid,l1i_req_ready,l1i_resp_valid,l1i_resp_ready;
    logic l1d_req_valid,l1d_req_ready,l1d_resp_valid,l1d_resp_ready;
    coh_req_t l1i_req,l1d_req;coh_rsp_down_t l1i_resp,l1d_resp;
    logic rsp_up_valid,rsp_up_ready,snp_valid,snp_ready;
    coh_rsp_up_t rsp_up;coh_snp_t snp;fatal_evt_t l2_fatal;be_perf_t l2_perf;
    logic dma_coh_req_valid,dma_coh_req_ready,dma_coh_resp_valid,dma_coh_resp_ready;
    coh_req_t dma_coh_req;coh_rsp_down_t dma_coh_resp;
    logic mmio_valid,mmio_ready,mmio_resp_valid,mmio_irreversible;
    dcache_req_t mmio_req;dcache_resp_t mmio_resp;
    assign inclusion_err_o=0;
    dma_line_adapter #(.CFG(CFG.be)) u_dma(.clk(clk_i),.rst(rst_i),.req_valid_i(dma_req_valid_i),.req_ready_o(dma_req_ready_o),.req_i(dma_req_i),
        .resp_valid_o(dma_resp_valid_o),.resp_ready_i(dma_resp_ready_i),.resp_o(dma_resp_o),
        .coh_req_valid_o(dma_coh_req_valid),.coh_req_ready_i(dma_coh_req_ready),.coh_req_o(dma_coh_req),
        .coh_resp_valid_i(dma_coh_resp_valid),.coh_resp_ready_o(dma_coh_resp_ready),.coh_resp_i(dma_coh_resp));
    mmio_axil_master #(.CFG(CFG.be)) u_mmio(.clk(clk_i),.rst(rst_i),.req_valid_i(mmio_valid),.req_ready_o(mmio_ready),.req_i(mmio_req),
        .resp_valid_o(mmio_resp_valid),.resp_ready_i(1'b1),.resp_o(mmio_resp),.irreversible_o(mmio_irreversible),
        .m_axil_awvalid(m_axil_awvalid),.m_axil_awready(m_axil_awready),.m_axil_awaddr(m_axil_awaddr),.m_axil_awprot(m_axil_awprot),
        .m_axil_wvalid(m_axil_wvalid),.m_axil_wready(m_axil_wready),.m_axil_wdata(m_axil_wdata),.m_axil_wstrb(m_axil_wstrb),
        .m_axil_bvalid(m_axil_bvalid),.m_axil_bready(m_axil_bready),.m_axil_bresp(m_axil_bresp),
        .m_axil_arvalid(m_axil_arvalid),.m_axil_arready(m_axil_arready),.m_axil_araddr(m_axil_araddr),.m_axil_arprot(m_axil_arprot),
        .m_axil_rvalid(m_axil_rvalid),.m_axil_rready(m_axil_rready),.m_axil_rdata(m_axil_rdata),.m_axil_rresp(m_axil_rresp));

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
        .l2_resp_valid_i(l1i_resp_valid),.l2_resp_i(l1i_resp), .l2_resp_ready_o(l1i_resp_ready),
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
        .l2_resp_valid_i(l1d_resp_valid),.l2_resp_i(l1d_resp), .l2_resp_ready_o(l1d_resp_ready),
        .rsp_up_valid_o(rsp_up_valid),.rsp_up_ready_i(rsp_up_ready),.rsp_up_o(rsp_up),
        .snp_valid_i(snp_valid),.snp_ready_o(snp_ready),.snp_i(snp),.l2_perf_i(l2_perf),
        .mtime_i(mtime_i),.irq_m_ext_i(irq_m_ext_i), .irq_m_timer_i(irq_m_timer_i),
        .irq_m_soft_i(irq_m_soft_i), .irq_s_ext_i(irq_s_ext_i),
        .mmio_valid_o(mmio_valid),.mmio_ready_i(mmio_ready),.mmio_req_o(mmio_req),.mmio_resp_i(mmio_resp),.mmio_irreversible_i(mmio_irreversible),
        .l2_fatal_i(l2_fatal), .fatal_o(fatal_o),
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

    l2_home #(.CFG(CFG.be)) u_l2_home (
        .clk(clk_i),.rst(rst_i),
        .l1i_req_valid_i(l1i_req_valid),.l1i_req_ready_o(l1i_req_ready),.l1i_req_i(l1i_req),
        .l1i_resp_valid_o(l1i_resp_valid),.l1i_resp_o(l1i_resp),.l1i_resp_ready_i(l1i_resp_ready),
        .l1d_req_valid_i(l1d_req_valid),.l1d_req_ready_o(l1d_req_ready),.l1d_req_i(l1d_req),
        .l1d_resp_valid_o(l1d_resp_valid),.l1d_resp_o(l1d_resp),.l1d_resp_ready_i(l1d_resp_ready),
        .rsp_up_valid_i(rsp_up_valid),.rsp_up_ready_o(rsp_up_ready),.rsp_up_i(rsp_up),
        .snp_valid_o(snp_valid),.snp_ready_i(snp_ready),.snp_o(snp),
        .dma_req_valid_i(dma_coh_req_valid),.dma_req_ready_o(dma_coh_req_ready),.dma_req_i(dma_coh_req),
        .dma_resp_valid_o(dma_coh_resp_valid),.dma_resp_ready_i(dma_coh_resp_ready),.dma_resp_o(dma_coh_resp),
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
        .fatal_o(l2_fatal),
        .perf_o(l2_perf)
    );

endmodule
