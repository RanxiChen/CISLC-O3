/** L8a dual lookup into the L10 shared TLB, one PTW miss slot. */
module l8a_dtlb_array import o3_types_pkg::*; #(
    parameter int PORTS
)(
    input logic clk,rst,kill_i,
    input logic lookup_valid_i[PORTS],
    input vaddr_t lookup_vaddr_i[PORTS],
    input logic lookup_store_i[PORTS],
    input logic [1:0] priv_i,
    input logic sum_i,mxr_i,adue_i,
    input logic [3:0] mode_i,
    input asid_t asid_i,
    input logic [43:0] root_i,
    input xlate_epoch_t epoch_i,
    output logic resp_valid_o[PORTS],
    output tlb_resp_t resp_o[PORTS],
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
    entry_t base_q[8][4],super_q[4],selected[PORTS];
    logic [2:0] plru_q[8],sp_plru_q;
    logic valid_q[PORTS],store_q[PORTS],translate_q[PORTS],sum_q[PORTS],mxr_q[PORTS],adue_q[PORTS];
    logic [1:0] priv_q[PORTS];
    vaddr_t va_q[PORTS];
    asid_t asid_q[PORTS];
    xlate_epoch_t epoch_q[PORTS],last_epoch_q;
    logic miss_q,granted_q,killed_q,fault_q,fault_access_q;
    ptw_req_t miss_req_q,query_q[PORTS],fault_req_q;
    logic hit[PORTS],pending_match[PORTS],miss_now[PORTS];
    int hit_way[PORTS],hit_super[PORTS],set_idx[PORTS],victim,fill_set;
    sfence_req_t sf_q;
    logic sf_pending_q,sf_done_q;
    assign sfence_done_o=sf_done_q;
    assign ptw_req_valid_o=miss_q && !granted_q && !kill_i && miss_req_q.epoch==epoch_i;
    assign ptw_req_o=miss_req_q;
    always_comb begin
        for(int p=0;p<PORTS;p++) begin
        query_q[p]='{vpn:va_q[p][38:12],asid:asid_q[p],epoch:epoch_q[p],
            src:PTW_SRC_DTLB,root_ppn:root_i,
            priv:priv_q[p],is_store:store_q[p],sum:sum_q[p],mxr:mxr_q[p],adue:adue_q[p]};
        set_idx[p]=int'(va_q[p][14:12]);selected[p]='0;hit[p]=0;hit_way[p]=-1;hit_super[p]=-1;
        for(int w=3;w>=0;w--) if(super_q[w].valid &&
            sv39_covers(super_q[w].vpn,va_q[p][38:12],super_q[w].level) &&
            (super_q[w].g || super_q[w].asid==asid_q[p])) begin
            selected[p]=super_q[w];hit[p]=1;hit_super[p]=w;
        end
        for(int w=3;w>=0;w--) if(base_q[set_idx[p]][w].valid &&
            base_q[set_idx[p]][w].vpn==va_q[p][38:12] && (base_q[set_idx[p]][w].g || base_q[set_idx[p]][w].asid==asid_q[p])) begin
            selected[p]=base_q[set_idx[p]][w];hit[p]=1;hit_way[p]=w;hit_super[p]=-1;
        end
        pending_match[p]=fault_q && fault_req_q.vpn==va_q[p][38:12] && fault_req_q.asid==asid_q[p]
            && fault_req_q.epoch==epoch_q[p] && fault_req_q.is_store==store_q[p]
            && fault_req_q.priv==priv_q[p] && fault_req_q.sum==sum_q[p] && fault_req_q.mxr==mxr_q[p];
        resp_valid_o[p]=valid_q[p] && !kill_i && epoch_q[p]==epoch_i && !sfence_i.valid && !sf_pending_q;
        resp_o[p]='0;
        if(!translate_q[p]) begin resp_o[p].hit=1;resp_o[p].ppn=va_q[p][55:12];resp_o[p].perm_d=1;end
        else if(!sv39_canonical(va_q[p])) resp_o[p].page_fault=1;
        else if(pending_match[p]) begin resp_o[p].access_fault=fault_access_q;resp_o[p].page_fault=!fault_access_q;end
        else if(!hit[p]) resp_o[p].miss=1;
        else if(!sv39_perm({56'b0,selected[p].d,selected[p].a,selected[p].g,selected[p].u,selected[p].x,selected[p].w,selected[p].r,1'b1},
            priv_q[p],1'b0,store_q[p],sum_q[p],mxr_q[p]) || !selected[p].a || (store_q[p] && !selected[p].d && !adue_q[p])) resp_o[p].page_fault=1;
        else begin
            resp_o[p].hit=1;resp_o[p].ppn=selected[p].ppn;resp_o[p].level=selected[p].level;
            resp_o[p].perm_r=selected[p].r;resp_o[p].perm_w=selected[p].w;resp_o[p].perm_x=selected[p].x;
            resp_o[p].perm_u=selected[p].u;resp_o[p].perm_g=selected[p].g;resp_o[p].perm_a=selected[p].a;resp_o[p].perm_d=selected[p].d;
        end
        miss_now[p]=resp_valid_o[p] && resp_o[p].miss;
        end
        fill_set=int'(ptw_resp_i.vpn[2:0]);victim=ptw_resp_i.level==0 ? mmu_plru_victim(plru_q[fill_set]) : mmu_plru_victim(sp_plru_q);
        for(int w=3;w>=0;w--) if(ptw_resp_i.level==0 ? !base_q[fill_set][w].valid : !super_q[w].valid) victim=w;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            valid_q<='{default:0};miss_q<=0;granted_q<=0;killed_q<=0;fault_q<=0;sf_pending_q<=0;sf_done_q<=0;
            last_epoch_q<=epoch_i;miss_req_q<='0;fault_req_q<='0;fault_access_q<=0;
            va_q<='{default:0};priv_q<='{default:0};asid_q<='{default:0};epoch_q<='{default:0};
            store_q<='{default:0};translate_q<='{default:0};sum_q<='{default:0};mxr_q<='{default:0};adue_q<='{default:0};sf_q<='0;
            sp_plru_q<=0;
            for(int s=0;s<8;s++) begin plru_q[s]<=0;for(int w=0;w<4;w++) base_q[s][w]<='0;end
            for(int w=0;w<4;w++) super_q[w]<='0;
        end else begin
            last_epoch_q<=epoch_i;sf_done_q<=0;
            for(int p=0;p<PORTS;p++) begin
            valid_q[p]<=lookup_valid_i[p] && !kill_i && !sfence_i.valid && !sf_pending_q;
            if(lookup_valid_i[p]) begin
                va_q[p]<=lookup_vaddr_i[p];store_q[p]<=lookup_store_i[p];priv_q[p]<=priv_i;
                translate_q[p]<=mode_i==8 && priv_i!=3;asid_q[p]<=asid_i;epoch_q[p]<=epoch_i;
                sum_q[p]<=sum_i;mxr_q[p]<=mxr_i;adue_q[p]<=adue_i;
            end
            if(resp_valid_o[p] && resp_o[p].hit && translate_q[p]) begin
                if(hit_way[p]>=0) plru_q[set_idx[p]]<=mmu_plru_touch(plru_q[set_idx[p]],hit_way[p]);
                else if(hit_super[p]>=0) sp_plru_q<=mmu_plru_touch(sp_plru_q,hit_super[p]);
            end
            if(pending_match[p] && resp_valid_o[p]) fault_q<=0;
            end
            // Port zero wins simultaneous misses; port one retries after this walk.
            begin int winner;winner=-1;
                for(int p=0;p<PORTS;p++) if(winner<0 && miss_now[p]) winner=p;
                if(winner>=0 && !miss_q && !fault_q) begin
                    miss_q<=1;granted_q<=0;killed_q<=0;miss_req_q<=query_q[winner];
                end
            end
            if(ptw_req_valid_o && ptw_req_ready_i) granted_q<=1;
            if(ptw_resp_i.valid && ptw_resp_i.src==PTW_SRC_DTLB
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
                    if((sf_q.rs1_is_x0 || (s==int'(sf_q.vaddr[14:12]) && base_q[s][w].vpn==sf_q.vaddr[38:12])) &&
                        (sf_q.rs2_is_x0 || (!base_q[s][w].g && base_q[s][w].asid==sf_q.asid))) base_q[s][w].valid<=0;
                for(int w=0;w<4;w++) if((sf_q.rs1_is_x0 || sv39_covers(super_q[w].vpn,sf_q.vaddr[38:12],super_q[w].level)) &&
                    (sf_q.rs2_is_x0 || (!super_q[w].g && super_q[w].asid==sf_q.asid))) super_q[w].valid<=0;
            end
        end
    end
endmodule

module dtlb import o3_types_pkg::*; #(parameter o3_cfg_pkg::backend_cfg_t CFG,
    localparam int PORTS=CFG.lsu.agu_pipes)(
    input logic clk,rst,kill_i,
    input logic lookup_valid_i[PORTS],input vaddr_t lookup_vaddr_i[PORTS],input logic lookup_is_store_i[PORTS],
    output logic resp_valid_o[PORTS],output tlb_resp_t resp_o[PORTS],
    output logic ptw_req_valid_o,input logic ptw_req_ready_i,output ptw_req_t ptw_req_o,input ptw_resp_t ptw_resp_i,
    input dmmu_csr_t csr_i,input sfence_req_t sfence_i,output logic sfence_done_o,output be_perf_t perf_o);
    l8a_dtlb_array #(.PORTS(PORTS)) u_tlb(.clk(clk),.rst(rst),.kill_i(kill_i),
        .lookup_valid_i(lookup_valid_i),.lookup_vaddr_i(lookup_vaddr_i),.lookup_store_i(lookup_is_store_i),
        .priv_i(csr_i.priv_eff),.sum_i(csr_i.sum),.mxr_i(csr_i.mxr),.adue_i(csr_i.adue),
        .mode_i(csr_i.satp_mode),.asid_i(csr_i.satp_asid),.root_i(csr_i.satp_ppn),.epoch_i(csr_i.epoch),
        .resp_valid_o(resp_valid_o),.resp_o(resp_o),.ptw_req_valid_o(ptw_req_valid_o),.ptw_req_ready_i(ptw_req_ready_i),
        .ptw_req_o(ptw_req_o),.ptw_resp_i(ptw_resp_i),.sfence_i(sfence_i),.sfence_done_o(sfence_done_o));
    always_comb begin
        perf_o='0;
        for(int p=0;p<PORTS;p++) perf_o[BE_DTLB_MISS]+=BE_PERF_INC_W'(resp_valid_o[p] && resp_o[p].miss);
    end
    initial assert(CFG.mmu.dtlb_entries==32 && CFG.mmu.dtlb_ways==4);
endmodule
