/** Two-entry registered beat queue between F0 alignment and F1 predecode.
 * No bypass: first delivery follows an enqueue edge. Registered occupancy
 * supplies F0 ready, while pop/push can sustain one beat/cycle. Empty beats
 * retain their brief/last/edge-pending metadata for c-prime correction.
 * Kill blocks both handshakes, masks surviving instructions, and compacts
 * surviving beats; clear_i discards all state for frontend synchronization.
 */
module ifu_decode_queue import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
)(
    input logic clk_i,rst_i,clear_i,
    input logic in_beat_valid_i, output logic in_ready_o,
    input logic [F0_SLOTS-1:0] in_valid_i,
    input f0_inst_t in_i[F0_SLOTS],
    input ftq_pred_brief_t in_brief_i,
    input logic in_last_i,in_edge_pend_i,
    output logic out_beat_valid_o,input logic out_ready_i,
    output logic [F0_SLOTS-1:0] out_valid_o,
    output f0_inst_t out_o[F0_SLOTS],
    output ftq_pred_brief_t out_brief_o,
    output logic out_last_o,out_edge_pend_o,
    output logic boundary_wait_o,
    input fe_kill_t kill_i,input ftq_id_t ftq_head_i
);
    typedef struct packed {
        logic [F0_SLOTS-1:0] mask;
        logic [F0_SLOTS-1:0][$bits(f0_inst_t)-1:0] lanes;
        ftq_pred_brief_t brief;
        logic last,edge_pend;
    } beat_t;
    beat_t beat_q[2],beat_d[2],input_beat,survivor[2],output_beat;
    logic [1:0] count_q,count_d;
    logic [1:0] keep;
    logic push,pop;
    // Do not let alignment consume a pending halfword before its owner beat
    // reaches F1. A slot-7 c-prime redirect must retain that halfword while the
    // younger path is killed; ordinary queued payload can simply be squashed.
    logic boundary_wait_q;
    ftq_id_t boundary_id_q;
    assign boundary_wait_o=boundary_wait_q;
    always_ff @(posedge clk_i) begin
        if(rst_i || clear_i) begin boundary_wait_q<=0;boundary_id_q<='0;end
        else if(kill_i.valid) begin
            if(fe_killed_by(kill_i,boundary_id_q,fetch_slot_t'(REGION_SLOTS-1),ftq_head_i)) boundary_wait_q<=0;
        end else begin
            if(pop && output_beat.edge_pend && output_beat.brief.ftq_id==boundary_id_q) boundary_wait_q<=0;
            if(push && in_edge_pend_i) begin boundary_wait_q<=1;boundary_id_q<=in_brief_i.ftq_id;end
        end
    end
    assign in_ready_o=!rst_i && !clear_i && !kill_i.valid && count_q<2'd2;
    assign out_beat_valid_o=!rst_i && !clear_i && !kill_i.valid && count_q!=0;
    assign push=in_beat_valid_i && in_ready_o;
    assign pop=out_beat_valid_o && out_ready_i;
    assign output_beat=count_q!=0 ? beat_q[0]:beat_t'('0);
    assign out_valid_o=output_beat.mask;
    assign out_brief_o=output_beat.brief;
    assign out_last_o=output_beat.last;
    assign out_edge_pend_o=output_beat.edge_pend;
    for(genvar lane=0;lane<F0_SLOTS;lane++) begin : g_ports
        assign input_beat.lanes[lane]=in_i[lane];
        assign out_o[lane]=f0_inst_t'(output_beat.lanes[lane]);
    end
    assign input_beat.mask=in_valid_i;
    assign input_beat.brief=in_brief_i;
    assign input_beat.last=in_last_i;
    assign input_beat.edge_pend=in_edge_pend_i;
    for(genvar row=0;row<2;row++) begin : g_boundary
        logic [F0_SLOTS-1:0] live_mask;
        logic pending_killed;
        for(genvar lane=0;lane<F0_SLOTS;lane++) begin : g_lane
            f0_inst_t inst;
            assign inst=f0_inst_t'(beat_q[row].lanes[lane]);
            assign live_mask[lane]=beat_q[row].mask[lane]
                && !fe_killed_by(kill_i,inst.ftq_id,inst.slot,ftq_head_i);
        end
        assign pending_killed=fe_killed_by(kill_i,beat_q[row].brief.ftq_id,
            fetch_slot_t'(REGION_SLOTS-1),ftq_head_i);
        assign keep[row]=row<int'(count_q) && ((|live_mask) || (beat_q[row].mask=='0 && !pending_killed));
        always_comb begin
            survivor[row]=beat_q[row];
            survivor[row].mask=live_mask;
            survivor[row].last=beat_q[row].last || live_mask!=beat_q[row].mask;
            survivor[row].edge_pend=beat_q[row].edge_pend && !pending_killed;
        end
    end
    always_comb begin
        beat_d=beat_q;count_d=count_q;
        if(pop) begin beat_d[0]=beat_q[1];beat_d[1]='0;count_d=count_q-1'b1;end
        if(push) begin
            if(count_d==0) beat_d[0]=input_beat;
            else beat_d[1]=input_beat;
            count_d=count_d+1'b1;
        end
        if(kill_i.valid) begin
            beat_d[0]=keep[0] ? survivor[0]:keep[1] ? survivor[1]:beat_t'('0);
            beat_d[1]=keep[0] && keep[1] ? survivor[1]:beat_t'('0);
            count_d=2'(keep[0])+2'(keep[1]);
        end
        if(rst_i || clear_i) begin beat_d='{default:'0};count_d=0;end
    end
    always_ff @(posedge clk_i) begin
        beat_q<=beat_d;count_q<=count_d;
        if(!rst_i) assert(count_q<=2) else $fatal(1,"IFU beat queue overflow");
    end
endmodule
