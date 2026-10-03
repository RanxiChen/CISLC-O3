/**
 * ICache: 64B whole-line interleaving over two banks, with an S0-S3
 * synchronous lookup pipeline (D10-D14).
 *
 * 当前实现状态：闭环简化（L1，含 cache 数据通路）
 * - S0 samples a demand and starts banked tag/data and ITCM reads. S1 holds
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
 * - The L1 physical-address/ITCM mode still bypasses ITLB, PMP and PMA.
 *   Translation and protection must join S1-S3 before privileged execution;
 *   no claim is made that those checks are implemented. Prefetch, recall,
 *   epoch retirement and performance events are also pending.
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
    localparam int FETCH_BYTES = CFG.fetch.region_bytes,
    localparam logic [ADDR_WIDTH-1:0] ITCM_BASE = ADDR_WIDTH'(CFG.icache.itcm_base),
    localparam int ITCM_BYTES = CFG.icache.itcm_bytes
) (
    input  logic clk,
    input  logic rst,

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
    input  logic itcm_init_valid_i,
    input  logic [ADDR_WIDTH-1:0] itcm_init_addr_i,
    input  logic [63:0] itcm_init_data_i,
    input  logic [7:0] itcm_init_wmask_i,
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
    localparam int ITCM_WORD_W = $clog2(ITCM_BYTES / FETCH_BYTES);

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
        logic [WAYS-1:0] valid_bits;
        logic itcm;
        word_data_t itcm_data;
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
        assert (ITCM_BYTES > 0 && ITCM_BYTES % FETCH_BYTES == 0)
            else $fatal(1, "ICache: ITCM must contain whole fetch words");
    end

    // The global 64-set configuration means 32 sets in each bank:
    // address[5:4] word, [6] bank, [11:7] set and [PADDR_W-1:12] tag.
    paddr_t req_pa;
    bank_idx_t req_bank;
    set_idx_t req_set;
    word_idx_t req_word;
    tag_t req_tag;
    logic req_itcm;
    logic s0_fire;
    logic s1_valid_q, s2_valid_q, s3_valid_q;
    logic s1_ready, s2_ready, s3_ready;
    lookup_meta_t s1_meta_q, s2_meta_q, s3_meta_q;
    logic [WAYS-1:0][TAG_W-1:0] s2_tags_q;
    logic [WAYS-1:0][DATA_W-1:0] s2_data_q, s3_data_q;
    logic [WAYS-1:0] s3_way_hit_q;

    logic [BANKS-1:0][WAYS-1:0][SETS_PER_BANK-1:0] valid_q;
    logic [TAG_W-1:0] tag_read_data [BANKS][WAYS];
    logic [DATA_W-1:0] data_read_data [BANKS][WAYS];
    logic [DATA_ADDR_W-1:0] data_read_addr, data_write_addr;
    logic [SET_W-1:0] tag_read_addr;
    logic fill_write, fill_last;
    logic [BANKS-1:0][WAYS-1:0] tag_write_en, data_write_en;

    assign req_pa = paddr_t'(req_i.region_base);
    assign req_bank = bank_idx_t'(req_pa[6]);
    assign req_set = req_pa[7 +: SET_W];
    assign req_word = req_pa[4 +: WORD_W];
    assign req_tag = req_pa[PADDR_W-1:TAG_LSB];
    assign req_itcm = (ADDR_WIDTH'(req_i.region_base) >= ITCM_BASE)
                   && ((ADDR_WIDTH'(req_i.region_base) + ADDR_WIDTH'(FETCH_BYTES))
                       <= ITCM_BASE + ADDR_WIDTH'(ITCM_BYTES));
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
    paddr_t recent_line_q;
    logic [ICACHE_BLOCK_SIZE_BYTES*8-1:0] recent_data_q;
    logic inv_done_q;

    assign fill_write = (mstate_q == M_INSTALL);
    assign fill_last = fill_write && install_word_q == word_idx_t'(WORDS_PER_LINE - 1);
    assign data_write_addr = {m_set_q, install_word_q};

    for (genvar bank = 0; bank < BANKS; bank++) begin : g_bank
        for (genvar way = 0; way < WAYS; way++) begin : g_way
            assign data_write_en[bank][way] =
                fill_write && m_bank_q == bank_idx_t'(bank) && m_way_q == way_idx_t'(way);
            assign tag_write_en[bank][way] = fill_last
                && m_bank_q == bank_idx_t'(bank) && m_way_q == way_idx_t'(way);
            o3_sram_1r1w #(.DATA_WIDTH(DATA_W), .ENTRIES(SETS_PER_BANK*WORDS_PER_LINE))
                u_data (
                    .clk_i(clk),
                    .read_en_i(s0_fire && !req_itcm && req_bank == bank_idx_t'(bank)),
                    .read_addr_i(data_read_addr),
                    .read_data_o(data_read_data[bank][way]),
                    .write_en_i(data_write_en[bank][way]),
                    .write_addr_i(data_write_addr),
                    .write_data_i(m_data_q[install_word_q*DATA_W +: DATA_W])
                );
            o3_sram_1r1w #(.DATA_WIDTH(TAG_W), .ENTRIES(SETS_PER_BANK))
                u_tag (
                    .clk_i(clk),
                    .read_en_i(s0_fire && !req_itcm && req_bank == bank_idx_t'(bank)),
                    .read_addr_i(tag_read_addr),
                    .read_data_o(tag_read_data[bank][way]),
                    .write_en_i(tag_write_en[bank][way]),
                    .write_addr_i(m_set_q),
                    .write_data_i(m_tag_q)
                );
        end
    end

    // ITCM is a 16B synchronous word store. Testbench initialization writes
    // eight bytes at a time; normal fetches read one aligned word at S0.
    word_data_t itcm_mem_q [0:ITCM_BYTES/FETCH_BYTES-1];
    word_data_t itcm_read_q;
    always_ff @(posedge clk) begin
        if (itcm_init_valid_i) begin
            for (int byte_idx = 0; byte_idx < 8; byte_idx++) begin
                if (itcm_init_wmask_i[byte_idx]
                  && itcm_init_addr_i + ADDR_WIDTH'(byte_idx) >= ITCM_BASE
                  && itcm_init_addr_i + ADDR_WIDTH'(byte_idx) < ITCM_BASE + ADDR_WIDTH'(ITCM_BYTES)) begin
                    itcm_mem_q[ITCM_WORD_W'(
                        (itcm_init_addr_i + ADDR_WIDTH'(byte_idx) - ITCM_BASE) >> 4)]
                              [7'((32'(itcm_init_addr_i[3:0]) + byte_idx) * 8) +: 8]
                        <= itcm_init_data_i[byte_idx*8 +: 8];
                end
            end
        end
        if (s0_fire && req_itcm) begin
            itcm_read_q <= itcm_mem_q[ITCM_WORD_W'(
                (ADDR_WIDTH'(req_i.region_base)-ITCM_BASE) >> 4)];
        end
    end

    logic s3_recent_hit, s3_cache_hit, s3_hit, m_resp;
    word_data_t s3_selected_data;
    paddr_t s3_line;
    assign s3_line = line_addr(s3_meta_q.req.region_base);
    assign s3_recent_hit = recent_valid_q && s3_line == recent_line_q;
    assign s3_cache_hit = |s3_way_hit_q;
    assign s3_hit = s3_meta_q.itcm || s3_cache_hit || s3_recent_hit;
    assign m_resp = (mstate_q == M_RESP);
    always_comb begin
        s3_selected_data = '0;
        if (s3_meta_q.itcm) begin
            s3_selected_data = s3_meta_q.itcm_data;
        end else if (s3_recent_hit) begin
            s3_selected_data = recent_data_q[s3_meta_q.word_idx*DATA_W +: DATA_W];
        end else begin
            for (int way = 0; way < WAYS; way++) begin
                if (s3_way_hit_q[way]) s3_selected_data = s3_data_q[way];
            end
        end
    end

    // An active miss does not occupy the lookup pipeline. A later miss waits
    // at S3 if the single MSHR is busy, propagating backpressure losslessly.
    assign s3_ready = !s3_valid_q || (!m_resp && (s3_hit || mstate_q == M_IDLE));
    assign s2_ready = !s2_valid_q || s3_ready;
    assign s1_ready = !s1_valid_q || s2_ready;
    assign req_ready_o = !rst && !inv_all_i && s1_ready
        && !(fill_write && req_bank == m_bank_q)
        && !(mstate_q != M_IDLE && {req_pa[PADDR_W-1:6], 6'b0} == m_line_q);
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
                s2_valid_q <= s1_valid_q;
                if (s1_valid_q) begin
                    s2_meta_q <= s1_meta_q;
                    s2_meta_q.itcm_data <= itcm_read_q;
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
                    s1_meta_q.itcm <= req_itcm;
                    s1_meta_q.itcm_data <= '0;
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
            resp_o.exc_cause = EXCEPTION_CAUSE_INST_ACCESS_FAULT;
        end else if (s3_valid_q && s3_hit) begin
            resp_o.valid = 1'b1;
            resp_o.rq_idx = s3_meta_q.req.rq_idx;
            resp_o.ftq_id = s3_meta_q.req.ftq_id;
            resp_o.data = s3_selected_data;
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
            recent_valid_q <= 1'b0;
            recent_line_q <= '0;
            recent_data_q <= '0;
            valid_q <= '0;
            inv_done_q <= 1'b0;
        end else begin
            inv_done_q <= inv_all_i;
            if (inv_all_i) begin
                valid_q <= '0;
                recent_valid_q <= 1'b0;
            end else if (fill_last) begin
                valid_q[m_bank_q][m_way_q][m_set_q] <= 1'b1;
                recent_valid_q <= 1'b1;
                recent_line_q <= m_line_q;
                recent_data_q <= m_data_q;
            end

            case (mstate_q)
                M_IDLE: begin
                    if (s3_valid_q && !s3_hit && s3_ready && !inv_all_i) begin
                        m_req_q <= s3_meta_q.req;
                        m_line_q <= line_addr(s3_meta_q.req.region_base);
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
    assign ptw_req_valid_o = 1'b0;
    assign ptw_req_o = '0;
    assign pmp_update_done_o = 1'b0;
    assign sfence_done_o = 1'b0;
    assign recall_ready_o = 1'b0;
    assign recall_resp_o = '0;
    assign perf_o = '0;
endmodule
