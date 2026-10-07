/** Shared L10 Sv39 walker: round-robin I/D, one physical request owner.
 * N accept snapshot; N+1 walk-cache lookup; REQ/WAIT/CHECK per level.
 * Physical S-mode R/PMA check precedes every read. Epoch invalidation drains
 * an accepted read and returns its old identity solely to release ownership.
 * Svadu: permission check precedes A/D CAS; only queue-head DCOMMIT sets D.
 * SFENCE waits for idle outside this module. Tests: sim/cocotb/mmu/.
 */
module ptw import o3_types_pkg::*; #(parameter o3_cfg_pkg::backend_cfg_t CFG)(
    input logic clk,rst,
    input logic itlb_req_valid_i,output logic itlb_req_ready_o,input ptw_req_t itlb_req_i,
    input logic dtlb_req_valid_i,output logic dtlb_req_ready_o,input ptw_req_t dtlb_req_i,
    output ptw_resp_t resp_o,
    output logic mem_req_valid_o,input logic mem_req_ready_i,output dcache_req_t mem_req_o,input dcache_resp_t mem_resp_i,
    input dmmu_csr_t csr_i,input pmp_state_t pmp_i,input sfence_req_t sfence_i,
    output logic sfence_done_o,idle_o,
    output logic a_upd_req_valid_o,input logic a_upd_req_ready_i,output pte_ad_req_t a_upd_req_o,input pte_ad_resp_t a_upd_resp_i,
    input logic rewalk_req_valid_i,output logic rewalk_req_ready_o,input ptw_req_t rewalk_req_i,
    output be_perf_t perf_o
);
    typedef enum logic[3:0] {IDLE,LOOKUP,REQ,WAIT,CHECK,RETURN,AD_REQ,AD_WAIT} state_t;
    state_t state_q;
    ptw_req_t req_q;
    logic last_d_q,g_q,af_q,pf_q;
    logic[1:0] level_q;
    logic[43:0] base_q;
    logic[63:0] pte_q;
    paddr_t pte_pa_q,address;
    logic wc_hit,wc_g,wc_fill,physical_ok,ad_physical_ok,bad_pte,leaf,permission_ok,misaligned,ad_needed;
    logic[1:0] wc_level;
    logic[43:0] wc_ppn;
    logic[8:0] vpn_index;
    assign idle_o=state_q==IDLE;
    assign rewalk_req_ready_o=idle_o && rewalk_req_valid_i;
    assign dtlb_req_ready_o=idle_o && !rewalk_req_valid_i && (!itlb_req_valid_i || !last_d_q);
    assign itlb_req_ready_o=idle_o && !rewalk_req_valid_i && (!dtlb_req_valid_i || last_d_q);
    assign vpn_index=level_q==2 ? req_q.vpn[26:18] : level_q==1 ? req_q.vpn[17:9] : req_q.vpn[8:0];
    assign address={base_q,vpn_index,3'b0};
    assign physical_ok=pma_main({8'b0,address},8) && pmp_allow(pmp_i,address,8,2'b01,1'b1,1'b0,1'b0);
    assign ad_physical_ok=pma_main({8'b0,pte_pa_q},8) && pmp_allow(pmp_i,pte_pa_q,8,2'b01,1'b1,1'b1,1'b0);
    assign ad_needed=!pte_q[6] || (req_q.src==PTW_SRC_DCOMMIT && !pte_q[7]);
    assign bad_pte=!pte_q[0] || (!pte_q[1] && pte_q[2]) || |pte_q[63:54];
    assign leaf=pte_q[1] || pte_q[3];
    assign misaligned=(level_q==2 && |pte_q[27:10]) || (level_q==1 && |pte_q[18:10]);
    assign permission_ok=sv39_perm(pte_q,req_q.priv,req_q.src==PTW_SRC_IFETCH,req_q.is_store,req_q.sum,req_q.mxr);
    assign wc_fill=state_q==CHECK && !af_q && !bad_pte && !leaf && level_q!=0 && req_q.epoch==csr_i.epoch;
    walk_cache #(.CFG(CFG)) u_walk_cache(.clk(clk),.rst(rst),.lookup_valid_i(state_q==LOOKUP),
        .lookup_vpn_i(req_q.vpn),.lookup_asid_i(req_q.asid),.hit_o(wc_hit),.hit_level_o(wc_level),
        .hit_next_ppn_o(wc_ppn),.hit_global_o(wc_g),.fill_valid_i(wc_fill),.fill_vpn_i(req_q.vpn),
        .fill_asid_i(req_q.asid),.fill_global_i(g_q || pte_q[5]),.fill_level_i(level_q),
        .fill_next_ppn_i(pte_q[53:10]),.fill_epoch_i(req_q.epoch),.cur_epoch_i(csr_i.epoch),.sfence_i(sfence_i));
    always_comb begin
        mem_req_valid_o=state_q==REQ && physical_ok && req_q.epoch==csr_i.epoch;
        mem_req_o='0;mem_req_o.src=DC_SRC_PTW;mem_req_o.paddr=address;mem_req_o.size=3;
        resp_o='0;resp_o.valid=state_q==RETURN;resp_o.vpn=req_q.vpn;resp_o.asid=req_q.asid;
        resp_o.epoch=req_q.epoch;resp_o.src=req_q.src;resp_o.ppn=pte_q[53:10];resp_o.level=level_q;
        resp_o.perm_r=pte_q[1];resp_o.perm_w=pte_q[2];resp_o.perm_x=pte_q[3];resp_o.perm_u=pte_q[4];
        resp_o.perm_g=g_q || pte_q[5];resp_o.perm_a=pte_q[6];resp_o.perm_d=pte_q[7];
        resp_o.access_fault=af_q;resp_o.page_fault=pf_q;resp_o.pte_paddr=pte_pa_q;resp_o.pte=pte_q;
        a_upd_req_valid_o=state_q==AD_REQ && req_q.epoch==csr_i.epoch && ad_physical_ok;
        a_upd_req_o='{pte_paddr:pte_pa_q,expected_pte:pte_q,set_a:1'b1,
            set_d:(req_q.src==PTW_SRC_DCOMMIT),epoch:req_q.epoch};
        sfence_done_o=sfence_i.valid && idle_o;
        perf_o='0;perf_o[BE_PTW_WALK]=BE_PERF_INC_W'(idle_o &&
            ((itlb_req_valid_i && itlb_req_ready_o) || (dtlb_req_valid_i && dtlb_req_ready_o) || rewalk_req_valid_i));
        perf_o[BE_WALK_CACHE_HIT]=BE_PERF_INC_W'(state_q==LOOKUP && wc_hit);
    end
    always_ff @(posedge clk) begin
        if(rst) begin state_q<=IDLE;req_q<='0;last_d_q<=0;g_q<=0;af_q<=0;pf_q<=0;level_q<=0;base_q<=0;pte_q<=0;pte_pa_q<=0;end
        else case(state_q)
            IDLE: if(rewalk_req_valid_i || (dtlb_req_valid_i && dtlb_req_ready_o) || (itlb_req_valid_i && itlb_req_ready_o)) begin
                if(rewalk_req_valid_i) req_q<=rewalk_req_i;
                else if(dtlb_req_valid_i && dtlb_req_ready_o) begin req_q<=dtlb_req_i;last_d_q<=1;end
                else begin req_q<=itlb_req_i;last_d_q<=0;end
                g_q<=0;af_q<=0;pf_q<=0;pte_q<=0;state_q<=LOOKUP;
            end
            LOOKUP: begin
                base_q<=wc_hit ? wc_ppn : req_q.root_ppn;level_q<=wc_hit ? wc_level-1'b1 : 2;
                g_q<=wc_hit && wc_g;state_q<=REQ;
            end
            REQ: if(req_q.epoch!=csr_i.epoch) begin pf_q<=1;state_q<=RETURN;end
                else if(!physical_ok) begin af_q<=1;state_q<=RETURN;end
                else if(mem_req_ready_i) begin pte_pa_q<=address;state_q<=WAIT;end
            WAIT: if(mem_resp_i.valid) begin pte_q<=mem_resp_i.rdata;af_q<=mem_resp_i.status==DC_ERROR;state_q<=CHECK;end
            CHECK: if(req_q.epoch!=csr_i.epoch || af_q || bad_pte || (leaf && (misaligned || !permission_ok || (!req_q.adue && (!pte_q[6] || (req_q.is_store && !pte_q[7]))))) || (!leaf && level_q==0)) begin
                pf_q<=!af_q;state_q<=RETURN;
            end else if(leaf) state_q<=ad_needed ? AD_REQ : RETURN;
            else begin g_q<=g_q || pte_q[5];base_q<=pte_q[53:10];level_q<=level_q-1'b1;state_q<=REQ;end
            AD_REQ: if(req_q.epoch!=csr_i.epoch) begin pf_q<=1;state_q<=RETURN;end
                else if(!ad_physical_ok) begin af_q<=1;state_q<=RETURN;end
                else if(a_upd_req_ready_i) state_q<=AD_WAIT;
            AD_WAIT: if(a_upd_resp_i.valid) begin
                if(req_q.epoch!=csr_i.epoch) begin pf_q<=1;state_q<=RETURN;end
                else if(a_upd_resp_i.access_fault) begin af_q<=1;state_q<=RETURN;end
                else if(a_upd_resp_i.mismatch) begin g_q<=0;af_q<=0;pf_q<=0;state_q<=LOOKUP;end
                else if(a_upd_resp_i.updated) begin pte_q[6]<=1;if(req_q.src==PTW_SRC_DCOMMIT) pte_q[7]<=1;state_q<=RETURN;end
            end
            RETURN: state_q<=IDLE;
            default: state_q<=IDLE;
        endcase
    end
endmodule
