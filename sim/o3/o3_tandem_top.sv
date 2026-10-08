/** Whole-core retirement observer. Instruction images load into AXI RAM and
 * fetch through the real ICache and inclusive L2. Retirement is exported as
 * scalar lane fields.
 */
module o3_tandem_top
    import o3_types_pkg::*;
    import o3_pkg::*;
#(
    parameter int MEM_PIPES=2, MSHRS=4, RFO=1,
    localparam int AXI_ID_W = o3_cfg_pkg::O3_CFG.be.l2.axi_id_bits,
    localparam int AXI_DATA_W = o3_cfg_pkg::O3_CFG.be.l2.axi_data_bits
) (
    input logic clk_i, rst_i,
    input logic [PC_WIDTH-1:0] reset_pc_i,
    input logic axi_init_valid_i,
    input logic [PADDR_W-1:0] axi_init_addr_i,
    input logic [AXI_DATA_W-1:0] axi_init_data_i,
    input logic [AXI_DATA_W/8-1:0] axi_init_wmask_i,
    output logic done_o, fatal_o, inclusion_err_o,
    output logic cache_init_done_o,output logic [31:0] cfg_l2_sets_o,
    output logic [63:0] retired_inst_count_o,
    output logic [31:0] icache_refill_count_o,
    output logic [31:0] load_replay_count_o,
    output logic [31:0] correct_resolve_count_o, mispredict_count_o,
    output logic [o3_cfg_pkg::O3_CFG.core.commit_width-1:0] tandem_valid_o,
    output logic [o3_cfg_pkg::O3_CFG.core.commit_width-1:0] tandem_rd_write_o,
    output logic [INST_ID_WIDTH-1:0] tandem_instruction_id_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [ROB_IDX_WIDTH-1:0] tandem_rob_idx_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [PC_WIDTH-1:0] tandem_pc_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [ILEN-1:0] tandem_instruction_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [REG_ADDR_WIDTH-1:0] tandem_rd_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [1:0] tandem_mem_kind_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [XLEN-1:0] tandem_mem_addr_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [1:0] tandem_mem_size_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [XLEN-1:0] tandem_mem_data_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [o3_cfg_pkg::O3_CFG.core.commit_width-1:0] tandem_csr_valid_o, tandem_exc_valid_o,
    output logic [11:0] tandem_csr_addr_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [63:0] tandem_csr_wdata_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [63:0] tandem_exc_cause_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [63:0] tandem_exc_tval_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0],
    output logic [XLEN-1:0] tandem_rd_wdata_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0]
);
    // Passive startup observation lets cocotb retain its functional watchdog
    // while checking the new sequential default cache initialization separately.
    assign cache_init_done_o=u_core.u_l2_home.init_done_q && u_core.u_backend.u_dcache.init_done_q;
    assign cfg_l2_sets_o=o3_cfg_pkg::O3_CFG.be.l2.sets;
    localparam int RETIRE_W = o3_cfg_pkg::O3_CFG.core.commit_width;
    retire_info_t retire_info [RETIRE_W-1:0];
    logic awvalid, awready, wvalid, wready, bvalid, bready;
    logic arvalid, arready, rvalid, rready, wlast, rlast;
    logic [AXI_ID_W-1:0] awid, bid, arid, rid;
    logic [PADDR_W-1:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [AXI_DATA_W-1:0] wdata, rdata;
    logic [AXI_DATA_W/8-1:0] wstrb;

    logic [63:0] mtime_q;
    integer irq_m_soft_at,irq_m_timer_at,irq_m_ext_at,irq_s_ext_at;
    initial begin
        irq_m_soft_at=-1;irq_m_timer_at=-1;irq_m_ext_at=-1;irq_s_ext_at=-1;
        void'($value$plusargs("irq_m_soft_at=%d",irq_m_soft_at));
        void'($value$plusargs("irq_m_timer_at=%d",irq_m_timer_at));
        void'($value$plusargs("irq_m_ext_at=%d",irq_m_ext_at));
        void'($value$plusargs("irq_s_ext_at=%d",irq_s_ext_at));
    end
    always_ff @(posedge clk_i) if(rst_i) mtime_q<=0; else mtime_q<=mtime_q+1;
    function automatic o3_cfg_pkg::o3_cfg_t simulation_config();
        o3_cfg_pkg::o3_cfg_t c;c=o3_cfg_pkg::O3_CFG;
        c.be.lsu.mem_pipes=MEM_PIPES;c.be.dcache.mshrs=MSHRS;
        c.be.dcache.rfo_enable=1'(RFO);return c;
    endfunction
    localparam o3_cfg_pkg::o3_cfg_t SIM_CFG=simulation_config();
    initial begin assert(MEM_PIPES inside {1,2});assert(MSHRS inside {[1:4]});assert(RFO inside {0,1});end
    o3_core #(.CFG(SIM_CFG)) u_core (
        .clk_i(clk_i), .rst_i(rst_i), .reset_pc_i(reset_pc_i),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_awid(awid),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready), .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_arid(arid),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready), .m_axi_rid(rid),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .dma_req_valid_i(1'b0), .dma_req_ready_o(), .dma_req_i('0), .dma_resp_o(),
        .mtime_i(mtime_q),
        .irq_m_ext_i(irq_m_ext_at>=0 && mtime_q>=64'(irq_m_ext_at)),
        .irq_m_timer_i(irq_m_timer_at>=0 && mtime_q>=64'(irq_m_timer_at)),
        .irq_m_soft_i(irq_m_soft_at>=0 && mtime_q>=64'(irq_m_soft_at)),
        .irq_s_ext_i(irq_s_ext_at>=0 && mtime_q>=64'(irq_s_ext_at)),
        .fatal_o(fatal_o), .inclusion_err_o(inclusion_err_o),
        .done_o(done_o), .retired_inst_count_o(retired_inst_count_o),
        .retire_info_o(retire_info)
    );
    // Count actual ICache requests accepted by the RTL L2, not test responses.
    always_ff @(posedge clk_i) begin
        if (rst_i) icache_refill_count_o <= '0;
        else if (u_core.l1i_req_valid && u_core.l1i_req_ready)
            icache_refill_count_o <= icache_refill_count_o + 1'b1;
    end
    always_ff @(posedge clk_i) begin
        if (rst_i) load_replay_count_o <= '0;
        else begin
            int replayed;replayed=0;
            for(int p=0;p<o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes;p++)
                replayed+=int'(u_core.u_backend.lq_replay_valid[p] && u_core.u_backend.lq_replay_ready[p]);
            load_replay_count_o<=load_replay_count_o+32'(replayed);
        end
    end
    // Exec resolution is one-shot even if JAL link writeback is held.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            correct_resolve_count_o <= '0;
            mispredict_count_o <= '0;
        end else if (u_core.u_backend.exec_resolve_o.valid) begin
            if (u_core.u_backend.exec_resolve_o.mispredict)
                mispredict_count_o <= mispredict_count_o + 1'b1;
            else correct_resolve_count_o <= correct_resolve_count_o + 1'b1;
        end
    end
    o3_axi_ram #(.ADDR_W(PADDR_W), .ID_W(AXI_ID_W), .DATA_W(AXI_DATA_W)) u_axi_ram (
        .clk_i(clk_i), .rst_i(rst_i),
        .init_valid_i(axi_init_valid_i), .init_addr_i(axi_init_addr_i),
        .init_data_i(axi_init_data_i), .init_wmask_i(axi_init_wmask_i),
        .awvalid_i(awvalid), .awready_o(awready), .awid_i(awid),
        .awaddr_i(awaddr), .awlen_i(awlen), .awsize_i(awsize), .awburst_i(awburst),
        .wvalid_i(wvalid), .wready_o(wready), .wdata_i(wdata), .wstrb_i(wstrb), .wlast_i(wlast),
        .bvalid_o(bvalid), .bready_i(bready), .bid_o(bid), .bresp_o(bresp),
        .arvalid_i(arvalid), .arready_o(arready), .arid_i(arid),
        .araddr_i(araddr), .arlen_i(arlen), .arsize_i(arsize), .arburst_i(arburst),
        .rvalid_o(rvalid), .rready_i(rready), .rid_o(rid), .rdata_o(rdata),
        .rresp_o(rresp), .rlast_o(rlast)
    );
    for (genvar lane = 0; lane < RETIRE_W; lane++) begin : gen_retire
        assign tandem_csr_valid_o[lane]=retire_info[lane].csr_valid;
        assign tandem_csr_addr_o[lane]=retire_info[lane].csr_addr;
        assign tandem_csr_wdata_o[lane]=retire_info[lane].csr_wdata;
        assign tandem_exc_valid_o[lane]=retire_info[lane].exc_valid;
        assign tandem_exc_cause_o[lane]=retire_info[lane].exc_cause;
        assign tandem_exc_tval_o[lane]=retire_info[lane].exc_tval;
        assign tandem_valid_o[lane] = retire_info[lane].valid;
        assign tandem_rd_write_o[lane] = retire_info[lane].rd_write_en;
        assign tandem_instruction_id_o[lane] = retire_info[lane].instruction_id;
        assign tandem_rob_idx_o[lane] = retire_info[lane].rob_idx;
        assign tandem_pc_o[lane] = retire_info[lane].pc;
        assign tandem_instruction_o[lane] = retire_info[lane].instruction;
        assign tandem_rd_o[lane] = retire_info[lane].rd;
        assign tandem_rd_wdata_o[lane] = retire_info[lane].rd_wdata;
        assign tandem_mem_kind_o[lane] = retire_info[lane].mem.kind;
        assign tandem_mem_addr_o[lane] = retire_info[lane].mem.addr;
        assign tandem_mem_size_o[lane] = retire_info[lane].mem.size;
        assign tandem_mem_data_o[lane] = retire_info[lane].mem.data;
    end

    l10_event_checks l7_checks (
        .clk_i(clk_i),.rst_i(rst_i),
        .fe_sources_i('{u_core.u_frontend.perf_bpu,u_core.u_frontend.perf_ftq,
            u_core.u_frontend.perf_arb,u_core.u_frontend.perf_rq,u_core.u_frontend.perf_f0,
            u_core.u_frontend.perf_f1,u_core.u_frontend.perf_ibuf,u_core.u_frontend.perf_icache,
            u_core.u_frontend.perf_pf}),
        .be_sources_i('{u_core.u_backend.perf_commit,u_core.u_backend.perf_lsu,u_core.u_backend.perf_dcache,u_core.u_backend.perf_ptw,u_core.u_backend.perf_ad,u_core.l2_perf}),
        .fe_frontend_i(u_core.u_frontend.fe_perf_o),.fe_core_i(u_core.fe_perf),
        .fe_backend_i(u_core.u_backend.fe_perf_i),.fe_csr_i(u_core.u_backend.u_csr_file.fe_perf_i),
        .fe_hpm_i(u_core.u_backend.u_csr_file.u_hpm_counters.fe_perf_i),
        .be_backend_i(u_core.u_backend.be_perf),.be_hpm_i(u_core.u_backend.u_csr_file.u_hpm_counters.be_perf_i),
        .req_valid_i(u_core.u_backend.csr_req_valid),.req_i(u_core.u_backend.csr_req),
        .trap_i(u_core.u_backend.trap_update_valid),.retired_i(u_core.u_backend.retire_count_this_cycle),
        .cycle_i(u_core.u_backend.u_csr_file.u_hpm_counters.mcycle_q),
        .instret_i(u_core.u_backend.u_csr_file.u_hpm_counters.minstret_q),
        .counters_i(u_core.u_backend.u_csr_file.u_hpm_counters.counter_q),
        .selectors_i(u_core.u_backend.u_csr_file.u_hpm_counters.event_q),
        .priv_i(u_core.u_backend.priv),
        .inhibit_i(u_core.u_backend.u_csr_file.u_hpm_counters.inhibit_q),
        .accepted_i(u_core.u_frontend.redirect_o),.busy_i(u_core.u_frontend.recover_busy));

    int unsigned debug_cycle_q;
    always_ff @(posedge clk_i) begin
        if (rst_i) debug_cycle_q <= 0;
        else begin
            if ($test$plusargs("L1_DEBUG") && debug_cycle_q < 40) begin
                $display("[l1-fe] cycle=%0d alloc=%b/%b hold=%b recover=%b kill=%b demand=%b/%b rq=%b resp=%b deq=%b f0=%h f1=%h ibuf=%b be_ready=%b retired=%0d",
                    debug_cycle_q,
                    u_core.u_frontend.alloc_valid, u_core.u_frontend.alloc_ready,
                    u_core.u_frontend.sync_hold, u_core.u_frontend.recover_busy,
                    u_core.u_frontend.fe_kill.valid,
                    u_core.u_frontend.demand_valid, u_core.u_frontend.demand_ready,
                    u_core.u_frontend.rq_rsv_ready,
                    u_core.u_frontend.icache_resp.valid,
                    u_core.u_frontend.rq_deq_valid,
                    u_core.u_frontend.f0_valid, u_core.u_frontend.f1_valid,
                    u_core.fe_deliver_valid, u_core.be_fetch_ready,
                    retired_inst_count_o);
                $display("[l1-be] cycle=%0d pc=%h inst=%h fetch=%b decode=%b q=%0d rename=%0d issue=%b wb=%b rob=%b",
                    debug_cycle_q,
                    u_core.fe_deliver[0].pc, u_core.fe_deliver[0].instruction,
                    u_core.u_backend.fetch_fire, u_core.u_backend.decode_fire,
                    u_core.u_backend.uopq_deq_count,
                    u_core.u_backend.rename_accept_count,
                    u_core.u_backend.issueq_issue_valid,
                    u_core.u_backend.alu_result_q[0].valid,
                    u_core.u_backend.rob_retire_valid[0]);
            end
            if ($test$plusargs("L10_DEBUG") && debug_cycle_q >= 15500 && debug_cycle_q % 128 == 0) begin
                $display("[l10] cycle=%0d head=%b pc=%h done=%b exc=%b/%0d needsD=%b D=%b/%b/%b pending=%b refresh=%b fence=%b AG0=%b/%0d VA0=%h PTW=%0d epoch=%0d",
                    debug_cycle_q,u_core.u_backend.head_valid,u_core.u_backend.rob_head_info.pc,
                    u_core.u_backend.rob_head_info.complete,u_core.u_backend.rob_head_info.exc.valid,u_core.u_backend.rob_head_info.exc.cause,
                    u_core.u_backend.rob_head_info.needs_d,u_core.u_backend.st_d_valid,u_core.u_backend.st_d_ready,u_core.u_backend.st_d_done,
                    u_core.u_backend.u_load_store_unit.d_pending_q,u_core.u_backend.u_load_store_unit.d_refresh_q,u_core.u_backend.u_load_store_unit.d_fence_q,
                    u_core.u_backend.u_load_store_unit.ag_q[0].valid,u_core.u_backend.u_load_store_unit.ag_q[0].r.uop.rob_idx,
                    u_core.u_backend.u_load_store_unit.ag_q[0].r.va,u_core.u_backend.u_ptw.state_q,u_core.u_backend.t_dmmu_csr.epoch);
            end
            if ($test$plusargs("L8A_DEBUG") &&
                ((debug_cycle_q>=3750 && debug_cycle_q<4000) || debug_cycle_q%1024==0)) begin
                $display("[l8a] c=%0d head=%b/%0d pc=%h complete=%b exc=%b/%0d flush=%b M=%b IQ=%b grant=%b ready=%b/%b RR=%b AG=%b S1=%b S2=%b DC=%b/%0d/%0d FIFO=%0d EXC=%b/%0d ready=%b SQempty=%b SQreplay=%b LQreplay=%b",
                    debug_cycle_q,u_core.u_backend.head_valid,u_core.u_backend.rob_head,
                    u_core.u_backend.rob_head_info.pc,u_core.u_backend.rob_head_info.complete,
                    u_core.u_backend.rob_head_info.exc.valid,u_core.u_backend.rob_head_info.exc.cause,
                    u_core.u_backend.global_flush,u_core.u_backend.branch_mispredict,u_core.u_backend.mem_iq_issue_valid,
                    u_core.u_backend.mem_read_grant,u_core.u_backend.mem_issue_ready[0],u_core.u_backend.mem_issue_ready[1],
                    u_core.u_backend.mem_execute_q[0].valid,u_core.u_backend.u_load_store_unit.ag_q[0].valid,
                    u_core.u_backend.u_load_store_unit.s1_q[0].valid,u_core.u_backend.u_load_store_unit.s2_q[0].valid,
                    u_core.u_backend.t_dc_ld_resp[0].valid,u_core.u_backend.t_dc_ld_resp[0].status,u_core.u_backend.t_dc_ld_resp[0].reason,
                    u_core.u_backend.u_load_store_unit.count_q[0],u_core.u_backend.mem_exc_valid[0],
                    u_core.u_backend.mem_exc_idx[0],u_core.u_backend.mem_exc_ready[0],u_core.u_backend.t_sq_committed_empty,
                    u_core.u_backend.sq_replay_valid[0],u_core.u_backend.lq_replay_valid[0]);
            end
            if ($test$plusargs("L8A_AD_DEBUG") && debug_cycle_q>=16300 &&
                (debug_cycle_q<16600 || debug_cycle_q%1024==0)) begin
                $display("[l8a-ad] c=%0d owner=%0d pending=%b refresh=%b sq=%b/%b/%0d lq=%b/%b/%0d ag=%b/%0d s1=%b/%0d/%h sta=%b blocked=%b tlb=%b/%b D=%b s2=%b/%0d rsp=%b/%0d/%0d upd=%b/%0d exe=%b clear=%b",
                    debug_cycle_q,u_core.u_backend.u_load_store_unit.d_uop_q.rob_idx,
                    u_core.u_backend.u_load_store_unit.d_pending_q,u_core.u_backend.u_load_store_unit.d_refresh_q,
                    u_core.u_backend.sq_replay_valid[0],u_core.u_backend.sq_replay_ready[0],u_core.u_backend.sq_replay[0].uop.rob_idx,
                    u_core.u_backend.lq_replay_valid[0],u_core.u_backend.lq_replay_ready[0],u_core.u_backend.lq_replay[0].uop.rob_idx,
                    u_core.u_backend.u_load_store_unit.ag_q[0].valid,u_core.u_backend.u_load_store_unit.ag_q[0].r.uop.rob_idx,
                    u_core.u_backend.u_load_store_unit.s1_q[0].valid,u_core.u_backend.u_load_store_unit.s1_q[0].r.uop.rob_idx,
                    u_core.u_backend.t_dc_s1[0].paddr,u_core.u_backend.t_dc_s1[0].is_sta,u_core.u_backend.t_dc_s1[0].blocked,
                    u_core.u_backend.u_load_store_unit.tlb_rsp_valid[0],u_core.u_backend.u_load_store_unit.tlb_rsp[0].hit,
                    u_core.u_backend.u_load_store_unit.tlb_rsp[0].perm_d,
                    u_core.u_backend.u_load_store_unit.s2_q[0].valid,u_core.u_backend.u_load_store_unit.s2_q[0].r.uop.rob_idx,
                    u_core.u_backend.t_dc_ld_resp[0].valid,u_core.u_backend.t_dc_ld_resp[0].status,u_core.u_backend.t_dc_ld_resp[0].reason,
                    u_core.u_backend.sq_update[0],u_core.u_backend.mem_update[0].reason,u_core.u_backend.sq_execute_valid[0],u_core.u_backend.d_clear);
            end
            debug_cycle_q <= debug_cycle_q + 1;
            if ($test$plusargs("L5_DEBUG") && debug_cycle_q < 2000) begin
                $display("[l5] cycle=%0d head=%b/%0d pc=%h done=%b exc=%b flush=%b csr=%b serial=%b AG=%b/%b LDreq=%b/%b rsp=%b/%b SQreq=%b/%b SQrsp=%b",
                    debug_cycle_q,u_core.u_backend.head_valid,u_core.u_backend.rob_head_info.rob_idx,u_core.u_backend.rob_head_info.pc,
                    u_core.u_backend.rob_head_info.complete,u_core.u_backend.rob_head_info.exc.valid,u_core.u_backend.global_flush,
                    u_core.u_backend.csr_req_valid,u_core.u_backend.head_serial_done,
                    u_core.u_backend.u_load_store_unit.ag_q[0].valid,u_core.u_backend.u_load_store_unit.ag_q[1].valid,
                    u_core.u_backend.t_dc_ld_req_valid[0],u_core.u_backend.t_dc_ld_req_valid[1],
                    u_core.u_backend.t_dc_ld_resp[0].valid,u_core.u_backend.t_dc_ld_resp[1].valid,
                    u_core.u_backend.t_sq_dc_req_valid,u_core.u_backend.t_sq_dc_req_ready,u_core.u_backend.t_sq_dc_resp.valid);
            end
        end
    end
    // Read-only M6 measurements from the live DCache event interface.
    logic [63:0] l8a_sample_cycles_q,l8a_mshr_sum_q,l8a_rfo_issued_q,l8a_rfo_useful_q,l8a_bank_replays_q;
    logic [63:0] l8a_probe_q,l8a_writeback_q;
    always_ff @(posedge clk_i) begin
        if(rst_i) begin
            l8a_sample_cycles_q<=0;l8a_mshr_sum_q<=0;l8a_rfo_issued_q<=0;
            l8a_rfo_useful_q<=0;l8a_bank_replays_q<=0;l8a_probe_q<=0;l8a_writeback_q<=0;
        end else begin
            l8a_sample_cycles_q<=l8a_sample_cycles_q+1;
            l8a_mshr_sum_q<=l8a_mshr_sum_q+64'(u_core.u_backend.perf_dcache[BE_DC_MSHR_OCCUPANCY]);
            l8a_rfo_issued_q<=l8a_rfo_issued_q+64'(u_core.u_backend.perf_dcache[BE_RFO_ISSUED]);
            l8a_rfo_useful_q<=l8a_rfo_useful_q+64'(u_core.u_backend.perf_dcache[BE_RFO_USEFUL]);
            l8a_bank_replays_q<=l8a_bank_replays_q+64'(u_core.u_backend.perf_dcache[BE_DC_BANK_CONFLICT]);
            l8a_probe_q<=l8a_probe_q+64'(u_core.u_backend.perf_dcache[BE_DC_PROBE]);
            l8a_writeback_q<=l8a_writeback_q+64'(u_core.u_backend.perf_dcache[BE_DC_WB_PUT]);
        end
    end
    final begin
        if($test$plusargs("L8A_STATS"))
            $display("[l8a-stats] sample_cycles=%0d MSHR_sum=%0d MSHR_average=%0.6f RFO_issued=%0d RFO_useful=%0d bank_replays=%0d probes=%0d writebacks=%0d",
                l8a_sample_cycles_q,l8a_mshr_sum_q,
                l8a_sample_cycles_q==0 ? 0.0:real'(l8a_mshr_sum_q)/real'(l8a_sample_cycles_q),
                l8a_rfo_issued_q,l8a_rfo_useful_q,l8a_bank_replays_q,l8a_probe_q,l8a_writeback_q);
    end

endmodule

/** Single outstanding AXI4 read and write transaction, backed by 1 MiB RAM.
 * READ_LATENCY and READY_STALL_PERIOD provide deterministic delay/backpressure.
 * R and B payloads remain stable until the master accepts them.
 */
module o3_axi_ram #(
    parameter int ADDR_W = 40, ID_W = 4, DATA_W = 128,
    parameter int RAM_BYTES = 2 << 20,
    parameter int READ_LATENCY = 2,
    parameter int READY_STALL_PERIOD = 0
) (
    input logic clk_i, rst_i,
    input logic init_valid_i,
    input logic [ADDR_W-1:0] init_addr_i,
    input logic [DATA_W-1:0] init_data_i,
    input logic [DATA_W/8-1:0] init_wmask_i,
    input logic awvalid_i,
    output logic awready_o,
    input logic [ID_W-1:0] awid_i,
    input logic [ADDR_W-1:0] awaddr_i,
    input logic [7:0] awlen_i,
    input logic [2:0] awsize_i,
    input logic [1:0] awburst_i,
    input logic wvalid_i,
    output logic wready_o,
    input logic [DATA_W-1:0] wdata_i,
    input logic [DATA_W/8-1:0] wstrb_i,
    input logic wlast_i,
    output logic bvalid_o,
    input logic bready_i,
    output logic [ID_W-1:0] bid_o,
    output logic [1:0] bresp_o,
    input logic arvalid_i,
    output logic arready_o,
    input logic [ID_W-1:0] arid_i,
    input logic [ADDR_W-1:0] araddr_i,
    input logic [7:0] arlen_i,
    input logic [2:0] arsize_i,
    input logic [1:0] arburst_i,
    output logic rvalid_o,
    input logic rready_i,
    output logic [ID_W-1:0] rid_o,
    output logic [DATA_W-1:0] rdata_o,
    output logic [1:0] rresp_o,
    output logic rlast_o
);
    localparam int BEAT_BYTES = DATA_W / 8;
    localparam int RAM_WORDS = RAM_BYTES / BEAT_BYTES;
    localparam logic [ADDR_W-1:0] RAM_BASE = ADDR_W'(32'h8000_0000);
    localparam int PHASE_W = (READY_STALL_PERIOD < 2) ? 1 : $clog2(READY_STALL_PERIOD);
    logic [DATA_W-1:0] ram [RAM_WORDS];
    logic [PHASE_W-1:0] ready_phase_q;
    logic accept_window;
    logic write_active_q, read_active_q;
    logic [ADDR_W-1:0] write_addr_q, read_addr_q;
    logic [7:0] write_left_q, read_left_q;
    logic [2:0] write_size_q, read_size_q;
    logic [ID_W-1:0] write_id_q, read_id_q;
    logic write_error_q, read_error_q;
    int unsigned read_delay_q;

    function automatic logic in_range(input logic [ADDR_W-1:0] addr);
        return addr >= RAM_BASE && addr < RAM_BASE + ADDR_W'(RAM_BYTES);
    endfunction
    function automatic int unsigned word_index(input logic [ADDR_W-1:0] addr);
        return int'((addr - RAM_BASE) / ADDR_W'(BEAT_BYTES));
    endfunction
    assign accept_window = (READY_STALL_PERIOD <= 1) || (ready_phase_q != '0);
    assign awready_o = !write_active_q && !bvalid_o && accept_window;
    assign wready_o = write_active_q && !bvalid_o && accept_window;
    assign arready_o = !read_active_q && accept_window;
    assign rvalid_o = read_active_q && (read_delay_q == 0);
    assign rlast_o = rvalid_o && (read_left_q == 0);
    assign rid_o = read_id_q;
    assign rresp_o = (read_error_q || !in_range(read_addr_q)) ? 2'b10 : 2'b00;
    assign rdata_o = in_range(read_addr_q) ? ram[word_index(read_addr_q)] : '0;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ready_phase_q <= '0;
            write_active_q <= 1'b0;
            read_active_q <= 1'b0;
            write_addr_q <= '0;
            read_addr_q <= '0;
            write_left_q <= '0;
            read_left_q <= '0;
            write_size_q <= '0;
            read_size_q <= '0;
            write_id_q <= '0;
            read_id_q <= '0;
            write_error_q <= 1'b0;
            read_error_q <= 1'b0;
            read_delay_q <= 0;
            bvalid_o <= 1'b0;
            bid_o <= '0;
            bresp_o <= 2'b00;
        end else begin
            if (READY_STALL_PERIOD > 0)
                ready_phase_q <= (ready_phase_q == PHASE_W'(READY_STALL_PERIOD - 1))
                               ? '0 : ready_phase_q + 1'b1;
            if (awvalid_i && awready_o) begin
                write_active_q <= 1'b1;
                write_addr_q <= awaddr_i;
                write_left_q <= awlen_i;
                write_size_q <= awsize_i;
                write_id_q <= awid_i;
                write_error_q <= (awburst_i != 2'b01);
            end
            if (wvalid_i && wready_o) begin
                if (in_range(write_addr_q)) begin
                    for (int byte_idx = 0; byte_idx < BEAT_BYTES; byte_idx++)
                        if (wstrb_i[byte_idx])
                            ram[word_index(write_addr_q)][8*byte_idx +: 8]
                                <= wdata_i[8*byte_idx +: 8];
                end else write_error_q <= 1'b1;
                if (write_left_q == 0 || wlast_i) begin
                    write_active_q <= 1'b0;
                    bvalid_o <= 1'b1;
                    bid_o <= write_id_q;
                    bresp_o <= (write_error_q || !in_range(write_addr_q)
                             || (wlast_i != (write_left_q == 0))) ? 2'b10 : 2'b00;
                end else begin
                    write_left_q <= write_left_q - 1'b1;
                    write_addr_q <= write_addr_q + (ADDR_W'(1) << write_size_q);
                end
            end
            if (bvalid_o && bready_i) bvalid_o <= 1'b0;
            if (arvalid_i && arready_o) begin
                read_active_q <= 1'b1;
                read_addr_q <= araddr_i;
                read_left_q <= arlen_i;
                read_size_q <= arsize_i;
                read_id_q <= arid_i;
                read_error_q <= (arburst_i != 2'b01);
                read_delay_q <= READ_LATENCY;
            end else if (read_active_q) begin
                if (read_delay_q != 0) read_delay_q <= read_delay_q - 1;
                else if (rvalid_o && rready_i) begin
                    if (read_left_q == 0) read_active_q <= 1'b0;
                    else begin
                        read_left_q <= read_left_q - 1'b1;
                        read_addr_q <= read_addr_q + (ADDR_W'(1) << read_size_q);
                        read_delay_q <= READ_LATENCY;
                    end
                end
            end
        end
        if (init_valid_i && in_range(init_addr_i))
            for (int byte_idx = 0; byte_idx < BEAT_BYTES; byte_idx++)
                if (init_wmask_i[byte_idx])
                    ram[word_index(init_addr_i)][8*byte_idx +: 8]
                        <= init_data_i[8*byte_idx +: 8];
    end
endmodule

`include "sim/o3/tests/l10_event_checks.sv"
