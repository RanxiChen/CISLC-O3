/**
 * ICache: 64B whole-line interleaving over two banks, with an S0-S3
 * synchronous lookup pipeline (D10-D14).
 *
 * 当前实现状态：闭环简化（L10 T08a，Bare 缓存取指）
 * - S0 samples a demand and starts banked tag/data reads. S1 holds
 *   the synchronous results; S2 registers tag comparisons; S3 selects data
 *   and returns the original FTQ/RQ identity. Uncontended hits accept one
 *   demand per cycle, including consecutive hits in the same bank.
 * - Each 64B line belongs entirely to address[6]'s bank. Each bank has one
 *   synchronous read and one write address per way. Four 16B words are data
 *   addresses within a line, not four cache banks (D11/D12).
 * - One demand MSHR accepts a line miss, receives four 16B L2 beats, installs
 *   the full line, then publishes valid and responds. Independent hits can
 *   pass a pending miss (D13/D14). MSHR count/merge capacity remains below
 *   the provisional CFG count; a second miss waits in S3.
 * - L10 T08a: Bare physical addresses pass through real PMP S2/S3 and PMA.
 *   Cached hits repeat protection checks; faults do not allocate an MSHR.
 *   ITLB translation joins in T08b; prefetch remains disabled. Inclusive
 *   L2 recall drains lookup stages and invalidates the exact resident line.
 * - Tests: sim/cocotb/icache/. Whole-core closure: sim/o3/.
 *
 * Timing: N's S0 acceptance starts registered SRAM reads; N+1 S1 has their
 * outputs; N+2 S2 has per-way hit candidates; N+3 S3 forms a response or
 * allocates the MSHR. Stalled stages retain data and identity. Same-bank
 * refill writes block new S0 reads; the other bank remains available.
 * Read-during-write on one address is forbidden at the SRAM boundary.
 */
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
    output l2_req_t l2_req_o,
    input  l2_resp_t l2_resp_i,
    output logic l2_resp_ready_o,

    input  fe_csr_t csr_i,
    input  pmp_state_t pmp_i,
    output logic pmp_update_done_o,
    input  sfence_req_t sfence_i,
    output logic sfence_done_o,
    input  logic inv_all_i,
    output logic inv_done_o,
    output logic idle_o,

    input  logic recall_valid_i,
    output logic recall_ready_o,
    input  l1_recall_req_t recall_i,
    output l1i_recall_resp_t recall_resp_o,

    output fe_perf_t perf_o
);
    localparam int BANKS = CFG.icache.banks;
    localparam int WAYS = CFG.icache.ways;
    localparam int SETS_PER_BANK = CFG.icache.sets / BANKS;
    localparam int WORDS_PER_LINE = ICACHE_BLOCK_SIZE_BYTES / FETCH_BYTES;
    localparam int BEATS_PER_LINE = ICACHE_BLOCK_SIZE_BYTES / CFG.icache.refill_beat_bytes;
    localparam int BANK_W = $clog2(BANKS);
    localparam int WAY_W = $clog2(WAYS);
    localparam int SET_W = $clog2(SETS_PER_BANK);
    localparam int WORD_W = $clog2(WORDS_PER_LINE);
    localparam int BEAT_W = $clog2(BEATS_PER_LINE);
    localparam int TAG_LSB = 6 + BANK_W + SET_W;
    localparam int TAG_W = PADDR_W - TAG_LSB;
    localparam int DATA_W = FETCH_BYTES * 8;
    localparam int DATA_ADDR_W = SET_W + WORD_W;

    typedef logic [BANK_W-1:0] bank_idx_t;
    typedef logic [WAY_W-1:0] way_idx_t;
    typedef logic [SET_W-1:0] set_idx_t;
    typedef logic [WORD_W-1:0] word_idx_t;
    typedef logic [TAG_W-1:0] tag_t;
    typedef logic [DATA_W-1:0] word_data_t;

    function automatic paddr_t line_addr(input vaddr_t addr);
        paddr_t pa;
        pa = paddr_t'(addr);
        return {pa[PADDR_W-1:6], 6'b0};
    endfunction

    typedef struct packed {
        icache_req_t req;
        bank_idx_t bank;
        set_idx_t set_idx;
        word_idx_t word_idx;
        tag_t tag;
        paddr_t pa;
        logic page_fault,access_fault;
        logic [WAYS-1:0] valid_bits;
    } lookup_meta_t;

    initial begin
        assert (BANKS == 2 && WAYS > 1 && SETS_PER_BANK > 1)
            else $fatal(1, "ICache: expected two whole-line banks, multiple ways and sets");
        assert (CFG.icache.sets % BANKS == 0
             && (SETS_PER_BANK & (SETS_PER_BANK - 1)) == 0)
            else $fatal(1, "ICache: global sets must split into power-of-two bank sets");
        assert (FETCH_BYTES == 16 && ICACHE_BLOCK_SIZE_BYTES == 64
             && CFG.icache.refill_beat_bytes == 16)
            else $fatal(1, "ICache: current bank datapath requires 64B lines and 16B words/beats");
        assert (TAG_LSB <= PAGE_OFFSET_W)
            else $fatal(1, "ICache: VIPT bank/index bits escape the 4KiB page offset");
    end

    // The global 64-set configuration means 32 sets in each bank:
    // address[5:4] word, [6] bank, [11:7] set and [PADDR_W-1:12] tag.
    paddr_t req_pa;
    bank_idx_t req_bank;
    set_idx_t req_set;
    word_idx_t req_word;
    tag_t req_tag;
    logic s0_fire;
    logic s1_valid_q, s2_valid_q, s3_valid_q;
    logic s1_ready, s2_ready, s3_ready;
    lookup_meta_t s1_meta_q, s2_meta_q, s3_meta_q;
    logic [WAYS-1:0][TAG_W-1:0] s2_tags_q;
    logic [WAYS-1:0][DATA_W-1:0] s2_data_q, s3_data_q;
    logic [WAYS-1:0] s3_way_hit_q;

    logic [BANKS-1:0][WAYS-1:0][SETS_PER_BANK-1:0] valid_q;
    tag_t tag_shadow_q [BANKS][WAYS][SETS_PER_BANK];
    logic [TAG_W-1:0] tag_read_data [BANKS][WAYS];
    logic [DATA_W-1:0] data_read_data [BANKS][WAYS];
    logic [DATA_ADDR_W-1:0] data_read_addr, data_write_addr;
    logic [SET_W-1:0] tag_read_addr;
    logic fill_write, fill_last;
    logic [BANKS-1:0][WAYS-1:0] tag_write_en, data_write_en;

    logic tlb_valid,tlb_hit,tlb_miss,tlb_pf,tlb_af,xlate_done,xlate_saved_q;
    logic [43:0] tlb_ppn;
    logic [1:0] tlb_level;
    paddr_t translated_pa,saved_pa_q;
    logic saved_pf_q,saved_af_q;
    fe_perf_t tlb_perf;
    itlb #(.CFG(CFG)) u_itlb(.clk_i(clk),.rst_i(rst),.kill_i(xlate_kill_i),
        .s0_valid_i(s0_fire || (s1_valid_q && !xlate_done)),
        .s0_vaddr_i(s0_fire ? req_i.region_base : s1_meta_q.req.region_base),
        .s1_valid_o(tlb_valid),.s1_hit_o(tlb_hit),.s1_miss_o(tlb_miss),
        .s1_ppn_o(tlb_ppn),.s1_level_o(tlb_level),.s1_page_fault_o(tlb_pf),.s1_access_fault_o(tlb_af),
        .ptw_req_valid_o(ptw_req_valid_o),.ptw_req_ready_i(ptw_req_ready_i),.ptw_req_o(ptw_req_o),
        .ptw_resp_i(ptw_resp_i),.csr_i(csr_i),.sfence_i(sfence_i),.sfence_done_o(sfence_done_o),.perf_o(tlb_perf));
    assign translated_pa=xlate_saved_q ? saved_pa_q : sv39_pa(tlb_ppn,s1_meta_q.req.region_base,tlb_level);
    assign xlate_done=xlate_saved_q || (tlb_valid && (tlb_hit || tlb_pf || tlb_af));
    always_ff @(posedge clk) begin
        if(rst || inv_all_i) begin xlate_saved_q<=0;saved_pa_q<=0;saved_pf_q<=0;saved_af_q<=0;end
        else begin
            if(s1_valid_q && xlate_done && !s2_ready && !xlate_saved_q) begin
                xlate_saved_q<=1;saved_pa_q<=translated_pa;saved_pf_q<=tlb_pf;saved_af_q<=tlb_af;
            end
            if(s1_ready) xlate_saved_q<=0;
        end
    end
    assign req_pa = paddr_t'(req_i.region_base);
    assign req_bank = bank_idx_t'(req_pa[6]);
    assign req_set = req_pa[7 +: SET_W];
    assign req_word = req_pa[4 +: WORD_W];
    assign req_tag = req_pa[PADDR_W-1:TAG_LSB];
    assign data_read_addr = {req_set, req_word};
    assign tag_read_addr = req_set;

    typedef enum logic [2:0] {M_IDLE, M_SEND, M_RECV, M_INSTALL, M_RESP} mstate_t;
    mstate_t mstate_q;
    icache_req_t m_req_q;
    paddr_t m_line_q;
    bank_idx_t m_bank_q;
    set_idx_t m_set_q;
    tag_t m_tag_q;
    way_idx_t m_way_q, victim_rr_q;
    logic [ICACHE_BLOCK_SIZE_BYTES*8-1:0] m_data_q;
    logic m_error_q;
    logic [BEAT_W-1:0] beat_q;
    word_idx_t install_word_q;
    logic recent_valid_q;
    xlate_epoch_t recent_epoch_q,m_epoch_q;
    logic [1:0] recent_priv_q,m_priv_q;
    paddr_t recent_line_q;
    logic [ICACHE_BLOCK_SIZE_BYTES*8-1:0] recent_data_q;
    logic inv_done_q;
    l1i_recall_resp_t recall_resp_q;
    logic recall_fire;
    bank_idx_t recall_bank;
    set_idx_t recall_set;
    tag_t recall_tag;

    assign fill_write = (mstate_q == M_INSTALL);
    assign fill_last = fill_write && install_word_q == word_idx_t'(WORDS_PER_LINE - 1);
    assign data_write_addr = {m_set_q, install_word_q};
    assign recall_bank = bank_idx_t'(recall_i.line_paddr[6]);
    assign recall_set = set_idx_t'(recall_i.line_paddr[7 +: SET_W]);
    assign recall_tag = tag_t'(recall_i.line_paddr[PADDR_W-1:TAG_LSB]);
    assign recall_ready_o = !rst && !s1_valid_q && !s2_valid_q && !s3_valid_q
        && (mstate_q == M_IDLE || m_line_q != recall_i.line_paddr)
        && !recall_resp_q.valid;
    assign recall_fire = recall_valid_i && recall_ready_o;
    assign recall_resp_o = recall_resp_q;

    for (genvar bank = 0; bank < BANKS; bank++) begin : g_bank
        for (genvar way = 0; way < WAYS; way++) begin : g_way
            assign data_write_en[bank][way] =
                fill_write && m_bank_q == bank_idx_t'(bank) && m_way_q == way_idx_t'(way);
            assign tag_write_en[bank][way] = fill_last
                && m_bank_q == bank_idx_t'(bank) && m_way_q == way_idx_t'(way);
            o3_sram_1r1w #(.DATA_WIDTH(DATA_W), .ENTRIES(SETS_PER_BANK*WORDS_PER_LINE))
                u_data (
                    .clk_i(clk),
                    .read_en_i(s0_fire && req_bank == bank_idx_t'(bank)),
                    .read_addr_i(data_read_addr),
                    .read_data_o(data_read_data[bank][way]),
                    .write_en_i(data_write_en[bank][way]),
                    .write_addr_i(data_write_addr),
                    .write_data_i(m_data_q[install_word_q*DATA_W +: DATA_W])
                );
            o3_sram_1r1w #(.DATA_WIDTH(TAG_W), .ENTRIES(SETS_PER_BANK))
                u_tag (
                    .clk_i(clk),
                    .read_en_i(s0_fire && req_bank == bank_idx_t'(bank)),
                    .read_addr_i(tag_read_addr),
                    .read_data_o(tag_read_data[bank][way]),
                    .write_en_i(tag_write_en[bank][way]),
                    .write_addr_i(m_set_q),
                    .write_data_i(m_tag_q)
                );
        end
    end

    logic s3_recent_hit, s3_cache_hit, s3_hit, m_resp;
    logic pmp_valid,pmp_allow_result,pmp_fault;
    logic pma_exec,pma_cached,pma_exists,pma_fault_q,s3_fault;
    pmp_checker #(.CFG(CFG)) u_pmp_checker(.clk_i(clk),.rst_i(rst),
        .s2_valid_i(s2_valid_q),.s2_paddr_i(s2_meta_q.pa),
        .stall_i(!s3_ready),.bytes_i(7'(FETCH_BYTES)),.read_i(1'b0),.write_i(1'b0),.exec_i(1'b1),
        .s3_valid_o(pmp_valid),.s3_allow_o(pmp_allow_result),.s3_fault_o(pmp_fault),
        .cfg_i(pmp_i),.priv_i(csr_i.priv),.cfg_update_done_o(pmp_update_done_o));
    pma_checker #(.CFG(CFG)) u_pma_checker(.paddr_i(64'(s2_meta_q.pa)),.bytes_i(7'(FETCH_BYTES)),
        .exec_ok_o(pma_exec),.cacheable_o(pma_cached),.exists_o(pma_exists),.read_ok_o(),.write_ok_o());
    always_ff @(posedge clk) begin
        if(rst || inv_all_i) pma_fault_q<=0;
        else if(s3_ready) pma_fault_q<=!pma_exec;
    end
    assign s3_fault=pmp_fault || pma_fault_q || s3_meta_q.page_fault || s3_meta_q.access_fault;
    // N S2 range/PMA checks; edge N latches candidates alongside way matches;
    // N+1 S3 permission has priority over hit or allocation of a demand MSHR.
    word_data_t s3_selected_data;
    paddr_t s3_line;
    assign s3_line = line_addr(64'(s3_meta_q.pa));
    assign s3_recent_hit = recent_valid_q && s3_line == recent_line_q && recent_epoch_q==csr_i.epoch && recent_priv_q==csr_i.priv;
    assign s3_cache_hit = |s3_way_hit_q;
    assign s3_hit = s3_cache_hit || s3_recent_hit;
    assign m_resp = (mstate_q == M_RESP);
    always_comb begin
        s3_selected_data = '0;
        if (s3_recent_hit) begin
            s3_selected_data = recent_data_q[s3_meta_q.word_idx*DATA_W +: DATA_W];
        end else begin
            for (int way = 0; way < WAYS; way++) begin
                if (s3_way_hit_q[way]) s3_selected_data = s3_data_q[way];
            end
        end
    end

    // An active miss does not occupy the lookup pipeline. A later miss waits
    // at S3 if the single MSHR is busy, propagating backpressure losslessly.
    assign s3_ready = !s3_valid_q || (!m_resp && (s3_hit || s3_fault || mstate_q == M_IDLE));
    assign s2_ready = !s2_valid_q || s3_ready;
    assign s1_ready = !s1_valid_q || (s2_ready && xlate_done);
    assign req_ready_o = !rst && !inv_all_i && !recall_valid_i && s1_ready
        && !(fill_write && req_bank == m_bank_q)
&& !(mstate_q != M_IDLE && (csr_i.satp_mode!=8 || csr_i.priv==3) && line_addr(req_i.region_base)==m_line_q); // Sv39 compares physical lines after S1.
    assign s0_fire = req_valid_i && req_ready_o;

    always_ff @(posedge clk) begin
        if (rst || inv_all_i) begin
            s1_valid_q <= 1'b0;
            s2_valid_q <= 1'b0;
            s3_valid_q <= 1'b0;
            s1_meta_q <= '0;
            s2_meta_q <= '0;
            s3_meta_q <= '0;
            s2_tags_q <= '0;
            s2_data_q <= '0;
            s3_data_q <= '0;
            s3_way_hit_q <= '0;
        end else begin
            if (s3_ready) begin
                s3_valid_q <= s2_valid_q;
                if (s2_valid_q) begin
                    s3_meta_q <= s2_meta_q;
                    s3_data_q <= s2_data_q;
                    for (int way = 0; way < WAYS; way++) begin
                        s3_way_hit_q[way] <= s2_meta_q.valid_bits[way]
                            && s2_tags_q[way] == s2_meta_q.tag;
                    end
                end
            end
            if (s2_ready) begin
                s2_valid_q <= s1_valid_q && xlate_done;
                if (s1_valid_q && xlate_done) begin
                    s2_meta_q <= s1_meta_q;
                    s2_meta_q.pa <= translated_pa;
                    s2_meta_q.tag <= translated_pa[PADDR_W-1:TAG_LSB];
                    s2_meta_q.page_fault <= xlate_saved_q ? saved_pf_q : tlb_pf;
                    s2_meta_q.access_fault <= (xlate_saved_q ? saved_af_q : tlb_af) ||
                        ((csr_i.satp_mode!=8 || csr_i.priv==3) && |s1_meta_q.req.region_base[63:56]);
                    for (int way = 0; way < WAYS; way++) begin
                        s2_tags_q[way] <= tag_read_data[s1_meta_q.bank][way];
                        s2_data_q[way] <= data_read_data[s1_meta_q.bank][way];
                    end
                end
            end
            if (s1_ready) begin
                s1_valid_q <= s0_fire;
                if (s0_fire) begin
                    s1_meta_q.req <= req_i;
                    s1_meta_q.bank <= req_bank;
                    s1_meta_q.set_idx <= req_set;
                    s1_meta_q.word_idx <= req_word;
                    s1_meta_q.tag <= req_tag;
                    for (int way = 0; way < WAYS; way++) begin
                        s1_meta_q.valid_bits[way] <= valid_q[req_bank][way][req_set];
                    end
                end
            end
        end
    end

    always_comb begin
        resp_o = '0;
        if (m_resp) begin
            resp_o.valid = 1'b1;
            resp_o.rq_idx = m_req_q.rq_idx;
            resp_o.ftq_id = m_req_q.ftq_id;
            resp_o.data = m_data_q[m_req_q.region_base[5:4]*DATA_W +: DATA_W];
            resp_o.exc_valid = m_error_q;
            resp_o.exc_cause = o3_isa_pkg::EXCEPTION_CAUSE_INST_ACCESS_FAULT;
        end else if (s3_valid_q && (s3_hit || s3_fault)) begin
            resp_o.valid = 1'b1;
            resp_o.rq_idx = s3_meta_q.req.rq_idx;
            resp_o.ftq_id = s3_meta_q.req.ftq_id;
            resp_o.data = s3_selected_data;
            resp_o.exc_valid=s3_fault;
            resp_o.exc_cause=s3_meta_q.page_fault ? EXCEPTION_CAUSE_INST_PAGE_FAULT : EXCEPTION_CAUSE_INST_ACCESS_FAULT;
        end
    end

    always_comb begin
        l2_req_o = '0;
        l2_req_o.line_paddr = m_line_q;
        l2_req_o.kind = L2_DEMAND;
    end
    assign l2_req_valid_o = (mstate_q == M_SEND);
    assign l2_resp_ready_o = (mstate_q == M_RECV);
    assign idle_o = (mstate_q == M_IDLE) && !s1_valid_q && !s2_valid_q && !s3_valid_q;
    assign inv_done_o = inv_done_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mstate_q <= M_IDLE;
            m_req_q <= '0;
            m_line_q <= '0;
            m_bank_q <= '0;
            m_set_q <= '0;
            m_tag_q <= '0;
            m_way_q <= '0;
            victim_rr_q <= '0;
            m_data_q <= '0;
            m_error_q <= 1'b0;
            beat_q <= '0;
            install_word_q <= '0;
            recent_valid_q <= 1'b0;recent_epoch_q<=0;recent_priv_q<=0;m_epoch_q<=0;m_priv_q<=0;
            recent_line_q <= '0;
            recent_data_q <= '0;
            valid_q <= '0;
            recall_resp_q <= '0;
            inv_done_q <= 1'b0;
        end else begin
            inv_done_q <= inv_all_i;
            recall_resp_q.valid <= 1'b0;
            if (inv_all_i) begin
                valid_q <= '0;
                recent_valid_q <= 1'b0;
            end else if (fill_last) begin
                valid_q[m_bank_q][m_way_q][m_set_q] <= 1'b1;
                tag_shadow_q[m_bank_q][m_way_q][m_set_q] <= m_tag_q;
                recent_valid_q <= 1'b1;recent_epoch_q<=m_epoch_q;recent_priv_q<=m_priv_q;
                recent_line_q <= m_line_q;
                recent_data_q <= m_data_q;
            end
            if (recall_fire) begin
                for (int way = 0; way < WAYS; way++)
                    if (valid_q[recall_bank][way][recall_set]
                      && tag_shadow_q[recall_bank][way][recall_set] == recall_tag)
                        valid_q[recall_bank][way][recall_set] <= 1'b0;
                if (recent_valid_q && recent_line_q == recall_i.line_paddr)
                    recent_valid_q <= 1'b0;
                recall_resp_q.valid <= 1'b1;
                recall_resp_q.recall_id <= recall_i.recall_id;
                recall_resp_q.quiesced <= 1'b1;
            end

            case (mstate_q)
                M_IDLE: begin
                    if (s3_valid_q && !s3_hit && !s3_fault && s3_ready && !inv_all_i) begin
                        m_req_q <= s3_meta_q.req;m_epoch_q<=csr_i.epoch;m_priv_q<=csr_i.priv;
                        m_line_q <= line_addr(64'(s3_meta_q.pa));
                        m_bank_q <= s3_meta_q.bank;
                        m_set_q <= s3_meta_q.set_idx;
                        m_tag_q <= s3_meta_q.tag;
                        m_way_q <= victim_rr_q;
                        for (int way = WAYS-1; way >= 0; way--) begin
                            if (!valid_q[s3_meta_q.bank][way][s3_meta_q.set_idx])
                                m_way_q <= way_idx_t'(way);
                        end
                        victim_rr_q <= victim_rr_q + way_idx_t'(1);
                        beat_q <= '0;
                        m_error_q <= 1'b0;
                        mstate_q <= M_SEND;
                    end
                end
                M_SEND: begin
                    if (l2_req_ready_i) mstate_q <= M_RECV;
                end
                M_RECV: begin
                    if (l2_resp_i.valid && l2_resp_ready_o) begin
                        assert (l2_resp_i.txn_id == '0
                             && l2_resp_i.last == (beat_q == BEAT_W'(BEATS_PER_LINE-1)))
                            else $fatal(1, "ICache: L2 refill beat/id mismatch");
                        m_data_q[beat_q*L2_BEAT_BYTES*8 +: L2_BEAT_BYTES*8] <= l2_resp_i.data;
                        m_error_q <= m_error_q || l2_resp_i.error;
                        if (l2_resp_i.last) begin
                            install_word_q <= '0;
                            mstate_q <= (m_error_q || l2_resp_i.error) ? M_RESP : M_INSTALL;
                        end else begin
                            beat_q <= beat_q + BEAT_W'(1);
                        end
                    end
                end
                M_INSTALL: begin
                    if (fill_last) mstate_q <= M_RESP;
                    else install_word_q <= install_word_q + word_idx_t'(1);
                end
                M_RESP: mstate_q <= M_IDLE;
                default: mstate_q <= M_IDLE;
            endcase
            assert (!(inv_all_i && !idle_o))
                else $error("ICache: inv_all requires an idle lookup and refill path");
        end
    end

    // Legacy contract and not-yet-connected target mechanisms.
    assign s0_ready = 1'b0;
    assign refill_req_valid = 1'b0;
    assign refill_req_pc = '0;
    assign out_valid = 1'b0;
    assign out_hit = 1'b0;
    assign out_pc = '0;
    assign out_data = '0;
    assign out_error = 1'b0;
    assign pf_req_ready_o = 1'b0;
    assign pf_resp_o = '0;



    assign perf_o = tlb_perf;
endmodule
