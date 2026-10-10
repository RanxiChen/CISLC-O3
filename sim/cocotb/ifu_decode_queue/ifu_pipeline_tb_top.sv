/** F0 -> registered beat queue -> F1, with the registered F1 request's
 * actual next-cycle kill boundary. This fixture exercises alignment rollback,
 * not an alternative predictor or a tied-off F1 correction path. */
module ifu_pipeline_tb_top import o3_types_pkg::*; (
    input logic clk_i,rst_i,in_valid_i,out_ready_i,clear_i,
    input vaddr_t region_base_i,
    input logic [REGION_BYTES*8-1:0] block_data_i,
    input logic [$bits(ftq_id_t)-1:0] ftq_id_i,head_id_i,
    input fetch_slot_t entry_slot_i,
    input logic cfi_valid_i,
    input fetch_slot_t cfi_slot_i,
    input vaddr_t predicted_target_i,
    output logic in_ready_o,boundary_wait_o,
    output logic [F1_W-1:0] out_valid_o,out_edge_o,out_last_o,
    output logic [F1_W-1:0][VADDR_W-1:0] out_pc_o,out_next_o,
    output logic [F1_W-1:0][ILEN-1:0] out_instruction_o,
    output logic correction_o,
    output vaddr_t correction_target_o,
    output fetch_slot_t correction_slot_o
);
    rq_out_t block_in;
    ftq_pred_brief_t brief_in,f0_brief,f1_brief;
    f0_inst_t f0_data[F0_SLOTS],f1_data[F0_SLOTS];
    fetch_entry_t result[F1_W];
    logic [F0_SLOTS-1:0] f0_mask,f1_mask;
    logic f0_ready,f1_ready,f0_beat,f1_beat,f0_last,f1_last,f0_edge_pend,f1_edge_pend;
    redirect_req_t correction;
    fe_kill_t kill;
    always_comb begin
        block_in='0;block_in.ftq_id=ftq_id_t'(ftq_id_i);
        block_in.region_base=region_base_i;block_in.data=block_data_i;
        brief_in='0;brief_in.ftq_id=ftq_id_t'(ftq_id_i);brief_in.slow_done=1;
        brief_in.pred.region_base=region_base_i;brief_in.pred.entry_slot=entry_slot_i;
        brief_in.pred.cfi_valid=cfi_valid_i;brief_in.pred.cfi_slot=cfi_slot_i;
        brief_in.pred.cfi_type=CFI_JAL;brief_in.pred.cfi_target=predicted_target_i;
        brief_in.pred.next_pc=cfi_valid_i ? predicted_target_i:region_base_i+vaddr_t'(REGION_BYTES);
    end
    assign kill='{valid:correction.valid,all:1'b0,ftq_id:correction.ftq_id,slot:correction.slot,kill_self:1'b0};
    assign correction_o=correction.valid;
    assign correction_target_o=correction.target_pc;
    assign correction_slot_o=correction.slot;
    ifu_f0 #(.CFG(o3_cfg_pkg::O3_CFG.fe)) u_f0(
        .clk_i(clk_i),.rst_i(rst_i),.in_valid_i(in_valid_i),.in_ready_o(in_ready_o),.in_i(block_in),.in_brief_i(brief_in),
        .out_valid_o(f0_mask),.out_ready_i(f0_ready),.out_o(f0_data),.out_brief_o(f0_brief),
        .out_beat_valid_o(f0_beat),.out_last_o(f0_last),.out_edge_pend_o(f0_edge_pend),
        .trunc_i(1'b0),.trunc_slot_i('0),.boundary_wait_i(boundary_wait_o),
        .kill_i(kill),.ftq_head_i(ftq_id_t'(head_id_i)),.sync_clear_i(clear_i),.perf_o());
    ifu_decode_queue #(.CFG(o3_cfg_pkg::O3_CFG.fe)) u_queue(
        .clk_i(clk_i),.rst_i(rst_i),.clear_i(clear_i),.in_beat_valid_i(f0_beat),.in_ready_o(f0_ready),
        .in_valid_i(f0_mask),.in_i(f0_data),.in_brief_i(f0_brief),.in_last_i(f0_last),.in_edge_pend_i(f0_edge_pend),
        .out_beat_valid_o(f1_beat),.out_ready_i(f1_ready),.out_valid_o(f1_mask),.out_o(f1_data),.out_brief_o(f1_brief),
        .out_last_o(f1_last),.out_edge_pend_o(f1_edge_pend),.boundary_wait_o(boundary_wait_o),
        .kill_i(kill),.ftq_head_i(ftq_id_t'(head_id_i)));
    ifu_f1 #(.CFG(o3_cfg_pkg::O3_CFG.fe)) u_f1(
        .clk_i(clk_i),.rst_i(rst_i),.in_valid_i(f1_mask),.in_beat_valid_i(f1_beat),.in_last_i(f1_last),
        .in_edge_pend_i(f1_edge_pend),.in_ready_o(f1_ready),.in_i(f1_data),.in_brief_i(f1_brief),
        .out_o(result),.out_valid_o(out_valid_o),.out_ready_i(out_ready_i),.predecode_o(correction),
        .trunc_o(),.trunc_slot_o(),.kill_i(kill),.perf_o());
    for(genvar lane=0;lane<F1_W;lane++) begin : g_outputs
        assign out_pc_o[lane]=result[lane].pc;
        assign out_next_o[lane]=result[lane].predicted_next_pc;
        assign out_instruction_o[lane]=result[lane].instruction;
        assign out_edge_o[lane]=result[lane].is_edge;
        assign out_last_o[lane]=result[lane].ftq_last;
    end
endmodule
