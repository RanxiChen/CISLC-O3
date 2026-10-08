/** L8a L1D: two unstalled S0/S1/S2 lanes, eight word banks, line-only
 * MSHRs, exact clean/dirty Put, one PS and one SNP. All line operations
 * reserve their S0 bank slot two cycles in advance. Replay leaves S2. */
module dcache import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,localparam int P=CFG.lsu.agu_pipes,
    localparam int SETS=CFG.dcache.sets,WAYS=CFG.dcache.ways,BANKS=CFG.dcache.banks,
    localparam int SW=$clog2(SETS),WW=$clog2(WAYS),TW=MEM_PADDR_W-6-SW,
    localparam int N=CFG.dcache.mshrs,WN=CFG.dcache.wb_buffers,
    localparam int IP=CFG.lsu.mem_pipes-1
)(input logic clk,rst,
    input logic ld_req_valid_i[P],output logic ld_req_ready_o[P],input dcache_req_t ld_req_i[P],
    input dcache_req_t ld_s1_i[P],output dcache_resp_t ld_resp_o[P],
    input rob_idx_t rob_head_i,
    input logic rsv_clear_i=1'b0,input logic [1:0] priv_i=2'd3,
    output logic dma_invalidate_o,output coh_addr_t dma_line_o,output logic irreversible_o,
    input logic flush_i,resolution_valid_i,resolution_mispredict_i,input br_tag_t resolution_tag_i,
    // Reservations for LSU's IS stage; the CPU S0 request arrives two cycles later.
    output logic full_line_busy_o,output logic internal_busy_o,
    input logic st_req_valid_i,output logic st_req_ready_o,input dcache_req_t st_req_i,output dcache_resp_t st_resp_o,
    input logic ptw_req_valid_i,output logic ptw_req_ready_o,input dcache_req_t ptw_req_i,output dcache_resp_t ptw_resp_o,
    input logic pte_ad_req_valid_i,output logic pte_ad_req_ready_o,input pte_ad_req_t pte_ad_req_i,
    output pte_ad_resp_t pte_ad_resp_o,input xlate_epoch_t cur_epoch_i,input pmp_state_t pmp_i,
    output dc_wake_t wake_o,
    output logic l2_req_valid_o,input logic l2_req_ready_i,output coh_req_t l2_req_o,
    input logic l2_resp_valid_i,input coh_rsp_down_t l2_resp_i,output logic l2_resp_ready_o,
    output logic rsp_up_valid_o,input logic rsp_up_ready_i,output coh_rsp_up_t rsp_up_o,
    input logic snp_valid_i,output logic snp_ready_o,input coh_snp_t snp_i,
    output logic idle_o,output fatal_evt_t fatal_o,output be_perf_t perf_o);
    typedef struct packed {coh_state_e state;logic [TW-1:0] tag;} tag_t;
    (* ram_style="distributed" *) tag_t tags_q[P][SETS][WAYS];
    (* ram_style="block" *) logic [63:0] data_q[BANKS][WAYS][SETS];
    logic [WAYS-2:0] plru_q[SETS];logic locked_q[SETS][WAYS],rfo_q[SETS][WAYS];
    int init_q;logic init_done_q;
    typedef struct packed {logic valid,conflict,bank,snap;dcache_req_t req;pte_ad_req_t ad;logic internal;} lane_t;
    lane_t s1_q[P],s2_q[P],s0[P];tag_t tag_read_q[P][WAYS],s2_tags_q[P][WAYS];
    logic [63:0] bank_read_q[BANKS][WAYS],s2_words_q[P][2][WAYS];
    typedef enum logic [1:0] {LINE_NONE,LINE_PROBE,LINE_INSTALL,LINE_WB} line_kind_t;
    typedef struct packed {line_kind_t kind;coh_addr_t addr;coh_id_t id;logic [DC_WAY_W-1:0] way;dc_line_txn_t txn;} line_op_t;
    line_op_t line_choose,line_launch_q[2],line_read_q,line_result_q;
    logic [63:0] line_words_q[BANKS][WAYS];tag_t line_tags_q[WAYS];
    coh_data_t line_data_q;coh_state_e line_state_q;int line_way_q;
    logic ps_valid_q;dcache_req_t ps_req_q;pte_ad_req_t ps_ad_q;logic ps_internal_q;
    int ps_way_q;logic ps_is_ad_q,ps_write; dcache_resp_t ps_resp_q;
    logic rsv_set,rsv_clear,rsv_conflict,rsv_valid,rsv_window,rsv_ok[P];
    paddr_t rsv_addr;logic [1:0] rsv_size;
    coh_addr_t rsv_line,rsv_conflict_line; paddr_t rsv_set_pa;logic [1:0] rsv_set_size;
    logic atomic_hold_q;coh_addr_t atomic_line_q;int unsigned atomic_timer_q;
    logic [N-1:0] atomic_live_q;
    logic [63:0] amo_new[P];
    dc_mshr_state_e ms_state[N];dc_line_txn_t ms_txn[N];
    logic ms_free,ms_alloc,ms_install,ms_install_issue,ms_install_done,ms_free_pulse;
    coh_id_t ms_free_id,ms_install_id;dc_line_txn_t alloc_txn,install_txn;
    logic [$clog2(N+1)-1:0] ms_free_count;
    logic wb_free,wb_alloc,wb_read,wb_issue,wb_done,wb_free_pulse,wb_put,wb_put_ready;
    coh_id_t wb_free_id,wb_read_id;dc_wb_t alloc_wb,wb_read_meta,wb_meta[WN];logic wb_valid[WN];
    coh_rsp_up_t wb_put_msg;
    logic probe_pending,probe_hold,probe_read,probe_issue,probe_done,probe_ack,probe_ack_ready;
    coh_snp_t probe_snp;coh_rsp_up_t probe_ack_msg;
    logic up_held_q,up_probe_q;logic choose_probe;
    dcache_req_t internal_req_q,internal_choose,internal_launch_q[2];
    pte_ad_req_t internal_ad_q,internal_ad_launch_q[2],internal_ad_choose;
    logic internal_valid_q,internal_inpipe_q,internal_wait_q;
    ld_wait_e internal_reason_q;coh_id_t internal_mshr_q;
    logic internal_fire,internal_finish,internal_launch_valid_q[2],internal_select;
    dcache_resp_t decision[P];int hit_way[P];logic hit[P];coh_state_e hit_state[P];
    int alloc_lane,alloc_way,ps_lane;logic upgrade,alloc_victim,external_mutation;
    logic [SW-1:0] mutation_set;logic tag_change;int tag_way;tag_t tag_new;
    logic [SW-1:0] tag_set;
    function automatic logic killed(input dcache_req_t r);
        return (r.src==DC_SRC_LOAD || r.is_sta || r.head) && (flush_i ||
            (resolution_valid_i && resolution_mispredict_i && r.br_mask[resolution_tag_i]));
    endfunction
    function automatic logic [WAYS-2:0] touch(input logic [WAYS-2:0] tree,input int way_idx);
        logic [WAYS-2:0] t;int node,dir;t=tree;node=0;
        for(int l=0;l<WW;l++) begin dir=(way_idx>>(WW-l-1))&1;t[node]=1'(1-dir);node=2*node+1+dir;end
        return t;
    endfunction
    function automatic int victim(input logic [WAYS-2:0] tree);
        int node,w,dir;node=0;w=0;
        for(int l=0;l<WW;l++) begin dir=int'(tree[node]);w=2*w+dir;node=2*node+1+dir;end
        return w;
    endfunction
    function automatic logic [7:0] byte_mask(input logic [1:0] sz);
        return 8'((9'b1<<(1<<int'(sz)))-1);
    endfunction
    function automatic logic [63:0] format(input logic [127:0] words,input dcache_req_t r);
        logic [63:0] raw;raw=64'(words>>(8*int'(r.paddr[2:0])));
        if(r.raw) return raw & (64'hffffffffffffffff >> (64-8*dc_bytes(r)));
        case(r.size)
            0:raw=r.is_signed ? 64'($signed(raw[7:0])):64'(raw[7:0]);
            1:raw=r.is_signed ? 64'($signed(raw[15:0])):64'(raw[15:0]);
            2:raw=r.is_flw ? {32'hffffffff,raw[31:0]}:
                r.is_signed ? 64'($signed(raw[31:0])):64'(raw[31:0]);
            default:;
        endcase
        return raw;
    endfunction
    lrsc_reservation #(.CFG(CFG)) u_reservation(.clk(clk),.rst(rst),.set_i(rsv_set),
        .set_paddr_i(rsv_set_pa),.set_size_i(rsv_set_size),.check_paddr_i('0),.check_size_i('0),.check_ok_o(),
        .clear_i(rsv_clear),.conflict_i(rsv_conflict),.conflict_line_i(rsv_conflict_line),
        .valid_o(rsv_valid),.window_o(rsv_window),.line_o(rsv_line),.addr_o(rsv_addr),.size_o(rsv_size));
    for(genvar p=0;p<P;p++) begin : gen_atomic
        dcache_amo_unit #(.CFG(CFG)) u_alu(.op_i(s2_q[p].req.amo_op),.size_i(s2_q[p].req.size),
            .old_i(64'( {s2_words_q[p][1][hit_way[p]],s2_words_q[p][0][hit_way[p]]} >> (8*int'(s2_q[p].req.paddr[2:0])))),
            .data_i(s2_q[p].req.wdata),.new_o(amo_new[p]));
        assign rsv_ok[p]=rsv_valid && rsv_addr==s2_q[p].req.paddr && rsv_size==s2_q[p].req.size;
    end
    always_comb begin
        rsv_set=0;rsv_set_pa=0;rsv_set_size=0;rsv_clear=rsv_clear_i;rsv_conflict=0;rsv_conflict_line=0;
        for(int p=0;p<P;p++) if(decision[p].valid && decision[p].status==DC_OK && s2_q[p].req.src==DC_SRC_AMO && !s2_q[p].req.check_only) begin
            if(s2_q[p].req.amo_op==AMO_LR) begin rsv_set=1;rsv_set_pa=s2_q[p].req.paddr;rsv_set_size=s2_q[p].req.size;end
            if(s2_q[p].req.amo_op==AMO_SC) rsv_clear=1;
        end
        if(ps_write && coh_addr_t'(ps_req_q.paddr>>6)==rsv_line) rsv_conflict=1;
        if(ms_alloc && alloc_victim && alloc_wb.line_addr==rsv_line) rsv_conflict=1;
        if(probe_done && probe_snp.op==COH_INV && line_result_q.addr==rsv_line) rsv_conflict=1;
        rsv_conflict_line=rsv_line;
    end
    assign dma_invalidate_o=probe_done && probe_snp.op==COH_INV && probe_snp.dma_write;
    assign dma_line_o=line_result_q.addr;
    assign irreversible_o=ps_write && ps_req_q.head;
    dcache_mshr #(.CFG(CFG)) u_mshr(.clk(clk),.rst(rst),.alloc_i(ms_alloc),.alloc_txn_i(alloc_txn),
        .free_o(ms_free),.free_id_o(ms_free_id),.free_count_o(ms_free_count),.state_o(ms_state),.txn_o(ms_txn),
        .wb_read_done_i(wb_done),.wb_read_id_i(line_result_q.id),
        .req_valid_o(l2_req_valid_o),.req_ready_i(l2_req_ready_i),.req_o(l2_req_o),
        .rsp_valid_i(l2_resp_valid_i && l2_resp_i.op!=COH_PUTACK),.rsp_i(l2_resp_i),
        .install_valid_o(ms_install),.install_id_o(ms_install_id),.install_o(install_txn),
        .install_issue_i(ms_install_issue),.install_done_i(ms_install_done),.install_done_id_i(line_launch_q[1].id),
        .mshr_free_o(ms_free_pulse));
    dcache_writeback #(.CFG(CFG)) u_wb(.clk(clk),.rst(rst),.alloc_i(wb_alloc),.alloc_wb_i(alloc_wb),
        .free_o(wb_free),.free_id_o(wb_free_id),.valid_o(wb_valid),.wb_o(wb_meta),
        .read_valid_o(wb_read),.read_id_o(wb_read_id),.read_o(wb_read_meta),.read_issue_i(wb_issue),
        .read_done_i(wb_done),.read_done_id_i(line_result_q.id),.read_data_i(line_data_q),
        .put_valid_o(wb_put),.put_ready_i(wb_put_ready),.put_o(wb_put_msg),
        .ack_valid_i(l2_resp_valid_i && l2_resp_i.op==COH_PUTACK),.ack_i(l2_resp_i),.wb_free_o(wb_free_pulse));
    dcache_probe #(.CFG(CFG)) u_probe(.clk(clk),.rst(rst),.init_done_i(init_done_q),
        .snp_valid_i(snp_valid_i),.snp_ready_o(snp_ready_o),.snp_i(snp_i),
        .hold_i(probe_hold),.pending_o(probe_pending),.pending_snp_o(probe_snp),
        .read_valid_o(probe_read),.read_issue_i(probe_issue),.read_done_i(probe_done),
        .read_data_i(line_data_q),.read_state_i(line_state_q),
        .ack_valid_o(probe_ack),.ack_ready_i(probe_ack_ready),.ack_o(probe_ack_msg));
    assign l2_resp_ready_o=1;
    assign choose_probe=up_held_q ? up_probe_q:probe_ack;
    assign rsp_up_valid_o=choose_probe ? probe_ack:wb_put;
    assign rsp_up_o=choose_probe ? probe_ack_msg:wb_put_msg;
    assign probe_ack_ready=rsp_up_ready_i && choose_probe;
    assign wb_put_ready=rsp_up_ready_i && !choose_probe;
    // Only protocol completions and bounded PS execution can block a SNP.
    always_comb begin
        probe_hold=(rsv_window && rsv_line==probe_snp.addr) || (atomic_hold_q && atomic_line_q==probe_snp.addr);
        probe_hold|=ps_valid_q && coh_addr_t'(ps_req_q.paddr>>6)==probe_snp.addr;
        for(int n=0;n<N;n++) if(ms_txn[n].line_addr==probe_snp.addr &&
            (ms_state[n]==DM_INSTALL || (ms_state[n]==DM_WAIT && !ms_txn[n].atomic)))
            probe_hold|=!(ms_txn[n].upgrade && ms_state[n]==DM_WAIT && !probe_snp.owner);
        for(int n=0;n<WN;n++) probe_hold|=wb_valid[n] && wb_meta[n].line_addr==probe_snp.addr;
        for(int p=0;p<P;p++) begin
            probe_hold|=s1_q[p].valid && s1_q[p].req.write && coh_addr_t'(s1_q[p].req.paddr>>6)==probe_snp.addr;
            probe_hold|=s2_q[p].valid && s2_q[p].req.write && coh_addr_t'(s2_q[p].req.paddr>>6)==probe_snp.addr;
        end
        for(int l=0;l<2;l++) probe_hold|=internal_launch_valid_q[l] && internal_launch_q[l].write &&
            coh_addr_t'(internal_launch_q[l].paddr>>6)==probe_snp.addr;
    end
    // Choose a future bank slot. INSTALL writes at the reserved S0 edge;
    // PROBE/WB synchronously read all banks and complete at S2.
    always_comb begin
        line_choose='0;
        if(init_done_q && line_launch_q[0].kind==LINE_NONE && line_launch_q[1].kind==LINE_NONE &&
            line_read_q.kind==LINE_NONE && line_result_q.kind==LINE_NONE && !ps_valid_q &&
            !internal_inpipe_q) begin
            if(probe_read) begin line_choose.kind=LINE_PROBE;line_choose.addr=probe_snp.addr;end
            else if(ms_install) begin
                line_choose.kind=LINE_INSTALL;line_choose.addr=install_txn.line_addr;
                line_choose.id=ms_install_id;line_choose.way=install_txn.way;line_choose.txn=install_txn;
            end else if(wb_read) begin
                line_choose.kind=LINE_WB;line_choose.addr=wb_read_meta.line_addr;
                line_choose.id=wb_read_id;line_choose.way=wb_read_meta.way;
            end
        end
        full_line_busy_o=!init_done_q || line_choose.kind!=LINE_NONE;
        probe_issue=line_choose.kind==LINE_PROBE;ms_install_issue=line_choose.kind==LINE_INSTALL;wb_issue=line_choose.kind==LINE_WB;
        internal_select=0;internal_choose='0;internal_ad_choose='0;
        if(!full_line_busy_o && !internal_inpipe_q) begin
            if(internal_valid_q && !internal_wait_q) begin
                internal_select=1;internal_choose=internal_req_q;internal_ad_choose=internal_ad_q;
            end else if(!internal_valid_q) begin
                if(ptw_req_valid_i) begin internal_select=1;internal_choose=ptw_req_i;end
                else if(pte_ad_req_valid_i) begin
                    internal_select=1;internal_choose.src=DC_SRC_PTE_AD;internal_choose.paddr=pte_ad_req_i.pte_paddr;
                    internal_choose.vaddr=64'(pte_ad_req_i.pte_paddr);internal_choose.size=3;internal_choose.write=1;
                    internal_choose.wmask='1;internal_ad_choose=pte_ad_req_i;
                end else if(st_req_valid_i) begin internal_select=1;internal_choose=st_req_i;end
            end
        end
        internal_choose.vaddr=64'(internal_choose.paddr);
        internal_choose.priv=1;
        internal_choose.permission=dc_permissions(internal_choose,pmp_i,2'd1);
        if(internal_choose.src==DC_SRC_STORE_DRAIN) begin
            internal_choose.permission.pmp_ok=1; // reuse STA authorization
        end
        internal_busy_o=!init_done_q || internal_select;
        ptw_req_ready_o=internal_select && !internal_valid_q && ptw_req_valid_i;
        pte_ad_req_ready_o=internal_select && !internal_valid_q && !ptw_req_valid_i && pte_ad_req_valid_i;
        st_req_ready_o=internal_select && !internal_valid_q && !ptw_req_valid_i && !pte_ad_req_valid_i;
        internal_fire=internal_select;
    end
    always_comb begin
        for(int p=0;p<P;p++) begin
            s0[p]='0;s0[p].valid=ld_req_valid_i[p] && !killed(ld_req_i[p]);s0[p].req=ld_req_i[p];
            ld_req_ready_o[p]=init_done_q && line_launch_q[1].kind==LINE_NONE && !(p==IP && internal_launch_valid_q[1]);
        end
        if(internal_launch_valid_q[1]) begin
            s0[IP]='0;s0[IP].valid=1;s0[IP].req=internal_launch_q[1];s0[IP].ad=internal_ad_launch_q[1];s0[IP].internal=1;
        end
        // Store-word hazards include both touched words for unaligned loads.
        for(int p=0;p<P;p++) begin
            logic [11:0] a,b;a=s0[p].req.vaddr[11:0];b=a+12'((1<<int'(s0[p].req.size))-1);
            if(s0[p].internal) begin a=s0[p].req.paddr[11:0];b=a+12'((1<<int'(s0[p].req.size))-1);end
            if(s0[p].valid && !s0[p].req.write && !s0[p].req.is_sta) begin
            for(int q=0;q<P;q++) begin
                s0[p].conflict|=s1_q[q].valid && (s1_q[q].req.write || s1_q[q].req.is_sta) &&
                    (s1_q[q].req.vaddr[11:3]==a[11:3] || s1_q[q].req.vaddr[11:3]==b[11:3]);
                s0[p].conflict|=s2_q[q].valid && (s2_q[q].req.write || s2_q[q].req.is_sta) &&
                    (s2_q[q].req.vaddr[11:3]==a[11:3] || s2_q[q].req.vaddr[11:3]==b[11:3]);
            end
            s0[p].conflict|=ps_valid_q && (ps_req_q.paddr[11:3]==a[11:3] || ps_req_q.paddr[11:3]==b[11:3]);
        end
        end
        if(P>1) begin
            logic [7:0] m0,m1;int younger;
            m0=8'(1<<int'(s0[0].req.vaddr[5:3]));m1=8'(1<<int'(s0[1].req.vaddr[5:3]));
            if(int'(s0[0].req.vaddr[2:0])+(1<<int'(s0[0].req.size))>8) m0|=8'(1<<((int'(s0[0].req.vaddr[5:3])+1)%BANKS));
            if(int'(s0[1].req.vaddr[2:0])+(1<<int'(s0[1].req.size))>8) m1|=8'(1<<((int'(s0[1].req.vaddr[5:3])+1)%BANKS));
            younger=((int'(s0[0].req.rob_idx)+CFG.rob.entries-int'(rob_head_i))%CFG.rob.entries <=
                (int'(s0[1].req.rob_idx)+CFG.rob.entries-int'(rob_head_i))%CFG.rob.entries) ? 1:0;
            // IQ/replay lanes are placed in age order by LSU. Internal lane wins.
            if(s0[1].internal) younger=0;
            if(s0[0].valid && s0[1].valid && (m0&m1)!=0 && SW'(s0[0].req.vaddr>>6)!=SW'(s0[1].req.vaddr>>6)) s0[younger].bank=1;
        end
    end
    assign ps_write=ps_valid_q && line_launch_q[1].kind==LINE_NONE;
    assign ms_install_done=line_launch_q[1].kind==LINE_INSTALL;
    assign probe_done=line_result_q.kind==LINE_PROBE;
    assign wb_done=line_result_q.kind==LINE_WB;
    // Existing tags mutate before S2 may use an older snapshot.
    always_comb begin
        external_mutation=0;mutation_set='0;
        // A probe reservation also protects its tag snapshot from an older
        // S2 allocation. Otherwise a dirty victim Put can race the Down ack.
        if(line_choose.kind==LINE_PROBE) begin external_mutation=1;mutation_set=SW'(line_choose.addr);end
        if(line_launch_q[0].kind==LINE_PROBE) begin external_mutation=1;mutation_set=SW'(line_launch_q[0].addr);end
        if(line_launch_q[1].kind==LINE_PROBE) begin external_mutation=1;mutation_set=SW'(line_launch_q[1].addr);end
        if(line_read_q.kind==LINE_PROBE) begin external_mutation=1;mutation_set=SW'(line_read_q.addr);end
        if(probe_done) begin external_mutation=1;mutation_set=SW'(line_result_q.addr);end
        if(ms_install_done) begin external_mutation=1;mutation_set=SW'(line_launch_q[1].addr);end
        if(ps_write) begin external_mutation=1;mutation_set=SW'(ps_req_q.paddr>>6);end
    end
    always_comb begin
        alloc_lane=-1;alloc_way=0;ps_lane=-1;upgrade=0;alloc_victim=0;ms_alloc=0;wb_alloc=0;alloc_txn='0;alloc_wb='0;
        for(int p=0;p<P;p++) begin
            logic same_wb;int same_ms;logic [SW-1:0] set_idx;int v;logic can_alloc,privileged,want_m;
            logic [63:0] raw;logic [127:0] words;dcache_req_t aligned;aligned=s2_q[p].req;aligned.paddr[2:0]=0;
            set_idx=SW'(s2_q[p].req.paddr>>6);same_ms=-1;same_wb=0;hit[p]=0;hit_way[p]=0;hit_state[p]=COH_I;
            for(int w=0;w<WAYS;w++) if(s2_tags_q[p][w].state!=COH_I && !locked_q[set_idx][w] &&
                s2_tags_q[p][w].tag==TW'(s2_q[p].req.paddr>>(6+SW))) begin
                hit[p]=1;hit_way[p]=w;hit_state[p]=s2_tags_q[p][w].state;
            end
            for(int n=0;n<N;n++) if(ms_state[n]!=DM_IDLE && ms_txn[n].line_addr==coh_addr_t'(s2_q[p].req.paddr>>6)) same_ms=n;
            // A second lane can merge a same-cycle allocation.
            if(alloc_lane>=0 && alloc_txn.line_addr==coh_addr_t'(s2_q[p].req.paddr>>6)) same_ms=int'(ms_free_id);
            for(int n=0;n<WN;n++) same_wb|=wb_valid[n] && wb_meta[n].line_addr==coh_addr_t'(s2_q[p].req.paddr>>6);
            words={s2_words_q[p][1][hit_way[p]],s2_words_q[p][0][hit_way[p]]};raw=format(words,s2_q[p].req);
            decision[p]='0;decision[p].valid=s2_q[p].valid && !killed(s2_q[p].req);
            decision[p].src=s2_q[p].req.src;decision[p].lq_tag=s2_q[p].req.lq_tag;decision[p].sq_idx=s2_q[p].req.sq_idx;
            decision[p].rdata=raw;decision[p].status=DC_OK;
            decision[p].exc=s2_q[p].req.exc;decision[p].head=s2_q[p].req.head;
            decision[p].paddr=s2_q[p].req.paddr;decision[p].need_d=s2_q[p].req.need_d;decision[p].io=s2_q[p].req.permission.io;
            privileged=s2_q[p].internal || s2_q[p].req.is_rob_head;
            want_m=s2_q[p].req.write || s2_q[p].req.is_sta || s2_q[p].req.src==DC_SRC_AMO;
            v=victim(plru_q[set_idx]);
            // Walk PLRU candidate then wrap past locked ways; invalid first.
            begin int start;start=v;v=-1;
                for(int d=0;d<WAYS;d++) if(v<0 && !locked_q[set_idx][(start+d)%WAYS]) v=(start+d)%WAYS;
                for(int w=WAYS-1;w>=0;w--) if(!locked_q[set_idx][w] && s2_tags_q[p][w].state==COH_I) v=w;
            end
            if(hit[p] && hit_state[p]==COH_S && want_m) v=hit_way[p];
            can_alloc=v>=0 && ms_free && alloc_lane<0 && !external_mutation && !ps_valid_q &&
                int'(ms_free_count)>=(privileged ? 1:1+(N==1 ? 0:CFG.dcache.mshr_reserve)) &&
                (v<0 || s2_tags_q[p][v].state==COH_I || (hit[p] && hit_state[p]==COH_S && want_m) || wb_free);
            if(s2_q[p].req.is_sta) can_alloc&=CFG.dcache.rfo_enable &&
                int'(ms_free_count)>=2+(N==1 ? 0:CFG.dcache.mshr_reserve);
            if(decision[p].valid) begin
                if(s2_q[p].req.exc.valid) decision[p].status=DC_ERROR;
                else if(s2_q[p].req.translation_miss) begin decision[p].status=DC_REPLAY;decision[p].reason=LDW_TLB_MISS;end
                else if(s2_q[p].req.permission.high_addr || !s2_q[p].req.permission.pmp_ok || !s2_q[p].req.permission.exists ||
                    (s2_q[p].req.permission.io && s2_q[p].internal) ||
                    (s2_q[p].req.src==DC_SRC_AMO && !(s2_q[p].req.amo_op inside {AMO_LR,AMO_SC} ?
                        s2_q[p].req.permission.rsrv_ok:s2_q[p].req.permission.amo_ok)) ||
                    (s2_q[p].req.permission.io && !CFG.lsu.heu_enable)) begin
                    decision[p].status=DC_ERROR;
                    decision[p].exc='{valid:1'b1,cause:((s2_q[p].req.write || s2_q[p].req.is_sta) ?
                        EXCEPTION_CAUSE_STORE_ACCESS_FAULT:EXCEPTION_CAUSE_LOAD_ACCESS_FAULT),tval:s2_q[p].req.vaddr};
                end else if((s2_q[p].req.src==DC_SRC_AMO || s2_q[p].req.permission.io) &&
                    (int'(s2_q[p].req.paddr) & ((1<<int'(s2_q[p].req.size))-1))!=0 ||
                    int'(s2_q[p].req.paddr[5:0])+dc_bytes(s2_q[p].req)>64) begin
                    decision[p].status=DC_ERROR;decision[p].exc='{valid:1'b1,cause:((s2_q[p].req.write || s2_q[p].req.is_sta) ?
                        EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED:EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED),tval:s2_q[p].req.vaddr};
                end else if(s2_q[p].req.check_only) begin
                    if(s2_q[p].req.split && s2_q[p].req.permission.io) begin
                        decision[p].status=DC_ERROR;decision[p].exc='{valid:1'b1,cause:(s2_q[p].req.write ?
                            EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED:EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED),tval:s2_q[p].req.vaddr};
                    end
                end else if(s2_q[p].req.permission.io) begin decision[p].status=DC_REPLAY;decision[p].reason=LDW_HEAD;
                end else if(s2_q[p].req.src==DC_SRC_AMO && s2_q[p].req.amo_op==AMO_SC && !rsv_ok[p]) begin
                    decision[p].rdata=1;decision[p].sc_fail=1;
                end else if(s2_q[p].snap || (external_mutation && mutation_set==set_idx)) begin decision[p].status=DC_REPLAY;decision[p].reason=LDW_SNAP;end
                else if(s2_q[p].conflict) begin decision[p].status=DC_REPLAY;decision[p].reason=LDW_CONFLICT;end
                else if(s2_q[p].bank) begin decision[p].status=DC_REPLAY;decision[p].reason=LDW_BANK;end
                else if(s2_q[p].req.blocked) begin decision[p].status=DC_REPLAY;decision[p].reason=LDW_OLDER_STORE_ADDR;end
                else if(s2_q[p].req.forward_valid && !want_m) begin
                    decision[p].rdata=format({64'b0,s2_q[p].req.forward_data},aligned);
                end else if(s2_q[p].req.is_sta) begin
                    // STA completes without waiting for ownership; RFO is optional.
                    if((!hit[p] || hit_state[p]==COH_S) && same_ms<0 && !same_wb && can_alloc) alloc_lane=p;
                end else if(hit[p] && (!want_m || hit_state[p]==COH_E || hit_state[p]==COH_M)) begin
                    if(want_m && !(s2_q[p].req.src==DC_SRC_AMO && s2_q[p].req.amo_op==AMO_LR)) begin
                        if(ps_valid_q || ps_lane>=0 || external_mutation || line_launch_q[0].kind!=LINE_NONE) begin decision[p].status=DC_REPLAY;decision[p].reason=LDW_CONFLICT;end
                        else if(s2_q[p].req.src==DC_SRC_PTE_AD &&
                            (s2_q[p].ad.epoch!=cur_epoch_i || s2_words_q[p][0][hit_way[p]]!=s2_q[p].ad.expected_pte)) decision[p].sc_fail=1;
                        else ps_lane=p;
                    end
                end else if(same_ms>=0) begin decision[p].status=DC_MISS_WAIT;decision[p].reason=LDW_MSHR;decision[p].mshr_id=COH_ID_W'(same_ms);end
                else if(same_wb) begin decision[p].status=DC_REPLAY;decision[p].reason=LDW_WB_LINE;end
                else if(can_alloc) begin alloc_lane=p;decision[p].status=DC_MISS_WAIT;decision[p].reason=LDW_MSHR;decision[p].mshr_id=ms_free_id;end
                else begin
                    decision[p].status=DC_REPLAY;
                    if(external_mutation || ps_valid_q || alloc_lane>=0) decision[p].reason=LDW_CONFLICT;
                    else if(v>=0 && s2_tags_q[p][v].state!=COH_I && !(hit[p] && hit_state[p]==COH_S && want_m) && !wb_free)
                        decision[p].reason=LDW_WB_LINE;
                    else decision[p].reason=LDW_MSHR_FULL;
                end
                if(alloc_lane==p) begin
                    alloc_way=v;upgrade=hit[p] && hit_state[p]==COH_S && want_m;
                    alloc_victim=!upgrade && s2_tags_q[p][v].state!=COH_I;
                    ms_alloc=1;wb_alloc=alloc_victim;
                    alloc_txn.line_addr=coh_addr_t'(s2_q[p].req.paddr>>6);alloc_txn.is_getm=want_m;
                    alloc_txn.atomic=s2_q[p].req.src==DC_SRC_AMO;
                    alloc_txn.way=DC_WAY_W'(v);alloc_txn.upgrade=upgrade;
                    alloc_txn.wb_wait=alloc_victim;alloc_txn.wb_id=wb_free_id;
                    alloc_wb.line_addr=coh_addr_t'({s2_tags_q[p][v].tag,set_idx});
                    alloc_wb.has_data=s2_tags_q[p][v].state==COH_M;alloc_wb.way=DC_WAY_W'(v);
                end
            end
        end
        // STA Replay is handled by LSU as an address-only recheck; no ownership wait.
        internal_finish=0;
        for(int p=0;p<P;p++) begin
            ld_resp_o[p]=s2_q[p].internal || (ps_lane==p && s2_q[p].req.head) ? '0:decision[p];
            if(s2_q[p].internal && decision[p].valid &&
                (decision[p].status==DC_ERROR ||
                 (s2_q[p].req.src==DC_SRC_STORE_DRAIN && decision[p].status!=DC_OK) ||
                 (decision[p].status==DC_OK && (!s2_q[p].req.write || decision[p].sc_fail)))) internal_finish=1;
        end
        st_resp_o='0;ptw_resp_o='0;pte_ad_resp_o='0;
        for(int p=0;p<P;p++) if(s2_q[p].internal && internal_finish) begin
            if(s2_q[p].req.src==DC_SRC_PTW) ptw_resp_o=decision[p];
            if(s2_q[p].req.src==DC_SRC_STORE_DRAIN) st_resp_o=decision[p];
            if(s2_q[p].req.src==DC_SRC_PTE_AD) pte_ad_resp_o='{valid:1'b1,updated:1'b0,
                mismatch:(decision[p].status==DC_OK && decision[p].sc_fail),access_fault:(decision[p].status==DC_ERROR)};
        end
        if(ps_write) begin
            if(ps_is_ad_q) pte_ad_resp_o='{valid:1'b1,updated:1'b1,mismatch:1'b0,access_fault:1'b0};
            else if(ps_req_q.head) ld_resp_o[IP]=ps_resp_q;
            else begin st_resp_o='0;st_resp_o.valid=1;st_resp_o.src=DC_SRC_STORE_DRAIN;st_resp_o.sq_idx=ps_req_q.sq_idx;end
        end
        wake_o='{valid:ms_install_done,mshr_id:line_launch_q[1].id,err:line_launch_q[1].txn.err,
            mshr_free:ms_free_pulse,wb_free:wb_free_pulse};
        perf_o='0;
        perf_o[BE_RSV_PROBE_HOLD_CYCLE]=BE_PERF_INC_W'(probe_pending && rsv_window && rsv_line==probe_snp.addr);
        for(int p=0;p<P;p++) if(decision[p].valid && decision[p].status==DC_OK && s2_q[p].req.src==DC_SRC_AMO && !s2_q[p].req.check_only) begin
            perf_o[BE_LR_EXEC]+=BE_PERF_INC_W'(s2_q[p].req.amo_op==AMO_LR);
            perf_o[BE_SC_FAIL]+=BE_PERF_INC_W'(decision[p].sc_fail);
            perf_o[BE_AMO_EXEC]+=BE_PERF_INC_W'(!(s2_q[p].req.amo_op inside {AMO_LR,AMO_SC}));
        end
        perf_o[BE_DC_MSHR_ALLOC]=BE_PERF_INC_W'(ms_alloc);
        perf_o[BE_DC_MSHR_OCCUPANCY]=BE_PERF_INC_W'(N-int'(ms_free_count));
        perf_o[BE_DC_WB_PUT]=BE_PERF_INC_W'(wb_put && wb_put_ready);
        perf_o[BE_DC_PROBE]=BE_PERF_INC_W'(probe_issue);
        for(int p=0;p<P;p++) if(decision[p].valid) begin
            perf_o[BE_DC_HIT_UNDER_MISS]+=BE_PERF_INC_W'(decision[p].status==DC_OK && !s2_q[p].req.is_sta && !s2_q[p].req.write && hit[p] && int'(ms_free_count)<N);
            perf_o[BE_DC_MSHR_MERGE]+=BE_PERF_INC_W'(decision[p].status==DC_MISS_WAIT && !(ms_alloc && alloc_lane==p));
            perf_o[BE_DC_BANK_CONFLICT]+=BE_PERF_INC_W'(decision[p].reason==LDW_BANK);
            perf_o[BE_DC_MSHR_FULL]+=BE_PERF_INC_W'(decision[p].reason==LDW_MSHR_FULL);
            perf_o[BE_DC_REPLAY_SNAP]+=BE_PERF_INC_W'(decision[p].reason==LDW_SNAP);
            perf_o[BE_RFO_ISSUED]+=BE_PERF_INC_W'(s2_q[p].req.is_sta && ms_alloc && alloc_lane==p);
            perf_o[BE_RFO_DROPPED]+=BE_PERF_INC_W'(CFG.dcache.rfo_enable && s2_q[p].req.is_sta && decision[p].status==DC_OK && (!hit[p] || hit_state[p]==COH_S) && !(ms_alloc && alloc_lane==p));
            perf_o[BE_RFO_USEFUL]+=BE_PERF_INC_W'(ps_lane==p && rfo_q[SW'(s2_q[p].req.paddr>>6)][hit_way[p]]);
        end
        tag_change=0;tag_set='0;tag_way=0;tag_new='0;
        if(ms_alloc && alloc_victim) begin
            tag_change=1;tag_set=SW'(s2_q[alloc_lane].req.paddr>>6);tag_way=alloc_way;
            tag_new=s2_tags_q[alloc_lane][alloc_way];tag_new.state=COH_I;
        end
        if(ps_write) begin
            tag_change=1;tag_set=SW'(ps_req_q.paddr>>6);tag_way=ps_way_q;
            tag_new='{state:COH_M,tag:TW'(ps_req_q.paddr>>(6+SW))};
        end
        if(probe_done && line_state_q!=COH_I) begin
            tag_change=1;tag_set=SW'(line_result_q.addr);tag_way=line_way_q;
            tag_new='{state:(probe_snp.op==COH_INV ? COH_I:COH_S),tag:TW'(line_result_q.addr>>SW)};
        end
        if(ms_install_done) begin
            tag_change=1;tag_set=SW'(line_launch_q[1].addr);tag_way=int'(line_launch_q[1].way);
            tag_new='{state:(line_launch_q[1].txn.err ? COH_I:line_launch_q[1].txn.grant_e ? COH_E:COH_S),
                tag:TW'(line_launch_q[1].addr>>SW)};
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            atomic_hold_q<=0;atomic_timer_q<=0;atomic_line_q<=0;atomic_live_q<='0;ps_resp_q<='0;
            init_q<=0;init_done_q<=0;s1_q<='{default:'0};s2_q<='{default:'0};
            line_launch_q<='{default:'0};line_read_q<='0;line_result_q<='0;
            line_data_q<=0;line_state_q<=COH_I;line_way_q<=0;ps_valid_q<=0;ps_req_q<='0;ps_ad_q<='0;
            ps_way_q<=0;ps_is_ad_q<=0;ps_internal_q<=0;up_held_q<=0;up_probe_q<=0;
            internal_valid_q<=0;internal_inpipe_q<=0;internal_wait_q<=0;internal_reason_q<=LDW_NONE;
            internal_mshr_q<=0;internal_req_q<='0;internal_ad_q<='0;
            internal_launch_valid_q<='{default:0};internal_launch_q<='{default:'0};internal_ad_launch_q<='{default:'0};
            fatal_o<='0;
        end else begin
            // A cancelled HEU still drains its retained coherence request.
            // Keep the transaction's protocol classification, but only a live
            // head retry may arm the bounded post-install probe guard.
            if(ms_alloc) atomic_live_q[ms_free_id]<=alloc_txn.atomic;
            for(int p=0;p<P;p++) if(decision[p].valid && decision[p].status==DC_MISS_WAIT &&
                s2_q[p].req.src==DC_SRC_AMO && ms_state[decision[p].mshr_id]!=DM_IDLE &&
                ms_txn[decision[p].mshr_id].atomic) atomic_live_q[decision[p].mshr_id]<=1;
            if(ms_install_done) atomic_live_q[line_launch_q[1].id]<=0;
            if(flush_i) atomic_live_q<='0;
            if(atomic_hold_q) begin
                atomic_timer_q<=atomic_timer_q+1;
                assert(atomic_timer_q<CFG.dcache.atomic_hold_max) else $fatal(1,"atomic install retry exceeded bound");
                for(int p=0;p<P;p++) if(decision[p].valid && s2_q[p].req.src==DC_SRC_AMO &&
                    !s2_q[p].req.check_only && coh_addr_t'(s2_q[p].req.paddr>>6)==atomic_line_q) atomic_hold_q<=0;
                if(flush_i) atomic_hold_q<=0;
            end
            if(ms_install_done && line_launch_q[1].txn.atomic && atomic_live_q[line_launch_q[1].id] &&
                !line_launch_q[1].txn.err && !flush_i) begin
                atomic_hold_q<=1;atomic_timer_q<=0;atomic_line_q<=line_launch_q[1].addr;
            end
            if(!init_done_q) begin
                for(int p=0;p<P;p++) for(int w=0;w<WAYS;w++) tags_q[p][init_q][w]<='0;
                for(int w=0;w<WAYS;w++) begin locked_q[init_q][w]<=0;rfo_q[init_q][w]<=0;end
                plru_q[init_q]<=0;
                if(init_q==SETS-1) init_done_q<=1;else init_q<=init_q+1;
            end
            line_launch_q[0]<=line_choose;line_launch_q[1]<=line_launch_q[0];
            internal_launch_valid_q[0]<=internal_fire;internal_launch_valid_q[1]<=internal_launch_valid_q[0];
            internal_launch_q[0]<=internal_choose;internal_launch_q[1]<=internal_launch_q[0];
            internal_ad_launch_q[0]<=internal_ad_choose;internal_ad_launch_q[1]<=internal_ad_launch_q[0];
            if(internal_fire) begin
                internal_valid_q<=1;internal_inpipe_q<=1;internal_wait_q<=0;
                internal_req_q<=internal_choose;internal_ad_q<=internal_ad_choose;
            end
            for(int p=0;p<P;p++) begin
                s1_q[p]<=s0[p];s2_q[p]<=s1_q[p];
                if(!s1_q[p].internal) s2_q[p].req<=ld_s1_i[p];
                s1_q[p].req.br_mask<=s0[p].req.br_mask & ~(resolution_valid_i ? (CKPT_N'(1)<<resolution_tag_i):'0);
                s2_q[p].req.br_mask<=s1_q[p].req.br_mask & ~(resolution_valid_i ? (CKPT_N'(1)<<resolution_tag_i):'0);
                s2_q[p].valid<=s1_q[p].valid && !killed(s1_q[p].req);
                if(s0[p].valid) begin
                    for(int w=0;w<WAYS;w++) tag_read_q[p][w]<=tags_q[p][SW'(s0[p].req.vaddr>>6)][w];
                end
                for(int w=0;w<WAYS;w++) begin
                    s2_tags_q[p][w]<=tag_read_q[p][w];
                    s2_words_q[p][0][w]<=bank_read_q[int'(s1_q[p].req.vaddr[5:3])][w];
                    s2_words_q[p][1][w]<=bank_read_q[(int'(s1_q[p].req.vaddr[5:3])+1)%BANKS][w];
                end
                if(dma_invalidate_o && SW'(s0[p].req.vaddr>>6)==SW'(dma_line_o)) s1_q[p].snap<=1;
                if(dma_invalidate_o && SW'(s1_q[p].req.vaddr>>6)==SW'(dma_line_o)) s2_q[p].snap<=1;
                if(tag_change && SW'(s0[p].req.vaddr>>6)==tag_set) s1_q[p].snap<=1;
                if(tag_change && SW'(s1_q[p].req.vaddr>>6)==tag_set) s2_q[p].snap<=1;
                if(s2_q[p].internal && decision[p].valid && decision[p].status!=DC_OK) begin
                    internal_inpipe_q<=0;internal_wait_q<=1;
                    internal_reason_q<=decision[p].reason;internal_mshr_q<=decision[p].mshr_id;
                    if(decision[p].status==DC_MISS_WAIT && wake_o.valid && wake_o.mshr_id==decision[p].mshr_id) begin
                        internal_wait_q<=0;
                        if(wake_o.err) internal_req_q.exc<='{valid:1'b1,cause:(s2_q[p].req.write ?
                            o3_isa_pkg::EXCEPTION_CAUSE_STORE_ACCESS_FAULT:o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ACCESS_FAULT),tval:s2_q[p].req.vaddr};
                    end
                    if(decision[p].reason==LDW_MSHR_FULL && wake_o.mshr_free) internal_wait_q<=0;
                    if(decision[p].reason==LDW_WB_LINE && wake_o.wb_free) internal_wait_q<=0;
                    if(decision[p].status==DC_ERROR || s2_q[p].req.src==DC_SRC_STORE_DRAIN) begin internal_valid_q<=0;internal_wait_q<=0;end
                end
            end
            // Shared bank read: same-set requests may consume the same output.
            for(int b=0;b<BANKS;b++) begin
                int selected;selected=-1;
                for(int p=0;p<P;p++) if(s0[p].valid && !s0[p].conflict && !s0[p].bank &&
                    (int'(s0[p].req.vaddr[5:3])==b || ((int'(s0[p].req.vaddr[2:0])+(1<<int'(s0[p].req.size))>8) && (int'(s0[p].req.vaddr[5:3])+1)%BANKS==b))) selected=p;
                if(selected>=0) for(int w=0;w<WAYS;w++) bank_read_q[b][w]<=data_q[b][w][SW'(s0[selected].req.vaddr>>6)];
            end
            line_read_q<=line_launch_q[1];line_result_q<=line_read_q;
            if(line_launch_q[1].kind==LINE_PROBE || line_launch_q[1].kind==LINE_WB) begin
                for(int b=0;b<BANKS;b++) for(int w=0;w<WAYS;w++) line_words_q[b][w]<=data_q[b][w][SW'(line_launch_q[1].addr)];
                for(int w=0;w<WAYS;w++) line_tags_q[w]<=tags_q[0][SW'(line_launch_q[1].addr)][w];
            end
            if(line_read_q.kind==LINE_PROBE || line_read_q.kind==LINE_WB) begin
                int w;w=int'(line_read_q.way);line_state_q<=COH_I;
                if(line_read_q.kind==LINE_PROBE) begin w=0;
                    for(int n=0;n<WAYS;n++) if(line_tags_q[n].state!=COH_I && line_tags_q[n].tag==TW'(line_read_q.addr>>SW)) begin
                        w=n;line_state_q<=line_tags_q[n].state;
                    end
                end
                line_way_q<=w;
                for(int b=0;b<BANKS;b++) line_data_q[b*64+:64]<=line_words_q[b][w];
            end
            if(tag_change) for(int p=0;p<P;p++) tags_q[p][tag_set][tag_way]<=tag_new;
            if(ms_install_done) begin
                locked_q[SW'(line_launch_q[1].addr)][line_launch_q[1].way]<=0;
                if(!line_launch_q[1].txn.err) begin
                    plru_q[SW'(line_launch_q[1].addr)]<=touch(plru_q[SW'(line_launch_q[1].addr)],int'(line_launch_q[1].way));
                    if(!line_launch_q[1].txn.ack_e) for(int b=0;b<BANKS;b++)
                        data_q[b][line_launch_q[1].way][SW'(line_launch_q[1].addr)]<=line_launch_q[1].txn.refill[b*64+:64];
                end
            end
            if(ps_write) begin
                for(int i=0;i<8;i++) if(ps_req_q.wmask[i]) begin
                    int off,b,byte_idx;off=int'(ps_req_q.paddr[5:0])+i;b=(off/8)%BANKS;byte_idx=off%8;
                    data_q[b][ps_way_q][SW'(ps_req_q.paddr>>6)][byte_idx*8+:8]<=ps_req_q.wdata[i*8+:8];
                end
                ps_valid_q<=0;
                if(ps_internal_q) begin internal_valid_q<=0;internal_inpipe_q<=0;end
                rfo_q[SW'(ps_req_q.paddr>>6)][ps_way_q]<=0;
            end
            if(ps_lane>=0) begin
                ps_valid_q<=1;ps_req_q<=s2_q[ps_lane].req;ps_way_q<=hit_way[ps_lane];
                ps_internal_q<=s2_q[ps_lane].internal;ps_resp_q<=decision[ps_lane];
                if(s2_q[ps_lane].req.src==DC_SRC_AMO) begin
                    ps_req_q.wdata<=s2_q[ps_lane].req.amo_op==AMO_SC ? s2_q[ps_lane].req.wdata:amo_new[ps_lane];
                    ps_req_q.wmask<=byte_mask(s2_q[ps_lane].req.size);
                    if(s2_q[ps_lane].req.amo_op==AMO_SC) ps_resp_q.rdata<=0;
                end
                ps_is_ad_q<=s2_q[ps_lane].req.src==DC_SRC_PTE_AD;ps_ad_q<=s2_q[ps_lane].ad;
                if(s2_q[ps_lane].req.src==DC_SRC_PTE_AD) ps_req_q.wdata<=s2_q[ps_lane].ad.expected_pte |
                    (s2_q[ps_lane].ad.set_a ? 64'h40:0) | (s2_q[ps_lane].ad.set_d ? 64'h80:0);
            end
            if(ms_alloc) begin
                locked_q[SW'(alloc_txn.line_addr)][alloc_way]<=1;
                rfo_q[SW'(alloc_txn.line_addr)][alloc_way]<=s2_q[alloc_lane].req.is_sta;
            end
            for(int p=0;p<P;p++) if(decision[p].valid && decision[p].status==DC_OK && hit[p] && !external_mutation && !s2_q[p].req.permission.io && !s2_q[p].req.check_only)
                plru_q[SW'(s2_q[p].req.paddr>>6)]<=touch(plru_q[SW'(s2_q[p].req.paddr>>6)],hit_way[p]);
            if(internal_finish) begin internal_valid_q<=0;internal_inpipe_q<=0;internal_wait_q<=0;end
            if(internal_wait_q) begin
                case(internal_reason_q)
                    LDW_MSHR:if(wake_o.valid && wake_o.mshr_id==internal_mshr_q) begin
                        internal_wait_q<=0;
                        if(wake_o.err) begin
                            internal_req_q.exc<='{valid:1'b1,cause:(internal_req_q.write ? o3_isa_pkg::EXCEPTION_CAUSE_STORE_ACCESS_FAULT:o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ACCESS_FAULT),tval:internal_req_q.vaddr};
                        end
                    end
                    LDW_MSHR_FULL:if(wake_o.mshr_free) internal_wait_q<=0;
                    LDW_WB_LINE:if(wake_o.wb_free) internal_wait_q<=0;
                    default:internal_wait_q<=0;
                endcase
            end
            if(rsp_up_valid_o && !rsp_up_ready_i && !up_held_q) begin up_held_q<=1;up_probe_q<=choose_probe;end
            if(rsp_up_valid_o && rsp_up_ready_i) up_held_q<=0;
            if(l2_req_valid_o) for(int n=0;n<WN;n++) assert(!wb_valid[n] || wb_meta[n].line_addr!=l2_req_o.addr);
            for(int p=0;p<P;p++) if(ld_req_valid_i[p] && !killed(ld_req_i[p])) assert(ld_req_ready_o[p]) else $fatal(1,"CPU S0 missing IS reservation");
        end
    end
`ifndef SYNTHESIS
    // Y13: shadow recomputation has no fanout into the functional S2 logic.
    always_ff @(posedge clk) if(!rst) for(int p=0;p<P;p++)
        if(s2_q[p].valid && !killed(s2_q[p].req) && !s2_q[p].req.translation_miss && !s2_q[p].req.exc.valid &&
            s2_q[p].req.src!=DC_SRC_STORE_DRAIN)
            assert(s2_q[p].req.permission==dc_permissions(s2_q[p].req,pmp_i,s2_q[p].internal ? 2'd1:priv_i))
                else $fatal(1,"Y13 permission mismatch src=%0d PA=%h",s2_q[p].req.src,s2_q[p].req.paddr);
`endif
    assign idle_o=init_done_q && int'(ms_free_count)==N && !ps_valid_q && !internal_valid_q &&
        !s1_q[0].valid && !s2_q[0].valid && !s1_q[P-1].valid && !s2_q[P-1].valid &&
        !(|{wb_valid[0],wb_valid[WN-1]}) && !probe_pending && !probe_ack;
    // An accepted RMW reserves exactly its decision edge and the next PS edge.
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst && ps_valid_q && ps_req_q.src==DC_SRC_AMO)
        assert(ps_write) else $fatal(1,"AMO RMW exceeded two-edge window");
`endif
    initial begin
        assert(BANKS==8 && CFG.dcache.line_bytes==64 && SETS*CFG.dcache.line_bytes<=4096);
        assert(WAYS>=2 && (WAYS&(WAYS-1))==0 && SETS>=2 && (SETS&(SETS-1))==0);
        assert(N>=1 && N<=4 && WN>=1 && WN<=2 && CFG.lsu.mem_pipes inside {1,2});
    end
endmodule
