// Reused diagnostic from OOC snapshot 42968c23235bd812d2361fe4acd1fc018e7b2f73.
// Diagnostic only. Same backend CFG as default o3_core.
// Every data/control port, including rst, has one boundary register.
// clk is the sole clock and is deliberately not registered. DONT_TOUCH
// preserves the measuring boundaries in both retiming modes.
module l2_home_ooc_wrapper import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    localparam int ID_W=CFG.l2.axi_id_bits,DATA_W=CFG.l2.axi_data_bits,
    localparam int SETS=CFG.l2.sets,WAYS=CFG.l2.ways,N=CFG.l2.slots,
    localparam int SW=$clog2(SETS),WW=$clog2(WAYS),TW=COH_ADDR_W-SW
)(input logic clk,rst,
    input logic l1d_req_valid_i,output logic l1d_req_ready_o,input coh_req_t l1d_req_i,
    output logic l1d_resp_valid_o,input logic l1d_resp_ready_i,output coh_rsp_down_t l1d_resp_o,
    input logic l1i_req_valid_i,output logic l1i_req_ready_o,input coh_req_t l1i_req_i,
    output logic l1i_resp_valid_o,input logic l1i_resp_ready_i,output coh_rsp_down_t l1i_resp_o,
    input logic dma_req_valid_i,output logic dma_req_ready_o,input coh_req_t dma_req_i,
    output logic dma_resp_valid_o,input logic dma_resp_ready_i,output coh_rsp_down_t dma_resp_o,
    input logic rsp_up_valid_i,output logic rsp_up_ready_o,input coh_rsp_up_t rsp_up_i,
    output logic snp_valid_o,input logic snp_ready_i,output coh_snp_t snp_o,
    output fatal_evt_t fatal_o,output be_perf_t perf_o,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [ID_W-1:0]   m_axi_awid,
    output logic [PADDR_W-1:0]    m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [DATA_W-1:0] m_axi_wdata,
    output logic [DATA_W/8-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [ID_W-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [ID_W-1:0]   m_axi_arid,
    output logic [PADDR_W-1:0]    m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [ID_W-1:0]   m_axi_rid,
    input  logic [DATA_W-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast
);
    (* DONT_TOUCH = "yes" *) logic rst_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l1d_req_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l1d_req_ready_o_boundary_q;
    logic l1d_req_ready_o_dut;
    assign l1d_req_ready_o = l1d_req_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_req_t l1d_req_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l1d_resp_valid_o_boundary_q;
    logic l1d_resp_valid_o_dut;
    assign l1d_resp_valid_o = l1d_resp_valid_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l1d_resp_ready_i_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_rsp_down_t l1d_resp_o_boundary_q;
    coh_rsp_down_t l1d_resp_o_dut;
    assign l1d_resp_o = l1d_resp_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l1i_req_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l1i_req_ready_o_boundary_q;
    logic l1i_req_ready_o_dut;
    assign l1i_req_ready_o = l1i_req_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_req_t l1i_req_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l1i_resp_valid_o_boundary_q;
    logic l1i_resp_valid_o_dut;
    assign l1i_resp_valid_o = l1i_resp_valid_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l1i_resp_ready_i_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_rsp_down_t l1i_resp_o_boundary_q;
    coh_rsp_down_t l1i_resp_o_dut;
    assign l1i_resp_o = l1i_resp_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic dma_req_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic dma_req_ready_o_boundary_q;
    logic dma_req_ready_o_dut;
    assign dma_req_ready_o = dma_req_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_req_t dma_req_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic dma_resp_valid_o_boundary_q;
    logic dma_resp_valid_o_dut;
    assign dma_resp_valid_o = dma_resp_valid_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic dma_resp_ready_i_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_rsp_down_t dma_resp_o_boundary_q;
    coh_rsp_down_t dma_resp_o_dut;
    assign dma_resp_o = dma_resp_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic rsp_up_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic rsp_up_ready_o_boundary_q;
    logic rsp_up_ready_o_dut;
    assign rsp_up_ready_o = rsp_up_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_rsp_up_t rsp_up_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic snp_valid_o_boundary_q;
    logic snp_valid_o_dut;
    assign snp_valid_o = snp_valid_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic snp_ready_i_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_snp_t snp_o_boundary_q;
    coh_snp_t snp_o_dut;
    assign snp_o = snp_o_boundary_q;
    (* DONT_TOUCH = "yes" *) fatal_evt_t fatal_o_boundary_q;
    fatal_evt_t fatal_o_dut;
    assign fatal_o = fatal_o_boundary_q;
    (* DONT_TOUCH = "yes" *) be_perf_t perf_o_boundary_q;
    be_perf_t perf_o_dut;
    assign perf_o = perf_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_awvalid_boundary_q;
    logic m_axi_awvalid_dut;
    assign m_axi_awvalid = m_axi_awvalid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_awready_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [ID_W-1:0] m_axi_awid_boundary_q;
    logic [ID_W-1:0] m_axi_awid_dut;
    assign m_axi_awid = m_axi_awid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [PADDR_W-1:0] m_axi_awaddr_boundary_q;
    logic [PADDR_W-1:0] m_axi_awaddr_dut;
    assign m_axi_awaddr = m_axi_awaddr_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [7:0] m_axi_awlen_boundary_q;
    logic [7:0] m_axi_awlen_dut;
    assign m_axi_awlen = m_axi_awlen_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [2:0] m_axi_awsize_boundary_q;
    logic [2:0] m_axi_awsize_dut;
    assign m_axi_awsize = m_axi_awsize_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] m_axi_awburst_boundary_q;
    logic [1:0] m_axi_awburst_dut;
    assign m_axi_awburst = m_axi_awburst_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_wvalid_boundary_q;
    logic m_axi_wvalid_dut;
    assign m_axi_wvalid = m_axi_wvalid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_wready_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [DATA_W-1:0] m_axi_wdata_boundary_q;
    logic [DATA_W-1:0] m_axi_wdata_dut;
    assign m_axi_wdata = m_axi_wdata_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [DATA_W/8-1:0] m_axi_wstrb_boundary_q;
    logic [DATA_W/8-1:0] m_axi_wstrb_dut;
    assign m_axi_wstrb = m_axi_wstrb_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_wlast_boundary_q;
    logic m_axi_wlast_dut;
    assign m_axi_wlast = m_axi_wlast_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_bvalid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_bready_boundary_q;
    logic m_axi_bready_dut;
    assign m_axi_bready = m_axi_bready_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [ID_W-1:0] m_axi_bid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] m_axi_bresp_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_arvalid_boundary_q;
    logic m_axi_arvalid_dut;
    assign m_axi_arvalid = m_axi_arvalid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_arready_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [ID_W-1:0] m_axi_arid_boundary_q;
    logic [ID_W-1:0] m_axi_arid_dut;
    assign m_axi_arid = m_axi_arid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [PADDR_W-1:0] m_axi_araddr_boundary_q;
    logic [PADDR_W-1:0] m_axi_araddr_dut;
    assign m_axi_araddr = m_axi_araddr_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [7:0] m_axi_arlen_boundary_q;
    logic [7:0] m_axi_arlen_dut;
    assign m_axi_arlen = m_axi_arlen_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [2:0] m_axi_arsize_boundary_q;
    logic [2:0] m_axi_arsize_dut;
    assign m_axi_arsize = m_axi_arsize_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] m_axi_arburst_boundary_q;
    logic [1:0] m_axi_arburst_dut;
    assign m_axi_arburst = m_axi_arburst_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_rvalid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_rready_boundary_q;
    logic m_axi_rready_dut;
    assign m_axi_rready = m_axi_rready_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [ID_W-1:0] m_axi_rid_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [DATA_W-1:0] m_axi_rdata_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] m_axi_rresp_boundary_q;
    (* DONT_TOUCH = "yes" *) logic m_axi_rlast_boundary_q;
    always_ff @(posedge clk) begin
        rst_boundary_q <= rst;
        l1d_req_valid_i_boundary_q <= l1d_req_valid_i;
        l1d_req_ready_o_boundary_q <= l1d_req_ready_o_dut;
        l1d_req_i_boundary_q <= l1d_req_i;
        l1d_resp_valid_o_boundary_q <= l1d_resp_valid_o_dut;
        l1d_resp_ready_i_boundary_q <= l1d_resp_ready_i;
        l1d_resp_o_boundary_q <= l1d_resp_o_dut;
        l1i_req_valid_i_boundary_q <= l1i_req_valid_i;
        l1i_req_ready_o_boundary_q <= l1i_req_ready_o_dut;
        l1i_req_i_boundary_q <= l1i_req_i;
        l1i_resp_valid_o_boundary_q <= l1i_resp_valid_o_dut;
        l1i_resp_ready_i_boundary_q <= l1i_resp_ready_i;
        l1i_resp_o_boundary_q <= l1i_resp_o_dut;
        dma_req_valid_i_boundary_q <= dma_req_valid_i;
        dma_req_ready_o_boundary_q <= dma_req_ready_o_dut;
        dma_req_i_boundary_q <= dma_req_i;
        dma_resp_valid_o_boundary_q <= dma_resp_valid_o_dut;
        dma_resp_ready_i_boundary_q <= dma_resp_ready_i;
        dma_resp_o_boundary_q <= dma_resp_o_dut;
        rsp_up_valid_i_boundary_q <= rsp_up_valid_i;
        rsp_up_ready_o_boundary_q <= rsp_up_ready_o_dut;
        rsp_up_i_boundary_q <= rsp_up_i;
        snp_valid_o_boundary_q <= snp_valid_o_dut;
        snp_ready_i_boundary_q <= snp_ready_i;
        snp_o_boundary_q <= snp_o_dut;
        fatal_o_boundary_q <= fatal_o_dut;
        perf_o_boundary_q <= perf_o_dut;
        m_axi_awvalid_boundary_q <= m_axi_awvalid_dut;
        m_axi_awready_boundary_q <= m_axi_awready;
        m_axi_awid_boundary_q <= m_axi_awid_dut;
        m_axi_awaddr_boundary_q <= m_axi_awaddr_dut;
        m_axi_awlen_boundary_q <= m_axi_awlen_dut;
        m_axi_awsize_boundary_q <= m_axi_awsize_dut;
        m_axi_awburst_boundary_q <= m_axi_awburst_dut;
        m_axi_wvalid_boundary_q <= m_axi_wvalid_dut;
        m_axi_wready_boundary_q <= m_axi_wready;
        m_axi_wdata_boundary_q <= m_axi_wdata_dut;
        m_axi_wstrb_boundary_q <= m_axi_wstrb_dut;
        m_axi_wlast_boundary_q <= m_axi_wlast_dut;
        m_axi_bvalid_boundary_q <= m_axi_bvalid;
        m_axi_bready_boundary_q <= m_axi_bready_dut;
        m_axi_bid_boundary_q <= m_axi_bid;
        m_axi_bresp_boundary_q <= m_axi_bresp;
        m_axi_arvalid_boundary_q <= m_axi_arvalid_dut;
        m_axi_arready_boundary_q <= m_axi_arready;
        m_axi_arid_boundary_q <= m_axi_arid_dut;
        m_axi_araddr_boundary_q <= m_axi_araddr_dut;
        m_axi_arlen_boundary_q <= m_axi_arlen_dut;
        m_axi_arsize_boundary_q <= m_axi_arsize_dut;
        m_axi_arburst_boundary_q <= m_axi_arburst_dut;
        m_axi_rvalid_boundary_q <= m_axi_rvalid;
        m_axi_rready_boundary_q <= m_axi_rready_dut;
        m_axi_rid_boundary_q <= m_axi_rid;
        m_axi_rdata_boundary_q <= m_axi_rdata;
        m_axi_rresp_boundary_q <= m_axi_rresp;
        m_axi_rlast_boundary_q <= m_axi_rlast;
    end
    l2_home #(.CFG(CFG)) u_dut (
        .clk(clk),
        .rst(rst_boundary_q),
        .l1d_req_valid_i(l1d_req_valid_i_boundary_q),
        .l1d_req_ready_o(l1d_req_ready_o_dut),
        .l1d_req_i(l1d_req_i_boundary_q),
        .l1d_resp_valid_o(l1d_resp_valid_o_dut),
        .l1d_resp_ready_i(l1d_resp_ready_i_boundary_q),
        .l1d_resp_o(l1d_resp_o_dut),
        .l1i_req_valid_i(l1i_req_valid_i_boundary_q),
        .l1i_req_ready_o(l1i_req_ready_o_dut),
        .l1i_req_i(l1i_req_i_boundary_q),
        .l1i_resp_valid_o(l1i_resp_valid_o_dut),
        .l1i_resp_ready_i(l1i_resp_ready_i_boundary_q),
        .l1i_resp_o(l1i_resp_o_dut),
        .dma_req_valid_i(dma_req_valid_i_boundary_q),
        .dma_req_ready_o(dma_req_ready_o_dut),
        .dma_req_i(dma_req_i_boundary_q),
        .dma_resp_valid_o(dma_resp_valid_o_dut),
        .dma_resp_ready_i(dma_resp_ready_i_boundary_q),
        .dma_resp_o(dma_resp_o_dut),
        .rsp_up_valid_i(rsp_up_valid_i_boundary_q),
        .rsp_up_ready_o(rsp_up_ready_o_dut),
        .rsp_up_i(rsp_up_i_boundary_q),
        .snp_valid_o(snp_valid_o_dut),
        .snp_ready_i(snp_ready_i_boundary_q),
        .snp_o(snp_o_dut),
        .fatal_o(fatal_o_dut),
        .perf_o(perf_o_dut),
        .m_axi_awvalid(m_axi_awvalid_dut),
        .m_axi_awready(m_axi_awready_boundary_q),
        .m_axi_awid(m_axi_awid_dut),
        .m_axi_awaddr(m_axi_awaddr_dut),
        .m_axi_awlen(m_axi_awlen_dut),
        .m_axi_awsize(m_axi_awsize_dut),
        .m_axi_awburst(m_axi_awburst_dut),
        .m_axi_wvalid(m_axi_wvalid_dut),
        .m_axi_wready(m_axi_wready_boundary_q),
        .m_axi_wdata(m_axi_wdata_dut),
        .m_axi_wstrb(m_axi_wstrb_dut),
        .m_axi_wlast(m_axi_wlast_dut),
        .m_axi_bvalid(m_axi_bvalid_boundary_q),
        .m_axi_bready(m_axi_bready_dut),
        .m_axi_bid(m_axi_bid_boundary_q),
        .m_axi_bresp(m_axi_bresp_boundary_q),
        .m_axi_arvalid(m_axi_arvalid_dut),
        .m_axi_arready(m_axi_arready_boundary_q),
        .m_axi_arid(m_axi_arid_dut),
        .m_axi_araddr(m_axi_araddr_dut),
        .m_axi_arlen(m_axi_arlen_dut),
        .m_axi_arsize(m_axi_arsize_dut),
        .m_axi_arburst(m_axi_arburst_dut),
        .m_axi_rvalid(m_axi_rvalid_boundary_q),
        .m_axi_rready(m_axi_rready_dut),
        .m_axi_rid(m_axi_rid_boundary_q),
        .m_axi_rdata(m_axi_rdata_boundary_q),
        .m_axi_rresp(m_axi_rresp_boundary_q),
        .m_axi_rlast(m_axi_rlast_boundary_q)
    );
endmodule
