/** Public adapter; entries carry distinct metadata to check survivor integrity. */
module fetch_buffer_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i, flush_i,
    input logic [F1_W-1:0] enq_valid_i,
    input logic [F1_W-1:0][$bits(ftq_id_t)-1:0] enq_id_i,
    input logic [F1_W-1:0][SLOT_W-1:0] enq_slot_i,
    input logic [F1_W-1:0][VADDR_W-1:0] enq_pc_i,
    output logic enq_ready_o, deq_valid_o,
    input logic deq_ready_i,
    output logic [DELIVER_W-1:0] deq_mask_o,
    output logic [DELIVER_W-1:0][$bits(ftq_id_t)-1:0] deq_id_o,
    output logic [DELIVER_W-1:0][SLOT_W-1:0] deq_slot_o,
    output logic [DELIVER_W-1:0][VADDR_W-1:0] deq_pc_o,
    output logic [DELIVER_W-1:0][VADDR_W-1:0] deq_next_o,
    output logic [DELIVER_W-1:0][ILEN-1:0] deq_inst_o,
    output logic [DELIVER_W-1:0] deq_last_o, deq_taken_o,
    input logic kill_valid_i, kill_all_i, kill_self_i,
    input logic [$bits(ftq_id_t)-1:0] kill_id_i, head_i,
    input logic [SLOT_W-1:0] kill_slot_i,
    output logic [31:0] depth_o, ftq_depth_o
);
    fetch_entry_t enq [F1_W], deq [DELIVER_W];
    fe_kill_t kill;
    always_comb begin
        kill = '{valid:kill_valid_i, all:kill_all_i, kill_self:kill_self_i,
                 ftq_id:ftq_id_t'(kill_id_i), slot:kill_slot_i};
        for (int i=0; i<F1_W; i++) begin
            enq[i] = '0;
            enq[i].valid = enq_valid_i[i];
            enq[i].ftq_id = ftq_id_t'(enq_id_i[i]);
            enq[i].slot = enq_slot_i[i];
            enq[i].pc = enq_pc_i[i];
            enq[i].instruction = 32'(enq_pc_i[i]);
            enq[i].predicted_next_pc = enq_pc_i[i] + vaddr_t'(4);
            enq[i].ftq_last = enq_slot_i[i] == fetch_slot_t'(6);
            enq[i].pred_taken = enq_slot_i[i] == fetch_slot_t'(2);
        end
        for (int i=0; i<DELIVER_W; i++) begin
            deq_mask_o[i] = deq[i].valid;
            deq_id_o[i] = deq[i].ftq_id;
            deq_slot_o[i] = deq[i].slot;
            deq_pc_o[i] = deq[i].pc;
            deq_inst_o[i] = deq[i].instruction;
            deq_next_o[i] = deq[i].predicted_next_pc;
            deq_last_o[i] = deq[i].ftq_last;
            deq_taken_o[i] = deq[i].pred_taken;
        end
    end
    fetch_buffer #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i), .flush_i(flush_i),
        .enq_entry_i(enq), .enq_valid_i(enq_valid_i), .enq_ready_o(enq_ready_o),
        .deq_entry_o(deq), .deq_valid_o(deq_valid_o), .deq_ready_i(deq_ready_i),
        .kill_i(kill), .ftq_head_i(ftq_id_t'(head_i)),
        .icache_req_allowed_o(), .perf_o()
    );
    assign depth_o = O3_CFG.fe.fetch.ibuf_depth;
    assign ftq_depth_o = FTQ_DEPTH;
endmodule
