module load_store_unit_tb_top import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG=o3_cfg_pkg::O3_CFG.be,
    localparam int P=CFG.lsu.agu_pipes
)(input logic clk,rst,
    output logic ptw_req_valid_o,input logic ptw_req_ready_i,
    output o3_types_pkg::ptw_req_t ptw_req_o,input o3_types_pkg::ptw_resp_t ptw_resp_i,
    input logic d_done_i,input o3_types_pkg::exc_info_t d_exc_i,
    output logic d_mark_o,d_clear_o,ad_wake_o,
    output o3_types_pkg::rob_idx_t d_idx_o,output o3_types_pkg::vaddr_t d_va_o,
    output o3_types_pkg::sq_idx_t d_sq_o,
    input mem_execute_uop_t mem_uop_i[P],input logic issue_is_load_i[P],output logic issue_ready_o[P],
    input logic lq_replay_valid_i[P],input lq_replay_t lq_replay_i[P],output logic lq_replay_ready_o[P],
    input logic sq_replay_valid_i[P],input lq_replay_t sq_replay_i[P],output logic sq_replay_ready_o[P],
    output logic lq_capture_valid_o[P],sq_capture_valid_o[P],output lq_replay_t capture_o[P],
    output logic lq_update_valid_o[P],sq_update_valid_o[P],output o3_types_pkg::dcache_resp_t update_o[P],
    output logic sq_execute_valid_o[P],output logic [SQ_IDX_WIDTH-1:0] sq_execute_idx_o[P],
    output logic [XLEN-1:0] sq_execute_addr_o[P],sq_execute_data_o[P],output logic [7:0] sq_execute_mask_o[P],
    output logic [ROB_IDX_WIDTH-1:0] sq_execute_rob_idx_o[P],output mem_size_t sq_execute_size_o[P],
    output logic [XLEN-1:0] sq_execute_va_o[P],
    output logic sq_query_valid_o[P],output logic [ROB_IDX_WIDTH-1:0] sq_query_rob_idx_o[P],
    output logic [XLEN-1:0] sq_query_addr_o[P],output logic [7:0] sq_query_mask_o[P],
    input logic sq_query_block_i[P],sq_query_forward_valid_i[P],input logic [XLEN-1:0] sq_query_forward_data_i[P],
    input logic full_line_busy_i,internal_busy_i,
    output logic dc_req_valid_o[P],output o3_types_pkg::dcache_req_t dc_req_o[P],dc_s1_o[P],
    input o3_types_pkg::dcache_resp_t dc_resp_i[P],
    output logic store_complete_valid_o[P],output logic [ROB_IDX_WIDTH-1:0] store_complete_rob_idx_o[P],
    output load_result_t load_result_o[P],input logic load_result_ready_i[P],
    output logic exc_valid_o[P],output logic [ROB_IDX_WIDTH-1:0] exc_rob_idx_o[P],
    output o3_types_pkg::exc_info_t exc_o[P],input logic exc_ready_i[P],
    input logic flush_all_i,resolution_valid_i,resolution_mispredict_i,input branch_tag_t resolution_tag_i,
    input o3_types_pkg::dmmu_csr_t csr_i,input o3_types_pkg::pmp_state_t pmp_i,
    output logic [31:0] cfg_tags_o,cfg_rob_o,cfg_lq_o,
    output o3_types_pkg::dcache_resp_t fmt_response_valid,fmt_response_status,fmt_response_reason,
    fmt_response_mshr_id,fmt_response_lq_tag_idx,fmt_response_lq_tag_gen,fmt_response_rdata,fmt_response_exc,
    output mem_execute_uop_t fmt_uop_valid,fmt_uop_instruction_id,fmt_uop_rob_idx,fmt_uop_lq_idx,
    fmt_uop_sq_idx,fmt_uop_dst_preg,fmt_uop_dst_dom,fmt_uop_is_load,fmt_uop_is_store,
    fmt_uop_mem_size,fmt_uop_base_value,fmt_uop_store_value,fmt_uop_branch_mask,
    output load_result_t fmt_result_valid,fmt_result_instruction_id,fmt_result_result,fmt_result_branch_mask,
    output lq_replay_t fmt_replay_uop,fmt_replay_va,fmt_replay_tag_idx,fmt_replay_tag_gen,
    output o3_types_pkg::dcache_req_t fmt_request_blocked,fmt_request_forward_valid,fmt_request_forward_data,
    fmt_request_exc,fmt_request_translation_miss,fmt_request_lq_tag_idx,fmt_request_lq_tag_gen,
    fmt_request_paddr,fmt_request_vaddr,fmt_request_is_sta
);
    o3_types_pkg::lq_tag_t lq_tag_i[P];logic dc_req_ready_i[P];
    for(genvar p=0;p<P;p++) begin
        assign lq_tag_i[p]='{idx:capture_o[p].uop.lq_idx,gen:8'd1};
        assign dc_req_ready_i[p]=1'b1;
    end
    load_store_unit #(.CFG(CFG)) dut(.lq_tag_i(lq_tag_i),.dc_req_ready_i(dc_req_ready_i),
        .sfence_i('0),.sfence_done_o(),.rob_head_i('0),.perf_o(),.*);
    assign cfg_tags_o=CFG.rename.checkpoints;assign cfg_rob_o=CFG.rob.entries;assign cfg_lq_o=CFG.lsu.lq_depth;
    always_comb begin
        fmt_uop_valid='0;fmt_uop_valid.valid='1;
        fmt_uop_instruction_id='0;fmt_uop_instruction_id.instruction_id='1;
        fmt_uop_rob_idx='0;fmt_uop_rob_idx.rob_idx='1;
        fmt_uop_lq_idx='0;fmt_uop_lq_idx.lq_idx='1;
        fmt_uop_sq_idx='0;fmt_uop_sq_idx.sq_idx='1;
        fmt_uop_dst_preg='0;fmt_uop_dst_preg.dst_preg='1;
        fmt_uop_dst_dom='0;fmt_uop_dst_dom.dst_dom=o3_types_pkg::reg_domain_e'('1);
        fmt_uop_is_load='0;fmt_uop_is_load.is_load='1;
        fmt_uop_is_store='0;fmt_uop_is_store.is_store='1;
        fmt_uop_mem_size='0;fmt_uop_mem_size.mem_size=mem_size_t'('1);
        fmt_uop_base_value='0;fmt_uop_base_value.base_value='1;
        fmt_uop_store_value='0;fmt_uop_store_value.store_value='1;
        fmt_uop_branch_mask='0;fmt_uop_branch_mask.branch_mask='1;
        fmt_result_valid='0;fmt_result_valid.valid='1;
        fmt_result_instruction_id='0;fmt_result_instruction_id.instruction_id='1;
        fmt_result_result='0;fmt_result_result.result='1;
        fmt_result_branch_mask='0;fmt_result_branch_mask.branch_mask='1;
        fmt_replay_uop='0;fmt_replay_uop.uop='1;
        fmt_replay_va='0;fmt_replay_va.va='1;
        fmt_replay_tag_idx='0;fmt_replay_tag_idx.tag.idx='1;
        fmt_replay_tag_gen='0;fmt_replay_tag_gen.tag.gen='1;
        fmt_request_blocked='0;fmt_request_blocked.blocked='1;
        fmt_request_forward_valid='0;fmt_request_forward_valid.forward_valid='1;
        fmt_request_forward_data='0;fmt_request_forward_data.forward_data='1;
        fmt_request_exc='0;fmt_request_exc.exc='1;
        fmt_request_translation_miss='0;fmt_request_translation_miss.translation_miss='1;
        fmt_request_lq_tag_idx='0;fmt_request_lq_tag_idx.lq_tag.idx='1;
        fmt_request_lq_tag_gen='0;fmt_request_lq_tag_gen.lq_tag.gen='1;
        fmt_request_paddr='0;fmt_request_paddr.paddr='1;
        fmt_request_vaddr='0;fmt_request_vaddr.vaddr='1;
        fmt_request_is_sta='0;fmt_request_is_sta.is_sta='1;
        fmt_response_valid='0;fmt_response_valid.valid='1;
        fmt_response_status='0;fmt_response_status.status=o3_types_pkg::dc_status_e'('1);
        fmt_response_reason='0;fmt_response_reason.reason=o3_types_pkg::ld_wait_e'('1);
        fmt_response_mshr_id='0;fmt_response_mshr_id.mshr_id='1;
        fmt_response_lq_tag_idx='0;fmt_response_lq_tag_idx.lq_tag.idx='1;
        fmt_response_lq_tag_gen='0;fmt_response_lq_tag_gen.lq_tag.gen='1;
        fmt_response_rdata='0;fmt_response_rdata.rdata='1;
        fmt_response_exc='0;fmt_response_exc.exc='1;
    end
endmodule
