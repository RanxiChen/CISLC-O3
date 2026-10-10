/** L7b F0: four compacted instructions per beat, first-beat block consumption,
 * retained remainder, and a pending halfword owned by the following region.
 * All state changes require a beat handshake; truncation uses the same age
 * boundary as a normal kill, including slot-7 preservation of pend_q.
 */
module ifu_f0 import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
)(
    input logic clk_i,rst_i,
    input logic in_valid_i,output logic in_ready_o,
    input rq_out_t in_i,input ftq_pred_brief_t in_brief_i,
    output logic [F0_SLOTS-1:0] out_valid_o,input logic out_ready_i,
    output f0_inst_t out_o[F0_SLOTS],output ftq_pred_brief_t out_brief_o,
    output logic out_beat_valid_o,out_last_o,out_edge_pend_o,
    input logic trunc_i,input fetch_slot_t trunc_slot_i,
    input fe_kill_t kill_i,input ftq_id_t ftq_head_i,
    input logic sync_clear_i,output fe_perf_t perf_o
);
    typedef struct packed {
        logic valid;
        rq_out_t block_data;
        ftq_pred_brief_t brief;
        fetch_slot_t pos;
    } hold_t;
    typedef struct packed {
        logic valid;
        logic [15:0] halfword;
        ftq_id_t ftq_id;
        vaddr_t next_region_base;
    } pend_t;
    hold_t hold_q,hold_d;
    pend_t pend_q,pend_d;
    rq_out_t current_block;
    ftq_pred_brief_t current_brief;
    fe_kill_t trunc_boundary;
    logic active,edge_start,finished,save_half,fire;
    logic signed [4:0] start_pos,next_pos,exit_pos;

    assign current_block=hold_q.valid ? hold_q.block_data:in_i;
    assign current_brief=hold_q.valid ? hold_q.brief:in_brief_i;
    assign active=(hold_q.valid || in_valid_i) && !rst_i && !kill_i.valid && !sync_clear_i;
    assign out_beat_valid_o=active;
    assign out_brief_o=active ? current_brief:'0;
    assign in_ready_o=out_ready_i && !hold_q.valid && !kill_i.valid && !sync_clear_i && !rst_i;
    assign fire=active && out_ready_i;
    assign perf_o='0;
    assign edge_start=!hold_q.valid && pend_q.valid
        && current_block.region_base==pend_q.next_region_base
        && current_brief.pred.entry_slot==0;
    assign start_pos=hold_q.valid ? 5'(hold_q.pos)
        : (edge_start ? -1:5'(current_brief.pred.entry_slot));
    assign exit_pos=current_brief.pred.is_edge ? -1:5'(current_brief.pred.cfi_slot);

    // Decode each physical halfword before selecting the compacted lanes.
    // Only the one-bit start network is serial; no lane feeds a wide selector
    // or instruction-length adder in the following lane.
    logic [REGION_SLOTS-1:0] short_at, start_at;
    logic [31:0] expanded_at[REGION_SLOTS];
    logic legal_at[REGION_SLOTS];
    vaddr_t pc_at[REGION_SLOTS],edge_pc;
    assign edge_pc=current_block.region_base-vaddr_t'(2);
    logic [3:0] rank_at[REGION_SLOTS];
    logic signed [4:0] first_pos;
    assign first_pos=edge_start ? 1:start_pos;
    for(genvar hw=0;hw<REGION_SLOTS;hw++) begin : g_halfword
        logic start;
        assign start_at[hw]=start;
        wire [15:0] raw=current_block.data[hw*16 +: 16];
        assign pc_at[hw]=current_block.region_base+vaddr_t'(2*hw);
        assign short_at[hw]=raw[1:0]!=2'b11;
        rvc_expander expand(.in_i(raw),.out_o(expanded_at[hw]),.legal_o(legal_at[hw]));
        if(hw==0) assign start=first_pos==0;
        else if(hw==1) assign start=first_pos==1 ||
            (first_pos<1 && g_halfword[0].start && short_at[0]);
        else assign start=first_pos==hw || (first_pos<hw &&
            ((g_halfword[hw-1].start && short_at[hw-1]) ||
             (g_halfword[hw-2].start && !short_at[hw-2])));
        // Fixed prefix population count, independent of the selected lanes.
        always_comb begin
            rank_at[hw]='0;
            for(int k=0;k<=hw;k++) rank_at[hw]+=4'(start_at[k]);
        end
    end
    for(genvar lane=0;lane<F0_SLOTS;lane++) begin : decode_lane
        logic signed [4:0] selected_pos;
        vaddr_t selected_pc;
        logic edge_inst,short_inst;
        logic [31:0] selected_raw, selected_expanded;
        logic selected_legal,stop_out,pending_out,found;
        logic [2:0] selected_idx;
        wire stop_in;
        wire pending_in;
        if(lane==0) begin
            assign stop_in=!active;
            assign pending_in=1'b0;
        end else begin
            assign stop_in=decode_lane[lane-1].stop_out;
            assign pending_in=decode_lane[lane-1].pending_out;
        end
        always_comb begin
            selected_pos=5'(REGION_SLOTS);
            selected_raw='0;selected_expanded='0;selected_legal=0;
            selected_idx='0;found=0;selected_pc='0;
            for(int hw=0;hw<REGION_SLOTS;hw++) begin
                logic pick;
                pick=start_at[hw] && int'(rank_at[hw])==lane+1-int'(edge_start);
                found|=pick;
                selected_idx|=3'(hw) & {3{pick}};
                selected_raw|=32'(current_block.data >> (16*hw)) & {32{pick}};
                selected_expanded|=expanded_at[hw] & {32{pick}};
                selected_legal|=legal_at[hw] && pick;
                selected_pc|=pc_at[hw] & {VADDR_W{pick}};
            end
            if(found) selected_pos=5'(selected_idx);
            edge_inst=edge_start && lane==0;
            if(edge_inst) begin selected_pos=-1;selected_pc=edge_pc;end
            short_inst=!edge_inst && selected_pos<5'(REGION_SLOTS) &&
                selected_raw[1:0]!=2'b11;
        end
        always_comb begin
            logic signed [4:0] end_pos;
            end_pos=edge_inst ? 0:selected_pos+(short_inst ? 0:1);
            out_o[lane]='0;out_valid_o[lane]=0;
            stop_out=stop_in;
            pending_out=pending_in;
            // The next position is selected independently, not recursively.
            if(lane==F0_SLOTS-1) next_pos=end_pos+1;
            if(!stop_in && selected_pos<5'(REGION_SLOTS)) begin
                if(!current_block.exc_valid && selected_pos==5'(REGION_SLOTS-1) && !short_inst) begin
                    stop_out=1;pending_out=1;
                end else begin
                    out_valid_o[lane]=1;
                    out_o[lane].ftq_id=current_block.ftq_id;
                    out_o[lane].slot=edge_inst ? '0:fetch_slot_t'(selected_pos);
                    out_o[lane].is_edge=edge_inst;
                    out_o[lane].pc=selected_pc;
                    out_o[lane].is_rvc=short_inst;
                    out_o[lane].inst_len=short_inst ? 3'd2:3'd4;
                    if(edge_inst) begin
                        out_o[lane].instruction={current_block.data[15:0],pend_q.halfword};
                        out_o[lane].raw_instruction=out_o[lane].instruction;
                    end else if(short_inst) begin
                        out_o[lane].instruction=selected_expanded;
                        out_o[lane].raw_instruction={16'b0,selected_raw[15:0]};
                        if(!selected_legal) begin
                            out_o[lane].exc_valid=1;
                            out_o[lane].exc_cause=o3_isa_pkg::EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION;
                            out_o[lane].exc_tval=XLEN'(selected_raw[15:0]);
                        end
                    end else begin
                        out_o[lane].instruction=selected_raw;
                        out_o[lane].raw_instruction=selected_raw;
                    end
                    if(current_block.exc_valid) begin
                        out_o[lane].instruction='0;out_o[lane].raw_instruction='0;
                        out_o[lane].inst_len='0;out_o[lane].is_rvc=0;
                        out_o[lane].exc_valid=1;out_o[lane].exc_cause=current_block.exc_cause;
                        out_o[lane].exc_tval=edge_inst ? XLEN'(current_block.region_base):XLEN'(out_o[lane].pc);
                    end
                    stop_out=out_o[lane].exc_valid || end_pos>=5'(REGION_SLOTS-1)
                        || (current_brief.pred.cfi_valid && end_pos>=exit_pos);
                end
            end
        end
    end
    // Can save the final halfword without using a fifth instruction lane.
    assign save_half=active && !current_block.exc_valid
        && (decode_lane[F0_SLOTS-1].pending_out || (!decode_lane[F0_SLOTS-1].stop_out && next_pos==5'(REGION_SLOTS-1)
            && current_block.data[(REGION_SLOTS-1)*16 +: 2]==2'b11));
    assign finished=decode_lane[F0_SLOTS-1].stop_out || next_pos>=5'(REGION_SLOTS) || save_half;
    assign out_last_o=active && finished;
    assign out_edge_pend_o=save_half;
    always_comb begin
        hold_d=hold_q;pend_d=pend_q;
        trunc_boundary='{valid:trunc_i,all:1'b0,ftq_id:current_block.ftq_id,
            slot:trunc_slot_i,kill_self:1'b0};
        if(fire) begin
            if(!hold_q.valid) pend_d.valid=0;
            hold_d.valid=!finished;
            if(!finished) begin
                hold_d.block_data=current_block;hold_d.brief=current_brief;
                hold_d.pos=fetch_slot_t'(next_pos);
            end
            if(save_half) pend_d='{valid:1'b1,halfword:current_block.data[REGION_BYTES*8-16 +: 16],
                ftq_id:current_block.ftq_id,next_region_base:current_block.region_base+vaddr_t'(REGION_BYTES)};
            if(current_block.exc_valid) pend_d.valid=0;
        end
        if(hold_d.valid && (fe_killed_by(kill_i,hold_d.block_data.ftq_id,hold_d.pos,ftq_head_i)
            // The held remainder is always part of current_block. F1's
            // same-beat truncation needs only a slot comparison, not age math.
            || (trunc_i && hold_d.pos>trunc_slot_i))) hold_d.valid=0;
        if(pend_d.valid && (fe_killed_by(kill_i,pend_d.ftq_id,fetch_slot_t'(REGION_SLOTS-1),ftq_head_i)
            || fe_killed_by(trunc_boundary,pend_d.ftq_id,fetch_slot_t'(REGION_SLOTS-1),ftq_head_i))) pend_d.valid=0;
        if(sync_clear_i) begin hold_d='0;pend_d='0;end
    end
    always_ff @(posedge clk_i) begin
        if(rst_i) begin hold_q<='0;pend_q<='0;end
        else begin hold_q<=hold_d;pend_q<=pend_d;end
    end
endmodule
