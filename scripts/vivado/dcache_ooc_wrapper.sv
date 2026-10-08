// Reused diagnostic from OOC snapshot 42968c23235bd812d2361fe4acd1fc018e7b2f73.
// Diagnostic only. Same backend CFG as default o3_core.
// Every data/control port, including rst, has one boundary register.
// clk is the sole clock and is deliberately not registered. DONT_TOUCH
// preserves the measuring boundaries in both retiming modes.
module dcache_ooc_wrapper import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,localparam int P=CFG.lsu.agu_pipes,
    localparam int SETS=CFG.dcache.sets,WAYS=CFG.dcache.ways,BANKS=CFG.dcache.banks,
    localparam int SW=$clog2(SETS),WW=$clog2(WAYS),TW=MEM_PADDR_W-6-SW,
    localparam int N=CFG.dcache.mshrs,WN=CFG.dcache.wb_buffers,
    localparam int IP=CFG.lsu.mem_pipes-1
)(input logic clk,rst,
    input logic ld_req_valid_i[P],output logic ld_req_ready_o[P],input dcache_req_t ld_req_i[P],
    input dcache_req_t ld_s1_i[P],output dcache_resp_t ld_resp_o[P],
    input rob_idx_t rob_head_i,
    input logic rsv_clear_i,input logic [1:0] priv_i,
    output logic dma_invalidate_o,output coh_addr_t dma_line_o,output logic irreversible_o,
    output logic pte_a_write_o,output coh_addr_t pte_a_line_o,
    input logic flush_i,resolution_valid_i,resolution_mispredict_i,input br_tag_t resolution_tag_i,

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
    (* DONT_TOUCH = "yes" *) logic rst_boundary_q;
    (* DONT_TOUCH = "yes" *) logic ld_req_valid_i_boundary_q[P];
    (* DONT_TOUCH = "yes" *) logic ld_req_ready_o_boundary_q[P];
    logic ld_req_ready_o_dut[P];
    assign ld_req_ready_o = ld_req_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) dcache_req_t ld_req_i_boundary_q[P];
    (* DONT_TOUCH = "yes" *) dcache_req_t ld_s1_i_boundary_q[P];
    (* DONT_TOUCH = "yes" *) dcache_resp_t ld_resp_o_boundary_q[P];
    dcache_resp_t ld_resp_o_dut[P];
    assign ld_resp_o = ld_resp_o_boundary_q;
    (* DONT_TOUCH = "yes" *) rob_idx_t rob_head_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic rsv_clear_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] priv_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic dma_invalidate_o_boundary_q;
    logic dma_invalidate_o_dut;
    assign dma_invalidate_o = dma_invalidate_o_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_addr_t dma_line_o_boundary_q;
    coh_addr_t dma_line_o_dut;
    assign dma_line_o = dma_line_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic irreversible_o_boundary_q;
    logic irreversible_o_dut;
    assign irreversible_o = irreversible_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic pte_a_write_o_boundary_q;
    logic pte_a_write_o_dut;
    assign pte_a_write_o = pte_a_write_o_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_addr_t pte_a_line_o_boundary_q;
    coh_addr_t pte_a_line_o_dut;
    assign pte_a_line_o = pte_a_line_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic flush_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic resolution_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic resolution_mispredict_i_boundary_q;
    (* DONT_TOUCH = "yes" *) br_tag_t resolution_tag_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic full_line_busy_o_boundary_q;
    logic full_line_busy_o_dut;
    assign full_line_busy_o = full_line_busy_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic internal_busy_o_boundary_q;
    logic internal_busy_o_dut;
    assign internal_busy_o = internal_busy_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic st_req_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic st_req_ready_o_boundary_q;
    logic st_req_ready_o_dut;
    assign st_req_ready_o = st_req_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) dcache_req_t st_req_i_boundary_q;
    (* DONT_TOUCH = "yes" *) dcache_resp_t st_resp_o_boundary_q;
    dcache_resp_t st_resp_o_dut;
    assign st_resp_o = st_resp_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic ptw_req_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic ptw_req_ready_o_boundary_q;
    logic ptw_req_ready_o_dut;
    assign ptw_req_ready_o = ptw_req_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) dcache_req_t ptw_req_i_boundary_q;
    (* DONT_TOUCH = "yes" *) dcache_resp_t ptw_resp_o_boundary_q;
    dcache_resp_t ptw_resp_o_dut;
    assign ptw_resp_o = ptw_resp_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic pte_ad_req_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic pte_ad_req_ready_o_boundary_q;
    logic pte_ad_req_ready_o_dut;
    assign pte_ad_req_ready_o = pte_ad_req_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) pte_ad_req_t pte_ad_req_i_boundary_q;
    (* DONT_TOUCH = "yes" *) pte_ad_resp_t pte_ad_resp_o_boundary_q;
    pte_ad_resp_t pte_ad_resp_o_dut;
    assign pte_ad_resp_o = pte_ad_resp_o_boundary_q;
    (* DONT_TOUCH = "yes" *) xlate_epoch_t cur_epoch_i_boundary_q;
    (* DONT_TOUCH = "yes" *) pmp_state_t pmp_i_boundary_q;
    (* DONT_TOUCH = "yes" *) dc_wake_t wake_o_boundary_q;
    dc_wake_t wake_o_dut;
    assign wake_o = wake_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l2_req_valid_o_boundary_q;
    logic l2_req_valid_o_dut;
    assign l2_req_valid_o = l2_req_valid_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l2_req_ready_i_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_req_t l2_req_o_boundary_q;
    coh_req_t l2_req_o_dut;
    assign l2_req_o = l2_req_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l2_resp_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_rsp_down_t l2_resp_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic l2_resp_ready_o_boundary_q;
    logic l2_resp_ready_o_dut;
    assign l2_resp_ready_o = l2_resp_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic rsp_up_valid_o_boundary_q;
    logic rsp_up_valid_o_dut;
    assign rsp_up_valid_o = rsp_up_valid_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic rsp_up_ready_i_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_rsp_up_t rsp_up_o_boundary_q;
    coh_rsp_up_t rsp_up_o_dut;
    assign rsp_up_o = rsp_up_o_boundary_q;
    (* DONT_TOUCH = "yes" *) logic snp_valid_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic snp_ready_o_boundary_q;
    logic snp_ready_o_dut;
    assign snp_ready_o = snp_ready_o_boundary_q;
    (* DONT_TOUCH = "yes" *) coh_snp_t snp_i_boundary_q;
    (* DONT_TOUCH = "yes" *) logic idle_o_boundary_q;
    logic idle_o_dut;
    assign idle_o = idle_o_boundary_q;
    (* DONT_TOUCH = "yes" *) fatal_evt_t fatal_o_boundary_q;
    fatal_evt_t fatal_o_dut;
    assign fatal_o = fatal_o_boundary_q;
    (* DONT_TOUCH = "yes" *) be_perf_t perf_o_boundary_q;
    be_perf_t perf_o_dut;
    assign perf_o = perf_o_boundary_q;
    always_ff @(posedge clk) begin
        rst_boundary_q <= rst;
        ld_req_valid_i_boundary_q <= ld_req_valid_i;
        ld_req_ready_o_boundary_q <= ld_req_ready_o_dut;
        ld_req_i_boundary_q <= ld_req_i;
        ld_s1_i_boundary_q <= ld_s1_i;
        ld_resp_o_boundary_q <= ld_resp_o_dut;
        rob_head_i_boundary_q <= rob_head_i;
        rsv_clear_i_boundary_q <= rsv_clear_i;
        priv_i_boundary_q <= priv_i;
        dma_invalidate_o_boundary_q <= dma_invalidate_o_dut;
        dma_line_o_boundary_q <= dma_line_o_dut;
        irreversible_o_boundary_q <= irreversible_o_dut;
        pte_a_write_o_boundary_q <= pte_a_write_o_dut;
        pte_a_line_o_boundary_q <= pte_a_line_o_dut;
        flush_i_boundary_q <= flush_i;
        resolution_valid_i_boundary_q <= resolution_valid_i;
        resolution_mispredict_i_boundary_q <= resolution_mispredict_i;
        resolution_tag_i_boundary_q <= resolution_tag_i;
        full_line_busy_o_boundary_q <= full_line_busy_o_dut;
        internal_busy_o_boundary_q <= internal_busy_o_dut;
        st_req_valid_i_boundary_q <= st_req_valid_i;
        st_req_ready_o_boundary_q <= st_req_ready_o_dut;
        st_req_i_boundary_q <= st_req_i;
        st_resp_o_boundary_q <= st_resp_o_dut;
        ptw_req_valid_i_boundary_q <= ptw_req_valid_i;
        ptw_req_ready_o_boundary_q <= ptw_req_ready_o_dut;
        ptw_req_i_boundary_q <= ptw_req_i;
        ptw_resp_o_boundary_q <= ptw_resp_o_dut;
        pte_ad_req_valid_i_boundary_q <= pte_ad_req_valid_i;
        pte_ad_req_ready_o_boundary_q <= pte_ad_req_ready_o_dut;
        pte_ad_req_i_boundary_q <= pte_ad_req_i;
        pte_ad_resp_o_boundary_q <= pte_ad_resp_o_dut;
        cur_epoch_i_boundary_q <= cur_epoch_i;
        pmp_i_boundary_q <= pmp_i;
        wake_o_boundary_q <= wake_o_dut;
        l2_req_valid_o_boundary_q <= l2_req_valid_o_dut;
        l2_req_ready_i_boundary_q <= l2_req_ready_i;
        l2_req_o_boundary_q <= l2_req_o_dut;
        l2_resp_valid_i_boundary_q <= l2_resp_valid_i;
        l2_resp_i_boundary_q <= l2_resp_i;
        l2_resp_ready_o_boundary_q <= l2_resp_ready_o_dut;
        rsp_up_valid_o_boundary_q <= rsp_up_valid_o_dut;
        rsp_up_ready_i_boundary_q <= rsp_up_ready_i;
        rsp_up_o_boundary_q <= rsp_up_o_dut;
        snp_valid_i_boundary_q <= snp_valid_i;
        snp_ready_o_boundary_q <= snp_ready_o_dut;
        snp_i_boundary_q <= snp_i;
        idle_o_boundary_q <= idle_o_dut;
        fatal_o_boundary_q <= fatal_o_dut;
        perf_o_boundary_q <= perf_o_dut;
    end
    dcache #(.CFG(CFG)) u_dut (
        .clk(clk),
        .rst(rst_boundary_q),
        .ld_req_valid_i(ld_req_valid_i_boundary_q),
        .ld_req_ready_o(ld_req_ready_o_dut),
        .ld_req_i(ld_req_i_boundary_q),
        .ld_s1_i(ld_s1_i_boundary_q),
        .ld_resp_o(ld_resp_o_dut),
        .rob_head_i(rob_head_i_boundary_q),
        .rsv_clear_i(rsv_clear_i_boundary_q),
        .priv_i(priv_i_boundary_q),
        .dma_invalidate_o(dma_invalidate_o_dut),
        .dma_line_o(dma_line_o_dut),
        .irreversible_o(irreversible_o_dut),
        .pte_a_write_o(pte_a_write_o_dut),
        .pte_a_line_o(pte_a_line_o_dut),
        .flush_i(flush_i_boundary_q),
        .resolution_valid_i(resolution_valid_i_boundary_q),
        .resolution_mispredict_i(resolution_mispredict_i_boundary_q),
        .resolution_tag_i(resolution_tag_i_boundary_q),
        .full_line_busy_o(full_line_busy_o_dut),
        .internal_busy_o(internal_busy_o_dut),
        .st_req_valid_i(st_req_valid_i_boundary_q),
        .st_req_ready_o(st_req_ready_o_dut),
        .st_req_i(st_req_i_boundary_q),
        .st_resp_o(st_resp_o_dut),
        .ptw_req_valid_i(ptw_req_valid_i_boundary_q),
        .ptw_req_ready_o(ptw_req_ready_o_dut),
        .ptw_req_i(ptw_req_i_boundary_q),
        .ptw_resp_o(ptw_resp_o_dut),
        .pte_ad_req_valid_i(pte_ad_req_valid_i_boundary_q),
        .pte_ad_req_ready_o(pte_ad_req_ready_o_dut),
        .pte_ad_req_i(pte_ad_req_i_boundary_q),
        .pte_ad_resp_o(pte_ad_resp_o_dut),
        .cur_epoch_i(cur_epoch_i_boundary_q),
        .pmp_i(pmp_i_boundary_q),
        .wake_o(wake_o_dut),
        .l2_req_valid_o(l2_req_valid_o_dut),
        .l2_req_ready_i(l2_req_ready_i_boundary_q),
        .l2_req_o(l2_req_o_dut),
        .l2_resp_valid_i(l2_resp_valid_i_boundary_q),
        .l2_resp_i(l2_resp_i_boundary_q),
        .l2_resp_ready_o(l2_resp_ready_o_dut),
        .rsp_up_valid_o(rsp_up_valid_o_dut),
        .rsp_up_ready_i(rsp_up_ready_i_boundary_q),
        .rsp_up_o(rsp_up_o_dut),
        .snp_valid_i(snp_valid_i_boundary_q),
        .snp_ready_o(snp_ready_o_dut),
        .snp_i(snp_i_boundary_q),
        .idle_o(idle_o_dut),
        .fatal_o(fatal_o_dut),
        .perf_o(perf_o_dut)
    );
endmodule
