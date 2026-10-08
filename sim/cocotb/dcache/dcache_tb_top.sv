module dcache_tb_top import o3_types_pkg::*; #(
    parameter int SETS=64,WAYS=8,MSHRS=4,WBS=2,
    parameter bit RFO=1
)(input logic clk,rst,
    input logic context_valid_i=1'b0,input logic [1:0] test_priv_i=2'd3,
    input logic rsv_clear_i=1'b0,
    input logic [1:0] cpu_valid, output logic [1:0] cpu_ready,
    input dcache_req_t cpu0,cpu1,s1_cpu0,s1_cpu1,
    output dcache_resp_t resp0,resp1,
    input rob_idx_t rob_head_i,
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
    output logic idle_o,output fatal_evt_t fatal_o,output be_perf_t perf_o,
    output logic init_done,
    output logic mon_ps_valid,mon_ps_write,mon_probe_hold,mon_probe_read,mon_ps_alloc,
    output logic mon_rsv_valid,mon_rsv_window,mon_atomic_hold,
    output logic dma_invalidate_o,output coh_addr_t dma_line_o,output logic irreversible_o,
    output logic pte_a_write_o,output coh_addr_t pte_a_line_o,
    output logic [MSHRS-1:0] mon_ms_valid,
    output logic [WBS-1:0] mon_wb_valid,
    output logic [SETS*WAYS*2-1:0] mon_state,
    output logic [SETS*WAYS*26-1:0] mon_addr,
    output logic [SETS*(WAYS-1)-1:0] mon_plru,
    output logic [31:0] widths
);
    pmp_state_t pmp_test;
    always_comb begin pmp_test=pmp_i;pmp_test.dec=pmp_decode(pmp_i.entries);end
    function automatic o3_cfg_pkg::backend_cfg_t test_config();
        o3_cfg_pkg::backend_cfg_t c;c=o3_cfg_pkg::O3_CFG.be;
        c.dcache.sets=SETS;c.dcache.ways=WAYS;c.dcache.mshrs=MSHRS;
        c.dcache.wb_buffers=WBS;c.dcache.rfo_enable=RFO;return c;
    endfunction
    localparam o3_cfg_pkg::backend_cfg_t CFG=test_config();
    logic ld_req_valid_i[2],ld_req_ready_o[2];
    dcache_req_t ld_req_i[2],ld_s1_i[2];dcache_resp_t ld_resp_o[2];
    logic [1:0] priv_i;
    assign priv_i=context_valid_i ? test_priv_i:2'd3;
    assign ld_req_valid_i='{cpu_valid[0],cpu_valid[1]};
    assign ld_req_i='{cpu0,cpu1};
    always_comb begin
        ld_s1_i='{s1_cpu0,s1_cpu1};
        for(int p=0;p<2;p++) begin
            ld_s1_i[p].priv=priv_i;
            ld_s1_i[p].permission=dc_permissions(ld_s1_i[p],pmp_test,priv_i);
        end
    end
    assign cpu_ready={ld_req_ready_o[1],ld_req_ready_o[0]};
    assign resp0=ld_resp_o[0];assign resp1=ld_resp_o[1];
    dcache #(.CFG(CFG)) dut(.pmp_i(pmp_test),.*);
    assign init_done=dut.init_done_q;
    assign mon_ps_valid=dut.ps_valid_q;assign mon_ps_write=dut.ps_write;
    assign mon_ps_alloc=dut.ps_lane>=0;
    assign mon_probe_hold=dut.probe_hold;assign mon_probe_read=dut.probe_read;
    assign mon_rsv_valid=dut.rsv_valid;assign mon_rsv_window=dut.rsv_window;
    assign mon_atomic_hold=dut.atomic_hold_q;
    assign widths={8'(LQ_IDX_W),8'(SQ_IDX_W),8'(ROB_IDX_W),8'(CKPT_N)};
    for(genvar n=0;n<MSHRS;n++) assign mon_ms_valid[n]=dut.ms_state[n]!=DM_IDLE;
    for(genvar n=0;n<WBS;n++) assign mon_wb_valid[n]=dut.wb_valid[n];
    for(genvar s=0;s<SETS;s++) begin
        assign mon_plru[s*(WAYS-1)+:WAYS-1]=dut.plru_q[s];
        for(genvar w=0;w<WAYS;w++) begin
            localparam int K=s*WAYS+w;
            assign mon_state[K*2+:2]=dut.tags_q[0][s][w].state;
            assign mon_addr[K*26+:26]=26'({dut.tags_q[0][s][w].tag,$clog2(SETS)'(s)});
        end
    end
endmodule
