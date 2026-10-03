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
    output logic [DC_LINE_BYTES*8-1:0] resp_dirty_data,
    input logic ld_valid,
    output logic ld_ready,
    input logic [PADDR_W-1:0] ld_addr,
    input logic [LQ_IDX_W-1:0] ld_idx,
    output logic ld_resp_valid,
    output logic [XLEN-1:0] ld_resp_data,
    output logic [2:0] ld_resp_status,
    input logic st_valid,
    output logic st_ready,
    input logic [PADDR_W-1:0] st_addr,
    input logic [XLEN-1:0] st_data,
    input logic [7:0] st_mask,
    input logic [SQ_IDX_W-1:0] st_idx,
    output logic st_resp_valid,
    output logic [SQ_IDX_W-1:0] st_resp_idx,
    input logic l2_req_ready,
    output logic l2_req_valid,
    output logic [PADDR_W-1:0] l2_req_addr,
    input logic l2_resp_valid,
    input logic [127:0] l2_resp_data,
    input logic l2_resp_last,
    input logic l2_resp_error,
    output logic l2_resp_ready,
    output logic wb_valid,
    input logic wb_ready,
    output logic [PADDR_W-1:0] wb_addr,
    output logic [DC_LINE_BYTES*8-1:0] wb_data,
    input logic wb_error
);
    localparam int LOAD_PORTS = o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes;
    dc_probe_req_t req;
    dc_probe_resp_t resp;
    dcache_req_t ld_req [LOAD_PORTS];
    dcache_resp_t ld_resp [LOAD_PORTS];
    logic ld_req_valid [LOAD_PORTS];
    logic ld_req_ready [LOAD_PORTS];
    dcache_req_t st_req;
    dcache_resp_t st_resp;
    l2_req_t l2_req;
    l2_resp_t l2_resp;
    assign req = '{kind:PROBE_RECALL, line_paddr:probe_addr,
                   dma_write:1'b0, recall_id:probe_id};
    assign resp_valid = resp.valid;
    assign resp_id = resp.recall_id;
    assign resp_had_dirty = resp.had_dirty;
    assign resp_dirty_data = resp.dirty_data;
    for (genvar port = 0; port < LOAD_PORTS; port++) begin : g_load
        assign ld_req_valid[port] = (port == 0) ? ld_valid : 1'b0;
        assign ld_req[port] = (port == 0)
            ? '{src:DC_SRC_LOAD, paddr:ld_addr, size:2'd3,
                write:1'b0, wdata:'0, wmask:'0, amo_op:amo_op_e'(0),
                lq_tag:'{idx:ld_idx, gen:'0}, sq_idx:'0} : '0;
    end
    assign ld_ready = ld_req_ready[0];
    assign ld_resp_valid = ld_resp[0].valid;
    assign ld_resp_data = ld_resp[0].rdata;
    assign ld_resp_status = ld_resp[0].status;
    assign st_req = '{src:DC_SRC_STORE_DRAIN, paddr:st_addr,
        size:2'd3, write:1'b1, wdata:st_data, wmask:st_mask,
        amo_op:amo_op_e'(0), lq_tag:'0, sq_idx:st_idx};
    assign st_ready = st_req_ready;
    assign st_resp_valid = st_resp.valid;
    assign st_resp_idx = st_resp.sq_idx;
    assign l2_req_valid = l2_req_valid_dut;
    assign l2_req_addr = l2_req.line_paddr;
    assign l2_resp = '{valid:l2_resp_valid, txn_id:'0, data:l2_resp_data,
                       last:l2_resp_last, error:l2_resp_error};
    logic st_req_ready, l2_req_valid_dut;
    dcache #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut (
        .clk(clk), .rst(rst),
        .ld_req_valid_i(ld_req_valid), .ld_req_ready_o(ld_req_ready),
        .ld_req_i(ld_req), .ld_resp_o(ld_resp),
        .st_req_valid_i(st_valid), .st_req_ready_o(st_req_ready),
        .st_req_i(st_req), .st_resp_o(st_resp),
        .amo_req_valid_i(1'b0), .amo_req_i('0),
        .probe_valid_i(probe_valid), .probe_ready_o(probe_ready),
        .probe_i(req), .probe_resp_o(resp),
        .clean_all_req_i(1'b0),
        .pte_ad_req_valid_i(1'b0), .pte_ad_req_i('0), .cur_epoch_i('0),
        .rsv_clear_valid_i(1'b0), .rsv_clear_reason_i(RSV_CLR_TRAP),
        .rsv_pte_ad_conflict_i('0),
        .l2_req_valid_o(l2_req_valid_dut), .l2_req_ready_i(l2_req_ready),
        .l2_req_o(l2_req), .l2_resp_i(l2_resp),
        .l2_resp_ready_o(l2_resp_ready),
        .l2_wb_valid_o(wb_valid), .l2_wb_ready_i(wb_ready),
        .l2_wb_line_paddr_o(wb_addr), .l2_wb_data_o(wb_data),
        .l2_wb_error_i(wb_error)
    );
endmodule
