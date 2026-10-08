module mmu_tb_top import o3_types_pkg::*; (
    input logic clk,rst,kill_i,
    input logic d1_valid_i,d1_store_i,input logic [63:0] d1_va_i,
    output logic d1_resp_o,d1_hit_o,d1_miss_o,d1_pf_o,d1_af_o,d1_dirty_o,
    output logic [55:0] d1_pa_o,
    input logic d_commit_i,output logic d_commit_ready_o,d_commit_done_o,d_commit_exc_o,
    input logic i_probe_i,
    output logic i_walk_o,output fe_perf_t i_perf_o,
    input logic i_valid_i,d_valid_i,d_store_i,input logic [63:0] i_va_i,d_va_i,
    input logic [3:0] mode_i,input logic [1:0] priv_i,input logic sum_i,mxr_i,adue_i,
    input logic [15:0] asid_i,input logic [43:0] root_i,input logic [7:0] epoch_i,
    input logic sf_valid_i,sf_rs1_x0_i,sf_rs2_x0_i,input logic[63:0] sf_va_i,input logic[15:0] sf_asid_i,
    input logic mem_ready_i,mem_valid_i,mem_fault_i,input logic[63:0] mem_data_i,
    input logic deny_read_i,deny_write_i,
    output logic mem_req_o,output logic[55:0] mem_addr_o,
    output logic i_resp_o,i_hit_o,i_miss_o,i_pf_o,i_af_o,d_resp_o,d_hit_o,d_miss_o,d_pf_o,d_af_o,d_dirty_o,
    output logic[55:0] i_pa_o,d_pa_o,output logic idle_o,sf_done_o,
    output logic ad_req_o,output logic[55:0] ad_addr_o,output logic[63:0] ad_expected_o,
    output logic ad_set_a_o,ad_set_d_o,
    input logic ad_ready_i,ad_valid_i,ad_updated_i,ad_mismatch_i,ad_fault_i
);
    fe_csr_t fe;dmmu_csr_t csr;sfence_req_t sf;pmp_state_t pmp;
    ptw_req_t i_req,d_req;ptw_resp_t resp;dcache_req_t mem_req;dcache_resp_t mem_resp;
    logic i_req_valid,i_ready,d_req_valid,d_ready,i_resp;
    logic[43:0] i_ppn;logic[1:0] i_level;
    logic dv[2],ds[2],dr[2];vaddr_t da[2];tlb_resp_t dp[2];logic i_sf,d_sf;
    pte_ad_req_t ad_req,ptw_ad;pte_ad_resp_t ad_resp,ptw_ad_resp;
    logic ptw_ad_valid,ptw_ad_ready,rewalk_valid,rewalk_ready;
    ptw_req_t rewalk_req;exc_info_t d_exc;
    always_comb begin
        fe='{fe_feat:'0,priv:priv_i,adue:adue_i,satp_mode:mode_i,satp_asid:asid_i,satp_ppn:root_i,epoch:xlate_epoch_t'(epoch_i)};
        csr='{priv_eff:priv_i,sum:sum_i,mxr:mxr_i,adue:adue_i,satp_mode:mode_i,
            satp_asid:asid_i,satp_ppn:root_i,epoch:xlate_epoch_t'(epoch_i),default:'0};
        sf='{valid:sf_valid_i,rs1_is_x0:sf_rs1_x0_i,rs2_is_x0:sf_rs2_x0_i,vaddr:sf_va_i,asid:sf_asid_i};
        pmp='0;pmp.entries[0].addr=54'h3fffffffffffff;
        pmp.entries[0].cfg=deny_read_i ? 8'h18 : deny_write_i ? 8'h19 : 8'h1f;
        dv[0]=d_valid_i;ds[0]=d_store_i;da[0]=d_va_i;dv[1]=d1_valid_i;ds[1]=d1_store_i;da[1]=d1_va_i;
        mem_resp='{valid:mem_valid_i,src:DC_SRC_PTW,status:(mem_fault_i ? DC_ERROR : DC_OK),reason:LDW_NONE,rdata:mem_data_i,default:'0};
        ad_resp='{valid:ad_valid_i,updated:ad_updated_i,mismatch:ad_mismatch_i,access_fault:ad_fault_i};
        pmp.dec=pmp_decode(pmp.entries);
    end
    itlb #(.CFG(o3_cfg_pkg::O3_CFG.fe)) i_tlb(.clk_i(clk),.rst_i(rst),.kill_i(kill_i),
        .s0_probe_i(i_probe_i),.s0_valid_i(i_valid_i),.s0_vaddr_i(i_va_i),.s1_valid_o(i_resp_o),.s1_hit_o(i_hit_o),.s1_miss_o(i_miss_o),
        .s1_ppn_o(i_ppn),.s1_level_o(i_level),.s1_page_fault_o(i_pf_o),.s1_access_fault_o(i_af_o),
        .ptw_req_valid_o(i_req_valid),.ptw_req_ready_i(i_ready),.ptw_req_o(i_req),.ptw_resp_i(resp),
        .csr_i(fe),.sfence_i(sf),.sfence_done_o(i_sf),.perf_o(i_perf_o));
    dtlb #(.CFG(o3_cfg_pkg::O3_CFG.be)) d_tlb(.clk(clk),.rst(rst),.kill_i(kill_i),
        .lookup_valid_i(dv),.lookup_vaddr_i(da),.lookup_is_store_i(ds),.resp_valid_o(dr),.resp_o(dp),
        .ptw_req_valid_o(d_req_valid),.ptw_req_ready_i(d_ready),.ptw_req_o(d_req),.ptw_resp_i(resp),
        .csr_i(csr),.sfence_i(sf),.sfence_done_o(d_sf),.perf_o());
    assign i_walk_o=i_req_valid;
    assign i_pa_o=sv39_pa(i_ppn,i_va_i,i_level);
    assign d1_resp_o=dr[1];assign d1_hit_o=dp[1].hit;assign d1_miss_o=dp[1].miss;
    assign d1_pf_o=dp[1].page_fault;assign d1_af_o=dp[1].access_fault;assign d1_dirty_o=dp[1].perm_d;
    assign d1_pa_o=sv39_pa(dp[1].ppn,d1_va_i,dp[1].level);
    assign d_resp_o=dr[0];assign d_hit_o=dp[0].hit;assign d_miss_o=dp[0].miss;
    assign d_pf_o=dp[0].page_fault;assign d_af_o=dp[0].access_fault;assign d_dirty_o=dp[0].perm_d;
    assign d_pa_o=sv39_pa(dp[0].ppn,d_va_i,dp[0].level);
    assign sf_done_o=i_sf && d_sf;
    ptw #(.CFG(o3_cfg_pkg::O3_CFG.be)) walker(.clk(clk),.rst(rst),.itlb_req_valid_i(i_req_valid),
        .itlb_req_ready_o(i_ready),.itlb_req_i(i_req),.dtlb_req_valid_i(d_req_valid),.dtlb_req_ready_o(d_ready),.dtlb_req_i(d_req),
        .resp_o(resp),.mem_req_valid_o(mem_req_o),.mem_req_ready_i(mem_ready_i),.mem_req_o(mem_req),.mem_resp_i(mem_resp),
        .csr_i(csr),.pmp_i(pmp),.sfence_i(sf),.sfence_done_o(),.idle_o(idle_o),
        .a_upd_req_valid_o(ptw_ad_valid),.a_upd_req_ready_i(ptw_ad_ready),.a_upd_req_o(ptw_ad),.a_upd_resp_i(ptw_ad_resp),
        .rewalk_req_valid_i(rewalk_valid),.rewalk_req_ready_o(rewalk_ready),.rewalk_req_i(rewalk_req),.perf_o());
    pte_ad_updater #(.CFG(o3_cfg_pkg::O3_CFG.be)) updater(.clk(clk),.rst(rst),
        .ptw_a_req_valid_i(ptw_ad_valid),.ptw_a_req_ready_o(ptw_ad_ready),.ptw_a_req_i(ptw_ad),.ptw_a_resp_o(ptw_ad_resp),
        .st_d_req_valid_i(d_commit_i),.st_d_req_ready_o(d_commit_ready_o),.st_d_vaddr_i(d_va_i),.st_d_sq_idx_i('0),
        .st_d_done_o(d_commit_done_o),.st_d_exc_o(d_exc),.rewalk_req_valid_o(rewalk_valid),.rewalk_req_ready_i(rewalk_ready),
        .rewalk_req_o(rewalk_req),.rewalk_resp_i(resp),.dc_req_valid_o(ad_req_o),.dc_req_ready_i(ad_ready_i),
        .dc_req_o(ad_req),.dc_resp_i(ad_resp),.csr_i(csr),.cur_epoch_i(xlate_epoch_t'(epoch_i)),.kill_i(kill_i),
        .rsv_conflict_o(),.busy_o(),.perf_o());
    assign d_commit_exc_o=d_exc.valid;
    assign mem_addr_o=mem_req.paddr;assign ad_addr_o=ad_req.pte_paddr;assign ad_expected_o=ad_req.expected_pte;
    assign ad_set_a_o=ad_req.set_a;assign ad_set_d_o=ad_req.set_d;
endmodule
