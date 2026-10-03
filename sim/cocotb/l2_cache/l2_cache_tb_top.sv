module l2_cache_tb_top
    import o3_types_pkg::*;
(
    input logic clk, rst,
    input logic init_valid,
    input logic [PADDR_W-1:0] init_addr,
    input logic [127:0] init_data,
    input logic [15:0] init_wmask,
    input logic req_valid,
    output logic req_ready,
    input logic [PADDR_W-1:0] req_addr,
    input logic [L2_TXN_ID_W-1:0] req_id,
    input logic wb_valid,
    output logic wb_ready,
    input logic [PADDR_W-1:0] wb_addr,
    input logic [DC_LINE_BYTES*8-1:0] wb_data,
    output logic wb_error,
    output logic resp_valid,
    input logic resp_ready,
    output logic [127:0] resp_data,
    output logic resp_last,
    output logic resp_error,
    output logic [L2_TXN_ID_W-1:0] resp_id,
    input logic recall_allow,
    input logic probe_allow,
    input logic probe_dirty,
    input logic [511:0] probe_dirty_data,
    output logic recall_valid,
    output logic [PADDR_W-1:0] recall_addr,
    output logic probe_valid,
    output logic [31:0] ar_count,
    output logic [31:0] aw_count,
    output logic [31:0] recall_count,
    output logic [31:0] cfg_sets,
    output logic [31:0] cfg_ways,
    output logic inclusion_error,
    output logic fatal
);
    localparam int AXI_ID_W = o3_cfg_pkg::O3_CFG.be.l2.axi_id_bits;
    localparam int AXI_DATA_W = o3_cfg_pkg::O3_CFG.be.l2.axi_data_bits;
    l2_req_t req;
    l2_resp_t resp;
    l1_recall_req_t recall;
    l1i_recall_resp_t recall_ack_q;
    dc_probe_req_t probe;
    dc_probe_resp_t probe_ack_q;
    fatal_evt_t fatal_evt;
    logic awvalid, awready, wvalid, wready, bvalid, bready;
    logic arvalid, arready, rvalid, rready, wlast, rlast;
    logic [AXI_ID_W-1:0] awid, bid, arid, rid;
    logic [PADDR_W-1:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [AXI_DATA_W-1:0] wdata, rdata;
    logic [AXI_DATA_W/8-1:0] wstrb;

    assign req = '{line_paddr:req_addr, kind:L2_DEMAND, txn_id:req_id};
    assign cfg_sets = 32'(o3_cfg_pkg::O3_CFG.be.l2.sets);
    assign cfg_ways = 32'(o3_cfg_pkg::O3_CFG.be.l2.ways);
    assign resp_valid = resp.valid;
    assign resp_data = resp.data;
    assign resp_last = resp.last;
    assign resp_error = resp.error;
    assign resp_id = resp.txn_id;
    assign recall_addr = recall.line_paddr;
    assign inclusion_error = inclusion_error_int;
    assign fatal = fatal_evt.valid;
    logic inclusion_error_int;

    always_ff @(posedge clk) begin
        if (rst) begin
            recall_ack_q <= '0;
            probe_ack_q <= '0;
            ar_count <= '0;
            aw_count <= '0;
            recall_count <= '0;
        end else begin
            recall_ack_q.valid <= recall_valid && recall_allow;
            if (recall_valid && recall_allow) begin
                recall_ack_q.recall_id <= recall.recall_id;
                recall_ack_q.quiesced <= 1'b1;
                recall_count <= recall_count + 1'b1;
            end
            probe_ack_q.valid <= probe_valid && probe_allow;
            if (probe_valid && probe_allow) begin
                probe_ack_q.kind <= probe.kind;
                probe_ack_q.recall_id <= probe.recall_id;
                probe_ack_q.had_dirty <= probe_dirty;
                probe_ack_q.dirty_data <= probe_dirty_data;
            end
            if (arvalid && arready) ar_count <= ar_count + 1'b1;
            if (awvalid && awready) aw_count <= aw_count + 1'b1;
        end
    end

    l2_cache #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut (
        .clk(clk), .rst(rst),
        .l1i_req_valid_i(req_valid), .l1i_req_ready_o(req_ready), .l1i_req_i(req),
        .l1i_resp_o(resp), .l1i_resp_ready_i(resp_ready),
        .l1d_req_valid_i(1'b0), .l1d_req_ready_o(), .l1d_req_i('0),
        .l1d_resp_o(), .l1d_resp_ready_i(1'b0),
        .l1d_wb_valid_i(wb_valid), .l1d_wb_ready_o(wb_ready),
        .l1d_wb_line_paddr_i(wb_addr), .l1d_wb_data_i(wb_data), .l1d_wb_error_o(wb_error),
        .l1i_recall_valid_o(recall_valid), .l1i_recall_ready_i(recall_allow),
        .l1i_recall_o(recall), .l1i_recall_resp_i(recall_ack_q),
        .l1d_probe_valid_o(probe_valid), .l1d_probe_ready_i(probe_allow),
        .l1d_probe_o(probe), .l1d_probe_resp_i(probe_ack_q),
        .dma_req_valid_i(1'b0), .dma_req_ready_o(), .dma_req_i('0), .dma_resp_o(),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_awid(awid),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready), .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_arid(arid),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready), .m_axi_rid(rid),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .inclusion_err_o(inclusion_error_int), .fatal_o(fatal_evt), .perf_o()
    );
    o3_axi_ram #(.ADDR_W(PADDR_W), .ID_W(AXI_ID_W), .DATA_W(AXI_DATA_W),
                 .READ_LATENCY(2), .READY_STALL_PERIOD(3)) ram (
        .clk_i(clk), .rst_i(rst),
        .init_valid_i(init_valid), .init_addr_i(init_addr),
        .init_data_i(init_data), .init_wmask_i(init_wmask),
        .awvalid_i(awvalid), .awready_o(awready), .awid_i(awid),
        .awaddr_i(awaddr), .awlen_i(awlen), .awsize_i(awsize), .awburst_i(awburst),
        .wvalid_i(wvalid), .wready_o(wready), .wdata_i(wdata),
        .wstrb_i(wstrb), .wlast_i(wlast),
        .bvalid_o(bvalid), .bready_i(bready), .bid_o(bid), .bresp_o(bresp),
        .arvalid_i(arvalid), .arready_o(arready), .arid_i(arid),
        .araddr_i(araddr), .arlen_i(arlen), .arsize_i(arsize), .arburst_i(arburst),
        .rvalid_o(rvalid), .rready_i(rready), .rid_o(rid), .rdata_o(rdata),
        .rresp_o(rresp), .rlast_o(rlast)
    );
endmodule
