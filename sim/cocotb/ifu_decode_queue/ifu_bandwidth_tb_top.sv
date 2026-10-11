/** Actual default F0 -> queue -> F1 -> prefix buffer -> four-wide consumer. */
module ifu_bandwidth_tb_top import o3_types_pkg::*; (
    input logic clk_i,rst_i,in_valid_i,out_ready_i,clear_i,
    input vaddr_t region_base_i,
    input logic [REGION_BYTES*8-1:0] block_data_i,
    input ftq_id_t ftq_id_i,head_id_i,
    input fetch_slot_t entry_slot_i,
    input logic cfi_valid_i,
    input fetch_slot_t cfi_slot_i,
    input vaddr_t predicted_target_i,
    input logic exc_i,input exception_cause_t cause_i,
    input logic kill_valid_i,kill_all_i,kill_self_i,
    input ftq_id_t kill_id_i,input fetch_slot_t kill_slot_i,
    output logic in_ready_o,boundary_wait_o,
    output logic f0_fire_o,f0_last_o,f1_fire_o,
    output logic [F1_W-1:0] f1_mask_o,
    output logic [DELIVER_W-1:0] out_valid_o,out_edge_o,out_last_o,out_exc_o,
    output logic [DELIVER_W-1:0][VADDR_W-1:0] out_pc_o,out_next_o,
    output logic [DELIVER_W-1:0][ILEN-1:0] out_instruction_o,out_raw_o,
    output logic [DELIVER_W-1:0][$bits(ftq_id_t)-1:0] out_id_o,
    output logic [DELIVER_W-1:0][SLOT_W-1:0] out_slot_o,
    output logic [DELIVER_W-1:0][XLEN-1:0] out_tval_o,
    output fe_perf_t perf_o,
    output logic correction_o,
    output vaddr_t correction_target_o,
    output fetch_slot_t correction_slot_o
);
    rq_out_t block_in;
    ftq_pred_brief_t brief_in,f0_brief,f1_brief;
    f0_inst_t f0_data[F0_SLOTS],f1_data[F0_SLOTS];
    fetch_entry_t result[F1_W],delivered[DELIVER_W];
    logic [F0_SLOTS-1:0] f0_mask,f1_mask;
    logic f0_ready,f1_ready,buffer_ready,f0_beat,f1_beat,f1_last,f0_edge_pend,f1_edge_pend,buffer_valid;
    redirect_req_t correction;
    fe_kill_t kill;
    fe_perf_t f0_perf;
    always_comb begin
        block_in='0;block_in.ftq_id=ftq_id_i;
        block_in.region_base=region_base_i;block_in.data=block_data_i;
        block_in.exc_valid=exc_i;block_in.exc_cause=cause_i;
        brief_in='0;brief_in.ftq_id=ftq_id_i;brief_in.slow_done=1;
        brief_in.pred.region_base=region_base_i;brief_in.pred.entry_slot=entry_slot_i;
        brief_in.pred.cfi_valid=cfi_valid_i;brief_in.pred.cfi_slot=cfi_slot_i;
        brief_in.pred.cfi_type=CFI_JAL;brief_in.pred.cfi_target=predicted_target_i;
        brief_in.pred.next_pc=cfi_valid_i ? predicted_target_i:region_base_i+vaddr_t'(REGION_BYTES);
        kill=kill_valid_i ? fe_kill_t'{valid:1'b1,all:kill_all_i,ftq_id:kill_id_i,slot:kill_slot_i,kill_self:kill_self_i}:
            fe_kill_t'{valid:correction.valid,all:1'b0,ftq_id:correction.ftq_id,slot:correction.slot,kill_self:1'b0};
    end
    assign correction_o=correction.valid;
    assign correction_target_o=correction.target_pc;
    assign correction_slot_o=correction.slot;
    assign f0_fire_o=f0_beat && f0_ready;
    assign f1_fire_o=f1_beat && f1_ready;
    assign perf_o=rst_i ? fe_perf_t'('0):f0_perf | fe_delivery_events(out_ready_i,buffer_valid,out_valid_o);
    ifu_f0 #(.CFG(o3_cfg_pkg::O3_CFG.fe)) u_f0(
        .clk_i(clk_i),.rst_i(rst_i),.in_valid_i(in_valid_i),.in_ready_o(in_ready_o),.in_i(block_in),.in_brief_i(brief_in),
        .out_valid_o(f0_mask),.out_ready_i(f0_ready),.out_o(f0_data),.out_brief_o(f0_brief),
        .out_beat_valid_o(f0_beat),.out_last_o(f0_last_o),.out_edge_pend_o(f0_edge_pend),
        .trunc_i(1'b0),.trunc_slot_i('0),.boundary_wait_i(boundary_wait_o),
        .kill_i(kill),.ftq_head_i(head_id_i),.sync_clear_i(clear_i),.perf_o(f0_perf));
    ifu_decode_queue #(.CFG(o3_cfg_pkg::O3_CFG.fe)) u_queue(
        .clk_i(clk_i),.rst_i(rst_i),.clear_i(clear_i),.in_beat_valid_i(f0_beat),.in_ready_o(f0_ready),
        .in_valid_i(f0_mask),.in_i(f0_data),.in_brief_i(f0_brief),.in_last_i(f0_last_o),.in_edge_pend_i(f0_edge_pend),
        .out_beat_valid_o(f1_beat),.out_ready_i(f1_ready),.out_valid_o(f1_mask),.out_o(f1_data),.out_brief_o(f1_brief),
        .out_last_o(f1_last),.out_edge_pend_o(f1_edge_pend),.boundary_wait_o(boundary_wait_o),
        .kill_i(kill),.ftq_head_i(head_id_i));
    ifu_f1 #(.CFG(o3_cfg_pkg::O3_CFG.fe),.PREFIX_INPUT(1'b1)) u_f1(
        .clk_i(clk_i),.rst_i(rst_i),.in_valid_i(f1_mask),.in_beat_valid_i(f1_beat),.in_last_i(f1_last),
        .in_edge_pend_i(f1_edge_pend),.in_ready_o(f1_ready),.in_i(f1_data),.in_brief_i(f1_brief),
        .out_o(result),.out_valid_o(f1_mask_o),.out_ready_i(buffer_ready),.predecode_o(correction),
        .trunc_o(),.trunc_slot_o(),.kill_i(kill),.perf_o());
    fetch_buffer #(.CFG(o3_cfg_pkg::O3_CFG.fe),.PREFIX_ENQUEUE(1'b1)) u_buffer(
        .clk_i(clk_i),.rst_i(rst_i),.flush_i(clear_i),.enq_entry_i(result),.enq_valid_i(f1_mask_o),
        .enq_ready_o(buffer_ready),.deq_entry_o(delivered),.deq_valid_o(buffer_valid),.deq_ready_i(out_ready_i),
        .icache_req_allowed_o(),.kill_i(kill),.ftq_head_i(head_id_i),.perf_o());
    for(genvar lane=0;lane<DELIVER_W;lane++) begin
        assign out_valid_o[lane]=buffer_valid && delivered[lane].valid;
        assign out_pc_o[lane]=delivered[lane].pc;
        assign out_next_o[lane]=delivered[lane].predicted_next_pc;
        assign out_instruction_o[lane]=delivered[lane].instruction;
        assign out_raw_o[lane]=delivered[lane].raw_instruction;
        assign out_edge_o[lane]=delivered[lane].is_edge;
        assign out_last_o[lane]=delivered[lane].ftq_last;
        assign out_exc_o[lane]=delivered[lane].exception_valid;
        assign out_tval_o[lane]=delivered[lane].exception_tval;
        assign out_id_o[lane]=delivered[lane].ftq_id;
        assign out_slot_o[lane]=delivered[lane].slot;
    end
endmodule
