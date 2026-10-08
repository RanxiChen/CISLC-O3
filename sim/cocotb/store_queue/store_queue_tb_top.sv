module store_queue_tb_top
    import o3_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk, rst, flush_all_i,
 input sq_kind_e kind_i,
 input logic heu_done_i,input rob_idx_t heu_done_idx_i,rob_head_i,
 output logic heu_valid_o,output lq_replay_t heu_entry_o,output sq_kind_e heu_kind_o,
    input logic execute1_valid,query1_valid,
    input logic [SQ_IDX_WIDTH-1:0] execute1_idx,
    input logic [XLEN-1:0] execute1_addr,execute1_data,query1_addr,
    input logic [7:0] execute1_mask,query1_mask,
    input logic [ROB_IDX_WIDTH-1:0] query1_rob,
    output logic query1_block,query1_forward_valid,
    output logic [XLEN-1:0] query1_forward_data,
    input logic dc_retry,
    input ld_wait_e dc_reason,
    input dc_wake_t dc_wake_i,
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
        status:(dc_retry ? DC_REPLAY:DC_OK),reason:dc_reason, sq_idx:dc_resp_idx, default:'0};

    logic ev[2],qv[2],qb[2],qf[2];logic [SQ_IDX_WIDTH-1:0] ei[2];
    logic [XLEN-1:0] ea[2],ed[2],qa[2],qdata[2];logic [7:0] em[2],qm[2];
    logic [ROB_IDX_WIDTH-1:0] qr[2];
    assign ev='{execute_valid,execute1_valid};assign ei='{execute_idx,execute1_idx};
    assign ea='{execute_addr,execute1_addr};assign ed='{execute_data,execute1_data};assign em='{execute_mask,execute1_mask};
    assign qv='{query_valid,query1_valid};assign qr='{query_rob,query1_rob};
    assign qa='{query_addr,query1_addr};assign qm='{query_mask,query1_mask};
    assign query_block=qb[0];assign query1_block=qb[1];
    assign query_forward_valid=qf[0];assign query1_forward_valid=qf[1];
    assign query_forward_data=qdata[0];assign query1_forward_data=qdata[1];
    store_queue #(.CFG(o3_cfg_pkg::O3_CFG.be), .DCACHE_DRAIN(1'b1)) dut (
        .alloc_kind_i('{default:kind_i}),.execute_kind_i('{default:kind_i}),
        .heu_done_i(heu_done_i),.heu_done_idx_i(heu_done_idx_i),.heu_valid_o(heu_valid_o),.heu_entry_o(heu_entry_o),.heu_kind_o(heu_kind_o),
        .clk(clk), .rst(rst),.flush_all_i(flush_all_i),
        .alloc_req_i(alloc_req), .alloc_fire_i(multi_mode_i ? multi_alloc_count_i != 0 : alloc_valid),
        .alloc_rob_idx_i(alloc_rob_idx), .alloc_branch_mask_i(alloc_branch_mask),
        .alloc_idx_o(alloc_idx_arr), .free_count_o(free_count_o), .tail_o(),
        .execute_valid_i(ev), .execute_idx_i(ei),
        .execute_addr_i(ea), .execute_data_i(ed),
        .execute_mask_i(em),
        .commit_valid_i(commit_valid_arr), .commit_idx_i(commit_idx_arr),
        .query_valid_i(qv), .query_rob_idx_i(qr),
        .rob_head_i(rob_head_i), .query_addr_i(qa),
        .query_mask_i(qm), .query_block_o(qb),
        .query_forward_valid_o(qf),
        .query_forward_data_o(qdata),
        .drain_valid_o(local_drain_valid), .drain_ready_i(local_drain_ready),
        .drain_addr_o(), .drain_data_o(), .drain_mask_o(),
        .resolution_valid_i(resolution_valid_i), .resolution_mispredict_i(resolution_mispredict_i),
        .resolution_tag_i(resolution_tag_i), .restore_tail_i(restore_tail_i),
        .t_dc_req_valid_o(dc_req_valid), .t_dc_req_ready_i(dc_req_ready),
        .t_dc_req_o(dc_req), .t_dc_resp_i(dc_resp),
        .dc_wake_i(dc_wake_i),.capture_valid_i('{default:0}),.capture_i('{default:'0}),
        .update_valid_i('{default:0}),.update_i('{default:'0}),.tlb_wake_i(1'b0),.ad_wake_i(1'b0),
        .replay_valid_o(),.replay_o(),.replay_ready_i('{default:0}),
        .t_committed_empty_o(committed_empty)
    );
endmodule
