module ifu_decode_queue_tb_top import o3_types_pkg::*; (
    input logic clk_i,rst_i,clear_i,in_beat_valid_i,out_ready_i,
    input logic [F0_SLOTS-1:0] in_valid_i,
    input logic [F0_SLOTS-1:0][$bits(f0_inst_t)-1:0] in_inst_bits_i,
    input logic [$bits(ftq_pred_brief_t)-1:0] in_brief_bits_i,
    input logic in_last_i,in_edge_pend_i,
    output logic in_ready_o,out_beat_valid_o,
    output logic [F0_SLOTS-1:0] out_valid_o,
    output logic [F0_SLOTS-1:0][$bits(f0_inst_t)-1:0] out_inst_bits_o,
    output logic [$bits(ftq_pred_brief_t)-1:0] out_brief_bits_o,
    output logic out_last_o,out_edge_pend_o,
    input logic kill_valid_i,kill_all_i,kill_self_i,
    input logic [$bits(ftq_id_t)-1:0] kill_id_i,head_id_i,
    input fetch_slot_t kill_slot_i,
    output logic [$bits(f0_inst_t)-1:0] inst_id_mask_o,inst_slot_mask_o,
    output logic [$bits(ftq_pred_brief_t)-1:0] brief_id_mask_o,
    output logic [31:0] ftq_depth_o,region_slots_o
);
    f0_inst_t in_lanes[F0_SLOTS],out_lanes[F0_SLOTS],id_mask,slot_mask;
    ftq_pred_brief_t in_brief,out_brief,brief_mask;
    fe_kill_t kill;
    assign kill='{valid:kill_valid_i,all:kill_all_i,ftq_id:ftq_id_t'(kill_id_i),slot:kill_slot_i,kill_self:kill_self_i};
    assign in_brief=ftq_pred_brief_t'(in_brief_bits_i);
    assign out_brief_bits_o=out_brief;
    for(genvar lane=0;lane<F0_SLOTS;lane++) begin
        assign in_lanes[lane]=f0_inst_t'(in_inst_bits_i[lane]);
        assign out_inst_bits_o[lane]=out_lanes[lane];
    end
    always_comb begin
        id_mask='0;id_mask.ftq_id='1;
        slot_mask='0;slot_mask.slot='1;
        brief_mask='0;brief_mask.ftq_id='1;
    end
    assign inst_id_mask_o=id_mask;
    assign inst_slot_mask_o=slot_mask;
    assign brief_id_mask_o=brief_mask;
    assign ftq_depth_o=FTQ_DEPTH;
    assign region_slots_o=REGION_SLOTS;
    ifu_decode_queue #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut(
        .clk_i(clk_i),.rst_i(rst_i),.clear_i(clear_i),
        .in_beat_valid_i(in_beat_valid_i),.in_ready_o(in_ready_o),.in_valid_i(in_valid_i),
        .in_i(in_lanes),.in_brief_i(in_brief),.in_last_i(in_last_i),.in_edge_pend_i(in_edge_pend_i),
        .out_beat_valid_o(out_beat_valid_o),.out_ready_i(out_ready_i),.out_valid_o(out_valid_o),
        .out_o(out_lanes),.out_brief_o(out_brief),.out_last_o(out_last_o),.out_edge_pend_o(out_edge_pend_o),
        .boundary_wait_o(),.kill_i(kill),.ftq_head_i(ftq_id_t'(head_id_i)));
endmodule
