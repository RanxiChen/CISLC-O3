module fetch_buffer_payload_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
#(localparam int EW = O3_CFG.fe.fetch.f1_width,
  localparam int DW = O3_CFG.fe.fetch.deliver_width,
  localparam int BITS = $bits(fetch_entry_t)) (
    input logic clk_i, rst_i, flush_i,
    input logic [EW-1:0][BITS-1:0] enq_payload_i,
    input logic [EW-1:0] enq_valid_i,
    output logic enq_ready_o,
    output logic [DW-1:0][BITS-1:0] deq_payload_o,
    output logic deq_valid_o,
    input logic deq_ready_i,
    input logic kill_valid_i, kill_all_i, kill_self_i,
    input ftq_id_t kill_id_i, head_id_i,
    input fetch_slot_t kill_slot_i,
    output logic [31:0] depth_o, ftq_depth_o, slots_o,
    output logic [BITS-1:0] id_mask_o, slot_mask_o
);
    fetch_entry_t enq [EW], deq [DW], id_format, slot_format;
    fe_kill_t kill;
    assign kill = '{valid:kill_valid_i, all:kill_all_i, ftq_id:kill_id_i,
                    slot:kill_slot_i, kill_self:kill_self_i};
    assign depth_o = O3_CFG.fe.fetch.ibuf_depth;
    assign ftq_depth_o = FTQ_DEPTH;
    assign slots_o = REGION_SLOTS;
    always_comb begin
        id_format = '0;
        id_format.ftq_id = '1;
        slot_format = '0;
        slot_format.slot = '1;
    end
    assign id_mask_o = id_format;
    assign slot_mask_o = slot_format;
    for (genvar lane = 0; lane < EW; lane++)
        assign enq[lane] = fetch_entry_t'(enq_payload_i[lane]);
    for (genvar lane = 0; lane < DW; lane++)
        assign deq_payload_o[lane] = deq[lane];
    fetch_buffer #(.CFG(O3_CFG.fe)) dut (
        .clk_i, .rst_i, .flush_i, .enq_entry_i(enq), .enq_valid_i,
        .enq_ready_o, .deq_entry_o(deq), .deq_valid_o, .deq_ready_i,
        .icache_req_allowed_o(), .kill_i(kill), .ftq_head_i(head_id_i), .perf_o()
    );
endmodule
