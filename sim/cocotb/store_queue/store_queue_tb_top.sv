module store_queue_tb_top
    import o3_pkg::*;
(
    input logic clk, rst,
    input logic alloc_valid,
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
    output logic [XLEN-1:0] query_forward_data
);
    localparam int RENAME_WIDTH = BACKEND_MACHINE_WIDTH;
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width;
    logic alloc_req [RENAME_WIDTH-1:0];
    logic [ROB_IDX_WIDTH-1:0] alloc_rob_idx [RENAME_WIDTH-1:0];
    branch_mask_t alloc_branch_mask [RENAME_WIDTH-1:0];
    logic [SQ_IDX_WIDTH-1:0] alloc_idx_arr [RENAME_WIDTH-1:0];
    logic commit_valid [COMMIT_WIDTH-1:0];
    logic [SQ_IDX_WIDTH-1:0] commit_idx [COMMIT_WIDTH-1:0];
    for (genvar lane = 0; lane < RENAME_WIDTH; lane++) begin : g_alloc
        assign alloc_req[lane] = lane == 0 ? alloc_valid : 1'b0;
        assign alloc_rob_idx[lane] = lane == 0 ? alloc_rob : '0;
        assign alloc_branch_mask[lane] = '0;
    end
    assign alloc_idx = alloc_idx_arr[0];
    for (genvar port = 0; port < COMMIT_WIDTH; port++) begin : g_commit
        assign commit_valid[port] = 1'b0;
        assign commit_idx[port] = '0;
    end

    store_queue #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut (
        .clk(clk), .rst(rst),
        .alloc_req_i(alloc_req), .alloc_fire_i(alloc_valid),
        .alloc_rob_idx_i(alloc_rob_idx), .alloc_branch_mask_i(alloc_branch_mask),
        .alloc_idx_o(alloc_idx_arr), .free_count_o(), .tail_o(),
        .execute_valid_i(execute_valid), .execute_idx_i(execute_idx),
        .execute_addr_i(execute_addr), .execute_data_i(execute_data),
        .execute_mask_i(execute_mask),
        .commit_valid_i(commit_valid), .commit_idx_i(commit_idx),
        .query_valid_i(query_valid), .query_rob_idx_i(query_rob),
        .rob_head_i(ROB_IDX_WIDTH'(0)), .query_addr_i(query_addr),
        .query_mask_i(query_mask), .query_block_o(query_block),
        .query_forward_valid_o(query_forward_valid),
        .query_forward_data_o(query_forward_data),
        .drain_valid_o(), .drain_ready_i(1'b0),
        .drain_addr_o(), .drain_data_o(), .drain_mask_o(),
        .resolution_valid_i(1'b0), .resolution_mispredict_i(1'b0),
        .resolution_tag_i('0), .restore_tail_i('0),
        .t_dc_req_valid_o(), .t_dc_req_ready_i(1'b0),
        .t_dc_req_o(), .t_dc_resp_i('0), .t_committed_empty_o()
    );
endmodule
