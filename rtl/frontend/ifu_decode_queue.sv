/** Two-entry registered beat queue between F0 alignment and F1 predecode.
 * No bypass: first delivery follows an enqueue edge. Registered occupancy
 * supplies F0 ready, while pop/push can sustain one beat/cycle. Empty beats
 * retain their brief/last/edge-pending metadata for c-prime correction.
 * Kill blocks both handshakes, masks surviving instructions, and compacts
 * surviving order; payload stays in two physical rows. clear_i invalidates
 * both rows for frontend synchronization.
 */
module ifu_decode_queue import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG,
    localparam int F0_SLOTS=CFG.fetch.f0_slots
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
    typedef struct packed {
        logic [F0_SLOTS-1:0][$bits(f0_inst_t)-1:0] lanes;
        ftq_pred_brief_t brief;
    } payload_t;
    // One local enqueue enable per stationary wide row. Pop and kill never
    // copy, clear, or select a new value for this payload storage.
    payload_t payload_q[2],input_payload;
    logic [F0_SLOTS-1:0] mask_q[2];
    logic last_q[2],edge_pend_q[2];
    beat_t output_beat;
    logic head_q,head_d,tail;
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
    assign tail=head_q ^ count_q[0];
    always_comb begin
        output_beat='0;
        if(count_q!=0) begin
            output_beat.mask=mask_q[head_q];
            output_beat.lanes=payload_q[head_q].lanes;
            output_beat.brief=payload_q[head_q].brief;
            output_beat.last=last_q[head_q];
            output_beat.edge_pend=edge_pend_q[head_q];
        end
    end
    assign out_valid_o=output_beat.mask;
    assign out_brief_o=output_beat.brief;
    assign out_last_o=output_beat.last;
    assign out_edge_pend_o=output_beat.edge_pend;
    for(genvar lane=0;lane<F0_SLOTS;lane++) begin : g_ports
        assign input_payload.lanes[lane]=in_i[lane];
        assign out_o[lane]=f0_inst_t'(output_beat.lanes[lane]);
    end
    assign input_payload.brief=in_brief_i;
    for(genvar row=0;row<2;row++) begin : g_storage
        logic [F0_SLOTS-1:0] live_mask;
        logic occupied,pending_killed,write_row;
        assign occupied=count_q!=0 && (count_q==2 || head_q==1'(row));
        assign write_row=push && tail==1'(row);
        for(genvar lane=0;lane<F0_SLOTS;lane++) begin : g_lane
            f0_inst_t inst;
            assign inst=f0_inst_t'(payload_q[row].lanes[lane]);
            assign live_mask[lane]=mask_q[row][lane]
                && !fe_killed_by(kill_i,inst.ftq_id,inst.slot,ftq_head_i);
        end
        assign pending_killed=fe_killed_by(kill_i,payload_q[row].brief.ftq_id,
            fetch_slot_t'(REGION_SLOTS-1),ftq_head_i);
        assign keep[row]=occupied && ((|live_mask) || (mask_q[row]=='0 && !pending_killed));
        always_ff @(posedge clk_i) begin : payload_write
            if(write_row) payload_q[row]<=input_payload;
        end
        always_ff @(posedge clk_i) begin : metadata_write
            if(rst_i || clear_i) begin
                mask_q[row]<='0;last_q[row]<=0;edge_pend_q[row]<=0;
            end else if(kill_i.valid && occupied) begin
                mask_q[row]<=live_mask;
                last_q[row]<=last_q[row] || live_mask!=mask_q[row];
                edge_pend_q[row]<=edge_pend_q[row] && !pending_killed;
            end else if(write_row) begin
                mask_q[row]<=in_valid_i;
                last_q[row]<=in_last_i;
                edge_pend_q[row]<=in_edge_pend_i;
            end
        end
    end
    always_comb begin
        count_d=count_q+2'(push)-2'(pop);
        head_d=pop ? ~head_q:head_q;
        if(kill_i.valid) begin
            count_d=2'(keep[0])+2'(keep[1]);
            // Arbitrary identities can kill the older physical row while the
            // second survives. Compact only the one-bit order, not payload.
            if(count_q==2 && !keep[head_q] && keep[~head_q]) head_d=~head_q;
        end
        if(rst_i || clear_i) begin count_d=0;head_d=0;end
    end
    always_ff @(posedge clk_i) begin
        head_q<=head_d;count_q<=count_d;
        if(!rst_i) assert(count_q<=2) else $fatal(1,"IFU beat queue overflow");
    end
endmodule
