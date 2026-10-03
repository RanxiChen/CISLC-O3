module icache_tb_top
    import o3_types_pkg::*;
(
    input logic clk,
    input logic rst,
    input logic req_valid,
    output logic req_ready,
    input logic [VADDR_W-1:0] req_pc,
    input logic [$bits(ftq_id_t)-1:0] req_ftq_id,
    input logic [$bits(rq_idx_t)-1:0] req_rq_idx,
    output logic resp_valid,
    output logic [$bits(ftq_id_t)-1:0] resp_ftq_id,
    output logic [$bits(rq_idx_t)-1:0] resp_rq_idx,
    output logic [REGION_BYTES*8-1:0] resp_data,
    output logic resp_exc,
    output logic l2_req_valid,
    input logic l2_req_ready,
    output logic [PADDR_W-1:0] l2_req_addr,
    input logic l2_resp_valid,
    output logic l2_resp_ready,
    input logic [L2_BEAT_BYTES*8-1:0] l2_resp_data,
    input logic l2_resp_last,
    input logic l2_resp_error,
    input logic itcm_init_valid,
    input logic [o3_pkg::PC_WIDTH-1:0] itcm_init_addr,
    input logic [63:0] itcm_init_data,
    input logic [7:0] itcm_init_wmask,
    input logic inv_all,
    output logic idle,
    output logic inv_done,
    output logic [7:0] cfg_banks,
    output logic [7:0] cfg_sets_per_bank,
    output logic [7:0] cfg_ways,
    output logic [7:0] cfg_region_bytes
);
    icache_req_t req;
    icache_resp_t resp;
    l2_req_t l2_req;
    l2_resp_t l2_resp;
    assign req = '{region_base:req_pc, ftq_id:req_ftq_id,
                   rq_idx:req_rq_idx, epoch:'0};
    assign l2_resp = '{valid:l2_resp_valid, txn_id:'0,
                       data:l2_resp_data, last:l2_resp_last, error:l2_resp_error};
    assign resp_valid = resp.valid;
    assign resp_ftq_id = resp.ftq_id;
    assign resp_rq_idx = resp.rq_idx;
    assign resp_data = resp.data;
    assign resp_exc = resp.exc_valid;
    assign l2_req_addr = l2_req.line_paddr;
    assign cfg_banks = 8'(o3_cfg_pkg::O3_CFG.fe.icache.banks);
    assign cfg_sets_per_bank = 8'(o3_cfg_pkg::O3_CFG.fe.icache.sets
                                   / o3_cfg_pkg::O3_CFG.fe.icache.banks);
    assign cfg_ways = 8'(o3_cfg_pkg::O3_CFG.fe.icache.ways);
    assign cfg_region_bytes = 8'(o3_cfg_pkg::O3_CFG.fe.fetch.region_bytes);

    ICache #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut (
        .clk(clk), .rst(rst),
        .flush(1'b0), .kill(1'b0), .s0_valid(1'b0),
        .s0_ready(), .s0_pc('0),
        .refill_req_valid(), .refill_req_pc(),
        .refill_resp_valid(1'b0), .refill_resp_pc('0),
        .refill_resp_error(1'b0), .refill_resp_data('0),
        .itcm_init_valid_i(itcm_init_valid), .itcm_init_addr_i(itcm_init_addr),
        .itcm_init_data_i(itcm_init_data), .itcm_init_wmask_i(itcm_init_wmask),
        .out_valid(), .out_hit(), .out_pc(), .out_data(), .out_error(),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_i(req), .resp_o(resp),
        .pf_req_valid_i(1'b0), .pf_req_ready_o(), .pf_req_i('0), .pf_resp_o(),
        .ptw_req_valid_o(), .ptw_req_ready_i(1'b0), .ptw_req_o(), .ptw_resp_i('0),
        .l2_req_valid_o(l2_req_valid), .l2_req_ready_i(l2_req_ready),
        .l2_req_o(l2_req), .l2_resp_i(l2_resp), .l2_resp_ready_o(l2_resp_ready),
        .csr_i('0), .pmp_i('0), .pmp_update_done_o(),
        .sfence_i('0), .sfence_done_o(),
        .inv_all_i(inv_all), .inv_done_o(inv_done), .idle_o(idle),
        .recall_valid_i(1'b0), .recall_ready_o(), .recall_i('0), .recall_resp_o(),
        .perf_o()
    );
endmodule
