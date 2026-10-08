/** ITLB: L10 Sv39, 8x4 base pages + four superpages, tree PLRU.
 * N accepts a lookup and captures its context; N+1 returns hit/miss/fault.
 * A single queued/granted miss never blocks resident hits (X2). Faults are
 * delivered once on retry, cleared by kill/epoch. SFENCE VA uses two cycles.
 * L7c probes are hit-only and do not walk, consume faults, touch PLRU or count
 * demand ITLB events. Tests: sim/cocotb/mmu/.
 */
module sv39_tlb import o3_types_pkg::*; #(
    parameter bit INSTRUCTION=0
)(
    input logic clk,rst,kill_i,
    input logic lookup_valid_i,lookup_probe_i=1'b0,
    input vaddr_t lookup_vaddr_i,
    input logic lookup_store_i,
    input logic [1:0] priv_i,
    input logic sum_i,mxr_i,adue_i,
    input logic [3:0] mode_i,
    input asid_t asid_i,
    input logic [43:0] root_i,
    input xlate_epoch_t epoch_i,
    output logic resp_valid_o,
    output tlb_resp_t resp_o,
    output logic ptw_req_valid_o,
    input logic ptw_req_ready_i,
    output ptw_req_t ptw_req_o,
    input ptw_resp_t ptw_resp_i,
    input sfence_req_t sfence_i,
    output logic sfence_done_o
);
    typedef struct packed {
        logic valid;
        sv39_vpn_t vpn;
        asid_t asid;
        logic [43:0] ppn;
        logic [1:0] level;
        logic r,w,x,u,g,a,d;
    } entry_t;
    entry_t base_q[8][4],super_q[4],selected;
    logic [2:0] plru_q[8],sp_plru_q;
    logic probe_q;
    logic valid_q,store_q,translate_q,sum_q,mxr_q,adue_q;
    logic [1:0] priv_q;
    vaddr_t va_q;
    asid_t asid_q;
    xlate_epoch_t epoch_q,last_epoch_q;
    logic miss_q,granted_q,killed_q,fault_q,fault_access_q;
    ptw_req_t miss_req_q,query_q,fault_req_q;
    logic hit,pending_match,miss_now;
    int hit_way,hit_super,set_idx,victim,fill_set;
    sfence_req_t sf_q;
    logic sf_pending_q,sf_done_q;
    assign sfence_done_o=sf_done_q;
    assign ptw_req_valid_o=miss_q && !granted_q && !kill_i && miss_req_q.epoch==epoch_i;
    assign ptw_req_o=miss_req_q;
    always_comb begin
        query_q='{vpn:va_q[38:12],asid:asid_q,epoch:epoch_q,
            src:(INSTRUCTION ? PTW_SRC_IFETCH : PTW_SRC_DTLB),root_ppn:root_i,
            priv:priv_q,is_store:store_q,sum:sum_q,mxr:mxr_q,adue:adue_q};
        set_idx=int'(va_q[14:12]);selected='0;hit=0;hit_way=-1;hit_super=-1;
        for(int w=3;w>=0;w--) if(super_q[w].valid &&
            sv39_covers(super_q[w].vpn,va_q[38:12],super_q[w].level) &&
            (super_q[w].g || super_q[w].asid==asid_q)) begin
            selected=super_q[w];hit=1;hit_super=w;
        end
        for(int w=3;w>=0;w--) if(base_q[set_idx][w].valid &&
            base_q[set_idx][w].vpn==va_q[38:12] && (base_q[set_idx][w].g || base_q[set_idx][w].asid==asid_q)) begin
            selected=base_q[set_idx][w];hit=1;hit_way=w;hit_super=-1;
        end
        pending_match=fault_q && fault_req_q.vpn==va_q[38:12] && fault_req_q.asid==asid_q
            && fault_req_q.epoch==epoch_q && fault_req_q.is_store==store_q
            && fault_req_q.priv==priv_q && fault_req_q.sum==sum_q && fault_req_q.mxr==mxr_q;
        resp_valid_o=valid_q && !kill_i && epoch_q==epoch_i && !sfence_i.valid && !sf_pending_q;
        resp_o='0;
        if(!translate_q) begin resp_o.hit=1;resp_o.ppn=va_q[55:12];resp_o.perm_d=1;end
        else if(!sv39_canonical(va_q)) resp_o.page_fault=1;
        else if(pending_match && !probe_q) begin resp_o.access_fault=fault_access_q;resp_o.page_fault=!fault_access_q;end
        else if(!hit) resp_o.miss=1;
        else if(!sv39_perm({56'b0,selected.d,selected.a,selected.g,selected.u,selected.x,selected.w,selected.r,1'b1},
            priv_q,INSTRUCTION,store_q,sum_q,mxr_q) || !selected.a || (store_q && !selected.d && !adue_q)) resp_o.page_fault=1;
        else begin
            resp_o.hit=1;resp_o.ppn=selected.ppn;resp_o.level=selected.level;
            resp_o.perm_r=selected.r;resp_o.perm_w=selected.w;resp_o.perm_x=selected.x;
            resp_o.perm_u=selected.u;resp_o.perm_g=selected.g;resp_o.perm_a=selected.a;resp_o.perm_d=selected.d;
        end
        miss_now=resp_valid_o && resp_o.miss && !probe_q;
        fill_set=int'(ptw_resp_i.vpn[2:0]);victim=ptw_resp_i.level==0 ? mmu_plru_victim(plru_q[fill_set]) : mmu_plru_victim(sp_plru_q);
        for(int w=3;w>=0;w--) if(ptw_resp_i.level==0 ? !base_q[fill_set][w].valid : !super_q[w].valid) victim=w;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            probe_q<=0;valid_q<=0;miss_q<=0;granted_q<=0;killed_q<=0;fault_q<=0;sf_pending_q<=0;sf_done_q<=0;
            last_epoch_q<=epoch_i;miss_req_q<='0;fault_req_q<='0;fault_access_q<=0;
            va_q<=0;priv_q<=0;asid_q<=0;epoch_q<=0;store_q<=0;translate_q<=0;sum_q<=0;mxr_q<=0;adue_q<=0;sf_q<='0;
            sp_plru_q<=0;
            for(int s=0;s<8;s++) begin plru_q[s]<=0;for(int w=0;w<4;w++) base_q[s][w]<='0;end
            for(int w=0;w<4;w++) super_q[w]<='0;
        end else begin
            last_epoch_q<=epoch_i;sf_done_q<=0;
            valid_q<=lookup_valid_i && !kill_i && !sfence_i.valid && !sf_pending_q;
            if(lookup_valid_i) begin
                probe_q<=lookup_probe_i;va_q<=lookup_vaddr_i;store_q<=lookup_store_i;priv_q<=priv_i;
                translate_q<=mode_i==8 && priv_i!=3;asid_q<=asid_i;epoch_q<=epoch_i;
                sum_q<=sum_i;mxr_q<=mxr_i;adue_q<=adue_i;
            end
            if(resp_valid_o && resp_o.hit && translate_q && !probe_q) begin
                if(hit_way>=0) plru_q[set_idx]<=mmu_plru_touch(plru_q[set_idx],hit_way);
                else if(hit_super>=0) sp_plru_q<=mmu_plru_touch(sp_plru_q,hit_super);
            end
            if(pending_match && resp_valid_o && !probe_q) fault_q<=0;
            if(miss_now && !miss_q && !fault_q) begin
                miss_q<=1;granted_q<=0;killed_q<=0;miss_req_q<=query_q;
            end
            if(ptw_req_valid_o && ptw_req_ready_i) granted_q<=1;
            if(ptw_resp_i.valid && ptw_resp_i.src==(INSTRUCTION ? PTW_SRC_IFETCH : PTW_SRC_DTLB)
                && miss_q && granted_q && ptw_resp_i.epoch==miss_req_q.epoch) begin
                miss_q<=0;granted_q<=0;
                if(ptw_resp_i.epoch==epoch_i && !sfence_i.valid && !sf_pending_q) begin
                    if(ptw_resp_i.page_fault || ptw_resp_i.access_fault) begin
                        if(!killed_q && !kill_i) begin fault_q<=1;fault_access_q<=ptw_resp_i.access_fault;fault_req_q<=miss_req_q;end
                    end else if(ptw_resp_i.perm_a) begin
                        if(ptw_resp_i.level==0) begin
                            base_q[fill_set][victim]<='{valid:1'b1,vpn:ptw_resp_i.vpn,asid:ptw_resp_i.asid,
                                ppn:ptw_resp_i.ppn,level:ptw_resp_i.level,r:ptw_resp_i.perm_r,w:ptw_resp_i.perm_w,
                                x:ptw_resp_i.perm_x,u:ptw_resp_i.perm_u,g:ptw_resp_i.perm_g,a:ptw_resp_i.perm_a,d:ptw_resp_i.perm_d};
                            plru_q[fill_set]<=mmu_plru_touch(plru_q[fill_set],victim);
                        end else begin
                            super_q[victim]<='{valid:1'b1,vpn:ptw_resp_i.vpn,asid:ptw_resp_i.asid,
                                ppn:ptw_resp_i.ppn,level:ptw_resp_i.level,r:ptw_resp_i.perm_r,w:ptw_resp_i.perm_w,
                                x:ptw_resp_i.perm_x,u:ptw_resp_i.perm_u,g:ptw_resp_i.perm_g,a:ptw_resp_i.perm_a,d:ptw_resp_i.perm_d};
                            sp_plru_q<=mmu_plru_touch(sp_plru_q,victim);
                        end
                    end
                end
            end
            if(kill_i || epoch_i!=last_epoch_q) begin
                fault_q<=0;killed_q<=1;
                if(!granted_q) miss_q<=0;
            end
            if(sfence_i.valid) begin sf_q<=sfence_i;sf_pending_q<=1;fault_q<=0;end
            if(sf_pending_q) begin
                sf_pending_q<=0;sf_done_q<=1;
                for(int s=0;s<8;s++) for(int w=0;w<4;w++)
                    if(sfence_match(sf_q,base_q[s][w].vpn,0,base_q[s][w].g,base_q[s][w].asid)) base_q[s][w].valid<=0;
                for(int w=0;w<4;w++) if(sfence_match(sf_q,super_q[w].vpn,super_q[w].level,super_q[w].g,super_q[w].asid)) super_q[w].valid<=0;
            end
        end
    end
endmodule

module itlb import o3_types_pkg::*; #(parameter o3_cfg_pkg::frontend_cfg_t CFG)(
    input logic clk_i,rst_i,kill_i=1'b0,
    input logic s0_valid_i,s0_probe_i=1'b0,input vaddr_t s0_vaddr_i,
    output logic s1_valid_o,s1_hit_o,s1_miss_o,s1_g_o,
    output logic [PPN_W-1:0] s1_ppn_o,output logic [1:0] s1_level_o,
    output logic s1_page_fault_o,s1_access_fault_o,
    output logic ptw_req_valid_o,input logic ptw_req_ready_i,output ptw_req_t ptw_req_o,input ptw_resp_t ptw_resp_i,
    input fe_csr_t csr_i,input sfence_req_t sfence_i,output logic sfence_done_o,output fe_perf_t perf_o
);
    initial assert(CFG.itlb.entries==32 && CFG.itlb.ways==4) else $fatal(1,"L10 ITLB organization must match X4");
    tlb_resp_t resp;
    sv39_tlb #(.INSTRUCTION(1)) u_tlb(.clk(clk_i),.rst(rst_i),.kill_i(kill_i),
        .lookup_probe_i(s0_probe_i),.lookup_valid_i(s0_valid_i),.lookup_vaddr_i(s0_vaddr_i),.lookup_store_i(1'b0),
        .priv_i(csr_i.priv),.sum_i(1'b0),.mxr_i(1'b0),.adue_i(csr_i.adue),
        .mode_i(csr_i.satp_mode),.asid_i(csr_i.satp_asid),.root_i(csr_i.satp_ppn),.epoch_i(csr_i.epoch),
        .resp_valid_o(s1_valid_o),.resp_o(resp),.ptw_req_valid_o(ptw_req_valid_o),.ptw_req_ready_i(ptw_req_ready_i),
        .ptw_req_o(ptw_req_o),.ptw_resp_i(ptw_resp_i),.sfence_i(sfence_i),.sfence_done_o(sfence_done_o));
    assign s1_g_o=resp.perm_g;
    assign s1_hit_o=resp.hit;assign s1_miss_o=resp.miss;assign s1_ppn_o=resp.ppn;assign s1_level_o=resp.level;
    assign s1_page_fault_o=resp.page_fault;assign s1_access_fault_o=resp.access_fault;
    logic probe_q;
    always_ff @(posedge clk_i) if(rst_i) probe_q<=0;else probe_q<=s0_valid_i && s0_probe_i;
    always_comb begin perf_o='0;perf_o[PE_ITLB_MISS]=PERF_INC_W'(s1_valid_o && resp.miss && !probe_q);perf_o[PE_ITLB_HIT]=PERF_INC_W'(s1_valid_o && resp.hit && !probe_q);end
endmodule
