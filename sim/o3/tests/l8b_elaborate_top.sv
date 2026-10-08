/** Static elaboration harness; no clocked functional tests. All six debug switches are independent. */
module l8b_elaborate_top import o3_types_pkg::*; #(
    parameter bit HEU=1,SPLIT=1,ORDER_FLUSH=1,RFO=1,
    parameter int MEM_PIPES=2,MSHRS=4
)(input logic clk,rst);
    function automatic o3_cfg_pkg::o3_cfg_t config_for_elaboration();
        o3_cfg_pkg::o3_cfg_t c;c=o3_cfg_pkg::O3_CFG;
        c.be.lsu.heu_enable=HEU;c.be.lsu.split_enable=SPLIT;c.be.lsu.order_flush_enable=ORDER_FLUSH;
        c.be.lsu.mem_pipes=MEM_PIPES;c.be.dcache.mshrs=MSHRS;c.be.dcache.rfo_enable=RFO;
        return c;
    endfunction
    localparam o3_cfg_pkg::o3_cfg_t CFG=config_for_elaboration();
    o3_core #(.CFG(CFG)) dut(.clk_i(clk),.rst_i(rst),.reset_pc_i(64'h80000000),
        .m_axi_awready(1'b0),.m_axi_wready(1'b0),.m_axi_bvalid(1'b0),.m_axi_bid('0),.m_axi_bresp('0),
        .m_axi_arready(1'b0),.m_axi_rvalid(1'b0),.m_axi_rid('0),.m_axi_rdata('0),.m_axi_rresp('0),.m_axi_rlast(1'b0),
        .m_axil_awready(1'b0),.m_axil_wready(1'b0),.m_axil_bvalid(1'b0),.m_axil_bresp('0),
        .m_axil_arready(1'b0),.m_axil_rvalid(1'b0),.m_axil_rdata('0),.m_axil_rresp('0),
        .dma_req_valid_i(1'b0),.dma_req_i('0),.dma_resp_ready_i(1'b1),
        .mtime_i('0),.irq_m_ext_i(1'b0),.irq_m_timer_i(1'b0),.irq_m_soft_i(1'b0),.irq_s_ext_i(1'b0));
endmodule
