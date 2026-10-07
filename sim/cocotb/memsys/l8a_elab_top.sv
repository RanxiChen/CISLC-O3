/** Compile-only configuration wrapper; no functional stimulus/golden claim. */
module l8a_elab_top #(
    parameter int MEM_PIPES=o3_cfg_pkg::O3_CFG.be.lsu.mem_pipes,
    parameter int MSHRS=o3_cfg_pkg::O3_CFG.be.dcache.mshrs,
    parameter bit RFO_ENABLE=o3_cfg_pkg::O3_CFG.be.dcache.rfo_enable,
    parameter bit PRESSURE=0
)(input logic clk,rst);
    function automatic o3_cfg_pkg::o3_cfg_t config_for_gate();
        o3_cfg_pkg::o3_cfg_t c;c=o3_cfg_pkg::O3_CFG;
        c.be.lsu.mem_pipes=MEM_PIPES;c.be.dcache.mshrs=MSHRS;c.be.dcache.rfo_enable=RFO_ENABLE;
        if(PRESSURE) begin
            c.be.dcache.sets=2;c.be.dcache.ways=2;c.be.dcache.mshrs=2;c.be.dcache.wb_buffers=1;
            c.be.l2.sets=2;c.be.l2.ways=2;c.be.l2.slots=2;
        end
        return c;
    endfunction
    localparam o3_cfg_pkg::o3_cfg_t CFG=config_for_gate();
    o3_core #(.CFG(CFG)) dut(.clk_i(clk),.rst_i(rst),.reset_pc_i('0),
        .m_axi_awready(1'b0),.m_axi_wready(1'b0),.m_axi_bvalid(1'b0),.m_axi_bid('0),.m_axi_bresp('0),
        .m_axi_arready(1'b0),.m_axi_rvalid(1'b0),.m_axi_rid('0),.m_axi_rdata('0),.m_axi_rresp('0),.m_axi_rlast(1'b0),
        .dma_req_valid_i(1'b0),.dma_req_i('0),.mtime_i('0),.irq_m_ext_i(1'b0),.irq_m_timer_i(1'b0),.irq_m_soft_i(1'b0),.irq_s_ext_i(1'b0));
endmodule
