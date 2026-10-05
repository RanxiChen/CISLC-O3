/** cocotb adapter for F0 public block and instruction fields. */
module ifu_f0_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i, in_valid_i, out_ready_i,
    input logic [VADDR_W-1:0] region_base_i,
    input logic [REGION_BYTES*8-1:0] block_data_i,
    input logic [$bits(ftq_id_t)-1:0] ftq_id_i,
    input logic [SLOT_W-1:0] entry_slot_i,
    input logic cfi_valid_i,
    input logic [SLOT_W-1:0] cfi_slot_i,
    input logic kill_valid_i, sync_clear_i,
    input logic exc_valid_i,
    input logic [5:0] exc_cause_i,
    output logic [F0_SLOTS-1:0] out_exc_o,
    output logic [F0_SLOTS*XLEN-1:0] out_tval_flat_o,
    output logic [F0_SLOTS*6-1:0] out_cause_flat_o,
    output logic in_ready_o,
    output logic [F0_SLOTS-1:0] out_valid_o,
    output logic [F0_SLOTS*VADDR_W-1:0] out_pc_flat_o,
    output logic [F0_SLOTS*ILEN-1:0] out_inst_flat_o,
    output logic [F0_SLOTS*3-1:0] out_len_flat_o,
    output logic [F0_SLOTS*SLOT_W-1:0] out_slot_flat_o,
    output logic [F0_SLOTS*$bits(ftq_id_t)-1:0] out_id_flat_o,
    output logic [$bits(ftq_id_t)-1:0] out_brief_id_o,
    output logic [31:0] cfg_region_bytes_o
);
    rq_out_t block_in;
    ftq_pred_brief_t brief_in, brief_out;
    f0_inst_t inst_out [F0_SLOTS];
    fe_kill_t kill;
    always_comb begin
        block_in = '0;
        block_in.exc_valid = exc_valid_i;
        block_in.exc_cause = exception_cause_t'(exc_cause_i);
        block_in.region_base = region_base_i;
        block_in.data = block_data_i;
        block_in.ftq_id = ftq_id_t'(ftq_id_i);
        brief_in = '0;
        brief_in.ftq_id = ftq_id_t'(ftq_id_i);
        brief_in.pred.entry_slot = entry_slot_i;
        brief_in.pred.cfi_valid = cfi_valid_i;
        brief_in.pred.cfi_slot = cfi_slot_i;
        kill = '0;
        kill.valid = kill_valid_i;
    end
    ifu_f0 #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .in_valid_i(in_valid_i), .in_ready_o(in_ready_o),
        .in_i(block_in), .in_brief_i(brief_in),
        .out_valid_o(out_valid_o), .out_ready_i(out_ready_i),
        .out_o(inst_out), .out_brief_o(brief_out),
        .kill_i(kill), .sync_clear_i(sync_clear_i), .perf_o()
    );
    for (genvar slot = 0; slot < F0_SLOTS; slot++) begin : flatten
        assign out_exc_o[slot] = inst_out[slot].exc_valid;
        assign out_tval_flat_o[slot*XLEN +: XLEN] = inst_out[slot].exc_tval;
        assign out_cause_flat_o[slot*6 +: 6] = 6'(inst_out[slot].exc_cause);
        assign out_pc_flat_o[slot*VADDR_W +: VADDR_W] = inst_out[slot].pc;
        assign out_inst_flat_o[slot*ILEN +: ILEN] = inst_out[slot].instruction;
        assign out_len_flat_o[slot*3 +: 3] = inst_out[slot].inst_len;
        assign out_slot_flat_o[slot*SLOT_W +: SLOT_W] = inst_out[slot].slot;
        assign out_id_flat_o[slot*$bits(ftq_id_t) +: $bits(ftq_id_t)] = inst_out[slot].ftq_id;
    end
    assign out_brief_id_o = brief_out.ftq_id;
    assign cfg_region_bytes_o = O3_CFG.fe.fetch.region_bytes;
endmodule
