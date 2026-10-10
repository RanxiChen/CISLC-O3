/** L8a ICache Read client. Four line MSHRs, physical-line merge and
 * independent request waiters. Redirects discard deliveries outside this
 * cache; accepted fills still install. L1I has no directory/recall path.
 * 当前实现状态：目标实现；L11 ROM/SRAM取指按平台X/cacheable属性判断，新增功能测试待补。 */
module ICache
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG,
    localparam int ADDR_WIDTH = o3_pkg::PC_WIDTH,
    localparam int ICACHE_BLOCK_SIZE_BYTES = CFG.icache.line_bytes,
    localparam int FETCH_BYTES = CFG.fetch.region_bytes
) (
    input  logic clk,
    input  logic rst,
    input logic xlate_kill_i=1'b0,

    // Legacy ports are retained only for source compatibility; no old
    // request path is active. The frontend uses req_* and resp_o below.
    input  logic flush,
    input  logic kill,
    input  logic s0_valid,
    output logic s0_ready,
    input  logic [ADDR_WIDTH-1:0] s0_pc,
    output logic refill_req_valid,
    output logic [ADDR_WIDTH-1:0] refill_req_pc,
    input  logic refill_resp_valid,
    input  logic [ADDR_WIDTH-1:0] refill_resp_pc,
    input  logic refill_resp_error,
    input  logic [ICACHE_BLOCK_SIZE_BYTES*8-1:0] refill_resp_data,
    output logic out_valid,
    output logic out_hit,
    output logic [ADDR_WIDTH-1:0] out_pc,
    output logic [FETCH_BYTES*8-1:0] out_data,
    output logic out_error,

    input  logic req_valid_i,
    output logic req_ready_o,
    input  icache_req_t req_i,
    output icache_resp_t resp_o,

    input logic xprobe_valid_i=1'b0,input vaddr_t xprobe_vaddr_i='0,
    output logic xprobe_grant_o,output xprobe_resp_t xprobe_resp_o,
    output xlate_fill_t xlate_fill_o,
    input  logic pf_req_valid_i,
    output logic pf_req_ready_o,
    input  pf_req_t pf_req_i,
    output pf_resp_t pf_resp_o,

    output logic ptw_req_valid_o,
    input  logic ptw_req_ready_i,
    output ptw_req_t ptw_req_o,
    input  ptw_resp_t ptw_resp_i,

    output logic l2_req_valid_o,
    input  logic l2_req_ready_i,
    output coh_req_t l2_req_o,
    input logic l2_resp_valid_i,
    input coh_rsp_down_t l2_resp_i,
    output logic l2_resp_ready_o,

    input  fe_csr_t csr_i,
    input  pmp_state_t pmp_i,
    output logic pmp_update_done_o,
    input  sfence_req_t sfence_i,
    output logic sfence_done_o,
    input  logic inv_all_i,
    output logic inv_done_o,
    output logic idle_o,

    output fe_perf_t perf_o
);

    localparam int BANKS=CFG.icache.banks,WAYS=CFG.icache.ways,SETS=CFG.icache.sets/BANKS,
        SW=$clog2(SETS),TW=MEM_PADDR_W-7-SW,WAITERS=CFG.fetch.return_queue_depth;
    typedef struct packed {logic valid,pf;logic [TW-1:0] tag;} tag_t;
    tag_t tags_q[BANKS][SETS][WAYS];
    logic [WAYS-2:0] plru_q[BANKS][SETS];logic [31:0] version_q[BANKS][SETS];
    typedef struct packed {icache_req_t req;paddr_t pa;logic pf,af;logic [31:0] version;} query_t;
    query_t s1_q,s2_q,s3_q;logic v1_q,v2_q,v3_q,s1_ready,s2_ready,s3_ready;
    tag_t tag_read_q[WAYS],tags2_q[WAYS],tags3_q[WAYS];
    coh_data_t data_read_q[WAYS];
    // Select the requested 16B region before S2; later stages carry only
    // that region per way, rather than registering four complete 64B lines.
    logic [FETCH_BYTES*8-1:0] data2_q[WAYS],data3_q[WAYS];
    coh_data_t bank_data_read_q[BANKS][WAYS];
    logic data_read_bank_q;
    logic tlb_raw_valid,probe_q,tlb_g,tlb_demand_lookup;
    logic tlb_valid,tlb_hit,tlb_miss,tlb_pf,tlb_af;logic [43:0] tlb_ppn;logic [1:0] tlb_level;
    fe_perf_t tlb_perf,mshr_perf;
    logic xlate_saved_q; paddr_t saved_pa_q;logic saved_pf_q,saved_af_q;
    logic fire;icache_req_t selected_req;logic retry_valid_q;icache_req_t retry_q;
    // Every accepted demand owns one replay credit until it exits S3.
    // Credits cover ingress, query stages and queued replays together. S3 can
    // always retire into a response, waiter, or reserved replay slot; its
    // hit/permission/resource decisions never drive external request ready.
    localparam int RETRIES=8, RPW=$clog2(RETRIES), RCW=$clog2(RETRIES+1);
    icache_req_t retry_fifo_q[RETRIES];
    logic [RPW-1:0] retry_head_q,retry_tail_q;
    logic [RCW-1:0] retry_count_q;
    logic retry_push,retry_pop,s3_complete;
    localparam int INGRESS=2;
    icache_req_t ingress_q[INGRESS];
    logic ingress_head_q,ingress_tail_q;
    logic [1:0] ingress_count_q;
    logic ingress_push,ingress_pop;
    logic [3:0] replay_used;
    assign replay_used=4'(retry_count_q)+4'(ingress_count_q)+
        4'(v1_q)+4'(v2_q)+4'(v3_q);
    assign ingress_push=req_valid_i && req_ready_o;
    assign ingress_pop=fire && !retry_valid_q;
    assign retry_valid_q=retry_count_q!=0;
    assign retry_q=retry_fifo_q[retry_head_q];
    assign retry_push=v3_q && !s3_complete && !inv_all_i;
    assign retry_pop=retry_valid_q && fire;
    logic hit,stale,fault;int hit_way;logic [FETCH_BYTES*8-1:0] hit_line;
    logic alloc_valid,alloc_ready,alloc_merged,probe_inflight,demand_miss_pending;
    logic [$clog2(CFG.icache.mshrs+1)-1:0] mshr_free;
    logic fill_pf,prefetch_bad;
    paddr_t alloc_line;logic fill_valid,fill_ready,fill_error,fill_done,mshr_idle;
    paddr_t fill_line,fill_done_line;coh_data_t fill_data;
    logic waiter_valid_q[WAITERS],waiter_ready_q[WAITERS],waiter_error_q[WAITERS];
    icache_req_t waiter_req_q[WAITERS];paddr_t waiter_line_q[WAITERS];
    logic [FETCH_BYTES*8-1:0] waiter_data_q[WAITERS];
    logic [31:0] waiter_age_q[WAITERS],age_q;int free_waiter,ready_waiter;
    int fill_way,fill_bank,fill_set;
    function automatic int victim(input logic [WAYS-2:0] tree);
        int node,w,d;node=0;w=0;
        for(int l=0;l<$clog2(WAYS);l++) begin d=int'(tree[node]);w=2*w+d;node=2*node+1+d;end
        return w;
    endfunction
    function automatic logic [WAYS-2:0] touch(input logic [WAYS-2:0] tree,input int w);
        logic [WAYS-2:0] t;int node,d;t=tree;node=0;
        for(int l=0;l<$clog2(WAYS);l++) begin d=(w>>($clog2(WAYS)-l-1))&1;t[node]=1'(1-d);node=2*node+1+d;end
        return t;
    endfunction
    assign tlb_demand_lookup=fire || (v1_q && !xlate_saved_q && !(tlb_valid && !tlb_miss));
    assign xprobe_grant_o=!rst && !inv_all_i && !sfence_i.valid && !tlb_demand_lookup;
    assign tlb_valid=tlb_raw_valid && !probe_q;
    assign xprobe_resp_o='{valid:tlb_raw_valid && probe_q,hit:tlb_hit && !tlb_pf && !tlb_af,ppn:tlb_ppn,level:tlb_level,g:tlb_g};
    always_comb begin
        xlate_fill_o='0;
        if(v1_q && tlb_valid && tlb_hit && !tlb_pf && !tlb_af && csr_i.satp_mode==8 && csr_i.priv!=3)
            xlate_fill_o='{valid:1'b1,vpn:s1_q.req.region_base[38:12],ppn:tlb_ppn,level:tlb_level,g:tlb_g,asid:csr_i.satp_asid,epoch:csr_i.epoch};
    end
    always_ff @(posedge clk) begin
        if(rst) probe_q<=0;
        else begin
            probe_q<=xprobe_valid_i && xprobe_grant_o;
            if(probe_q) assert(!v1_q || xlate_saved_q) else $fatal(1,"ITLB probe conflicts with demand S1");
        end
    end
    itlb #(.CFG(CFG)) u_itlb(.clk_i(clk),.rst_i(rst),.kill_i(xlate_kill_i),
        .s0_probe_i(xprobe_valid_i && xprobe_grant_o),.s0_valid_i(tlb_demand_lookup || (xprobe_valid_i && xprobe_grant_o)),
        .s0_vaddr_i(tlb_demand_lookup ? (fire ? selected_req.region_base:s1_q.req.region_base) : xprobe_vaddr_i),
        .s1_g_o(tlb_g),.s1_valid_o(tlb_raw_valid),.s1_hit_o(tlb_hit),.s1_miss_o(tlb_miss),.s1_ppn_o(tlb_ppn),.s1_level_o(tlb_level),
        .s1_page_fault_o(tlb_pf),.s1_access_fault_o(tlb_af),
        .ptw_req_valid_o(ptw_req_valid_o),.ptw_req_ready_i(ptw_req_ready_i),.ptw_req_o(ptw_req_o),.ptw_resp_i(ptw_resp_i),
        .csr_i(csr_i),.sfence_i(sfence_i),.sfence_done_o(sfence_done_o),.perf_o(tlb_perf));
    icache_mshr #(.CFG(CFG)) u_mshr(.clk_i(clk),.rst_i(rst),.alloc_valid_i(alloc_valid),.alloc_ready_o(alloc_ready),
        .alloc_line_paddr_i(alloc_line),.alloc_kind_i(demand_miss_pending ? L2_DEMAND:L2_PREFETCH),.alloc_merged_o(alloc_merged),
        .probe_line_paddr_i(pf_pending_req_q.line_paddr),.probe_inflight_o(probe_inflight),
        .l2_req_valid_o(l2_req_valid_o),.l2_req_ready_i(l2_req_ready_i),.l2_req_o(l2_req_o),
        .l2_resp_valid_i(l2_resp_valid_i),.l2_resp_i(l2_resp_i),.l2_resp_ready_o(l2_resp_ready_o),
        .fill_wr_valid_o(fill_valid),.fill_wr_ready_i(fill_ready),.fill_wr_line_paddr_o(fill_line),
        .fill_wr_data_o(fill_data),.fill_wr_error_o(fill_error),.fill_done_o(fill_done),.fill_done_line_paddr_o(fill_done_line),
        .free_count_o(mshr_free),.fill_pf_o(fill_pf),.idle_o(mshr_idle),.perf_o(mshr_perf));
    assign fill_ready=!inv_all_i; // independent SRAM write port
    // A dedicated prefetch register cuts permission/tag/MSHR decisions off
    // the candidate-ready path. Permission checks end at this register.
    logic pf_pending_q,pf_bad_q;
    pf_req_t pf_pending_req_q;
    logic prefetch_fire,prefetch_hit,pf_process_ready;
    always_ff @(posedge clk) begin : prefetch_request_register
        if(rst || inv_all_i || xlate_kill_i) begin
            pf_pending_q<=0;pf_pending_req_q<='0;pf_bad_q<=0;
        end else begin
            if(prefetch_fire) pf_pending_q<=0;
            if(pf_req_valid_i && pf_req_ready_o) begin
                pf_pending_q<=1;pf_pending_req_q<=pf_req_i;
                pf_bad_q<=!pf_req_i.paddr_valid || pf_req_i.epoch!=csr_i.epoch ||
                    !pma_exec(64'(pf_req_i.line_paddr),ICACHE_LINE_BYTES) ||
                    !pmp_allow_dec(pmp_i.dec,pf_req_i.line_paddr,ICACHE_LINE_BYTES,csr_i.priv,0,0,1);
            end
        end
    end
    always_comb begin
        hit=0;hit_way=0;hit_line='0;
        for(int w=0;w<WAYS;w++) if(tags3_q[w].valid && tags3_q[w].tag==TW'(s3_q.pa>>(7+SW))) begin hit=1;hit_way=w;hit_line=data3_q[w];end
        stale=s3_q.version!=version_q[s3_q.req.region_base[6]][SW'(s3_q.req.region_base>>7)];
        fault=s3_q.pf || s3_q.af || !pma_exec(64'(s3_q.pa),FETCH_BYTES) ||
            !pmp_allow_dec(pmp_i.dec,s3_q.pa,FETCH_BYTES,csr_i.priv,1'b0,1'b0,1'b1);
    end
    assign demand_miss_pending=v3_q && !stale && !hit && !fault;
    assign alloc_line=demand_miss_pending ? {s3_q.pa[PADDR_W-1:6],6'b0}:pf_pending_req_q.line_paddr;
    // Balanced oldest-ready tournament. Ties keep the lower slot index,
    // matching the original strict-age comparison without an eight-way chain.
    localparam int WA=$clog2(WAITERS), WT=1<<WA;
    typedef struct packed {logic valid;logic [31:0] age;logic [WAITERS-1:0] select;} waiter_pick_t;
    logic [WAITERS-1:0] ready_waiter_oh;
    // Elaborate children before their parent (Vivado 2022.2 requires this
    // ordering for references to a record in another generated instance).
    for (genvar n=2*WT-1; n>0; n--) begin : g_waiter_tree
        waiter_pick_t choice;
        if (n>=WT) begin : g_leaf
            if (n-WT<WAITERS) assign choice = '{valid:waiter_valid_q[n-WT] && waiter_ready_q[n-WT],
                age:waiter_age_q[n-WT],select:WAITERS'(1)<<(n-WT)};
            else assign choice = '0;
        end else begin : g_merge
            waiter_pick_t left, right;
            assign left = g_waiter_tree[2*n].choice;
            assign right = g_waiter_tree[2*n+1].choice;
            assign choice = !left.valid || (right.valid && right.age < left.age)
                ? right : left;
        end
    end
    waiter_pick_t oldest_ready;
    assign oldest_ready = g_waiter_tree[1].choice;
    assign ready_waiter_oh=oldest_ready.select & {WAITERS{oldest_ready.valid}};
    always_comb begin
        free_waiter=-1;ready_waiter=-1;
        for(int n=0;n<WAITERS;n++) begin
            if(!waiter_valid_q[n] && free_waiter<0) free_waiter=n;
            if(ready_waiter_oh[n]) ready_waiter=n;
        end
        s3_complete=!stale && ((ready_waiter<0 && (hit || fault)) ||
            (!hit && !fault && free_waiter>=0 && alloc_ready));
        s3_ready=1'b1;
        s2_ready=1'b1;
        s1_ready=!v1_q || (s2_ready && (xlate_saved_q || (tlb_valid && !tlb_miss)));
        selected_req=retry_valid_q ? retry_q:ingress_q[ingress_head_q];
        req_ready_o=!rst && !inv_all_i && !retry_valid_q &&
            ingress_count_q<2'(INGRESS) && replay_used<4'(RETRIES);
        fire=!rst && !inv_all_i && s1_ready && (retry_valid_q || ingress_count_q!=0) &&
            !(fill_valid && fill_line[6]==selected_req.region_base[6]);

        fill_bank=int'(fill_line[6]);fill_set=int'(SW'(fill_line>>7));
        fill_way=victim(plru_q[fill_bank][fill_set]);
        for(int w=WAYS-1;w>=0;w--) if(!tags_q[fill_bank][fill_set][w].valid) fill_way=w;
        for(int w=0;w<WAYS;w++) if(tags_q[fill_bank][fill_set][w].valid && tags_q[fill_bank][fill_set][w].tag==TW'(fill_line>>(7+SW))) fill_way=w;
        alloc_valid=v3_q && !stale && !hit && !fault && free_waiter>=0;
        prefetch_hit=0;
        for(int w=0;w<WAYS;w++) prefetch_hit|=tags_q[pf_pending_req_q.line_paddr[6]][SW'(pf_pending_req_q.line_paddr>>7)][w].valid &&
            tags_q[pf_pending_req_q.line_paddr[6]][SW'(pf_pending_req_q.line_paddr>>7)][w].tag==TW'(pf_pending_req_q.line_paddr>>(7+SW));
        prefetch_bad=pf_bad_q || pf_pending_req_q.epoch!=csr_i.epoch || pmp_i.update;
        pf_req_ready_o=!rst && !inv_all_i && !xlate_kill_i && !pf_pending_q;
        pf_process_ready=prefetch_bad || prefetch_hit || probe_inflight ||
            (!demand_miss_pending && int'(mshr_free)>int'(CFG.prefetch.mshr_reserve) && alloc_ready);
        prefetch_fire=!rst && !inv_all_i && !xlate_kill_i && pf_pending_q && pf_process_ready;
        if(prefetch_fire && !prefetch_bad && !prefetch_hit && !probe_inflight) alloc_valid=1;
        pf_resp_o='0;pf_resp_o.valid=prefetch_fire;
        pf_resp_o.status=prefetch_bad ? PF_XLATE_FAIL:prefetch_hit ? PF_HIT:probe_inflight ? PF_INFLIGHT:PF_ISSUED;
        resp_o='0;
        if(ready_waiter>=0) begin
            resp_o.valid=1;
            resp_o.exc_cause=o3_isa_pkg::EXCEPTION_CAUSE_INST_ACCESS_FAULT;
            for (int n=0; n<WAITERS; n++) begin
                resp_o.rq_idx |= waiter_req_q[n].rq_idx & {RQ_IDX_W{ready_waiter_oh[n]}};
                resp_o.ftq_id |= waiter_req_q[n].ftq_id & {$bits(ftq_id_t){ready_waiter_oh[n]}};
                resp_o.data |= waiter_data_q[n] & {FETCH_BYTES*8{ready_waiter_oh[n]}};
                resp_o.exc_valid |= waiter_error_q[n] && ready_waiter_oh[n];
            end
        end else if(v3_q && s3_complete && (hit || fault)) begin
            resp_o.valid=1;resp_o.rq_idx=s3_q.req.rq_idx;resp_o.ftq_id=s3_q.req.ftq_id;
            resp_o.data=hit_line;
            resp_o.exc_valid=fault;resp_o.exc_cause=s3_q.pf ? EXCEPTION_CAUSE_INST_PAGE_FAULT:EXCEPTION_CAUSE_INST_ACCESS_FAULT;
        end
        if(rst || inv_all_i) resp_o='0;
    end
    always_comb begin
        perf_o=tlb_perf | mshr_perf;
        perf_o[PE_PF_THROTTLED]=PERF_INC_W'(pf_req_valid_i && !pf_req_ready_o && !inv_all_i);
        perf_o[PE_PF_USEFUL]=PERF_INC_W'(v3_q && !stale && hit && !fault && s3_complete && tags_q[s3_q.req.region_base[6]][SW'(s3_q.req.region_base>>7)][hit_way].pf);
        perf_o[PE_PF_UNUSED_EVICT]=PERF_INC_W'(fill_done && !fill_error && tags_q[fill_bank][fill_set][fill_way].valid && tags_q[fill_bank][fill_set][fill_way].pf);perf_o[PE_ICACHE_DEMAND_HIT]=PERF_INC_W'(v3_q && !stale && hit && !fault && s3_complete);
        perf_o[PE_ICACHE_DEMAND_MISS]=PERF_INC_W'(v3_q && !stale && !hit && !fault && s3_complete);
    end
    // Each bank/way has one synchronous read and one fill write port. Select
    // the registered bank result with the bank captured at the same S0 edge.
    // Holding the bank selector with the read enable preserves S1 stalls.
    always_ff @(posedge clk) begin
        if(rst) data_read_bank_q<=0;
        else if(fire) data_read_bank_q<=selected_req.region_base[6];
    end
    for(genvar b=0;b<BANKS;b++) begin : g_data_bank
        for(genvar w=0;w<WAYS;w++) begin : g_data_way
            (* ram_style="block" *) logic [$bits(coh_data_t)-1:0] mem[0:SETS-1];
            always_ff @(posedge clk) begin
                if(!rst && fire && selected_req.region_base[6]==b)
                    bank_data_read_q[b][w]<=mem[SW'(selected_req.region_base>>7)];
                if(!rst && fill_done && !fill_error && fill_bank==b && fill_way==w)
                    mem[SW'(fill_set)]<=fill_data;
            end
        end
    end
    for(genvar w=0;w<WAYS;w++)
        assign data_read_q[w]=bank_data_read_q[data_read_bank_q][w];
    always_ff @(posedge clk) begin
        if(rst) begin
            v1_q<=0;v2_q<=0;v3_q<=0;s1_q<='0;s2_q<='0;s3_q<='0;
            xlate_saved_q<=0;saved_pa_q<=0;saved_pf_q<=0;saved_af_q<=0;retry_head_q<=0;retry_tail_q<=0;retry_count_q<=0;
            ingress_head_q<=0;ingress_tail_q<=0;ingress_count_q<=0;ingress_q<='{default:'0};
            waiter_valid_q<='{default:0};waiter_ready_q<='{default:0};waiter_error_q<='{default:0};
            waiter_req_q<='{default:'0};waiter_line_q<='{default:'0};waiter_age_q<='{default:0};age_q<=0;
            inv_done_o<=0;pmp_update_done_o<=0;
            for(int b=0;b<BANKS;b++) for(int s=0;s<SETS;s++) begin
                plru_q[b][s]<=0;version_q[b][s]<=0;for(int w=0;w<WAYS;w++) tags_q[b][s][w]<='0;
            end
        end else begin
            inv_done_o<=inv_all_i;pmp_update_done_o<=1;
            if(s3_ready) begin v3_q<=v2_q;s3_q<=s2_q;tags3_q<=tags2_q;data3_q<=data2_q;end
            if(s2_ready) begin
                v2_q<=v1_q && (xlate_saved_q || (tlb_valid && !tlb_miss));s2_q<=s1_q;
                s2_q.pa<=xlate_saved_q ? saved_pa_q:sv39_pa(tlb_ppn,s1_q.req.region_base,tlb_level);
                s2_q.pf<=xlate_saved_q ? saved_pf_q:tlb_pf;
                s2_q.af<=(xlate_saved_q ? saved_af_q:tlb_af) ||
                    ((csr_i.satp_mode!=8 || csr_i.priv==3) && (s1_q.req.region_base>>MEM_PADDR_W)!=0);
                tags2_q<=tag_read_q;
                for(int w=0;w<WAYS;w++)
                    data2_q[w]<=data_read_q[w][int'(s1_q.req.region_base[5:4])*FETCH_BYTES*8+:FETCH_BYTES*8];
            end
            if(v1_q && tlb_valid && !tlb_miss && !s2_ready && !xlate_saved_q) begin
                xlate_saved_q<=1;saved_pa_q<=sv39_pa(tlb_ppn,s1_q.req.region_base,tlb_level);saved_pf_q<=tlb_pf;saved_af_q<=tlb_af;
            end
            if(s1_ready) begin
                xlate_saved_q<=0;v1_q<=fire;
                if(fire) begin
                    s1_q.req<=selected_req;s1_q.version<=version_q[selected_req.region_base[6]][SW'(selected_req.region_base>>7)];
                    for(int w=0;w<WAYS;w++) begin
                        tag_read_q[w]<=tags_q[selected_req.region_base[6]][SW'(selected_req.region_base>>7)][w];
                    end
                end
            end
            if(ingress_push) begin
                ingress_q[ingress_tail_q]<=req_i;
                ingress_tail_q<=!ingress_tail_q;
            end
            if(ingress_pop) ingress_head_q<=!ingress_head_q;
            case({ingress_push,ingress_pop})
                2'b10:ingress_count_q<=ingress_count_q+1'b1;
                2'b01:ingress_count_q<=ingress_count_q-1'b1;
                default: ;
            endcase
            assert(replay_used<=4'(RETRIES)) else $fatal(1,"ICache replay credits overflow");
            assert(!retry_push || retry_count_q<RCW'(RETRIES) || retry_pop)
                else $fatal(1,"ICache replay slot was not reserved");
            if(retry_pop) retry_head_q<=retry_head_q+1'b1;
            if(retry_push) begin retry_fifo_q[retry_tail_q]<=s3_q.req;retry_tail_q<=retry_tail_q+1'b1;end
            case({retry_push,retry_pop})
                2'b10:retry_count_q<=retry_count_q+1'b1;
                2'b01:retry_count_q<=retry_count_q-1'b1;
                default: ;
            endcase
            assert(int'(retry_count_q)<=RETRIES);
            if(v3_q && !stale && !hit && !fault && s3_complete) begin
                waiter_valid_q[free_waiter]<=1;waiter_ready_q[free_waiter]<=0;waiter_req_q[free_waiter]<=s3_q.req;
                waiter_line_q[free_waiter]<={s3_q.pa[PADDR_W-1:6],6'b0};waiter_age_q[free_waiter]<=age_q;age_q<=age_q+1;
                // A same-cycle fill may complete the merged waiter immediately.
                if(fill_done && fill_line=={s3_q.pa[PADDR_W-1:6],6'b0}) begin
                    waiter_ready_q[free_waiter]<=1;waiter_data_q[free_waiter]<=fill_data[int'(s3_q.req.region_base[5:4])*FETCH_BYTES*8+:FETCH_BYTES*8];waiter_error_q[free_waiter]<=fill_error;
                end
            end
            if(ready_waiter>=0 && resp_o.valid) begin waiter_valid_q[ready_waiter]<=0;waiter_ready_q[ready_waiter]<=0;end
            if(fill_done) begin
                for(int n=0;n<WAITERS;n++) if(waiter_valid_q[n] && !waiter_ready_q[n] && waiter_line_q[n]==fill_line) begin
                    waiter_ready_q[n]<=1;waiter_data_q[n]<=fill_data[int'(waiter_req_q[n].region_base[5:4])*FETCH_BYTES*8+:FETCH_BYTES*8];waiter_error_q[n]<=fill_error;
                end
                if(!fill_error) begin
                    tags_q[fill_bank][fill_set][fill_way]<='{valid:1'b1,pf:fill_pf,tag:TW'(fill_line>>(7+SW))};
                    plru_q[fill_bank][fill_set]<=touch(plru_q[fill_bank][fill_set],fill_way);
                    version_q[fill_bank][fill_set]<=version_q[fill_bank][fill_set]+1;
                end
            end
            if(v3_q && !stale && hit && !fault && s3_complete) tags_q[s3_q.req.region_base[6]][SW'(s3_q.req.region_base>>7)][hit_way].pf<=0;
            if(v3_q && !stale && hit && s3_complete) plru_q[s3_q.req.region_base[6]][SW'(s3_q.req.region_base>>7)]<=
                touch(plru_q[s3_q.req.region_base[6]][SW'(s3_q.req.region_base>>7)],hit_way);
            if(inv_all_i) begin
                assert(mshr_idle);v1_q<=0;v2_q<=0;v3_q<=0;retry_count_q<=0;retry_head_q<=0;retry_tail_q<=0;xlate_saved_q<=0;ingress_count_q<=0;ingress_head_q<=0;ingress_tail_q<=0;
                for(int b=0;b<BANKS;b++) for(int s=0;s<SETS;s++) for(int w=0;w<WAYS;w++) tags_q[b][s][w]<='0;
            end
        end
    end
    assign idle_o=mshr_idle && !v1_q && !v2_q && !v3_q && !retry_valid_q && ingress_count_q==0 && !pf_pending_q && !waiters_busy();
    function automatic logic waiters_busy();
        logic busy;busy=0;for(int n=0;n<WAITERS;n++) busy|=waiter_valid_q[n];return busy;
    endfunction
    // Historical pulse interface is no longer an active request path.
    assign s0_ready=0;assign refill_req_valid=0;assign refill_req_pc='0;
    assign out_valid=0;assign out_hit=0;assign out_pc='0;assign out_data='0;assign out_error=0;
    initial begin assert(BANKS==2 && WAYS>=2 && CFG.icache.line_bytes==64);assert(SETS*BANKS*ICACHE_LINE_BYTES<=4096);end
endmodule
