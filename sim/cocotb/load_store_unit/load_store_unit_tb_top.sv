module load_store_unit_tb_top
    import o3_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk, rst,
    input logic mem_valid, mem_load, mem_store,
    input logic bus_mode_i, dc_ready_i, dc_response_i, result_ready_i, lq_live_i,
    input logic [XLEN-1:0] dc_response_data_i,
    output logic dc_request_o, pending_o,
    output logic [31:0] cfg_tags_o, cfg_rob_o, cfg_lq_o,
    output branch_mask_t result_mask_o,
    input logic [INST_ID_WIDTH-1:0] mem_id,
    input logic [ROB_IDX_WIDTH-1:0] mem_rob,
    input logic [LQ_IDX_WIDTH-1:0] mem_lq,
    input logic [SQ_IDX_WIDTH-1:0] mem_sq,
    input logic [XLEN-1:0] mem_base, mem_store_data,
    input branch_mask_t mem_branch_mask,
    input logic sq_block, sq_forward, sq_change,
    input logic resolution_valid, resolution_mispredict,
    input branch_tag_t resolution_tag,
    input logic [XLEN-1:0] sq_forward_data,
    output logic mem_ready, replay_busy, replay_capture,
    output logic query_valid, store_execute,
    output logic result_valid,
    output logic [INST_ID_WIDTH-1:0] result_id,
    output logic [XLEN-1:0] result_data
);
    mem_execute_uop_t mem_uop;
    load_result_t result;
    logic dc_ld_req_valid [o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes];
    logic dc_ld_req_ready [o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes];
    dcache_req_t dc_ld_req [o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes];
    dcache_resp_t dc_ld_resp [o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes];
    for (genvar port = 0; port < o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes; port++) begin
        assign dc_ld_req_ready[port] = bus_mode_i && port == 0 && dc_ready_i;
        assign dc_ld_resp[port] = '{valid:(bus_mode_i && port == 0 && dc_response_i), src:DC_SRC_LOAD, status:DC_OK, rdata:dc_response_data_i, default:'0};
    end
    always_comb begin
        mem_uop = '0;
        mem_uop.valid = mem_valid;
        mem_uop.is_load = mem_load;
        mem_uop.is_store = mem_store;
        mem_uop.instruction_id = mem_id;
        mem_uop.rob_idx = mem_rob;
        mem_uop.lq_idx = mem_lq;
        mem_uop.sq_idx = mem_sq;
        mem_uop.mem_size = MEM_SIZE_8B;
        mem_uop.base_value = mem_base;
        mem_uop.store_value = mem_store_data;
        mem_uop.branch_mask = mem_branch_mask;
    end
    assign dc_request_o = dc_ld_req_valid[0];
    assign pending_o = dut.pending_valid_q;
    assign cfg_tags_o = BACKEND_NUM_BRANCH_CHECKPOINTS;
    assign cfg_rob_o = o3_cfg_pkg::O3_CFG.be.rob.entries;
    assign cfg_lq_o = o3_cfg_pkg::O3_CFG.be.lsu.lq_depth;
    assign result_mask_o = result.branch_mask;
    assign result_valid = result.valid;
    assign result_id = result.instruction_id;
    assign result_data = result.result;
    load_store_unit #(.CFG(o3_cfg_pkg::O3_CFG.be), .USE_DCACHE(1'b1)) dut (
        .clk(clk), .rst(rst), .mem_uop_i(mem_uop), .mem_ready_o(mem_ready),
        .lq_execute_valid_o(), .lq_execute_idx_o(), .lq_execute_addr_o(),
        .lq_execute_generation_i(1'b0), .lq_request_fire_o(), .lq_request_idx_o(),
        .lq_response_valid_o(), .lq_response_tag_o(), .lq_response_live_i(bus_mode_i && lq_live_i),
        .sq_execute_valid_o(store_execute), .sq_execute_idx_o(),
        .sq_execute_addr_o(), .sq_execute_data_o(), .sq_execute_mask_o(),
        .sq_query_valid_o(query_valid), .sq_query_rob_idx_o(),
        .sq_query_addr_o(), .sq_query_mask_o(),
        .sq_query_block_i(sq_block), .sq_query_forward_valid_i(sq_forward),
        .sq_query_forward_data_i(sq_forward_data),
        .sq_drain_valid_i(1'b0), .sq_drain_ready_o(), .sq_drain_addr_i('0),
        .sq_drain_data_i('0), .sq_drain_mask_i('0),
        .sq_change_i(sq_change), .replay_busy_o(replay_busy),
        .replay_capture_o(replay_capture),
        .store_complete_valid_o(), .store_complete_rob_idx_o(),
        .load_result_o(result), .load_result_ready_i(result_ready_i),
        .resolution_valid_i(resolution_valid),
        .resolution_mispredict_i(resolution_mispredict),
        .resolution_tag_i(resolution_tag),
        .dtcm_init_valid_i(1'b0), .dtcm_init_addr_i('0),
        .dtcm_init_wdata_i('0), .dtcm_init_wmask_i('0),
        .ext_req_valid_o(), .ext_req_ready_i(1'b0), .ext_req_write_o(),
        .ext_req_addr_o(), .ext_req_wdata_o(), .ext_req_wmask_o(),
        .ext_rsp_valid_i(1'b0), .ext_rsp_ready_o(), .ext_rsp_rdata_i('0),
        .ext_rsp_error_i(1'b0),
        .t_dc_ld_req_valid_o(dc_ld_req_valid), .t_dc_ld_req_ready_i(dc_ld_req_ready),
        .t_dc_ld_req_o(dc_ld_req), .t_dc_ld_resp_i(dc_ld_resp)
    );
endmodule
