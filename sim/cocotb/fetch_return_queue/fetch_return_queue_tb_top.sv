/** cocotb adapter: public RQ records flattened without changing DUT state. */
module fetch_return_queue_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i,
    output logic rsv_ready_o,
    output logic [RQ_IDX_W-1:0] rsv_idx_o,
    input logic rsv_fire_i,
    input logic [$bits(ftq_id_t)-1:0] rsv_ftq_id_i,
    input logic [VADDR_W-1:0] rsv_region_base_i,
    input logic resp_valid_i,
    input logic [RQ_IDX_W-1:0] resp_rq_idx_i,
    input logic [$bits(ftq_id_t)-1:0] resp_ftq_id_i,
    input logic [REGION_BYTES*8-1:0] resp_data_i,
    output logic brief_rd_valid_o,
    output logic [$bits(ftq_id_t)-1:0] brief_rd_id_o,
    input logic brief_slow_done_i,
    input logic [$bits(ftq_id_t)-1:0] brief_ftq_id_i,
    output logic deq_valid_o,
    input logic deq_ready_i,
    output logic [$bits(ftq_id_t)-1:0] deq_ftq_id_o,
    output logic [VADDR_W-1:0] deq_region_base_o,
    output logic [REGION_BYTES*8-1:0] deq_data_o,
    output logic [$bits(ftq_id_t)-1:0] deq_brief_id_o,
    input logic kill_valid_i, kill_all_i, kill_self_i,
    input logic [$bits(ftq_id_t)-1:0] kill_ftq_id_i, ftq_head_i,
    input logic [SLOT_W-1:0] kill_slot_i,
    output logic [31:0] cfg_ftq_depth_o,
    output logic [31:0] cfg_region_bytes_o
);
    icache_req_t req;
    icache_resp_t resp;
    ftq_pred_brief_t brief, deq_brief;
    rq_out_t deq;
    fe_kill_t kill;
    always_comb begin
        req = '0;
        req.ftq_id = ftq_id_t'(rsv_ftq_id_i);
        req.region_base = rsv_region_base_i;
        req.rq_idx = rsv_idx_o;
        resp = '0;
        resp.valid = resp_valid_i;
        resp.rq_idx = resp_rq_idx_i;
        resp.ftq_id = ftq_id_t'(resp_ftq_id_i);
        resp.data = resp_data_i;
        brief = '0;
        brief.slow_done = brief_slow_done_i;
        brief.ftq_id = ftq_id_t'(brief_ftq_id_i);
        kill = '0;
        kill.valid = kill_valid_i;
        kill.all = kill_all_i;
        kill.kill_self = kill_self_i;
        kill.ftq_id = ftq_id_t'(kill_ftq_id_i);
        kill.slot = kill_slot_i;
    end
    fetch_return_queue #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .rsv_ready_o(rsv_ready_o), .rsv_idx_o(rsv_idx_o),
        .rsv_fire_i(rsv_fire_i), .rsv_req_i(req),
        .resp_i(resp), .ftq_brief_rd_valid_o(brief_rd_valid_o),
        .ftq_brief_rd_id_o(brief_rd_id_o), .ftq_brief_i(brief),
        .deq_valid_o(deq_valid_o), .deq_ready_i(deq_ready_i),
        .deq_o(deq), .deq_brief_o(deq_brief),
        .kill_i(kill), .ftq_head_i(ftq_id_t'(ftq_head_i)), .perf_o()
    );
    assign deq_ftq_id_o = deq.ftq_id;
    assign deq_region_base_o = deq.region_base;
    assign deq_data_o = deq.data;
    assign deq_brief_id_o = deq_brief.ftq_id;
    assign cfg_ftq_depth_o = FTQ_DEPTH;
    assign cfg_region_bytes_o = O3_CFG.fe.fetch.region_bytes;
endmodule
