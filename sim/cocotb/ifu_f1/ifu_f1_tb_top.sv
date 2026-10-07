/** cocotb adapter for F1: flattened F0 items, full FTQ brief, entries and predecode request. */
module ifu_f1_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i,
    input logic beat_valid_i,last_i,edge_pend_i,
    input logic [REGION_SLOTS*3-1:0] in_len_flat_i,
    input logic [REGION_SLOTS-1:0] in_edge_i,
    input logic brief_rvc_i,brief_edge_i,
    input logic [VADDR_W-1:0] brief_base_i,
    input logic [$bits(ftq_id_t)-1:0] brief_id_i,
    output logic trunc_o,
    output fetch_slot_t trunc_slot_o,
    input logic [REGION_SLOTS-1:0] in_valid_i,
    input logic [REGION_SLOTS*VADDR_W-1:0] in_pc_flat_i,
    input logic [REGION_SLOTS*ILEN-1:0] in_inst_flat_i,
    input logic [REGION_SLOTS*$bits(ftq_id_t)-1:0] in_id_flat_i,
    input logic [REGION_SLOTS-1:0] in_exc_valid_i,
    input logic [REGION_SLOTS*$bits(exception_cause_t)-1:0] in_exc_cause_flat_i,
    input logic [REGION_SLOTS*XLEN-1:0] in_exc_tval_flat_i,
    input logic brief_cfi_valid_i, brief_raw_taken_i,
    input logic [SLOT_W-1:0] brief_cfi_slot_i,
    input logic [1:0] brief_cfi_type_i, brief_ras_action_i,
    input logic [VADDR_W-1:0] brief_cfi_target_i, brief_next_pc_i,
    input logic [RAS_CNT_W-1:0] brief_ras_count_i,
    input logic [VADDR_W-1:0] brief_ras_top_i,
    input logic out_ready_i, kill_valid_i,
    output logic in_ready_o,
    output logic [F1_W-1:0] out_valid_o, entry_valid_o, ftq_last_o,
    output logic [F1_W-1:0] pred_taken_o, out_exc_valid_o,
    output logic [F1_W*VADDR_W-1:0] out_pc_flat_o, out_next_flat_o,
    output logic [F1_W*ILEN-1:0] out_inst_flat_o, out_raw_flat_o,
    output logic [F1_W*$bits(ftq_id_t)-1:0] out_id_flat_o,
    output logic [F1_W*SLOT_W-1:0] out_slot_flat_o,
    output logic [F1_W*$bits(exception_cause_t)-1:0] out_exc_cause_flat_o,
    output logic [F1_W*XLEN-1:0] out_exc_tval_flat_o,
    output logic predecode_valid_o,
    output logic [1:0] pd_src_o, pd_ras_fix_o,
    output logic [$bits(ftq_id_t)-1:0] pd_ftq_id_o,
    output logic [SLOT_W-1:0] pd_slot_o,
    output logic pd_kill_self_o, pd_hist_inject_o,
    output logic [VADDR_W-1:0] pd_target_o, pd_hist_branch_o, pd_hist_target_o, pd_push_addr_o,
    output logic [31:0] cfg_f1_width_o
);
    f0_inst_t in_inst [F0_SLOTS];
    logic [F0_SLOTS-1:0] compact_valid;
    fetch_entry_t out_inst [F1_W];
    ftq_pred_brief_t brief;
    redirect_req_t predecode;
    fe_kill_t kill;
    always_comb begin
        int count;
        count=0;
        brief = '0;
        brief.ftq_id=ftq_id_t'(brief_id_i);
        brief.pred.region_base=brief_base_i;
        brief.pred.cfi_is_rvc=brief_rvc_i;brief.pred.is_edge=brief_edge_i;
        brief.pred.cfi_valid = brief_cfi_valid_i;
        brief.pred.cfi_slot = brief_cfi_slot_i;
        brief.pred.cfi_type = cfi_type_e'(brief_cfi_type_i);
        brief.pred.ras_action = ras_action_e'(brief_ras_action_i);
        brief.pred.raw_pred_taken = brief_raw_taken_i;
        brief.pred.cfi_target = brief_cfi_target_i;
        brief.pred.next_pc = brief_next_pc_i;
        brief.ras_ckpt.count = brief_ras_count_i;
        brief.ras_ckpt.top_addr = brief_ras_top_i;
        kill = '0;
        kill.valid = kill_valid_i;
        for(int lane=0;lane<F0_SLOTS;lane++) in_inst[lane]='0;
        compact_valid='0;
        for (int slot = 0; slot < REGION_SLOTS; slot++) begin
          if(in_valid_i[slot] && count<F0_SLOTS) begin
            compact_valid[count]=1;
            in_inst[count].pc = in_pc_flat_i[slot*VADDR_W +: VADDR_W];
            in_inst[count].instruction = in_inst_flat_i[slot*ILEN +: ILEN];
            in_inst[count].raw_instruction = in_inst_flat_i[slot*ILEN +: ILEN];
            in_inst[count].inst_len = in_len_flat_i[slot*3 +: 3];
            in_inst[count].is_rvc = in_inst[count].inst_len==2;
            in_inst[count].is_edge = in_edge_i[slot];
            in_inst[count].ftq_id =
                ftq_id_t'(in_id_flat_i[slot*$bits(ftq_id_t) +: $bits(ftq_id_t)]);
            in_inst[count].slot = fetch_slot_t'(slot);
            in_inst[count].exc_valid = in_exc_valid_i[slot];
            in_inst[count].exc_cause = exception_cause_t'(
                in_exc_cause_flat_i[slot*$bits(exception_cause_t) +: $bits(exception_cause_t)]);
            in_inst[count].exc_tval = in_exc_tval_flat_i[slot*XLEN +: XLEN];
            count++;
          end
        end
    end
    ifu_f1 #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .in_valid_i(compact_valid),.in_beat_valid_i(beat_valid_i),.in_last_i(last_i),.in_edge_pend_i(edge_pend_i), .in_ready_o(in_ready_o),
        .in_i(in_inst), .in_brief_i(brief),
        .out_o(out_inst), .out_valid_o(out_valid_o), .out_ready_i(out_ready_i),
        .predecode_o(predecode),.trunc_o(trunc_o),.trunc_slot_o(trunc_slot_o), .kill_i(kill), .perf_o()
    );
    for (genvar lane = 0; lane < F1_W; lane++) begin : flatten
        assign entry_valid_o[lane] = out_inst[lane].valid;
        assign ftq_last_o[lane] = out_inst[lane].ftq_last;
        assign pred_taken_o[lane] = out_inst[lane].pred_taken;
        assign out_exc_valid_o[lane] = out_inst[lane].exception_valid;
        assign out_pc_flat_o[lane*VADDR_W +: VADDR_W] = out_inst[lane].pc;
        assign out_next_flat_o[lane*VADDR_W +: VADDR_W] = out_inst[lane].predicted_next_pc;
        assign out_inst_flat_o[lane*ILEN +: ILEN] = out_inst[lane].instruction;
        assign out_raw_flat_o[lane*ILEN +: ILEN] = out_inst[lane].raw_instruction;
        assign out_id_flat_o[lane*$bits(ftq_id_t) +: $bits(ftq_id_t)] = out_inst[lane].ftq_id;
        assign out_slot_flat_o[lane*SLOT_W +: SLOT_W] = out_inst[lane].slot;
        assign out_exc_cause_flat_o[lane*$bits(exception_cause_t) +: $bits(exception_cause_t)] =
            out_inst[lane].exception_cause;
        assign out_exc_tval_flat_o[lane*XLEN +: XLEN] = out_inst[lane].exception_tval;
    end
    assign predecode_valid_o = predecode.valid;
    assign pd_src_o = predecode.src;
    assign pd_ras_fix_o = predecode.ras_fix;
    assign pd_ftq_id_o = predecode.ftq_id;
    assign pd_slot_o = predecode.slot;
    assign pd_kill_self_o = predecode.kill_self;
    assign pd_hist_inject_o = predecode.hist_inject;
    assign pd_target_o = predecode.target_pc;
    assign pd_hist_branch_o = predecode.hist_branch_pc;
    assign pd_hist_target_o = predecode.hist_target_pc;
    assign pd_push_addr_o = predecode.ras_push_addr;
    assign cfg_f1_width_o = O3_CFG.fe.fetch.f1_width;
endmodule
