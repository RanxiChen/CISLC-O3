/** Whole-core retirement observer. Instruction images load into AXI RAM and
 * fetch through the real ICache and inclusive L2. Retirement is exported as
 * scalar lane fields.
 */
module o3_tandem_top
    import o3_types_pkg::*;
    import o3_pkg::*;
#(
    localparam int AXI_ID_W = o3_cfg_pkg::O3_CFG.be.l2.axi_id_bits,
    localparam int AXI_DATA_W = o3_cfg_pkg::O3_CFG.be.l2.axi_data_bits
) (
    input logic clk_i, rst_i,
    input logic [PC_WIDTH-1:0] reset_pc_i,
    input logic dtcm_init_valid_i,
    input logic [XLEN-1:0] dtcm_init_addr_i, dtcm_init_wdata_i,
    input logic [7:0] dtcm_init_wmask_i,
    input logic axi_init_valid_i,
    input logic [PADDR_W-1:0] axi_init_addr_i,
    input logic [AXI_DATA_W-1:0] axi_init_data_i,
    input logic [AXI_DATA_W/8-1:0] axi_init_wmask_i,
    output logic done_o, fatal_o, inclusion_err_o,
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
    output logic [XLEN-1:0] tandem_rd_wdata_o [o3_cfg_pkg::O3_CFG.core.commit_width-1:0]
);
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

    o3_core u_core (
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
        .irq_m_ext_i(1'b0), .irq_m_timer_i(1'b0),
        .irq_m_soft_i(1'b0), .irq_s_ext_i(1'b0),
        .dtcm_init_valid_i(dtcm_init_valid_i), .dtcm_init_addr_i(dtcm_init_addr_i),
        .dtcm_init_wdata_i(dtcm_init_wdata_i), .dtcm_init_wmask_i(dtcm_init_wmask_i),
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
        else if (u_core.u_backend.mem_replay_capture)
            load_replay_count_o <= load_replay_count_o + 1'b1;
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
            debug_cycle_q <= debug_cycle_q + 1;
        end
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
