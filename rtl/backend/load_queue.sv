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
    output logic [CFG.rob.entries-1:0] rob_order_flush_o,
    output logic [o3_cfg_pkg::O3_CFG.core.commit_width-1:0] retire_order_flush_o,
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
    logic [o3_types_pkg::LQ_GEN_W-1:0] gen_q[DEPTH];
    typedef struct packed {logic valid;o3_types_pkg::rob_idx_t rob_idx;branch_mask_t branch_mask;} owner_uop_t;
    typedef struct packed {
        owner_uop_t uop;logic [XLEN-1:0] va;o3_types_pkg::lq_tag_t tag;
        o3_types_pkg::ld_wait_e wait_reason;o3_types_pkg::coh_id_t mshr_id;o3_types_pkg::exc_info_t exc;
    } entry_meta_t;
    entry_meta_t entry_q[DEPTH];
    function automatic entry_meta_t metadata(input lq_replay_t x);
        return '{uop:'{valid:x.uop.valid,rob_idx:x.uop.rob_idx,branch_mask:x.uop.branch_mask},
            va:x.va,tag:x.tag,wait_reason:x.wait_reason,mshr_id:x.mshr_id,exc:x.exc};
    endfunction
    localparam int PAYLOAD_BITS=$bits(lq_replay_t),WRITER_BITS=P>1?$clog2(P):1;
    logic payload_written_q[DEPTH];logic [WRITER_BITS-1:0] payload_writer_q[DEPTH];
    logic [IW-1:0] payload_index[P+1];logic [PAYLOAD_BITS-1:0] bank_payload[P][P+1];
    lq_replay_t payload_read[P+1];
    // Each AGU capture source owns a writer bank. Replay/HEU readers select
    // the last writer for that stationary LQ row. Reset/allocation clear only
    // ownership; the wide RAM is never reset or rewritten by wake/response.
    for(genvar wp=0;wp<P;wp++) begin : g_payload_writer
        for(genvar rp=0;rp<P+1;rp++) begin : g_payload_reader
            (* ram_style="distributed" *) logic [PAYLOAD_BITS-1:0] mem[DEPTH];
            wire [IW-1:0] wi=IW'(capture_i[wp].uop.lq_idx);
            wire live_capture=capture_valid_i[wp] && int'(capture_i[wp].uop.lq_idx)<DEPTH
                && valid_q[wi] && !flush_i
                && !(resolution_valid_i && resolution_mispredict_i && entry_q[wi].uop.branch_mask[resolution_tag_i]);
            always_ff @(posedge clk) if(!rst && live_capture) mem[wi]<=PAYLOAD_BITS'(capture_i[wp]);
            assign bank_payload[wp][rp]=mem[payload_index[rp]];
        end
    end
    for(genvar rp=0;rp<P+1;rp++) begin : g_payload_select
        always_comb begin
            payload_read[rp]='0;
            for(int wp=0;wp<P;wp++)
                if(payload_written_q[payload_index[rp]] && payload_writer_q[payload_index[rp]]==WRITER_BITS'(wp))
                    payload_read[rp] |= lq_replay_t'(bank_payload[wp][rp]);
        end
    end
    function automatic lq_replay_t replay_record(input lq_replay_t payload,input entry_meta_t state);
        lq_replay_t x;
        x=payload;x.uop.valid=state.uop.valid;x.uop.rob_idx=state.uop.rob_idx;x.uop.branch_mask=state.uop.branch_mask;
        x.va=state.va;x.tag=state.tag;x.wait_reason=state.wait_reason;x.mshr_id=state.mshr_id;x.exc=state.exc;
        return x;
    endfunction
    logic [IW-1:0] head_q,tail_q;
    // The next count is rebuilt from at most DEPTH survivors and RENAME_WIDTH
    // allocations, minus a bounded release count. Keep the sign so the original
    // negative/overflow occupancy assertion remains effective.
    localparam int COUNT_BITS = $clog2(DEPTH+RENAME_WIDTH+1)+1;
    logic signed [COUNT_BITS-1:0] count_q;
    int replay_idx[P];int heu_idx;
    localparam int REPLAY_LEAVES = 1 << $clog2(DEPTH);
    typedef struct packed {
        logic valid;
        int unsigned age;
        logic [IW-1:0] index;
    } replay_pick_t;
    function automatic logic order_hit(input o3_types_pkg::paddr_t pa);
        return CFG.lsu.order_flush_enable &&
            ((dma_invalidate_i && o3_types_pkg::coh_addr_t'(pa>>6)==dma_line_i) ||
             (pte_a_write_i && o3_types_pkg::coh_addr_t'(pa>>6)==pte_a_line_i));
    endfunction
    // Compute one predicate per live LQ owner. The production ROB consumes only
    // its consecutive retirement positions, so compare those identities here;
    // avoid materialising a ROB-sized dynamically written map then reading it.
    logic [DEPTH-1:0] order_live,order_required;
    for(genvar n=0;n<DEPTH;n++) begin : g_order_owner
        assign order_live[n]=valid_q[n] &&
            !(resolution_valid_i && resolution_mispredict_i && entry_q[n].uop.branch_mask[resolution_tag_i]);
        assign order_required[n]=order_q[n] ||
            (order_hit(pa_q[n]) && executed_q[n] && !entry_q[n].exc.valid && !head_done_q[n]);
    end
    for(genvar lane=0;lane<o3_cfg_pkg::O3_CFG.core.commit_width;lane++) begin : g_retire_order
        logic [DEPTH-1:0] match_owner;
        o3_types_pkg::rob_idx_t index;
        assign index=o3_types_pkg::rob_idx_t'(int'(rob_head_i)+lane);
        for(genvar n=0;n<DEPTH;n++)
            assign match_owner[n]=order_live[n] && order_required[n] && entry_q[n].uop.rob_idx==index;
        assign retire_order_flush_o[lane]=|match_owner;
    end
    // Retain the diagnostic full map for existing standalone LQ observers.
    // It has no production consumer and is trimmed there.
    for(genvar row=0;row<CFG.rob.entries;row++) begin : g_order_observer
        logic [DEPTH-1:0] match_owner;
        for(genvar n=0;n<DEPTH;n++)
            assign match_owner[n]=order_live[n] && order_required[n]
                && entry_q[n].uop.rob_idx==o3_types_pkg::rob_idx_t'(row);
        assign rob_order_flush_o[row]=|match_owner;
    end
    assign order_flush_o=retire_order_flush_o[0];
    always_comb begin
        int before_lane;
        replay_pick_t tree [P][2*REPLAY_LEAVES];
        before_lane=0;heu_idx=-1;heu_valid_o=0;
        tree='{default:'{default:'0}};
        for(int n=0;n<DEPTH;n++) if(valid_q[n] && entry_q[n].uop.rob_idx==rob_head_i &&
            !(resolution_valid_i && resolution_mispredict_i && entry_q[n].uop.branch_mask[resolution_tag_i])) begin
            if(entry_q[n].wait_reason==o3_types_pkg::LDW_HEAD && !executed_q[n] && entry_q[n].uop.valid) heu_idx=n;
        end
        if(heu_idx>=0) heu_valid_o=1;
        for(int l=0;l<RENAME_WIDTH;l++) begin alloc_idx_o[l]=IW'((int'(tail_q)+before_lane)%DEPTH);before_lane+=int'(alloc_req_i[l]);end
        free_count_o=$clog2(DEPTH+1)'(DEPTH-count_q);tail_o=IW'(tail_q);
        for(int p=0;p<P;p++) begin
            capture_tag_o[p]='{idx:o3_types_pkg::lq_idx_t'(capture_i[p].uop.lq_idx),gen:gen_q[capture_i[p].uop.lq_idx]};
            replay_idx[p]=-1;replay_valid_o[p]=0;
        end
        // Select physical indices by circular age. Wide replay records do
        // not rotate with head or pass through each priority-scan stage.
        for(int p=0;p<P;p++) begin
            for(int n=0;n<DEPTH;n++) begin
                tree[p][REPLAY_LEAVES+n].valid=p<CFG.lsu.mem_pipes && valid_q[n] && ready_q[n]
                    && !(flush_i || (resolution_valid_i && resolution_mispredict_i
                                      && entry_q[n].uop.branch_mask[resolution_tag_i]));
                tree[p][REPLAY_LEAVES+n].age=(n+DEPTH-int'(head_q))%DEPTH;
                tree[p][REPLAY_LEAVES+n].index=IW'(n);
                for(int prior=0;prior<p;prior++)
                    if(tree[prior][1].valid && tree[prior][1].index==IW'(n))
                        tree[p][REPLAY_LEAVES+n].valid=0;
            end
            for(int node=REPLAY_LEAVES-1;node>0;node--)
                tree[p][node]=tree[p][2*node+1].valid
                    && (!tree[p][2*node].valid || tree[p][2*node+1].age<tree[p][2*node].age)
                    ? tree[p][2*node+1]:tree[p][2*node];
            if(tree[p][1].valid) begin
                replay_idx[p]=int'(tree[p][1].index);
                replay_valid_o[p]=1;
            end
        end
    end
    assign payload_index[0]=heu_valid_o ? IW'(heu_idx):'0;
    for(genvar rp=0;rp<P;rp++)
        assign payload_index[rp+1]=replay_valid_o[rp] ? IW'(replay_idx[rp]):'0;
    always_comb begin
        heu_entry_o='0;
        if(heu_valid_o) heu_entry_o=replay_record(payload_read[0],entry_q[heu_idx]);
        for(int rp=0;rp<P;rp++) begin
            replay_o[rp]='0;
            if(replay_valid_o[rp]) begin
                replay_o[rp]=replay_record(payload_read[rp+1],entry_q[replay_idx[rp]]);
                replay_o[rp].tag='{idx:o3_types_pkg::lq_idx_t'(replay_idx[rp]),gen:gen_q[replay_idx[rp]]};
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin head_q<=0;tail_q<=0;count_q<=0;valid_q<='{default:0};ready_q<='{default:0};
            order_q<='{default:0};pa_q<='{default:0};head_done_q<='{default:0};
            executed_q<='{default:0};gen_q<='{default:'0};entry_q<='{default:'0};
            payload_written_q<='{default:0};payload_writer_q<='{default:'0};end
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
                            entry_q[n]<=metadata(capture_i[p]);entry_q[n].tag<=capture_tag_o[p];
                            payload_written_q[n]<=1;payload_writer_q[n]<=WRITER_BITS'(p);
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
                valid_q[(int'(head_q)+l)%DEPTH]<=0;ready_q[(int'(head_q)+l)%DEPTH]<=0;
            end
            if(alloc_fire_i && !flush_i && !(resolution_valid_i && resolution_mispredict_i)) begin
                for(int l=0;l<RENAME_WIDTH;l++) if(alloc_req_i[l]) begin
                    int idx;idx=int'(alloc_idx_o[l]);allocated++;valid_q[idx]<=1;gen_q[idx]<=gen_q[idx]+1'b1;
                    ready_q[idx]<=0;executed_q[idx]<=0;order_q[idx]<=0;head_done_q[idx]<=0;entry_q[idx]<='0;payload_written_q[idx]<=0;
                    entry_q[idx].uop.rob_idx<=alloc_rob_idx_i[l];entry_q[idx].uop.branch_mask<=alloc_branch_mask_i[l];
                end
            end
            head_q<=flush_i ? '0:IW'((int'(head_q)+int'(release_count_i))%DEPTH);
            tail_q<=flush_i ? '0:(resolution_valid_i && resolution_mispredict_i) ? restore_tail_i:IW'((int'(tail_q)+allocated)%DEPTH);
            count_q<=flush_i ? '0:COUNT_BITS'(kept+allocated-int'(release_count_i));
            assert(int'(count_q)>=0 && int'(count_q)<=DEPTH);
        end
    end
endmodule
