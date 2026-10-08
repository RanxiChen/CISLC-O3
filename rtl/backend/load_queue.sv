/** L8a instruction waiters. Generation is incremented on allocation; branch
 * recovery cancels only younger entries. Install never supplies data: it
 * enables an age-selected replay using the saved VA and renamed identity. */
module load_queue import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,localparam int RENAME_WIDTH=BACKEND_MACHINE_WIDTH,
    localparam int DEPTH=CFG.lsu.lq_depth,P=CFG.lsu.agu_pipes,IW=$clog2(DEPTH)
)(input logic clk,rst,flush_i,
    input o3_types_pkg::rob_idx_t rob_head_i,
    input logic dma_invalidate_i,input o3_types_pkg::coh_addr_t dma_line_i,
    input logic pte_a_write_i,input o3_types_pkg::coh_addr_t pte_a_line_i,
    output logic order_flush_o,heu_valid_o,output lq_replay_t heu_entry_o,
    input logic heu_done_i,input o3_types_pkg::rob_idx_t heu_done_idx_i,
    input logic alloc_req_i[RENAME_WIDTH-1:0],input logic alloc_fire_i,
    input logic [ROB_IDX_WIDTH-1:0] alloc_rob_idx_i[RENAME_WIDTH-1:0],
    input branch_mask_t alloc_branch_mask_i[RENAME_WIDTH-1:0],
    output logic [IW-1:0] alloc_idx_o[RENAME_WIDTH-1:0],output logic [$clog2(DEPTH+1)-1:0] free_count_o,
    output logic [IW-1:0] tail_o,
    input logic capture_valid_i[P],input lq_replay_t capture_i[P],
    output o3_types_pkg::lq_tag_t capture_tag_o[P],
    input logic update_valid_i[P],input o3_types_pkg::dcache_resp_t update_i[P],
    input o3_types_pkg::dc_wake_t dc_wake_i,input logic tlb_wake_i,sq_change_i,ad_wake_i,
    output logic replay_valid_o[P],output lq_replay_t replay_o[P],input logic replay_ready_i[P],
    input logic [$clog2(RENAME_WIDTH+1)-1:0] release_count_i,
    input logic resolution_valid_i,resolution_mispredict_i,input branch_tag_t resolution_tag_i,
    input logic [IW-1:0] restore_tail_i);
    logic order_q[DEPTH];o3_types_pkg::paddr_t pa_q[DEPTH];
    logic head_done_q[DEPTH];
    logic valid_q[DEPTH],ready_q[DEPTH],executed_q[DEPTH];
    logic [o3_types_pkg::LQ_GEN_W-1:0] gen_q[DEPTH];lq_replay_t entry_q[DEPTH];
    int head_q,tail_q,count_q;int replay_idx[P];
    function automatic logic order_hit(input o3_types_pkg::paddr_t pa);
        return CFG.lsu.order_flush_enable &&
            ((dma_invalidate_i && o3_types_pkg::coh_addr_t'(pa>>6)==dma_line_i) ||
             (pte_a_write_i && o3_types_pkg::coh_addr_t'(pa>>6)==pte_a_line_i));
    endfunction
    always_comb begin
        int before_lane;before_lane=0;order_flush_o=0;heu_valid_o=0;heu_entry_o='0;
        for(int n=0;n<DEPTH;n++) if(valid_q[n] && entry_q[n].uop.rob_idx==rob_head_i &&
            !(resolution_valid_i && resolution_mispredict_i && entry_q[n].uop.branch_mask[resolution_tag_i])) begin
            order_flush_o=order_q[n] || (order_hit(pa_q[n]) && executed_q[n] && !entry_q[n].exc.valid && !head_done_q[n]);
            if(entry_q[n].wait_reason==o3_types_pkg::LDW_HEAD && !executed_q[n] && entry_q[n].uop.valid) begin heu_valid_o=1;heu_entry_o=entry_q[n];end
        end
        for(int l=0;l<RENAME_WIDTH;l++) begin alloc_idx_o[l]=IW'((tail_q+before_lane)%DEPTH);before_lane+=int'(alloc_req_i[l]);end
        free_count_o=$clog2(DEPTH+1)'(DEPTH-count_q);tail_o=IW'(tail_q);
        for(int p=0;p<P;p++) begin
            capture_tag_o[p]='{idx:o3_types_pkg::lq_idx_t'(capture_i[p].uop.lq_idx),gen:gen_q[capture_i[p].uop.lq_idx]};
            replay_idx[p]=-1;replay_valid_o[p]=0;replay_o[p]='0;
        end
        for(int d=0;d<DEPTH;d++) begin
            int idx,slot;logic selected;idx=(head_q+d)%DEPTH;slot=-1;selected=0;
            for(int p=0;p<P;p++) begin
                selected|=replay_idx[p]==idx;
                if(p<CFG.lsu.mem_pipes && slot<0 && replay_idx[p]<0) slot=p;
            end
            if(slot>=0 && valid_q[idx] && ready_q[idx] && !selected &&
                !(flush_i || (resolution_valid_i && resolution_mispredict_i && entry_q[idx].uop.branch_mask[resolution_tag_i]))) begin
                replay_idx[slot]=idx;replay_valid_o[slot]=1;replay_o[slot]=entry_q[idx];
                replay_o[slot].tag='{idx:o3_types_pkg::lq_idx_t'(idx),gen:gen_q[idx]};
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin head_q<=0;tail_q<=0;count_q<=0;valid_q<='{default:0};ready_q<='{default:0};
            order_q<='{default:0};pa_q<='{default:0};head_done_q<='{default:0};
            executed_q<='{default:0};gen_q<='{default:'0};entry_q<='{default:'0};end
        else begin
            int kept,allocated;kept=0;allocated=0;
            for(int n=0;n<DEPTH;n++) begin
                logic dead;dead=flush_i || (resolution_valid_i && resolution_mispredict_i && entry_q[n].uop.branch_mask[resolution_tag_i]);
                if(valid_q[n] && dead) begin valid_q[n]<=0;ready_q[n]<=0;executed_q[n]<=0;end
                else if(valid_q[n]) begin
                    kept++;
                    if(order_hit(pa_q[n]) && executed_q[n] && !entry_q[n].exc.valid && !head_done_q[n]) order_q[n]<=1;
                    if(heu_done_i && entry_q[n].uop.rob_idx==heu_done_idx_i) begin executed_q[n]<=1;head_done_q[n]<=1;end
                    if(resolution_valid_i) entry_q[n].uop.branch_mask[resolution_tag_i]<=0;
                    case(entry_q[n].wait_reason)
                        o3_types_pkg::LDW_MSHR:if(dc_wake_i.valid && dc_wake_i.mshr_id==entry_q[n].mshr_id) begin
                            ready_q[n]<=1;
                            if(dc_wake_i.err) entry_q[n].exc<='{valid:1'b1,cause:o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ACCESS_FAULT,tval:entry_q[n].va};
                        end
                        o3_types_pkg::LDW_MSHR_FULL:if(dc_wake_i.mshr_free) ready_q[n]<=1;
                        o3_types_pkg::LDW_WB_LINE:if(dc_wake_i.wb_free) ready_q[n]<=1;
                        o3_types_pkg::LDW_TLB_MISS:if(tlb_wake_i) ready_q[n]<=1;
                        o3_types_pkg::LDW_OLDER_STORE_ADDR,o3_types_pkg::LDW_OLDER_STORE_DATA:if(sq_change_i) ready_q[n]<=1;
                        o3_types_pkg::LDW_AD_ORDER:if(ad_wake_i) ready_q[n]<=1;
                        default:;
                    endcase
                    for(int p=0;p<P;p++) begin
                        if(replay_valid_o[p] && replay_ready_i[p] && replay_idx[p]==n) begin ready_q[n]<=0;entry_q[n].wait_reason<=o3_types_pkg::LDW_NONE;end
                        if(capture_valid_i[p] && int'(capture_i[p].uop.lq_idx)==n) begin
                            entry_q[n]<=capture_i[p];entry_q[n].tag<=capture_tag_o[p];
                            entry_q[n].uop.branch_mask<=br_resolved_mask(capture_i[p].uop.branch_mask,
                                '{valid:resolution_valid_i,mispredict:resolution_mispredict_i,branch_tag:resolution_tag_i,default:'0});
                            ready_q[n]<=0;
                        end
                        if(update_valid_i[p] && update_i[p].lq_tag.idx==n && update_i[p].lq_tag.gen==gen_q[n]) begin
                            entry_q[n].wait_reason<=update_i[p].reason;entry_q[n].mshr_id<=update_i[p].mshr_id;
                            entry_q[n].exc<=update_i[p].exc;pa_q[n]<=update_i[p].paddr;
                            if(order_hit(update_i[p].paddr) && update_i[p].status==o3_types_pkg::DC_OK && !update_i[p].exc.valid && !head_done_q[n] && !(heu_done_i && entry_q[n].uop.rob_idx==heu_done_idx_i)) order_q[n]<=1;
                            executed_q[n]<=update_i[p].status==o3_types_pkg::DC_OK || update_i[p].status==o3_types_pkg::DC_ERROR;
                            ready_q[n]<=update_i[p].status==o3_types_pkg::DC_REPLAY &&
                                update_i[p].reason inside {o3_types_pkg::LDW_CONFLICT,o3_types_pkg::LDW_SNAP,o3_types_pkg::LDW_BANK};
                            // Do not miss an install/resource wake on the wait-write edge.
                            if(update_i[p].status==o3_types_pkg::DC_MISS_WAIT && dc_wake_i.valid && dc_wake_i.mshr_id==update_i[p].mshr_id) begin
                                ready_q[n]<=1;
                                if(dc_wake_i.err) entry_q[n].exc<='{valid:1'b1,cause:o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ACCESS_FAULT,tval:entry_q[n].va};
                            end
                            if(update_i[p].reason==o3_types_pkg::LDW_MSHR_FULL && dc_wake_i.mshr_free) ready_q[n]<=1;
                            if(update_i[p].reason==o3_types_pkg::LDW_WB_LINE && dc_wake_i.wb_free) ready_q[n]<=1;
                            if(update_i[p].reason==o3_types_pkg::LDW_TLB_MISS && tlb_wake_i) ready_q[n]<=1;
                            if(update_i[p].reason inside {o3_types_pkg::LDW_OLDER_STORE_ADDR,o3_types_pkg::LDW_OLDER_STORE_DATA} && sq_change_i) ready_q[n]<=1;
                            if(update_i[p].reason==o3_types_pkg::LDW_AD_ORDER && ad_wake_i) ready_q[n]<=1;
                        end
                    end
                end
            end
            for(int l=0;l<RENAME_WIDTH;l++) if(l<int'(release_count_i)) begin
                valid_q[(head_q+l)%DEPTH]<=0;ready_q[(head_q+l)%DEPTH]<=0;
            end
            if(alloc_fire_i && !flush_i && !(resolution_valid_i && resolution_mispredict_i)) begin
                for(int l=0;l<RENAME_WIDTH;l++) if(alloc_req_i[l]) begin
                    int idx;idx=int'(alloc_idx_o[l]);allocated++;valid_q[idx]<=1;gen_q[idx]<=gen_q[idx]+1'b1;
                    ready_q[idx]<=0;executed_q[idx]<=0;order_q[idx]<=0;head_done_q[idx]<=0;entry_q[idx]<='0;
                    entry_q[idx].uop.rob_idx<=alloc_rob_idx_i[l];entry_q[idx].uop.branch_mask<=alloc_branch_mask_i[l];
                end
            end
            head_q<=flush_i ? 0:(head_q+int'(release_count_i))%DEPTH;
            tail_q<=flush_i ? 0:(resolution_valid_i && resolution_mispredict_i) ? int'(restore_tail_i):(tail_q+allocated)%DEPTH;
            count_q<=flush_i ? 0:kept+allocated-int'(release_count_i);
            assert(count_q>=0 && count_q<=DEPTH);
        end
    end
endmodule
