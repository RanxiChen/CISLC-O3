module sd_dma_bridge_tb_top import o3_types_pkg::*; (
    input logic clk_i, rst_i,
    input logic [28:0] wb_adr_i,
    input logic [63:0] wb_dat_w_i,
    input logic [7:0] wb_sel_i,
    input logic wb_cyc_i, wb_stb_i, wb_we_i,
    output logic [63:0] wb_dat_r_o,
    output logic wb_ack_o, wb_err_o, busy_o,
    output logic coh_req_valid_o,
    input logic coh_req_ready_i,
    output logic [1:0] coh_op_o,
    output logic [25:0] coh_line_o,
    output logic [511:0] coh_data_o,
    output logic [63:0] coh_mask_o,
    input logic coh_resp_valid_i,
    output logic coh_resp_ready_o,
    input logic [511:0] coh_resp_data_i,
    input logic coh_resp_error_i,
    input logic [2:0] coh_resp_op_i,
    output logic dma_req_valid_o, dma_req_ready_o
);
    dma_req_t dma_req;
    dma_resp_t dma_resp;
    logic dma_resp_valid, dma_resp_ready;
    coh_req_t coh_req;
    coh_rsp_down_t coh_resp;
    assign coh_op_o=coh_req.op;
    assign coh_line_o=coh_req.addr;
    assign coh_data_o=coh_req.data;
    assign coh_mask_o=coh_req.mask;
    assign coh_resp='{op:coh_down_op_e'(coh_resp_op_i),id:'0,
        error:coh_resp_error_i,data:coh_resp_data_i};
    sd_dma_bridge bridge(.*, .dma_req_ready_i(dma_req_ready_o),
        .dma_req_o(dma_req), .dma_resp_valid_i(dma_resp_valid),
        .dma_resp_ready_o(dma_resp_ready), .dma_resp_i(dma_resp));
    dma_line_adapter #(.CFG(o3_cfg_pkg::O3_CFG.be)) adapter(
        .clk(clk_i), .rst(rst_i), .req_valid_i(dma_req_valid_o),
        .req_ready_o(dma_req_ready_o), .req_i(dma_req),
        .resp_valid_o(dma_resp_valid), .resp_ready_i(dma_resp_ready), .resp_o(dma_resp),
        .coh_req_valid_o, .coh_req_ready_i, .coh_req_o(coh_req),
        .coh_resp_valid_i, .coh_resp_ready_o, .coh_resp_i(coh_resp));
endmodule
