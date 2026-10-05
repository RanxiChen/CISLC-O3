module store_queue_tb_top
    import o3_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk, rst, flush_all_i,
    input logic alloc_valid,
    input logic multi_mode_i,
    input logic [2:0] multi_alloc_count_i, multi_commit_count_i,
    input logic [ROB_IDX_WIDTH-1:0] multi_rob_i [BACKEND_MACHINE_WIDTH-1:0],
    input branch_mask_t multi_mask_i [BACKEND_MACHINE_WIDTH-1:0],
    input logic [SQ_IDX_WIDTH-1:0] multi_commit_idx_i [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    input logic resolution_valid_i, resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,
    input logic [SQ_IDX_WIDTH-1:0] restore_tail_i,
    output logic [SQ_IDX_WIDTH-1:0] multi_alloc_idx_o [BACKEND_MACHINE_WIDTH-1:0],
    output logic [31:0] cfg_width_o, cfg_depth_o,
    output logic [$clog2(o3_cfg_pkg::O3_CFG.be.lsu.sq_depth+1)-1:0] free_count_o,
    input logic [ROB_IDX_WIDTH-1:0] alloc_rob,
    output logic [SQ_IDX_WIDTH-1:0] alloc_idx,
    input logic execute_valid,
    input logic [SQ_IDX_WIDTH-1:0] execute_idx,
    input logic [XLEN-1:0] execute_addr, execute_data,
    input logic [7:0] execute_mask,
    input logic query_valid,
    input logic [ROB_IDX_WIDTH-1:0] query_rob,
    input logic [XLEN-1:0] query_addr,
    input logic [7:0] query_mask,
    output logic query_block, query_forward_valid,
    output logic [XLEN-1:0] query_forward_data,
    input logic commit_valid,
    input logic [SQ_IDX_WIDTH-1:0] commit_idx,
    output logic dc_req_valid,
    input logic dc_req_ready,
    output logic [SQ_IDX_WIDTH-1:0] dc_req_idx,
    output logic [XLEN-1:0] dc_req_addr,
    input logic dc_resp_valid,
    input logic [SQ_IDX_WIDTH-1:0] dc_resp_idx,
    output logic local_drain_valid,
    input logic local_drain_ready,
    output logic committed_empty
);
    localparam int RENAME_WIDTH = BACKEND_MACHINE_WIDTH;
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width;
    logic alloc_req [RENAME_WIDTH-1:0];
    logic [ROB_IDX_WIDTH-1:0] alloc_rob_idx [RENAME_WIDTH-1:0];
    branch_mask_t alloc_branch_mask [RENAME_WIDTH-1:0];
    logic [SQ_IDX_WIDTH-1:0] alloc_idx_arr [RENAME_WIDTH-1:0];
    logic commit_valid_arr [COMMIT_WIDTH-1:0];
    logic [SQ_IDX_WIDTH-1:0] commit_idx_arr [COMMIT_WIDTH-1:0];
    dcache_req_t dc_req;
    dcache_resp_t dc_resp;
    for (genvar lane = 0; lane < RENAME_WIDTH; lane++) begin : g_alloc
        assign alloc_req[lane] = multi_mode_i ? lane < multi_alloc_count_i : lane == 0 ? alloc_valid : 1'b0;
        assign alloc_rob_idx[lane] = multi_mode_i ? multi_rob_i[lane] : lane == 0 ? alloc_rob : '0;
        assign alloc_branch_mask[lane] = multi_mode_i ? multi_mask_i[lane] : '0;
        assign multi_alloc_idx_o[lane] = alloc_idx_arr[lane];
    end
    assign cfg_width_o = RENAME_WIDTH;
    assign cfg_depth_o = o3_cfg_pkg::O3_CFG.be.lsu.sq_depth;
    assign alloc_idx = alloc_idx_arr[0];
    for (genvar port = 0; port < COMMIT_WIDTH; port++) begin : g_commit
        assign commit_valid_arr[port] = multi_mode_i ? port < multi_commit_count_i : port == 0 ? commit_valid : 1'b0;
        assign commit_idx_arr[port] = multi_mode_i ? multi_commit_idx_i[port] : port == 0 ? commit_idx : '0;
    end
    assign dc_req_idx = dc_req.sq_idx;
    assign dc_req_addr = XLEN'(dc_req.paddr);
    assign dc_resp = '{valid:dc_resp_valid, src:DC_SRC_STORE_DRAIN,
        status:DC_OK, lq_tag:'0, sq_idx:dc_resp_idx, rdata:'0, sc_fail:1'b0};

    store_queue #(.CFG(o3_cfg_pkg::O3_CFG.be), .DCACHE_DRAIN(1'b1)) dut (
        .clk(clk), .rst(rst),.flush_all_i(flush_all_i),
        .alloc_req_i(alloc_req), .alloc_fire_i(multi_mode_i ? multi_alloc_count_i != 0 : alloc_valid),
        .alloc_rob_idx_i(alloc_rob_idx), .alloc_branch_mask_i(alloc_branch_mask),
        .alloc_idx_o(alloc_idx_arr), .free_count_o(free_count_o), .tail_o(),
        .execute_valid_i(execute_valid), .execute_idx_i(execute_idx),
        .execute_addr_i(execute_addr), .execute_data_i(execute_data),
        .execute_mask_i(execute_mask),
        .commit_valid_i(commit_valid_arr), .commit_idx_i(commit_idx_arr),
        .query_valid_i(query_valid), .query_rob_idx_i(query_rob),
        .rob_head_i(ROB_IDX_WIDTH'(0)), .query_addr_i(query_addr),
        .query_mask_i(query_mask), .query_block_o(query_block),
        .query_forward_valid_o(query_forward_valid),
        .query_forward_data_o(query_forward_data),
        .drain_valid_o(local_drain_valid), .drain_ready_i(local_drain_ready),
        .drain_addr_o(), .drain_data_o(), .drain_mask_o(),
        .resolution_valid_i(resolution_valid_i), .resolution_mispredict_i(resolution_mispredict_i),
        .resolution_tag_i(resolution_tag_i), .restore_tail_i(restore_tail_i),
        .t_dc_req_valid_o(dc_req_valid), .t_dc_req_ready_i(dc_req_ready),
        .t_dc_req_o(dc_req), .t_dc_resp_i(dc_resp),
        .t_committed_empty_o(committed_empty)
    );
endmodule
