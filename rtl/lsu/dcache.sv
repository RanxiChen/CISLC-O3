/**
 * L1 DCache —— 组相联、写回、多 bank、非阻塞数据缓存
 *
 * 作用（已定方向，B03/B04/B05/B08/B09）：
 * - 普通 load/store、PTW 页表读取、L1 原子操作复用本 cache；L2 缓冲 DDR 访问。
 * - hit-under-miss；多个独立 miss 在途与同 line 合并（dcache_mshr）。流水线等待与事务等待分开；
 *   一次 miss 不把整个访问流水线置忙。
 * - 多 bank 提供实际并行带宽；同 bank 仲裁，tag/meta 访问能力必须配套；
 *   不同 line 不保证不同 bank，不承诺两读一写无冲突。
 * - Load：翻译与 PMP/PMA 检查完成后才允许产生有效结果；SQ 与 cache 可并行查询，结果统一选择；
 *   SQ 完整提供数据时不因 cache miss 无条件申请下级取数。miss 分配或合并 MSHR；资源不足等待
 *   可用事件；回填安装后经 wake_o 唤醒 load 重查（不要求回填直接写 preg）。
 * - Store drain：请求接受与写完成分开；命中写完确认后 SQ 释放；miss/冲突/DMA 行保护时 SQ 保留项，
 *   等事件后重试，不重复发送在途请求；store 等 miss 不占 bank 流水级（B05）。
 * - 响应区分等待原因（dc_status_e），避免盲目重试（B04）。
 * - B31：普通可缓存标量非对齐访问同 line 内硬件支持（内部可跨 bank 拆分/拼接，仍是一次访问）；
 *   跨 line 由 LSU 在发出前报地址非对齐异常，不进入本 cache。
 * - DMA 行协调（B08）：接受 probe 后阻止该行新的 CPU 访问与 AMO，其他行继续；已接受访问完成到
 *   安全边界；clean+invalidate 后返回 quiesced；不得堵住完成旧事务所需的响应/回填/写回/探测应答；
 *   probe 使用维护队列与 bank 仲裁，持续 CPU 请求下也不能永久饥饿。
 * - AMO/LR/SC：内含 dcache_amo_unit 与独立 lrsc_reservation（B09/B35）。store drain/AMO 实际写、
 *   PTE A/D 实际写、DMA 写取得行保护权时向 reservation 送冲突事件；替换/clean/writeback/DMA 读/
 *   L2 容量回收不清除。SC 在途行不被重复选为 victim、维护请求不得无限抢占 SC（前进保障）。
 * - FENCE.I（B23/D25，commit_ctrl 编排）：clean_all_req_i 后遍历全部 tag/meta，跳过非脏行，每个
 *   脏行复用按行 clean+invalidate 写回 L2 并失效，等全部写回确认后 clean_all_done_o；
 *   clean_all_busy_o 供 fencei_dcache_evict_cycles 计数。干净行不逐出。
 * - 维护入口（2026-10-02 确认，常规流水不变）：probe_* 同时承载 DMA 行协调（PROBE_DMA）与 L2
 *   inclusive 回收（PROBE_RECALL）；均经维护队列与 bank 仲裁，不新增普通访问的查询口或流水级；
 *   探测应答不依赖普通 miss 的空闲 MSHR；同行在途回填须标记为不可安装，旧响应不得重新装回；
 *   脏副本先交回最新数据再确认。RECALL 不清 reservation。
 * - PTE A/D（B36）：pte_ad_* 是内部“完整 64 位 PTE 比较 + 条件置 A/D”入口，只供旁侧
 *   pte_ad_updater 使用；普通 load/store 不经过它。比较不匹配返回 mismatch；epoch 失效不写入。
 *   该入口不经 dcache_amo_unit 的 ROB 队首原子门控，避免被外部 AMO 卡死。
 * - 写回错误（B39）：脏行写回 L2 失败时 fatal_o 上报，失败写回不得按成功释放，维护/DMA 不得
 *   虚假完成。
 * - TLB 命中、权限与 A/D 均满足时 load/store 照常走原流水；store 遇 D=0 由 LSU 标记 needs_D（B36）。
 *
 * 细节待定（不能当作已决定）：容量、路数、line 大小、bank 数与映射（整行或行内 word 交错）、
 * 端口、流水级数、BRAM 映射、MSHR 与写回缓冲数、替换策略；FENCE.I 数据侧接口的具体形式。
 * 建议配置 16KiB/4-way/64B/4 bank/8 MSHR 仅为建议（B03）。
 *
 * 当前实现状态：闭环简化（L3，进行中）。四个 16B word bank、整行 tag/valid/dirty、
 * 两级 demand 查询、单个 demand 行事务、命中穿越 miss、脏 victim 交回、四拍 L2
 * 回填与 inclusive probe 已写入 RTL。多 MSHR、同 line 合并、PTW/AMO/预取与
 * DMA 保护尚未实现；普通 LSU 接线与 Alan 验证状态见 doc/LOOP.md。
 *
 * 测试：sim/cocotb/dcache/。
 */
module dcache
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int LOAD_PORTS = CFG.lsu.agu_pipes      // load/AGU 管线数待定（B03）
) (
    input  logic            clk,
    input  logic            rst,

    // load 管线（每条 AGU 管线一个）
    input  logic            ld_req_valid_i [LOAD_PORTS],
    output logic            ld_req_ready_o [LOAD_PORTS],
    input  dcache_req_t     ld_req_i       [LOAD_PORTS],
    output dcache_resp_t    ld_resp_o      [LOAD_PORTS],

    // committed store drain（SQ 按序，首版一次一笔，B05）
    input  logic            st_req_valid_i,
    output logic            st_req_ready_o,
    input  dcache_req_t     st_req_i,
    output dcache_resp_t    st_resp_o,

    // AMO / LR / SC（ROB 队头，B09）
    input  logic            amo_req_valid_i,
    output logic            amo_req_ready_o,
    input  dcache_req_t     amo_req_i,
    output dcache_resp_t    amo_resp_o,

    // PTW 物理读（B07）
    input  logic            ptw_req_valid_i,
    output logic            ptw_req_ready_o,
    input  dcache_req_t     ptw_req_i,
    output dcache_resp_t    ptw_resp_o,

    // stride 预取（B07）
    input  logic            pf_req_valid_i,
    output logic            pf_req_ready_o,
    input  dcache_req_t     pf_req_i,

    // MSHR 回填完成唤醒
    output dc_wake_t        wake_o,

    // DMA 行协调探测（来自 L2 协调器，B08）
    input  logic            probe_valid_i,
    output logic            probe_ready_o,
    input  dc_probe_req_t   probe_i,
    output dc_probe_resp_t  probe_resp_o,       // quiesced

    // FENCE.I 数据侧：L1D 全行扫描，脏行写回 L2 并逐出（B23，commit_ctrl 发起）
    input  logic            clean_all_req_i,
    output logic            clean_all_done_o,
    output logic            clean_all_busy_o,

    // PTE 比较 + 条件置 A/D 内部入口（B36，旁侧 pte_ad_updater）
    input  logic            pte_ad_req_valid_i,
    output logic            pte_ad_req_ready_o,
    input  pte_ad_req_t     pte_ad_req_i,
    output pte_ad_resp_t    pte_ad_resp_o,
    input  xlate_epoch_t    cur_epoch_i,

    // reservation 清除（trap/xRET/SFENCE.VMA/satp，来自 commit_ctrl）与 PTW A/D 写冲突
    input  logic            rsv_clear_valid_i,
    input  rsv_clear_e      rsv_clear_reason_i,
    input  rsv_conflict_t   rsv_pte_ad_conflict_i,

    // L1D ↔ L2：回填请求/响应、脏行写回
    output logic            l2_req_valid_o,
    input  logic            l2_req_ready_i,
    output l2_req_t         l2_req_o,
    input  l2_resp_t        l2_resp_i,
    output logic            l2_resp_ready_o,
    output logic            l2_wb_valid_o,
    input  logic            l2_wb_ready_i,
    output paddr_t          l2_wb_line_paddr_o,
    output logic [DC_LINE_BYTES*8-1:0] l2_wb_data_o,
    input  logic            l2_wb_error_i,       // B39：L2 拒绝/失败的写回（含包含关系错误）

    output logic            idle_o,
    output fatal_evt_t      fatal_o,             // B39：脏行写回 L2 失败
    output be_perf_t        perf_o
);
    localparam int SETS = CFG.dcache.sets;
    localparam int WAYS = CFG.dcache.ways;
    localparam int BANKS = CFG.dcache.banks;
    localparam int SET_W = $clog2(SETS);
    localparam int WAY_W = $clog2(WAYS);
    localparam int TAG_W = PADDR_W - 6 - SET_W;
    localparam int BEAT_W = $clog2(DC_LINE_BYTES / L2_BEAT_BYTES);
    typedef logic [SET_W-1:0] set_t;
    typedef logic [WAY_W-1:0] way_t;
    typedef logic [TAG_W-1:0] tag_t;
    typedef logic [BEAT_W-1:0] beat_t;
    typedef logic [DC_LINE_BYTES*8-1:0] line_t;
    typedef enum logic [2:0] {M_IDLE, M_WB, M_SEND, M_RECV, M_INSTALL, M_FAULT} mstate_t;

    // 16B word interleaving: each 64B line occupies the same set/way in all
    // four banks. A same-line unaligned scalar access may touch two banks.
    logic valid_q [SETS][WAYS];
    logic dirty_q [SETS][WAYS];
    tag_t tag_q [SETS][WAYS];
    logic [127:0] bank_read [BANKS][WAYS];
    logic [BANKS-1:0][WAYS-1:0] bank_write_en;
    logic [127:0] bank_write_data [BANKS][WAYS];
    set_t bank_read_set, bank_write_set;
    logic bank_read_en;
    logic [WAY_W-1:0] victim_rr_q;

    dcache_req_t stage_req_q;
    logic stage_valid_q, stage_store_q;
    set_t stage_set_q;
    tag_t stage_tag_q;
    logic [WAYS-1:0] stage_hits_q;
    logic stage_hit;
    way_t stage_way;
    way_t stage_victim_way;
    line_t stage_line, stage_store_line, stage_victim_line;
    logic stage_fire, stage_consume, stage_store_hit;
    logic input_hit, input_line_pending, stage_crossline;
    logic accept_window, accept_store, accept_load;
    dcache_req_t input_req;
    set_t input_set;
    tag_t input_tag;

    mstate_t mstate_q;
    dcache_req_t m_req_q;
    logic m_store_q;
    paddr_t m_line_q, m_victim_line_q;
    set_t m_set_q;
    tag_t m_tag_q;
    way_t m_way_q;
    beat_t m_beat_q;
    line_t m_data_q, m_victim_data_q;
    logic m_error_q;
    fatal_evt_t fatal_q;

    logic probe_fire, probe_pending_q, probe_had_dirty_q;
    way_t probe_way_q;
    dc_probe_resp_t probe_meta_q;
    logic [WAYS-1:0] probe_hits;
    way_t probe_way;
    set_t probe_set;
    tag_t probe_tag;
    line_t probe_line_data;
    dcache_resp_t ld_resp_q, st_resp_q;
    dc_wake_t wake_q;

    initial begin
        assert (BANKS == 4 && WAYS == 4 && SETS == 64 && DC_LINE_BYTES == 64
             && L2_BEAT_BYTES == 16 && LOAD_PORTS > 0)
            else $fatal(1, "DCache: current word-bank datapath requires 4x16B banks, 4 ways, 64 sets");
    end

    function automatic line_t merge_store(input line_t old_line,
                                           input dcache_req_t req);
        line_t result;
        int unsigned byte_offset;
        result = old_line;
        byte_offset = int'(req.paddr[5:0]);
        for (int byte_idx = 0; byte_idx < 8; byte_idx++)
            if (req.wmask[byte_idx] && byte_offset + byte_idx < DC_LINE_BYTES)
                result[(byte_offset + byte_idx)*8 +: 8] = req.wdata[byte_idx*8 +: 8];
        return result;
    endfunction

    function automatic logic [XLEN-1:0] extract_load(input line_t data,
                                                       input dcache_req_t req);
        return XLEN'(data >> (int'(req.paddr[5:0]) * 8));
    endfunction

    assign input_req = st_req_valid_i ? st_req_i : ld_req_i[0];
    assign input_set = set_t'(input_req.paddr[6 +: SET_W]);
    assign input_tag = tag_t'(input_req.paddr[PADDR_W-1:6+SET_W]);
    assign input_line_pending = mstate_q != M_IDLE
        && {input_req.paddr[PADDR_W-1:6], 6'b0} == m_line_q;
    assign stage_crossline = (int'(stage_req_q.paddr[5:0])
                            + (1 << stage_req_q.size)) > DC_LINE_BYTES;
    always_comb begin
        input_hit = 1'b0;
        for (int way = 0; way < WAYS; way++)
            if (valid_q[input_set][way] && tag_q[input_set][way] == input_tag)
                input_hit = 1'b1;
    end

    always_comb begin
        stage_hit = |stage_hits_q;
        stage_way = '0;
        stage_line = '0;
        stage_victim_way = victim_rr_q;
        stage_victim_line = '0;
        for (int way = 0; way < WAYS; way++)
            if (stage_hits_q[way]) stage_way = way_t'(way);
        for (int way = WAYS-1; way >= 0; way--)
            if (!valid_q[stage_set_q][way]) stage_victim_way = way_t'(way);
        for (int bank = 0; bank < BANKS; bank++)
            stage_line[bank*128 +: 128] = bank_read[bank][stage_way];
        for (int bank = 0; bank < BANKS; bank++)
            stage_victim_line[bank*128 +: 128] = bank_read[bank][stage_victim_way];
        stage_store_line = merge_store(stage_line, stage_req_q);
    end
    assign stage_store_hit = stage_valid_q && stage_hit && stage_store_q
                           && !stage_crossline && mstate_q != M_INSTALL;
    assign stage_consume = stage_valid_q && (stage_crossline
                         || (stage_hit && !(stage_store_q && mstate_q == M_INSTALL))
                         || (!stage_hit && mstate_q == M_IDLE));
    // A busy MSHR admits known resident hits. A second miss waits before S0,
    // so an L2 recall can always acquire the bank read port and make progress.
    assign accept_window = !rst && !probe_valid_i && !probe_pending_q
        && mstate_q != M_WB && mstate_q != M_INSTALL && mstate_q != M_FAULT
        && (!stage_valid_q || stage_consume)
        && !stage_store_hit && !(stage_valid_q && !stage_hit)
        && !input_line_pending && (mstate_q == M_IDLE || input_hit);
    assign st_req_ready_o = accept_window;
    for (genvar port = 0; port < LOAD_PORTS; port++) begin : g_load_port
        assign ld_req_ready_o[port] = (port == 0) && accept_window && !st_req_valid_i;
        assign ld_resp_o[port] = (port == 0) ? ld_resp_q : '0;
    end
    assign accept_store = st_req_valid_i && st_req_ready_o;
    assign accept_load = ld_req_valid_i[0] && ld_req_ready_o[0];
    assign stage_fire = accept_store || accept_load;
    assign bank_read_en = stage_fire || probe_fire;
    assign bank_read_set = probe_fire ? probe_set : input_set;

    assign probe_set = set_t'(probe_i.line_paddr[6 +: SET_W]);
    assign probe_tag = tag_t'(probe_i.line_paddr[PADDR_W-1:6+SET_W]);
    always_comb begin
        probe_hits = '0;
        probe_way = '0;
        for (int way = 0; way < WAYS; way++)
            if (valid_q[probe_set][way] && tag_q[probe_set][way] == probe_tag) begin
                probe_hits[way] = 1'b1;
                probe_way = way_t'(way);
            end
    end
    // Probe is prioritized over new demand reads. It can be accepted during
    // an unrelated L2 miss; it never waits for a free demand MSHR.
    assign probe_ready_o = !rst && !stage_valid_q && mstate_q != M_INSTALL
        && !(mstate_q != M_IDLE && probe_i.line_paddr == m_line_q);
    assign probe_fire = probe_valid_i && probe_ready_o;
    always_comb begin
        probe_line_data = '0;
        for (int bank = 0; bank < BANKS; bank++)
            probe_line_data[bank*128 +: 128] = bank_read[bank][probe_way_q];
        probe_resp_o = probe_meta_q;
        probe_resp_o.valid = probe_pending_q;
        probe_resp_o.dirty_data = probe_had_dirty_q ? probe_line_data : '0;
    end

    assign bank_write_set = mstate_q == M_INSTALL ? m_set_q : stage_set_q;
    always_comb begin
        bank_write_en = '0;
        for (int bank = 0; bank < BANKS; bank++)
            for (int way = 0; way < WAYS; way++) begin
                bank_write_data[bank][way] = '0;
                if (mstate_q == M_INSTALL && way == int'(m_way_q)) begin
                    bank_write_en[bank][way] = 1'b1;
                    bank_write_data[bank][way] = m_store_q
                        ? merge_store(m_data_q, m_req_q)[bank*128 +: 128]
                        : m_data_q[bank*128 +: 128];
                end else if (stage_store_hit && stage_consume
                         && way == int'(stage_way)) begin
                    bank_write_en[bank][way] = 1'b1;
                    bank_write_data[bank][way] = stage_store_line[bank*128 +: 128];
                end
            end
    end
    for (genvar bank = 0; bank < BANKS; bank++) begin : g_bank
        for (genvar way = 0; way < WAYS; way++) begin : g_way
            o3_sram_1r1w #(.DATA_WIDTH(128), .ENTRIES(SETS)) u_data (
                .clk_i(clk), .read_en_i(bank_read_en), .read_addr_i(bank_read_set),
                .read_data_o(bank_read[bank][way]),
                .write_en_i(bank_write_en[bank][way]), .write_addr_i(bank_write_set),
                .write_data_i(bank_write_data[bank][way])
            );
        end
    end

    assign l2_req_valid_o = (mstate_q == M_SEND);
    assign l2_req_o = '{line_paddr:m_line_q, kind:L2_DEMAND, txn_id:'0};
    assign l2_resp_ready_o = (mstate_q == M_RECV);
    assign l2_wb_valid_o = (mstate_q == M_WB)
        && !(probe_valid_i && probe_ready_o && probe_i.line_paddr == m_victim_line_q);
    assign l2_wb_line_paddr_o = m_victim_line_q;
    assign l2_wb_data_o = m_victim_data_q;
    assign idle_o = mstate_q == M_IDLE && !stage_valid_q && !probe_pending_q;
    assign fatal_o = fatal_q;
    assign st_resp_o = st_resp_q;
    assign wake_o = wake_q;

    // S0 reads four word banks and captures tag metadata. N+1 compares tags,
    // returns a hit or allocates the one line transaction. Hit loads can
    // overlap an unrelated L2 miss; stores insert a read/write bubble.
    always_ff @(posedge clk) begin
        if (rst) begin
            stage_valid_q <= 1'b0;
            stage_store_q <= 1'b0;
            stage_req_q <= '0;
            stage_set_q <= '0;
            stage_tag_q <= '0;
            stage_hits_q <= '0;
            mstate_q <= M_IDLE;
            m_req_q <= '0;
            m_store_q <= 1'b0;
            m_line_q <= '0;
            m_victim_line_q <= '0;
            m_set_q <= '0;
            m_tag_q <= '0;
            m_way_q <= '0;
            m_beat_q <= '0;
            m_data_q <= '0;
            m_victim_data_q <= '0;
            m_error_q <= 1'b0;
            victim_rr_q <= '0;
            probe_pending_q <= 1'b0;
            probe_had_dirty_q <= 1'b0;
            probe_way_q <= '0;
            probe_meta_q <= '0;
            ld_resp_q <= '0;
            st_resp_q <= '0;
            wake_q <= '0;
            fatal_q <= '0;
            for (int set_idx = 0; set_idx < SETS; set_idx++)
                for (int way = 0; way < WAYS; way++) begin
                    valid_q[set_idx][way] <= 1'b0;
                    dirty_q[set_idx][way] <= 1'b0;
                end
        end else begin
            ld_resp_q.valid <= 1'b0;
            st_resp_q.valid <= 1'b0;
            wake_q.valid <= 1'b0;
            probe_pending_q <= probe_fire;
            if (probe_fire) begin
                probe_pending_q <= 1'b1;
                probe_way_q <= probe_way;
                probe_had_dirty_q <= |probe_hits && dirty_q[probe_set][probe_way];
                probe_meta_q.kind <= probe_i.kind;
                probe_meta_q.recall_id <= probe_i.recall_id;
                probe_meta_q.had_dirty <= |probe_hits && dirty_q[probe_set][probe_way];
                if (|probe_hits) begin
                    valid_q[probe_set][probe_way] <= 1'b0;
                    dirty_q[probe_set][probe_way] <= 1'b0;
                end
                if (mstate_q == M_WB && probe_i.line_paddr == m_victim_line_q)
                    mstate_q <= M_SEND;
            end

            if (!stage_valid_q || stage_consume) begin
                stage_valid_q <= stage_fire;
                if (stage_fire) begin
                    stage_req_q <= input_req;
                    stage_store_q <= accept_store;
                    stage_set_q <= input_set;
                    stage_tag_q <= input_tag;
                    for (int way = 0; way < WAYS; way++)
                        stage_hits_q[way] <= valid_q[input_set][way]
                            && tag_q[input_set][way] == input_tag;
                end
            end
            if (stage_valid_q && stage_consume) begin
                if (stage_crossline) begin
                    if (stage_store_q) begin
                        fatal_q <= '{valid:1'b1, src:FATAL_MAINT,
                                     line_paddr:{stage_req_q.paddr[PADDR_W-1:6], 6'b0}};
                        mstate_q <= M_FAULT;
                    end else begin
                        ld_resp_q <= '{valid:1'b1, src:DC_SRC_LOAD,
                            status:DC_ERROR, lq_tag:stage_req_q.lq_tag, sq_idx:'0,
                            rdata:'0, sc_fail:1'b0};
                    end
                end else if (stage_hit) begin
                    if (stage_store_q) begin
                        dirty_q[stage_set_q][stage_way] <= 1'b1;
                        st_resp_q <= '{valid:1'b1, src:DC_SRC_STORE_DRAIN,
                            status:DC_OK, lq_tag:'0, sq_idx:stage_req_q.sq_idx,
                            rdata:'0, sc_fail:1'b0};
                    end else begin
                        ld_resp_q <= '{valid:1'b1, src:DC_SRC_LOAD,
                            status:DC_OK, lq_tag:stage_req_q.lq_tag, sq_idx:'0,
                            rdata:extract_load(stage_line, stage_req_q), sc_fail:1'b0};
                    end
                end else if (mstate_q == M_IDLE) begin
                    m_req_q <= stage_req_q;
                    m_store_q <= stage_store_q;
                    m_line_q <= {stage_req_q.paddr[PADDR_W-1:6], 6'b0};
                    m_set_q <= stage_set_q;
                    m_tag_q <= stage_tag_q;
                    m_way_q <= stage_victim_way;
                    m_victim_line_q <= {tag_q[stage_set_q][stage_victim_way], stage_set_q, 6'b0};
                    m_victim_data_q <= stage_victim_line;
                    m_beat_q <= '0;
                    m_data_q <= '0;
                    m_error_q <= 1'b0;
                    victim_rr_q <= victim_rr_q + way_t'(1);
                    mstate_q <= valid_q[stage_set_q][stage_victim_way]
                             && dirty_q[stage_set_q][stage_victim_way] ? M_WB : M_SEND;
                    if (valid_q[stage_set_q][stage_victim_way]
                     && !dirty_q[stage_set_q][stage_victim_way])
                        valid_q[stage_set_q][stage_victim_way] <= 1'b0;
                end
            end
            case (mstate_q)
                M_WB: if (l2_wb_valid_o && l2_wb_ready_i) begin
                    if (l2_wb_error_i) begin
                        fatal_q <= '{valid:1'b1, src:FATAL_L1D_WB,
                                     line_paddr:m_victim_line_q};
                        mstate_q <= M_FAULT;
                    end else begin
                        valid_q[m_set_q][m_way_q] <= 1'b0;
                        dirty_q[m_set_q][m_way_q] <= 1'b0;
                        mstate_q <= M_SEND;
                    end
                end
                M_SEND: if (l2_req_ready_i) mstate_q <= M_RECV;
                M_RECV: if (l2_resp_i.valid) begin
                    assert (l2_resp_i.txn_id == '0
                         && l2_resp_i.last == (m_beat_q == beat_t'(3)))
                        else $fatal(1, "DCache: L2 beat/id mismatch");
                    m_data_q[m_beat_q*128 +: 128] <= l2_resp_i.data;
                    m_error_q <= m_error_q || l2_resp_i.error;
                    if (l2_resp_i.last) begin
                        if (m_error_q || l2_resp_i.error) begin
                            if (m_store_q) begin
                                fatal_q <= '{valid:1'b1, src:FATAL_MAINT,
                                             line_paddr:m_line_q};
                                mstate_q <= M_FAULT;
                            end else begin
                                ld_resp_q <= '{valid:1'b1, src:DC_SRC_LOAD,
                                    status:DC_ERROR, lq_tag:m_req_q.lq_tag, sq_idx:'0,
                                    rdata:'0, sc_fail:1'b0};
                                mstate_q <= M_IDLE;
                            end
                        end else mstate_q <= M_INSTALL;
                    end else m_beat_q <= m_beat_q + beat_t'(1);
                end
                M_INSTALL: begin
                    tag_q[m_set_q][m_way_q] <= m_tag_q;
                    valid_q[m_set_q][m_way_q] <= 1'b1;
                    dirty_q[m_set_q][m_way_q] <= m_store_q;
                    wake_q <= '{valid:1'b1, line_paddr:m_line_q};
                    if (m_store_q) begin
                        st_resp_q <= '{valid:1'b1, src:DC_SRC_STORE_DRAIN,
                            status:DC_OK, lq_tag:'0, sq_idx:m_req_q.sq_idx,
                            rdata:'0, sc_fail:1'b0};
                    end else begin
                        ld_resp_q <= '{valid:1'b1, src:DC_SRC_LOAD,
                            status:DC_OK, lq_tag:m_req_q.lq_tag, sq_idx:'0,
                            rdata:extract_load(m_data_q, m_req_q), sc_fail:1'b0};
                    end
                    mstate_q <= M_IDLE;
                end
                default: ;
            endcase
        end
    end

    assign amo_req_ready_o = 1'b0;
    assign amo_resp_o = '0;
    assign ptw_req_ready_o = 1'b0;
    assign ptw_resp_o = '0;
    assign pf_req_ready_o = 1'b0;
    assign clean_all_done_o = clean_all_req_i;
    assign clean_all_busy_o = 1'b0;
    assign pte_ad_req_ready_o = 1'b0;
    assign pte_ad_resp_o = '0;
    assign perf_o = '0;
endmodule
