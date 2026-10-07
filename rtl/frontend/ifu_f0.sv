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
        vaddr_t region_base;
    } pend_t;
    hold_t hold_q,hold_d;
    pend_t pend_q,pend_d;
    rq_out_t current_block;
    ftq_pred_brief_t current_brief;
    fe_kill_t trunc_boundary;
    logic active,edge_start,finished,save_half,fire;
    int pos[F0_SLOTS+1];
    logic stopped[F0_SLOTS+1],pending_seen[F0_SLOTS+1];
    logic [15:0] halfword[F0_SLOTS];
    logic [31:0] expanded[F0_SLOTS];
    logic legal[F0_SLOTS];
    int exit_pos;

    assign current_block=hold_q.valid ? hold_q.block_data:in_i;
    assign current_brief=hold_q.valid ? hold_q.brief:in_brief_i;
    assign active=(hold_q.valid || in_valid_i) && !rst_i && !kill_i.valid && !sync_clear_i;
    assign out_beat_valid_o=active;
    assign out_brief_o=active ? current_brief:'0;
    assign in_ready_o=out_ready_i && !hold_q.valid && !kill_i.valid && !sync_clear_i && !rst_i;
    assign fire=active && out_ready_i;
    assign perf_o='0;
    assign edge_start=!hold_q.valid && pend_q.valid
        && current_block.region_base==pend_q.region_base+vaddr_t'(REGION_BYTES)
        && current_brief.pred.entry_slot==0;
    assign pos[0]=hold_q.valid ? int'(hold_q.pos)
        : (edge_start ? -1:int'(current_brief.pred.entry_slot));
    assign stopped[0]=!active;
    assign pending_seen[0]=0;
    assign exit_pos=current_brief.pred.is_edge ? -1:int'(current_brief.pred.cfi_slot);

    for(genvar lane=0;lane<F0_SLOTS;lane++) begin: decode_lane
        assign halfword[lane]=(pos[lane]>=0 && pos[lane]<REGION_SLOTS)
            ? 16'(current_block.data >> (16*pos[lane])):16'b0;
        rvc_expander expand(.in_i(halfword[lane]),.out_o(expanded[lane]),.legal_o(legal[lane]));
        always_comb begin
            int end_pos;
            logic edge_inst,short_inst;
            end_pos=pos[lane];edge_inst=pos[lane]<0;short_inst=!edge_inst && halfword[lane][1:0]!=2'b11;
            out_o[lane]='0;out_valid_o[lane]=0;
            pos[lane+1]=pos[lane];stopped[lane+1]=stopped[lane];
            pending_seen[lane+1]=pending_seen[lane];
            if(!stopped[lane] && pos[lane]<REGION_SLOTS) begin
                if(!current_block.exc_valid && pos[lane]==REGION_SLOTS-1 && !short_inst) begin
                    // The first half belongs to the next region; no instruction here.
                    stopped[lane+1]=1;pending_seen[lane+1]=1;
                end else begin
                    out_valid_o[lane]=1;
                    out_o[lane].ftq_id=current_block.ftq_id;
                    out_o[lane].slot=edge_inst ? '0:fetch_slot_t'(pos[lane]);
                    out_o[lane].is_edge=edge_inst;
                    out_o[lane].pc=current_block.region_base
                        +vaddr_t'(2*pos[lane]);
                    out_o[lane].is_rvc=short_inst;
                    out_o[lane].inst_len=short_inst ? 3'd2:3'd4;
                    end_pos=edge_inst ? 0:pos[lane]+(short_inst ? 0:1);
                    pos[lane+1]=end_pos+1;
                    if(edge_inst) begin
                        out_o[lane].instruction={current_block.data[15:0],pend_q.halfword};
                        out_o[lane].raw_instruction=out_o[lane].instruction;
                    end else if(short_inst) begin
                        out_o[lane].instruction=expanded[lane];
                        out_o[lane].raw_instruction={16'b0,halfword[lane]};
                        if(!legal[lane]) begin
                            out_o[lane].exc_valid=1;
                            out_o[lane].exc_cause=o3_isa_pkg::EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION;
                            out_o[lane].exc_tval=XLEN'(halfword[lane]);
                        end
                    end else begin
                        out_o[lane].instruction=32'(current_block.data >> (16*pos[lane]));
                        out_o[lane].raw_instruction=out_o[lane].instruction;
                    end
                    if(current_block.exc_valid) begin
                        out_o[lane].instruction='0;out_o[lane].raw_instruction='0;
                        out_o[lane].inst_len='0;out_o[lane].is_rvc=0;
                        out_o[lane].exc_valid=1;out_o[lane].exc_cause=current_block.exc_cause;
                        out_o[lane].exc_tval=edge_inst ? XLEN'(current_block.region_base):XLEN'(out_o[lane].pc);
                    end
                    stopped[lane+1]=out_o[lane].exc_valid || end_pos>=REGION_SLOTS-1
                        || (current_brief.pred.cfi_valid && end_pos>=exit_pos);
                end
            end
        end
    end
    // Can save the final halfword without using a fifth instruction lane.
    assign save_half=active && !current_block.exc_valid
        && (pending_seen[F0_SLOTS] || (!stopped[F0_SLOTS] && pos[F0_SLOTS]==REGION_SLOTS-1
            && current_block.data[(REGION_SLOTS-1)*16 +: 2]==2'b11));
    assign finished=stopped[F0_SLOTS] || pos[F0_SLOTS]>=REGION_SLOTS || save_half;
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
                hold_d.pos=fetch_slot_t'(pos[F0_SLOTS]);
            end
            if(save_half) pend_d='{valid:1'b1,halfword:current_block.data[REGION_BYTES*8-16 +: 16],
                ftq_id:current_block.ftq_id,region_base:current_block.region_base};
            if(current_block.exc_valid) pend_d.valid=0;
        end
        if(hold_d.valid && (fe_killed_by(kill_i,hold_d.block_data.ftq_id,hold_d.pos,ftq_head_i)
            || fe_killed_by(trunc_boundary,hold_d.block_data.ftq_id,hold_d.pos,ftq_head_i))) hold_d.valid=0;
        if(pend_d.valid && (fe_killed_by(kill_i,pend_d.ftq_id,fetch_slot_t'(REGION_SLOTS-1),ftq_head_i)
            || fe_killed_by(trunc_boundary,pend_d.ftq_id,fetch_slot_t'(REGION_SLOTS-1),ftq_head_i))) pend_d.valid=0;
        if(sync_clear_i) begin hold_d='0;pend_d='0;end
    end
    always_ff @(posedge clk_i) begin
        if(rst_i) begin hold_q<='0;pend_q<='0;end
        else begin hold_q<=hold_d;pend_q<=pend_d;end
    end
endmodule
