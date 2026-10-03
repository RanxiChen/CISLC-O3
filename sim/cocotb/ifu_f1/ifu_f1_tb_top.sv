/** cocotb adapter for F1 public input/output entries and prediction brief. */
module ifu_f1_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i,
    input logic [F0_SLOTS-1:0] in_valid_i,
    input logic [F0_SLOTS*VADDR_W-1:0] in_pc_flat_i,
    input logic [F0_SLOTS*ILEN-1:0] in_inst_flat_i,
    input logic [F0_SLOTS*$bits(ftq_id_t)-1:0] in_id_flat_i,
    input logic [SLOT_W-1:0] brief_cfi_slot_i,
    input logic brief_cfi_valid_i, brief_raw_taken_i,
    input logic [VADDR_W-1:0] brief_next_pc_i,
    input logic out_ready_i, kill_valid_i,
    output logic in_ready_o,
    output logic [F1_W-1:0] out_valid_o, entry_valid_o, ftq_last_o,
    output logic [F1_W-1:0] pred_taken_o,
    output logic [F1_W*VADDR_W-1:0] out_pc_flat_o, out_next_flat_o,
    output logic [F1_W*ILEN-1:0] out_inst_flat_o, out_raw_flat_o,
    output logic [F1_W*$bits(ftq_id_t)-1:0] out_id_flat_o,
    output logic [F1_W*SLOT_W-1:0] out_slot_flat_o,
    output logic predecode_valid_o,
    output logic [31:0] cfg_f1_width_o
);
    f0_inst_t in_inst [F0_SLOTS];
    fetch_entry_t out_inst [F1_W];
    ftq_pred_brief_t brief;
    redirect_req_t predecode;
    fe_kill_t kill;
    always_comb begin
        brief = '0;
        brief.pred.cfi_valid = brief_cfi_valid_i;
        brief.pred.cfi_slot = brief_cfi_slot_i;
        brief.pred.raw_pred_taken = brief_raw_taken_i;
        brief.pred.next_pc = brief_next_pc_i;
        kill = '0;
        kill.valid = kill_valid_i;
        for (int slot = 0; slot < F0_SLOTS; slot++) begin
            in_inst[slot] = '0;
            in_inst[slot].pc = in_pc_flat_i[slot*VADDR_W +: VADDR_W];
            in_inst[slot].instruction = in_inst_flat_i[slot*ILEN +: ILEN];
            in_inst[slot].raw_instruction = in_inst_flat_i[slot*ILEN +: ILEN];
            in_inst[slot].inst_len = 3'd4;
            in_inst[slot].ftq_id =
                ftq_id_t'(in_id_flat_i[slot*$bits(ftq_id_t) +: $bits(ftq_id_t)]);
            in_inst[slot].slot = fetch_slot_t'(slot);
        end
    end
    ifu_f1 #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .in_valid_i(in_valid_i), .in_ready_o(in_ready_o),
        .in_i(in_inst), .in_brief_i(brief),
        .out_o(out_inst), .out_valid_o(out_valid_o), .out_ready_i(out_ready_i),
        .predecode_o(predecode), .kill_i(kill), .perf_o()
    );
    for (genvar lane = 0; lane < F1_W; lane++) begin : flatten
        assign entry_valid_o[lane] = out_inst[lane].valid;
        assign ftq_last_o[lane] = out_inst[lane].ftq_last;
        assign pred_taken_o[lane] = out_inst[lane].pred_taken;
        assign out_pc_flat_o[lane*VADDR_W +: VADDR_W] = out_inst[lane].pc;
        assign out_next_flat_o[lane*VADDR_W +: VADDR_W] = out_inst[lane].predicted_next_pc;
        assign out_inst_flat_o[lane*ILEN +: ILEN] = out_inst[lane].instruction;
        assign out_raw_flat_o[lane*ILEN +: ILEN] = out_inst[lane].raw_instruction;
        assign out_id_flat_o[lane*$bits(ftq_id_t) +: $bits(ftq_id_t)] = out_inst[lane].ftq_id;
        assign out_slot_flat_o[lane*SLOT_W +: SLOT_W] = out_inst[lane].slot;
    end
    assign predecode_valid_o = predecode.valid;
    assign cfg_f1_width_o = O3_CFG.fe.fetch.f1_width;
endmodule
