/** L8a ICache Read client. Four line MSHRs, physical-line merge and
 * independent request waiters. Redirects discard deliveries outside this
 * cache; accepted fills still install. L1I has no directory/recall path. */
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
    typedef struct packed {logic valid;logic [TW-1:0] tag;} tag_t;
    tag_t tags_q[BANKS][SETS][WAYS];
    (* ram_style="block" *) coh_data_t data_q[BANKS][WAYS][SETS];
    logic [WAYS-2:0] plru_q[BANKS][SETS];logic [31:0] version_q[BANKS][SETS];
    typedef struct packed {icache_req_t req;paddr_t pa;logic pf,af;logic [31:0] version;} query_t;
    query_t s1_q,s2_q,s3_q;logic v1_q,v2_q,v3_q,s1_ready,s2_ready,s3_ready;
    tag_t tag_read_q[WAYS],tags2_q[WAYS],tags3_q[WAYS];
    coh_data_t data_read_q[WAYS],data2_q[WAYS],data3_q[WAYS];
    logic tlb_valid,tlb_hit,tlb_miss,tlb_pf,tlb_af;logic [43:0] tlb_ppn;logic [1:0] tlb_level;
    fe_perf_t tlb_perf,mshr_perf;
    logic xlate_saved_q; paddr_t saved_pa_q;logic saved_pf_q,saved_af_q;
    logic fire;icache_req_t selected_req;logic retry_valid_q;icache_req_t retry_q;
    logic hit,stale,fault;int hit_way;coh_data_t hit_line;
    logic alloc_valid,alloc_ready,alloc_merged,probe_inflight,demand_miss_pending;
    paddr_t alloc_line;logic fill_valid,fill_ready,fill_error,fill_done,mshr_idle;
    paddr_t fill_line,fill_done_line;coh_data_t fill_data;
    logic waiter_valid_q[WAITERS],waiter_ready_q[WAITERS],waiter_error_q[WAITERS];
    icache_req_t waiter_req_q[WAITERS];paddr_t waiter_line_q[WAITERS];coh_data_t waiter_data_q[WAITERS];
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
    itlb #(.CFG(CFG)) u_itlb(.clk_i(clk),.rst_i(rst),.kill_i(xlate_kill_i),
        .s0_valid_i(fire || (v1_q && !xlate_saved_q && !(tlb_valid && !tlb_miss))),
        .s0_vaddr_i(fire ? selected_req.region_base:s1_q.req.region_base),
        .s1_valid_o(tlb_valid),.s1_hit_o(tlb_hit),.s1_miss_o(tlb_miss),.s1_ppn_o(tlb_ppn),.s1_level_o(tlb_level),
        .s1_page_fault_o(tlb_pf),.s1_access_fault_o(tlb_af),
        .ptw_req_valid_o(ptw_req_valid_o),.ptw_req_ready_i(ptw_req_ready_i),.ptw_req_o(ptw_req_o),.ptw_resp_i(ptw_resp_i),
        .csr_i(csr_i),.sfence_i(sfence_i),.sfence_done_o(sfence_done_o),.perf_o(tlb_perf));
    icache_mshr #(.CFG(CFG)) u_mshr(.clk_i(clk),.rst_i(rst),.alloc_valid_i(alloc_valid),.alloc_ready_o(alloc_ready),
        .alloc_line_paddr_i(alloc_line),.alloc_kind_i(L2_DEMAND),.alloc_merged_o(alloc_merged),
        .probe_line_paddr_i(pf_req_i.line_paddr),.probe_inflight_o(probe_inflight),
        .l2_req_valid_o(l2_req_valid_o),.l2_req_ready_i(l2_req_ready_i),.l2_req_o(l2_req_o),
        .l2_resp_valid_i(l2_resp_valid_i),.l2_resp_i(l2_resp_i),.l2_resp_ready_o(l2_resp_ready_o),
        .fill_wr_valid_o(fill_valid),.fill_wr_ready_i(fill_ready),.fill_wr_line_paddr_o(fill_line),
        .fill_wr_data_o(fill_data),.fill_wr_error_o(fill_error),.fill_done_o(fill_done),.fill_done_line_paddr_o(fill_done_line),
        .idle_o(mshr_idle),.perf_o(mshr_perf));
    assign fill_ready=!inv_all_i; // independent SRAM write port
    logic prefetch_fire;logic prefetch_hit;
    always_comb begin
        hit=0;hit_way=0;hit_line='0;
        for(int w=0;w<WAYS;w++) if(tags3_q[w].valid && tags3_q[w].tag==TW'(s3_q.pa>>(7+SW))) begin hit=1;hit_way=w;hit_line=data3_q[w];end
        stale=s3_q.version!=version_q[s3_q.req.region_base[6]][SW'(s3_q.req.region_base>>7)];
        fault=s3_q.pf || s3_q.af || !pma_main(64'(s3_q.pa),FETCH_BYTES) ||
            !pmp_allow(pmp_i,s3_q.pa,FETCH_BYTES,csr_i.priv,1'b0,1'b0,1'b1);
    end
    assign demand_miss_pending=v3_q && !stale && !hit && !fault;
    assign alloc_line=demand_miss_pending ? {s3_q.pa[PADDR_W-1:6],6'b0}:pf_req_i.line_paddr;
    always_comb begin
        free_waiter=-1;ready_waiter=-1;
        for(int n=0;n<WAITERS;n++) begin
            if(!waiter_valid_q[n] && free_waiter<0) free_waiter=n;
            if(waiter_valid_q[n] && waiter_ready_q[n] &&
                (ready_waiter<0 || waiter_age_q[n]<waiter_age_q[ready_waiter])) ready_waiter=n;
        end
        s3_ready=!v3_q || (stale ? !retry_valid_q:
            ((ready_waiter<0 && (hit || fault)) || (!hit && !fault && free_waiter>=0 && alloc_ready)));
        s2_ready=!v2_q || s3_ready;
        s1_ready=!v1_q || (s2_ready && (xlate_saved_q || (tlb_valid && !tlb_miss)));
        selected_req=retry_valid_q ? retry_q:req_i;
        req_ready_o=!rst && !inv_all_i && !retry_valid_q && s1_ready && !(fill_valid && fill_line[6]==req_i.region_base[6]);
        fire=!rst && !inv_all_i && s1_ready && (retry_valid_q || req_valid_i) &&
            !(fill_valid && fill_line[6]==selected_req.region_base[6]);

        fill_bank=int'(fill_line[6]);fill_set=int'(SW'(fill_line>>7));
        fill_way=victim(plru_q[fill_bank][fill_set]);
        for(int w=WAYS-1;w>=0;w--) if(!tags_q[fill_bank][fill_set][w].valid) fill_way=w;
        for(int w=0;w<WAYS;w++) if(tags_q[fill_bank][fill_set][w].valid && tags_q[fill_bank][fill_set][w].tag==TW'(fill_line>>(7+SW))) fill_way=w;
        alloc_valid=v3_q && !stale && !hit && !fault && free_waiter>=0;
        prefetch_hit=0;
        for(int w=0;w<WAYS;w++) prefetch_hit|=tags_q[pf_req_i.line_paddr[6]][SW'(pf_req_i.line_paddr>>7)][w].valid &&
            tags_q[pf_req_i.line_paddr[6]][SW'(pf_req_i.line_paddr>>7)][w].tag==TW'(pf_req_i.line_paddr>>(7+SW));
        pf_req_ready_o=!rst && !inv_all_i && !demand_miss_pending && (!pf_req_i.paddr_valid || prefetch_hit || probe_inflight || alloc_ready);
        prefetch_fire=pf_req_valid_i && pf_req_ready_o;
        if(prefetch_fire && pf_req_i.paddr_valid && !prefetch_hit && !probe_inflight &&
            pma_main(64'(pf_req_i.line_paddr),ICACHE_LINE_BYTES)) begin alloc_valid=1;end
        pf_resp_o='0;pf_resp_o.valid=prefetch_fire;
        pf_resp_o.status=!pf_req_i.paddr_valid || !pma_main(64'(pf_req_i.line_paddr),ICACHE_LINE_BYTES) ? PF_XLATE_FAIL:
            prefetch_hit ? PF_HIT:probe_inflight ? PF_INFLIGHT:PF_ISSUED;
        resp_o='0;
        if(ready_waiter>=0) begin
            resp_o.valid=1;resp_o.rq_idx=waiter_req_q[ready_waiter].rq_idx;resp_o.ftq_id=waiter_req_q[ready_waiter].ftq_id;
            resp_o.data=waiter_data_q[ready_waiter][int'(waiter_req_q[ready_waiter].region_base[5:4])*FETCH_BYTES*8+:FETCH_BYTES*8];
            resp_o.exc_valid=waiter_error_q[ready_waiter];resp_o.exc_cause=o3_isa_pkg::EXCEPTION_CAUSE_INST_ACCESS_FAULT;
        end else if(v3_q && !stale && (hit || fault)) begin
            resp_o.valid=1;resp_o.rq_idx=s3_q.req.rq_idx;resp_o.ftq_id=s3_q.req.ftq_id;
            resp_o.data=hit_line[int'(s3_q.req.region_base[5:4])*FETCH_BYTES*8+:FETCH_BYTES*8];
            resp_o.exc_valid=fault;resp_o.exc_cause=s3_q.pf ? EXCEPTION_CAUSE_INST_PAGE_FAULT:EXCEPTION_CAUSE_INST_ACCESS_FAULT;
        end
        if(inv_all_i) resp_o='0;
    end
    always_comb begin
        perf_o=tlb_perf | mshr_perf;perf_o[PE_ICACHE_DEMAND_HIT]=PERF_INC_W'(v3_q && !stale && hit && !fault && s3_ready);
        perf_o[PE_ICACHE_DEMAND_MISS]=PERF_INC_W'(v3_q && !stale && !hit && !fault && s3_ready);
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            v1_q<=0;v2_q<=0;v3_q<=0;s1_q<='0;s2_q<='0;s3_q<='0;
            xlate_saved_q<=0;saved_pa_q<=0;saved_pf_q<=0;saved_af_q<=0;retry_valid_q<=0;retry_q<='0;
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
                tags2_q<=tag_read_q;data2_q<=data_read_q;
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
                        data_read_q[w]<=data_q[selected_req.region_base[6]][w][SW'(selected_req.region_base>>7)];
                    end
                end
            end
            if(retry_valid_q && fire) retry_valid_q<=0;
            if(v3_q && stale && s3_ready) begin retry_valid_q<=1;retry_q<=s3_q.req;end
            if(v3_q && !stale && !hit && !fault && s3_ready) begin
                waiter_valid_q[free_waiter]<=1;waiter_ready_q[free_waiter]<=0;waiter_req_q[free_waiter]<=s3_q.req;
                waiter_line_q[free_waiter]<={s3_q.pa[PADDR_W-1:6],6'b0};waiter_age_q[free_waiter]<=age_q;age_q<=age_q+1;
                // A same-cycle fill may complete the merged waiter immediately.
                if(fill_done && fill_line=={s3_q.pa[PADDR_W-1:6],6'b0}) begin
                    waiter_ready_q[free_waiter]<=1;waiter_data_q[free_waiter]<=fill_data;waiter_error_q[free_waiter]<=fill_error;
                end
            end
            if(ready_waiter>=0 && resp_o.valid) begin waiter_valid_q[ready_waiter]<=0;waiter_ready_q[ready_waiter]<=0;end
            if(fill_done) begin
                for(int n=0;n<WAITERS;n++) if(waiter_valid_q[n] && !waiter_ready_q[n] && waiter_line_q[n]==fill_line) begin
                    waiter_ready_q[n]<=1;waiter_data_q[n]<=fill_data;waiter_error_q[n]<=fill_error;
                end
                if(!fill_error) begin
                    data_q[fill_bank][fill_way][fill_set]<=fill_data;
                    tags_q[fill_bank][fill_set][fill_way]<='{valid:1'b1,tag:TW'(fill_line>>(7+SW))};
                    plru_q[fill_bank][fill_set]<=touch(plru_q[fill_bank][fill_set],fill_way);
                    version_q[fill_bank][fill_set]<=version_q[fill_bank][fill_set]+1;
                end
            end
            if(v3_q && !stale && hit && s3_ready) plru_q[s3_q.req.region_base[6]][SW'(s3_q.req.region_base>>7)]<=
                touch(plru_q[s3_q.req.region_base[6]][SW'(s3_q.req.region_base>>7)],hit_way);
            if(inv_all_i) begin
                assert(mshr_idle);v1_q<=0;v2_q<=0;v3_q<=0;retry_valid_q<=0;xlate_saved_q<=0;
                for(int b=0;b<BANKS;b++) for(int s=0;s<SETS;s++) for(int w=0;w<WAYS;w++) tags_q[b][s][w].valid<=0;
            end
        end
    end
    assign idle_o=mshr_idle && !v1_q && !v2_q && !v3_q && !retry_valid_q && !waiters_busy();
    function automatic logic waiters_busy();
        logic busy;busy=0;for(int n=0;n<WAITERS;n++) busy|=waiter_valid_q[n];return busy;
    endfunction
    // Historical pulse interface is no longer an active request path.
    assign s0_ready=0;assign refill_req_valid=0;assign refill_req_pc='0;
    assign out_valid=0;assign out_hit=0;assign out_pc='0;assign out_data='0;assign out_error=0;
    initial begin assert(BANKS==2 && WAYS>=2 && CFG.icache.line_bytes==64);assert(SETS*BANKS*ICACHE_LINE_BYTES<=4096);end
endmodule
