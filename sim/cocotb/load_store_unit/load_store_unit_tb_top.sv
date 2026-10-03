module load_store_unit_tb_top
    import o3_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk, rst,
    input logic mem_valid, mem_load, mem_store,
    input logic [INST_ID_WIDTH-1:0] mem_id,
    input logic [ROB_IDX_WIDTH-1:0] mem_rob,
    input logic [LQ_IDX_WIDTH-1:0] mem_lq,
    input logic [SQ_IDX_WIDTH-1:0] mem_sq,
    input logic [XLEN-1:0] mem_base, mem_store_data,
    input logic sq_block, sq_forward, sq_change,
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
        assign dc_ld_req_ready[port] = 1'b0;
        assign dc_ld_resp[port] = '0;
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
    end
    assign result_valid = result.valid;
    assign result_id = result.instruction_id;
    assign result_data = result.result;
    load_store_unit #(.CFG(o3_cfg_pkg::O3_CFG.be), .USE_DCACHE(1'b1)) dut (
        .clk(clk), .rst(rst), .mem_uop_i(mem_uop), .mem_ready_o(mem_ready),
        .lq_execute_valid_o(), .lq_execute_idx_o(), .lq_execute_addr_o(),
        .lq_execute_generation_i(1'b0), .lq_request_fire_o(), .lq_request_idx_o(),
        .lq_response_valid_o(), .lq_response_tag_o(), .lq_response_live_i(1'b0),
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
        .load_result_o(result), .load_result_ready_i(1'b0),
        .resolution_valid_i(1'b0), .resolution_mispredict_i(1'b0),
        .resolution_tag_i('0),
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
