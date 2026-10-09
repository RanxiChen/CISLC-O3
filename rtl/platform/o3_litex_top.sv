/** O3 v1 platform boundary, including coherent SD DMA.
 * 当前实现状态：目标实现（L11）；功能测试与FPGA验证待后续阶段。
 * Flattened ports for LiteX Instance; no Breeze build/runtime dependency.
 */
module o3_litex_top import o3_types_pkg::*; (

    input  logic            clk_i,
    input  logic            rst_i,
    input  logic [63:0]          reset_pc_i,

    // AXI4 memory master, 128-bit data / 4-bit ID / 32-bit address.
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [3:0]   m_axi_awid,
    output logic [31:0]    m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [127:0] m_axi_wdata,
    output logic [15:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [3:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [3:0]   m_axi_arid,
    output logic [31:0]    m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [3:0]   m_axi_rid,
    input  logic [127:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,

    // AXI4-Lite, one MMIO transaction in flight (64-bit data).
    output logic m_axil_awvalid,input logic m_axil_awready,output logic [31:0] m_axil_awaddr,output logic [2:0] m_axil_awprot,
    output logic m_axil_wvalid,input logic m_axil_wready,output logic [63:0] m_axil_wdata,output logic [7:0] m_axil_wstrb,
    input logic m_axil_bvalid,output logic m_axil_bready,input logic [1:0] m_axil_bresp,
    output logic m_axil_arvalid,input logic m_axil_arready,output logic [31:0] m_axil_araddr,output logic [2:0] m_axil_arprot,
    input logic m_axil_rvalid,output logic m_axil_rready,input logic [63:0] m_axil_rdata,input logic [1:0] m_axil_rresp,
    input logic [28:0] sd_dma_adr_i,
    input logic [63:0] sd_dma_dat_w_i,
    input logic [7:0] sd_dma_sel_i,
    input logic sd_dma_cyc_i,sd_dma_stb_i,sd_dma_we_i,
    output logic [63:0] sd_dma_dat_r_o,
    output logic sd_dma_ack_o,sd_dma_err_o,sd_dma_busy_o,
    input logic [63:0] mtime_i,
    input logic irq_m_ext_i,irq_m_timer_i,irq_m_soft_i,irq_s_ext_i,
    output logic fatal_o,inclusion_err_o,
    output logic [63:0] retired_inst_count_o,
    output logic [3:0] retire_valid_o,
    output logic [255:0] retire_pc_o,
    output logic [127:0] retire_inst_o
);
    dma_req_t dma_req; dma_resp_t dma_resp;
    logic dma_req_valid,dma_req_ready,dma_resp_valid,dma_resp_ready,done_unused;
    paddr_t axi_awaddr_full,axi_araddr_full;
    assign m_axi_awaddr=axi_awaddr_full[31:0];
    assign m_axi_araddr=axi_araddr_full[31:0];
    initial begin
        assert(o3_cfg_pkg::O3_CFG.be.l2.axi_data_bits==128);
        assert(o3_cfg_pkg::O3_CFG.be.l2.axi_id_bits==4);
        assert(o3_cfg_pkg::O3_CFG.core.commit_width==4);
    end
    sd_dma_bridge u_sd_dma(
        .clk_i(clk_i),.rst_i(rst_i),.wb_adr_i(sd_dma_adr_i),.wb_dat_w_i(sd_dma_dat_w_i),
        .wb_sel_i(sd_dma_sel_i),.wb_cyc_i(sd_dma_cyc_i),.wb_stb_i(sd_dma_stb_i),.wb_we_i(sd_dma_we_i),
        .wb_dat_r_o(sd_dma_dat_r_o),.wb_ack_o(sd_dma_ack_o),.wb_err_o(sd_dma_err_o),.busy_o(sd_dma_busy_o),
        .dma_req_valid_o(dma_req_valid),.dma_req_ready_i(dma_req_ready),.dma_req_o(dma_req),
        .dma_resp_valid_i(dma_resp_valid),.dma_resp_ready_o(dma_resp_ready),.dma_resp_i(dma_resp));
`ifdef ENABLE_RETIRE_INFO
    o3_pkg::retire_info_t retire_info [3:0];
    for(genvar lane=0;lane<4;lane++) begin
        assign retire_valid_o[lane]=retire_info[lane].valid;
        assign retire_pc_o[lane*64+:64]=64'(retire_info[lane].pc);
        assign retire_inst_o[lane*32+:32]=retire_info[lane].instruction;
    end
`else
    // Production omits detailed retirement traces; scalar count remains live.
    assign retire_valid_o='0; assign retire_pc_o='0; assign retire_inst_o='0;
`endif
    o3_core u_core(
        .clk_i(clk_i),
        .rst_i(rst_i),
        .reset_pc_i(reset_pc_i),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(axi_awaddr_full),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(axi_araddr_full),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axil_awvalid(m_axil_awvalid),
        .m_axil_awready(m_axil_awready),
        .m_axil_awaddr(m_axil_awaddr),
        .m_axil_awprot(m_axil_awprot),
        .m_axil_wvalid(m_axil_wvalid),
        .m_axil_wready(m_axil_wready),
        .m_axil_wdata(m_axil_wdata),
        .m_axil_wstrb(m_axil_wstrb),
        .m_axil_bvalid(m_axil_bvalid),
        .m_axil_bready(m_axil_bready),
        .m_axil_bresp(m_axil_bresp),
        .m_axil_arvalid(m_axil_arvalid),
        .m_axil_arready(m_axil_arready),
        .m_axil_araddr(m_axil_araddr),
        .m_axil_arprot(m_axil_arprot),
        .m_axil_rvalid(m_axil_rvalid),
        .m_axil_rready(m_axil_rready),
        .m_axil_rdata(m_axil_rdata),
        .m_axil_rresp(m_axil_rresp),
        .mtime_i(mtime_i),.irq_m_ext_i(irq_m_ext_i),.irq_s_ext_i(irq_s_ext_i),
        .irq_m_timer_i(irq_m_timer_i),.irq_m_soft_i(irq_m_soft_i),
        .dma_req_valid_i(dma_req_valid),.dma_req_ready_o(dma_req_ready),.dma_req_i(dma_req),
        .dma_resp_valid_o(dma_resp_valid),.dma_resp_ready_i(dma_resp_ready),.dma_resp_o(dma_resp),
        .fatal_o(fatal_o),.inclusion_err_o(inclusion_err_o),.done_o(done_unused),
        .retired_inst_count_o(retired_inst_count_o)
`ifdef ENABLE_RETIRE_INFO
        ,.retire_info_o(retire_info)
`endif
`ifdef O3_SIM_SINGLE_INST_TRACE
        ,.single_inst_retired_o()
`endif
    );
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) if(!rst_i && m_axi_awvalid)
        assert(axi_awaddr_full[PADDR_W-1:32]=='0 && pma_cached_write(64'(axi_awaddr_full),1 << int'(m_axi_awsize)))
            else $fatal(1,"L11 memory write targets read-only or unmapped region");
    always_ff @(posedge clk_i) if(!rst_i && m_axi_arvalid)
        assert(axi_araddr_full[PADDR_W-1:32]=='0)
            else $fatal(1,"L11 memory address exceeds physical bus width");
`endif
endmodule
