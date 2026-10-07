// L8a public request/wait interfaces; internal observation is read-only.
module load_queue_tb_top import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG=o3_cfg_pkg::O3_CFG.be,
    localparam int W=BACKEND_MACHINE_WIDTH,D=CFG.lsu.lq_depth,P=CFG.lsu.agu_pipes,IW=$clog2(D)
)(input logic clk,rst,flush_i,
    input logic alloc_req_i[W-1:0],input logic alloc_fire_i,
    input logic [ROB_IDX_WIDTH-1:0] alloc_rob_idx_i[W-1:0],
    input branch_mask_t alloc_branch_mask_i[W-1:0],
    output logic [IW-1:0] alloc_idx_o[W-1:0],output logic [$clog2(D+1)-1:0] free_count_o,
    output logic [IW-1:0] tail_o,
    input logic capture_valid_i[P],input lq_replay_t capture_i[P],
    output o3_types_pkg::lq_tag_t capture_tag_o[P],
    input logic update_valid_i[P],input o3_types_pkg::dcache_resp_t update_i[P],
    input o3_types_pkg::dc_wake_t dc_wake_i,input logic tlb_wake_i,sq_change_i,ad_wake_i,
    output logic replay_valid_o[P],output lq_replay_t replay_o[P],input logic replay_ready_i[P],
    input logic [$clog2(W+1)-1:0] release_count_i,
    input logic resolution_valid_i,resolution_mispredict_i,input branch_tag_t resolution_tag_i,
    input logic [IW-1:0] restore_tail_i,
    output logic [31:0] cfg_width_o,cfg_depth_o,cfg_rob_o,cfg_tags_o,cfg_pipes_o,
    output logic live_obs_o[D],ready_obs_o[D],executed_obs_o[D],
    output logic [7:0] gen_obs_o[D],output logic [63:0] va_obs_o[D],
    output branch_mask_t mask_obs_o[D],
    output lq_replay_t fmt_capture_uop_lq_idx,fmt_capture_uop_branch_mask,fmt_capture_uop_instruction_id,
    fmt_capture_uop_rob_idx,fmt_capture_uop_dst_preg,fmt_capture_uop_dst_dom,fmt_capture_uop_is_load,
    fmt_capture_uop_mem_size,fmt_capture_va,fmt_capture_wait_reason,fmt_capture_mshr_id,fmt_capture_exc,
    fmt_capture_tag_idx,fmt_capture_tag_gen,
    output o3_types_pkg::dcache_resp_t fmt_update_valid,fmt_update_status,fmt_update_reason,
    fmt_update_mshr_id,fmt_update_lq_tag_idx,fmt_update_lq_tag_gen,fmt_update_exc
);
    load_queue #(.CFG(CFG)) dut(.*);
    assign cfg_width_o=W;assign cfg_depth_o=D;assign cfg_rob_o=CFG.rob.entries;
    assign cfg_tags_o=CFG.rename.checkpoints;assign cfg_pipes_o=P;
    for(genvar n=0;n<D;n++) begin
        assign live_obs_o[n]=dut.valid_q[n];assign ready_obs_o[n]=dut.ready_q[n];
        assign executed_obs_o[n]=dut.executed_q[n];assign gen_obs_o[n]=dut.gen_q[n];
        assign va_obs_o[n]=dut.entry_q[n].va;assign mask_obs_o[n]=dut.entry_q[n].uop.branch_mask;
    end
    always_comb begin
        fmt_capture_uop_lq_idx='0;fmt_capture_uop_lq_idx.uop.lq_idx='1;
        fmt_capture_uop_branch_mask='0;fmt_capture_uop_branch_mask.uop.branch_mask='1;
        fmt_capture_uop_instruction_id='0;fmt_capture_uop_instruction_id.uop.instruction_id='1;
        fmt_capture_uop_rob_idx='0;fmt_capture_uop_rob_idx.uop.rob_idx='1;
        fmt_capture_uop_dst_preg='0;fmt_capture_uop_dst_preg.uop.dst_preg='1;
        fmt_capture_uop_dst_dom='0;fmt_capture_uop_dst_dom.uop.dst_dom=o3_types_pkg::reg_domain_e'('1);
        fmt_capture_uop_is_load='0;fmt_capture_uop_is_load.uop.is_load='1;
        fmt_capture_uop_mem_size='0;fmt_capture_uop_mem_size.uop.mem_size=mem_size_t'('1);
        fmt_capture_va='0;fmt_capture_va.va='1;
        fmt_capture_wait_reason='0;fmt_capture_wait_reason.wait_reason=o3_types_pkg::ld_wait_e'('1);
        fmt_capture_mshr_id='0;fmt_capture_mshr_id.mshr_id='1;
        fmt_capture_exc='0;fmt_capture_exc.exc='1;
        fmt_capture_tag_idx='0;fmt_capture_tag_idx.tag.idx='1;
        fmt_capture_tag_gen='0;fmt_capture_tag_gen.tag.gen='1;
        fmt_update_valid='0;fmt_update_valid.valid='1;
        fmt_update_status='0;fmt_update_status.status=o3_types_pkg::dc_status_e'('1);
        fmt_update_reason='0;fmt_update_reason.reason=o3_types_pkg::ld_wait_e'('1);
        fmt_update_mshr_id='0;fmt_update_mshr_id.mshr_id='1;
        fmt_update_lq_tag_idx='0;fmt_update_lq_tag_idx.lq_tag.idx='1;
        fmt_update_lq_tag_gen='0;fmt_update_lq_tag_gen.lq_tag.gen='1;
        fmt_update_exc='0;fmt_update_exc.exc='1;
    end
endmodule
