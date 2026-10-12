/** L8a SQ: two STA writes and two forwarding queries. Committed stores
 * retain their entry until PS st_done. Retry records the cache wait reason;
 * install/free and translation/A-D events enable reissue. Branch recovery
 * preserves the committed prefix and cancels younger speculative entries. */
module store_queue
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    // Legacy direct-drain test interface; the core enables the cache handshake.
    parameter bit DCACHE_DRAIN = 1'b0,
    localparam int RENAME_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    localparam int DEPTH = CFG.lsu.sq_depth,
    localparam int P=CFG.lsu.agu_pipes,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries
) (
    input logic clk,
    input logic rst,
    input logic alloc_req_i [RENAME_WIDTH-1:0],
    input logic alloc_fire_i,
    input o3_types_pkg::sq_kind_e alloc_kind_i[RENAME_WIDTH],execute_kind_i[P],
    input logic heu_done_i,input o3_types_pkg::rob_idx_t heu_done_idx_i,
    output logic heu_valid_o,output lq_replay_t heu_entry_o,output o3_types_pkg::sq_kind_e heu_kind_o,
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_rob_idx_i [RENAME_WIDTH-1:0],
    input branch_mask_t alloc_branch_mask_i [RENAME_WIDTH-1:0],
    output logic [$clog2(DEPTH)-1:0] alloc_idx_o [RENAME_WIDTH-1:0],
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,
    output logic [$clog2(DEPTH)-1:0] tail_o,

    input logic execute_valid_i [P],
    input logic [$clog2(DEPTH)-1:0] execute_idx_i [P],
    input logic [XLEN-1:0] execute_addr_i [P],
    input logic [XLEN-1:0] execute_data_i [P],
    input logic [7:0] execute_mask_i [P],

    input logic commit_valid_i [COMMIT_WIDTH-1:0],
    input logic [$clog2(DEPTH)-1:0] commit_idx_i [COMMIT_WIDTH-1:0],

    input logic query_valid_i [P],
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] query_rob_idx_i [P],
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_head_i,
    input logic [XLEN-1:0] query_addr_i [P],
    input logic [7:0] query_mask_i [P],
    output logic query_block_o [P],
    output logic query_forward_valid_o [P],
    output logic [XLEN-1:0] query_forward_data_o [P],

    output logic drain_valid_o,
    input logic drain_ready_i,
    output logic [XLEN-1:0] drain_addr_o,
    output logic [XLEN-1:0] drain_data_o,
    output logic [7:0] drain_mask_o,

    input logic flush_all_i,
    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,
    input logic [$clog2(DEPTH)-1:0] restore_tail_i
,

    // ---------------- 目标合同（框架新增，未接入逻辑） ----------------
    // drain 到 DCache：请求接受与写完成分开（B05）
    output logic                       t_dc_req_valid_o,
    input  logic                       t_dc_req_ready_i,
    output o3_types_pkg::dcache_req_t  t_dc_req_o,
    input  o3_types_pkg::dcache_resp_t t_dc_resp_i,
    input o3_types_pkg::dc_wake_t dc_wake_i,
    input logic capture_valid_i[P],input lq_replay_t capture_i[P],
    input logic update_valid_i[P],input o3_types_pkg::dcache_resp_t update_i[P],
    input logic tlb_wake_i,ad_wake_i,
    output logic replay_valid_o[P],output lq_replay_t replay_o[P],input logic replay_ready_i[P],
    // FENCE / AMO / FENCE.I / DMA 交接：已提交 store 是否全部 drain
    output logic                       t_committed_empty_o
);
    localparam int IDX_WIDTH = $clog2(DEPTH);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int ROB_IDX_WIDTH_LOCAL = $clog2(NUM_ROB_ENTRIES);
    logic [IDX_WIDTH-1:0] head_q, tail_q;
    logic [COUNT_WIDTH-1:0] count_q;
    logic valid_q [DEPTH-1:0];
    logic addr_valid_q [DEPTH-1:0];
    logic data_valid_q [DEPTH-1:0];
    logic committed_q [DEPTH-1:0];
    logic [XLEN-1:0] addr_q [DEPTH-1:0];
    logic [XLEN-1:0] data_q [DEPTH-1:0];
    logic [7:0] mask_q [DEPTH-1:0];
    logic [ROB_IDX_WIDTH_LOCAL-1:0] rob_idx_q [DEPTH-1:0];
    branch_mask_t branch_mask_q [DEPTH-1:0];
    o3_types_pkg::sq_kind_e kind_q[DEPTH];logic heu_complete_q[DEPTH];
    logic heu_release;int heu_selected;
    always_comb begin
        heu_selected = -1;
        heu_valid_o=0;heu_kind_o=o3_types_pkg::SQ_NORMAL;heu_release=0;
        for(int n=0;n<DEPTH;n++) if(valid_q[n] && rob_idx_q[n]==rob_head_i &&
            kind_q[n]!=o3_types_pkg::SQ_NORMAL && sta_q[n].uop.valid && !heu_complete_q[n])
            heu_selected = n;
        if (heu_selected >= 0) begin
            heu_valid_o=1;heu_kind_o=kind_q[heu_selected];
        end
        for(int p=0;p<COMMIT_WIDTH;p++) heu_release|=commit_valid_i[p] && commit_idx_i[p]==head_q && kind_q[head_q]!=o3_types_pkg::SQ_NORMAL;
    end
    always_ff @(posedge clk) begin
        if(rst) begin kind_q<='{default:o3_types_pkg::SQ_NORMAL};heu_complete_q<='{default:0};end
        else begin
            if(alloc_fire_i) for(int l=0;l<RENAME_WIDTH;l++) if(alloc_req_i[l]) begin
                kind_q[alloc_idx_o[l]]<=alloc_kind_i[l];heu_complete_q[alloc_idx_o[l]]<=0;
            end
            for(int p=0;p<P;p++) if(execute_valid_i[p]) kind_q[execute_idx_i[p]]<=execute_kind_i[p];
            if(heu_done_i) for(int n=0;n<DEPTH;n++) if(valid_q[n] && rob_idx_q[n]==heu_done_idx_i) heu_complete_q[n]<=1;
        end
    end
    logic dc_inflight_q;
    logic dc_wait_q;
    o3_types_pkg::ld_wait_e dc_reason_q;
    o3_types_pkg::coh_id_t dc_mshr_q;
    logic dc_drain_fire;
    logic dc_resp_match;
    assign dc_resp_match=dc_inflight_q && t_dc_resp_i.valid &&
        t_dc_resp_i.src==o3_types_pkg::DC_SRC_STORE_DRAIN &&
        t_dc_resp_i.sq_idx==o3_types_pkg::sq_idx_t'(head_q);
    logic head_dtcm;
    logic head_ready;

    typedef struct packed {logic valid;} sta_uop_t;
    typedef struct packed {sta_uop_t uop;o3_types_pkg::ld_wait_e wait_reason;} sta_metadata_t;
    sta_metadata_t sta_q[DEPTH];logic sta_ready_q[DEPTH],sta_wait_q[DEPTH];
    localparam int PAYLOAD_BITS=$bits(lq_replay_t),WRITER_BITS=P>1?$clog2(P):1;
    logic payload_written_q[DEPTH];logic [WRITER_BITS-1:0] payload_writer_q[DEPTH];
    logic [IDX_WIDTH-1:0] payload_index[P+1];logic [PAYLOAD_BITS-1:0] bank_payload[P][P+1];
    lq_replay_t payload_read[P+1];
    // Capture payload is immutable; retries only update narrow wait metadata.
    // Each capture lane has a writer bank and independent HEU/replay replicas.
    for(genvar wp=0;wp<P;wp++) begin : g_sta_writer
        for(genvar rp=0;rp<P+1;rp++) begin : g_sta_reader
            (* ram_style="distributed" *) logic [PAYLOAD_BITS-1:0] mem[DEPTH];
            wire [IDX_WIDTH-1:0] wi=IDX_WIDTH'(capture_i[wp].uop.sq_idx);
            wire accept=capture_valid_i[wp] && int'(capture_i[wp].uop.sq_idx)<DEPTH && !flush_all_i
                && !(resolution_valid_i && resolution_mispredict_i && branch_mask_q[wi][resolution_tag_i]);
            always_ff @(posedge clk) if(!rst && accept) mem[wi]<=PAYLOAD_BITS'(capture_i[wp]);
            assign bank_payload[wp][rp]=mem[payload_index[rp]];
        end
    end
    for(genvar rp=0;rp<P+1;rp++) begin : g_sta_select
        always_comb begin
            payload_read[rp]='0;
            for(int wp=0;wp<P;wp++)
                if(payload_written_q[payload_index[rp]] && payload_writer_q[payload_index[rp]]==WRITER_BITS'(wp))
                    payload_read[rp] |= lq_replay_t'(bank_payload[wp][rp]);
        end
    end
    function automatic lq_replay_t sta_record(input lq_replay_t payload,input sta_metadata_t state);
        lq_replay_t x;
        x=payload;x.uop.valid=state.uop.valid;x.wait_reason=state.wait_reason;
        return x;
    endfunction
    initial assert(P<=2) else $fatal(1,"SQ replay tree supports at most two memory pipes");
    localparam int REPLAY_LEAVES=1 << $clog2(DEPTH);
    typedef struct packed {
        logic valid;
        logic [IDX_WIDTH-1:0] age,idx;
    } replay_choice_t;
    typedef struct packed {replay_choice_t first,second;} replay_pair_t;
    replay_pair_t replay_tree[2*REPLAY_LEAVES];
    logic [IDX_WIDTH-1:0] replay_idx[P];
    function automatic replay_choice_t older_replay(input replay_choice_t a,b);
        return b.valid && (!a.valid || b.age<a.age) ? b:a;
    endfunction
    function automatic replay_pair_t merge_replay(input replay_pair_t a,b);
        replay_pair_t result;
        logic right_first;
        right_first=b.first.valid && (!a.first.valid || b.first.age<a.first.age);
        result.first=right_first ? b.first:a.first;
        result.second=right_first ? older_replay(a.first,b.second):older_replay(a.second,b.first);
        return result;
    endfunction
    // Compare physical owners in parallel. Only narrow age/index pairs enter
    // a balanced oldest-two tree; no rotating wide payload or serial age scan.
    for(genvar row=0;row<REPLAY_LEAVES;row++) begin : g_replay_leaf
        if(row<DEPTH) begin
            assign replay_tree[REPLAY_LEAVES+row].first='{
                valid:valid_q[row] && sta_ready_q[row] && !committed_q[row] &&
                    !(resolution_valid_i && resolution_mispredict_i && branch_mask_q[row][resolution_tag_i]),
                age:IDX_WIDTH'((row+DEPTH-int'(head_q))%DEPTH),idx:IDX_WIDTH'(row)};
            assign replay_tree[REPLAY_LEAVES+row].second='0;
        end else assign replay_tree[REPLAY_LEAVES+row]='0;
    end
    for(genvar node=1;node<REPLAY_LEAVES;node++) begin : g_replay_merge
        assign replay_tree[node]=merge_replay(replay_tree[2*node],replay_tree[2*node+1]);
    end
    always_comb begin
        replay_valid_o='{default:0};replay_idx='{default:'0};
        for(int p=0;p<P;p++) begin
            replay_choice_t chosen;
            chosen=p==0 ? replay_tree[1].first:replay_tree[1].second;
            replay_idx[p]=chosen.idx;
            replay_valid_o[p]=p<CFG.lsu.mem_pipes && chosen.valid && !flush_all_i;
        end
    end
    assign payload_index[0]=heu_valid_o ? IDX_WIDTH'(heu_selected):'0;
    for(genvar rp=0;rp<P;rp++) assign payload_index[rp+1]=replay_valid_o[rp] ? replay_idx[rp]:'0;
    always_comb begin
        heu_entry_o='0;
        if(heu_valid_o) heu_entry_o=sta_record(payload_read[0],sta_q[heu_selected]);
        for(int rp=0;rp<P;rp++) begin
            replay_o[rp]='0;
            if(replay_valid_o[rp]) begin
                replay_o[rp]=sta_record(payload_read[rp+1],sta_q[replay_idx[rp]]);
                replay_o[rp].uop.branch_mask=branch_mask_q[replay_idx[rp]];
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            payload_written_q<='{default:0};payload_writer_q<='{default:'0};
            sta_q<='{default:'0};sta_ready_q<='{default:0};sta_wait_q<='{default:0};
            dc_wait_q<=0;dc_reason_q<=o3_types_pkg::LDW_NONE;dc_mshr_q<=0;
        end else begin
            if(dc_resp_match && t_dc_resp_i.status!=o3_types_pkg::DC_OK) begin
                dc_wait_q<=1;dc_reason_q<=t_dc_resp_i.reason;dc_mshr_q<=t_dc_resp_i.mshr_id;
                assert(t_dc_resp_i.status!=o3_types_pkg::DC_ERROR) else $fatal(1,"committed drain access fault");
            end
            if(dc_wait_q) case(dc_reason_q)
                o3_types_pkg::LDW_MSHR:if(dc_wake_i.valid && dc_wake_i.mshr_id==dc_mshr_q) begin
                    assert(!dc_wake_i.err) else $fatal(1,"committed store GetM failed");dc_wait_q<=0;
                end
                o3_types_pkg::LDW_MSHR_FULL:if(dc_wake_i.mshr_free) dc_wait_q<=0;
                o3_types_pkg::LDW_WB_LINE:if(dc_wake_i.wb_free) dc_wait_q<=0;
                default:dc_wait_q<=0;
            endcase
            for(int n=0;n<DEPTH;n++) begin
                if(flush_all_i || (resolution_valid_i && resolution_mispredict_i && branch_mask_q[n][resolution_tag_i])) begin
                    sta_ready_q[n]<=0;sta_wait_q[n]<=0;
                end else begin
                    if(sta_wait_q[n] && kind_q[n]==o3_types_pkg::SQ_NORMAL) case(sta_q[n].wait_reason)
                        o3_types_pkg::LDW_TLB_MISS:if(tlb_wake_i) sta_ready_q[n]<=1;
                        o3_types_pkg::LDW_AD_ORDER:if(ad_wake_i) sta_ready_q[n]<=1;
                        default:sta_ready_q[n]<=1;
                    endcase
                    for(int p=0;p<P;p++) begin
                        if(replay_valid_o[p] && replay_ready_i[p] && replay_idx[p]==n) begin sta_ready_q[n]<=0;sta_wait_q[n]<=0;end
                        if(capture_valid_i[p] && capture_i[p].uop.sq_idx==n) begin
                            sta_q[n]<='{uop:'{valid:capture_i[p].uop.valid},wait_reason:capture_i[p].wait_reason};
                            payload_written_q[n]<=1;payload_writer_q[n]<=WRITER_BITS'(p);
                        end
                        if(update_valid_i[p] && update_i[p].sq_idx==n) begin
                            sta_q[n].wait_reason<=update_i[p].reason;
                            sta_wait_q[n]<=update_i[p].status==o3_types_pkg::DC_REPLAY && update_i[p].reason!=o3_types_pkg::LDW_HEAD;
                            sta_ready_q[n]<=update_i[p].status==o3_types_pkg::DC_REPLAY && update_i[p].reason!=o3_types_pkg::LDW_HEAD &&
                                !(update_i[p].reason inside {o3_types_pkg::LDW_TLB_MISS,o3_types_pkg::LDW_AD_ORDER});
                            if(update_i[p].reason==o3_types_pkg::LDW_TLB_MISS && tlb_wake_i) sta_ready_q[n]<=1;
                            if(update_i[p].reason==o3_types_pkg::LDW_AD_ORDER && ad_wake_i) sta_ready_q[n]<=1;
                        end
                    end
                end
            end
            // A resource wake on the st_retry edge is not lost.
            if(dc_resp_match && t_dc_resp_i.status!=o3_types_pkg::DC_OK) begin
                if(t_dc_resp_i.reason==o3_types_pkg::LDW_MSHR && dc_wake_i.valid && dc_wake_i.mshr_id==t_dc_resp_i.mshr_id) dc_wait_q<=0;
                if(t_dc_resp_i.reason==o3_types_pkg::LDW_MSHR_FULL && dc_wake_i.mshr_free) dc_wait_q<=0;
                if(t_dc_resp_i.reason==o3_types_pkg::LDW_WB_LINE && dc_wake_i.wb_free) dc_wait_q<=0;
            end
            if (alloc_fire_i) for (int n = 0; n < DEPTH; n++)
                for (int l = 0; l < RENAME_WIDTH; l++) if (alloc_req_i[l] && alloc_idx_o[l] == IDX_WIDTH'(n)) begin
                    sta_q[n] <= '0; payload_written_q[n]<=0; sta_ready_q[n] <= 0; sta_wait_q[n] <= 0;
                end
        end
    end

    function automatic logic [IDX_WIDTH-1:0] add_idx(
        input logic [IDX_WIDTH-1:0] base, input int unsigned offset
    );
        add_idx = IDX_WIDTH'((int'(base) + offset) % DEPTH);
    endfunction

    function automatic int unsigned rob_distance(
        input logic [ROB_IDX_WIDTH_LOCAL-1:0] idx,
        input logic [ROB_IDX_WIDTH_LOCAL-1:0] head
    );
        rob_distance = (int'(idx) + NUM_ROB_ENTRIES - int'(head)) % NUM_ROB_ENTRIES;
    endfunction

    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q;
    assign tail_o = tail_q;
    assign head_ready = valid_q[head_q] && committed_q[head_q]
                     && addr_valid_q[head_q] && data_valid_q[head_q];
    assign head_dtcm = 1'b0;
    assign drain_valid_o = head_ready && (!DCACHE_DRAIN || head_dtcm);
    assign drain_addr_o = addr_q[head_q];
    assign drain_data_o = data_q[head_q];
    assign drain_mask_o = mask_q[head_q];
    assign t_dc_req_valid_o = DCACHE_DRAIN && head_ready && !head_dtcm
                           && !dc_inflight_q && !dc_wait_q;
    always_comb begin
        t_dc_req_o = '0;
        t_dc_req_o.src = o3_types_pkg::DC_SRC_STORE_DRAIN;
        t_dc_req_o.paddr = o3_types_pkg::paddr_t'(addr_q[head_q]);
        t_dc_req_o.vaddr=addr_q[head_q];
        t_dc_req_o.size = (mask_q[head_q] == 8'hff) ? 2'd3
                        : (mask_q[head_q][3:0] == 4'hf) ? 2'd2
                        : (mask_q[head_q][1:0] == 2'b11) ? 2'd1 : 2'd0;
        t_dc_req_o.write = 1'b1;
        t_dc_req_o.wdata = data_q[head_q];
        t_dc_req_o.wmask = mask_q[head_q];
        t_dc_req_o.sq_idx = o3_types_pkg::sq_idx_t'(head_q);
    end
    assign dc_drain_fire = DCACHE_DRAIN && dc_inflight_q
                         && t_dc_resp_i.valid
                         && t_dc_resp_i.src == o3_types_pkg::DC_SRC_STORE_DRAIN
                         && t_dc_resp_i.sq_idx == o3_types_pkg::sq_idx_t'(head_q)
                         && t_dc_resp_i.status == o3_types_pkg::DC_OK;
    always_comb begin
        t_committed_empty_o = 1'b1;
        for (int entry = 0; entry < DEPTH; entry++)
            if (valid_q[entry] && committed_q[entry]) t_committed_empty_o = 1'b0;
    end

    always_comb begin
        for (int lane = 0; lane < RENAME_WIDTH; lane++) begin
            int unsigned req_before_lane;
            req_before_lane = 0;
            for (int older = 0; older < lane; older++) begin
                if (alloc_req_i[older]) req_before_lane++;
            end
            alloc_idx_o[lane] = add_idx(tail_q, req_before_lane);
        end
    end

    // Carry forwarding readiness with the overlap winner; do not re-index
    // all entry predicates after age selection. No extra query cycle.
    // Compare each physical entry once; only narrow age/index records enter
    // the selection tree. Rotating every wide address/data row by head_q
    // before comparing creates a DEPTH-by-DEPTH crossbar.
    localparam int QUERY_LEAVES = 1 << $clog2(DEPTH);
    typedef struct packed {
        logic valid;
        logic [IDX_WIDTH-1:0] age, idx;
        logic ready;
    } query_choice_t;
    function automatic query_choice_t younger_choice(input query_choice_t a, b);
        return b.valid && (!a.valid || b.age > a.age) ? b : a;
    endfunction

    for (genvar p = 0; p < P; p++) begin : g_query
        logic [DEPTH-1:0] unknown_addr, overlaps, full_ready, nonnegative;
        logic [2:0] byte_offset [DEPTH];
        query_choice_t overlap_tree [2*QUERY_LEAVES];
        query_choice_t full_tree [2*QUERY_LEAVES];
        assign overlap_tree[0] = '0;
        assign full_tree[0] = '0;
        for (genvar idx = 0; idx < DEPTH; idx++) begin : g_compare
            logic active, address_known;
            logic [XLEN-1:0] byte_delta;
            logic [7:0] covered_bytes;
            logic [IDX_WIDTH-1:0] age;
            assign age = IDX_WIDTH'((idx + DEPTH - int'(head_q)) % DEPTH);
            assign active = query_valid_i[p] && valid_q[idx]
                && (committed_q[idx] || rob_distance(rob_idx_q[idx], rob_head_i)
                    < rob_distance(query_rob_idx_i[p], rob_head_i))
                && kind_q[idx] != o3_types_pkg::SQ_MMIO && !heu_complete_q[idx];
            assign address_known = addr_valid_q[idx]
                && !(kind_q[idx] inside {o3_types_pkg::SQ_ATOMIC, o3_types_pkg::SQ_SPLIT});
            assign byte_delta = query_addr_i[p] - addr_q[idx];
            assign nonnegative[idx] = byte_delta[XLEN-1:3] == '0;
            assign byte_offset[idx] = byte_delta[2:0];
            always_comb begin
                covered_bytes = '0;
                if (nonnegative[idx]) covered_bytes = mask_q[idx] >> byte_delta[2:0];
                else if (byte_delta[XLEN-1:3] == '1 && byte_delta[2:0] != '0)
                    covered_bytes = mask_q[idx] << (3'(-byte_delta[2:0]));
            end
            assign unknown_addr[idx] = active && !address_known;
            assign overlaps[idx] = active && address_known && |(covered_bytes & query_mask_i[p]);
            assign full_ready[idx] = overlaps[idx] && data_valid_q[idx]
                && (covered_bytes & query_mask_i[p]) == query_mask_i[p];
            assign overlap_tree[QUERY_LEAVES+idx] =
                '{valid:overlaps[idx], age:age, idx:IDX_WIDTH'(idx),ready:full_ready[idx]};
            assign full_tree[QUERY_LEAVES+idx] =
                '{valid:full_ready[idx], age:age, idx:IDX_WIDTH'(idx),ready:1'b0};
        end
        for (genvar pad = DEPTH; pad < QUERY_LEAVES; pad++) begin : g_pad
            assign overlap_tree[QUERY_LEAVES+pad] = '0;
            assign full_tree[QUERY_LEAVES+pad] = '0;
        end
        for (genvar node = 1; node < QUERY_LEAVES; node++) begin : g_select
            assign overlap_tree[node] = younger_choice(overlap_tree[2*node], overlap_tree[2*node+1]);
            assign full_tree[node] = younger_choice(full_tree[2*node], full_tree[2*node+1]);
        end
        always_comb begin
            query_block_o[p] = |unknown_addr
                || (overlap_tree[1].valid && !overlap_tree[1].ready);
            query_forward_valid_o[p] = full_tree[1].valid && !query_block_o[p];
            // Preserve data even when a younger partial/unknown store blocks
            // the load: the old scan retained the youngest full-cover value.
            query_forward_data_o[p] = '0;
            if (full_tree[1].valid && nonnegative[full_tree[1].idx])
                query_forward_data_o[p] = data_q[full_tree[1].idx]
                    >> {byte_offset[full_tree[1].idx], 3'b000};
        end
`ifndef SYNTHESIS
        always_ff @(posedge clk) if(!rst && overlap_tree[1].valid)
            assert (overlap_tree[1].ready==full_ready[overlap_tree[1].idx]);
`endif
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
            valid_q <= '{default: 1'b0};
            addr_valid_q <= '{default: 1'b0};
            data_valid_q <= '{default: 1'b0};
            committed_q <= '{default: 1'b0};
            addr_q <= '{default: '0};
            data_q <= '{default: '0};
            mask_q <= '{default: '0};
            rob_idx_q <= '{default: '0};
            branch_mask_q <= '{default: '0};
            dc_inflight_q <= 1'b0;
        end else if (flush_all_i) begin
            int unsigned kept;
            logic drain_fire;
            kept=0; drain_fire=dc_drain_fire || (drain_valid_o && drain_ready_i) || heu_release;
            if (DCACHE_DRAIN && t_dc_req_valid_o && t_dc_req_ready_i) dc_inflight_q<=1;
            if (dc_resp_match) dc_inflight_q<=0;
            for (int entry=0;entry<DEPTH;entry++) begin
                if (valid_q[entry] && committed_q[entry]) kept++;
                else begin valid_q[entry]<=0; addr_valid_q[entry]<=0; data_valid_q[entry]<=0; end
                branch_mask_q[entry]<='0;
            end
            tail_q<=add_idx(head_q,kept);
            if (drain_fire) begin
                valid_q[head_q]<=0; committed_q[head_q]<=0;
                head_q<=add_idx(head_q,1);
            end
            count_q<=COUNT_WIDTH'(kept)-COUNT_WIDTH'(drain_fire);
        end else if (resolution_valid_i && resolution_mispredict_i) begin
            int unsigned kept;
            logic drain_fire;
            kept = 0;
            drain_fire = dc_drain_fire || (drain_valid_o && drain_ready_i) || heu_release;
            if (DCACHE_DRAIN && t_dc_req_valid_o && t_dc_req_ready_i)
                dc_inflight_q <= 1'b1;
            if (dc_resp_match) dc_inflight_q <= 1'b0;
            for (int entry = 0; entry < DEPTH; entry++) begin
                if (valid_q[entry] && !committed_q[entry]
                 && branch_mask_q[entry][resolution_tag_i]) begin
                    valid_q[entry] <= 1'b0;
                    addr_valid_q[entry] <= 1'b0;
                    data_valid_q[entry] <= 1'b0;
                end else if (valid_q[entry]) begin
                    kept++;
                    branch_mask_q[entry][resolution_tag_i] <= 1'b0;
                end
            end

            // 恢复优先级只负责删除错误路径，不能吞掉同拍已经握手的老Store事件。
            // 否则ROB会看到Store complete，而SQ对应entry仍没有地址/数据，队头
            // 将永久无法drain。老Store不携带本次解析tag，因此可在恢复拍继续写入。
            for(int p=0;p<P;p++) begin
            if (execute_valid_i[p] && valid_q[execute_idx_i[p]]
             && !branch_mask_q[execute_idx_i[p]][resolution_tag_i]) begin
                addr_q[execute_idx_i[p]] <= execute_addr_i[p];
                data_q[execute_idx_i[p]] <= execute_data_i[p];
                mask_q[execute_idx_i[p]] <= execute_mask_i[p];
                addr_valid_q[execute_idx_i[p]] <= 1'b1;
                data_valid_q[execute_idx_i[p]] <= 1'b1;
            end
            end
            for (int port = 0; port < COMMIT_WIDTH; port++) begin
                if (commit_valid_i[port] && valid_q[commit_idx_i[port]]
                 && !branch_mask_q[commit_idx_i[port]][resolution_tag_i]) begin
                    if(kind_q[commit_idx_i[port]]==o3_types_pkg::SQ_NORMAL) committed_q[commit_idx_i[port]] <= 1'b1;
                end
            end
            if (drain_fire) begin
                valid_q[head_q] <= 1'b0;
                addr_valid_q[head_q] <= 1'b0;
                data_valid_q[head_q] <= 1'b0;
                committed_q[head_q] <= 1'b0;
                head_q <= add_idx(head_q, 1);
            end
            tail_q <= restore_tail_i;
            count_q <= COUNT_WIDTH'(kept) - COUNT_WIDTH'(drain_fire);
        end else begin
            int unsigned alloc_count;
            logic drain_fire;
            alloc_count = 0;
            drain_fire = dc_drain_fire || (drain_valid_o && drain_ready_i) || heu_release;
            if (DCACHE_DRAIN && t_dc_req_valid_o && t_dc_req_ready_i)
                dc_inflight_q <= 1'b1;
            if (dc_resp_match) dc_inflight_q <= 1'b0;

            if (drain_fire) begin
                valid_q[head_q] <= 1'b0;
                addr_valid_q[head_q] <= 1'b0;
                data_valid_q[head_q] <= 1'b0;
                committed_q[head_q] <= 1'b0;
                head_q <= add_idx(head_q, 1);
            end

            for (int entry = 0; entry < DEPTH; entry++) begin
                if (resolution_valid_i) branch_mask_q[entry][resolution_tag_i] <= 1'b0;
            end

            if (alloc_fire_i) begin
                for (int lane = 0; lane < RENAME_WIDTH; lane++) begin
                    if (alloc_req_i[lane]) begin
                        valid_q[alloc_idx_o[lane]] <= 1'b1;
                        addr_valid_q[alloc_idx_o[lane]] <= 1'b0;
                        data_valid_q[alloc_idx_o[lane]] <= 1'b0;
                        committed_q[alloc_idx_o[lane]] <= 1'b0;
                        addr_q[alloc_idx_o[lane]] <= '0;
                        data_q[alloc_idx_o[lane]] <= '0;
                        mask_q[alloc_idx_o[lane]] <= '0;
                        rob_idx_q[alloc_idx_o[lane]] <= alloc_rob_idx_i[lane];
                        branch_mask_q[alloc_idx_o[lane]] <= alloc_branch_mask_i[lane];
                        alloc_count++;
                    end
                end
                tail_q <= add_idx(tail_q, alloc_count);
            end

            for(int p=0;p<P;p++) begin
            if (execute_valid_i[p] && valid_q[execute_idx_i[p]]) begin
                addr_q[execute_idx_i[p]] <= execute_addr_i[p];
                data_q[execute_idx_i[p]] <= execute_data_i[p];
                mask_q[execute_idx_i[p]] <= execute_mask_i[p];
                addr_valid_q[execute_idx_i[p]] <= 1'b1;
                data_valid_q[execute_idx_i[p]] <= 1'b1;
            end
            end
            for (int port = 0; port < COMMIT_WIDTH; port++) begin
                if (commit_valid_i[port] && valid_q[commit_idx_i[port]]) begin
                    if(kind_q[commit_idx_i[port]]==o3_types_pkg::SQ_NORMAL) committed_q[commit_idx_i[port]] <= 1'b1;
                end
            end

            count_q <= count_q + COUNT_WIDTH'(alloc_count) - COUNT_WIDTH'(drain_fire);
        end
    end

    initial if (DEPTH <= 0) $error("store_queue requires DEPTH > 0");
endmodule
