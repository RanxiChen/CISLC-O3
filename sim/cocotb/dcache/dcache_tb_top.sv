module dcache_tb_top
    import o3_types_pkg::*;
(
    input logic clk, rst,
    input logic probe_valid,
    output logic probe_ready,
    input logic [PADDR_W-1:0] probe_addr,
    input logic [L2_RECALL_ID_W-1:0] probe_id,
    output logic resp_valid,
    output logic [L2_RECALL_ID_W-1:0] resp_id,
    output logic resp_had_dirty,
    output logic [DC_LINE_BYTES*8-1:0] resp_dirty_data
);
    dc_probe_req_t req;
    dc_probe_resp_t resp;
    assign req = '{kind:PROBE_RECALL, line_paddr:probe_addr,
                   dma_write:1'b0, recall_id:probe_id};
    assign resp_valid = resp.valid;
    assign resp_id = resp.recall_id;
    assign resp_had_dirty = resp.had_dirty;
    assign resp_dirty_data = resp.dirty_data;
    dcache #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut (
        .clk(clk), .rst(rst),
        .probe_valid_i(probe_valid), .probe_ready_o(probe_ready),
        .probe_i(req), .probe_resp_o(resp),
        .clean_all_req_i(1'b0),
        .pte_ad_req_valid_i(1'b0), .pte_ad_req_i('0), .cur_epoch_i('0),
        .rsv_clear_valid_i(1'b0), .rsv_clear_reason_i(RSV_CLR_TRAP),
        .rsv_pte_ad_conflict_i('0),
        .l2_req_ready_i(1'b0), .l2_resp_i('0), .l2_wb_ready_i(1'b0),
        .l2_wb_error_i(1'b0)
    );
endmodule
