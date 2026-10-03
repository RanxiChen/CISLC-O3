/**
 * L2 cache —— L1I/L1D 下级 inclusive 缓存、DMA 行协调入口、DDR AXI 主口
 *
 * 已定结构（B41，2026-10-02 用户确认；B03/B08 的既有定位保持）：
 * - L2 已纳入首版，不是可选模块；单 hart，只处理一个 hart 与 SD DMA 的必要一致性，不引入
 *   多核 MESI/MOESI 目录。
 * - inclusive：覆盖 L1I 与 L1D。L1 中任何有效行在 L2 中必有驻留项或同行在途事务。
 * - 组相联；tree-PLRU 替换（每 set ways-1 位；命中与安装时更新；选 victim 时跳过正在回收、在途或
 *   受保护的 way；路数须为 2 的幂）。
 * - 淘汰（inclusive 回收，l2_recall_ctrl）：保护目标行 → 定向失效两个 L1（首版每次都探测两个，
 *   不建精确驻留目录）→ L1D 脏副本先交回最新数据再确认 → 协调在途回填，防止旧响应重新安装 →
 *   收齐确认、接管最新数据并为必要写回提供可靠保存位置后才复用 way。inclusive 不代表 L2 数据
 *   始终最新。容量替换不清 LR/SC reservation。
 * - 资源：启动回收前预留接收/写回所需资源；探测应答不依赖普通 miss 的空闲 MSHR；资源不足推迟新
 *   回收，不堵旧事务完成。
 * - 同一物理行由统一行事务状态确定顺序（兼容读 miss 合并）：回填、L1D 写回、淘汰、DMA 不能各自
 *   独立修改同行状态；不同行继续并行。
 * - 完整 L1D 行写回不需要先读 DDR；正常情况下应命中 L2 项或同行在途事务；正在回收时并入回收
 *   事务，不重新分配；既无驻留项又无在途事务时暴露包含关系错误（inclusion_err_o），不能用自动
 *   重新分配掩盖。
 * - 下级不能静默成为全部访存的全局串行瓶颈：独立命中继续服务、多个下级请求在途是设计目标。
 * - DMA 不能绕过仍可能持有最新数据的 L2 直接读旧 DDR；部分行写用最新数据保留未覆盖字节（B08）。
 *   内含 dma_line_coord：一笔 DMA 行协调事务在途，探测唯一 L1D；DMA 探测与回收探测在本模块内
 *   仲裁进入 L1D 的同一维护入口（l1d_probe_*），二者均不得被对方永久饥饿。
 * - 写回 DDR 失败（BRESP 错误等）按 B39 上报 fatal，不按成功释放，维护/DMA 不虚假完成。
 * - 曾讨论让 L2 跟踪 L1I 驻留、绕过 L1 查询，未选为第一版（前端 11.3 节）。
 *
 * 未冻结（不能当作已决定）：容量、路数、bank、line 大小、MSHR/回收槽/写回缓冲数、AXI 宽度/ID/
 * 突发、与 L1 line 大小不同时的处理、DDR 控制器接口（KCU105 MIG 等）、具体流水拍数；
 * “L2 整行收齐、无错误并安装后再交付 L1，暂不 early restart”仍只是建议，未确认。
 *
 * 当前实现状态：闭环简化（L4 I-side）。
 * - 已实现：组相联行阵列、4-way tree-PLRU、L1I/L1D 读行、AXI4 读回填、
 *   inclusive 容量回收的 L1I recall 与 L1D probe、脏副本接管和 AXI 写回。
 * - 闭环简化：普通请求一次只处理一笔，独立命中与多 MSHR 尚未实现，
 *   偏离 B03/B41 的并发目标；DMA 行协调与普通 L1D 写回的完整竞态待后级。
 *   完整行收齐并安装后才交付 L1 是本级暂用策略，B41 尚未冻结 early restart。
 * - 测试：sim/cocotb/l2_cache/；sim/o3/ 的 ICache→L2→AXI 取指闭环。
 * 现有 rtl/memory/axi_master.sv 是单笔在途冒烟主口，不用于本模块。
 *
 * 逐周期说明（目标）：
 * - 周期 N：L1/DMA 请求进入 L2 主流水查 tag，同行统一事务状态决定命中/合并/等待/新分配。
 * - miss 分配：tree-PLRU 选 victim；victim 有效时先启动回收（需资源预留），回收完成前该 way 不复用。
 * - 回收与 DMA 探测按各自身份收齐应答后推进；写回 DDR 在 B 通道确认后才释放写回缓冲。
 *
 */
module l2_cache
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int AXI_ID_W   = CFG.l2.axi_id_bits,
    localparam int AXI_DATA_W = CFG.l2.axi_data_bits
) (
    input  logic            clk,
    input  logic            rst,

    // L1I
    input  logic            l1i_req_valid_i,
    output logic            l1i_req_ready_o,
    input  l2_req_t         l1i_req_i,
    output l2_resp_t        l1i_resp_o,
    input  logic            l1i_resp_ready_i,

    // L1D 回填与写回
    input  logic            l1d_req_valid_i,
    output logic            l1d_req_ready_o,
    input  l2_req_t         l1d_req_i,
    output l2_resp_t        l1d_resp_o,
    input  logic            l1d_resp_ready_i,
    input  logic            l1d_wb_valid_i,
    output logic            l1d_wb_ready_o,
    input  paddr_t          l1d_wb_line_paddr_i,
    input  logic [DC_LINE_BYTES*8-1:0] l1d_wb_data_i,
    output logic            l1d_wb_error_o,       // 写回被拒（包含关系错误等，B39/B41）

    // L1I inclusive 回收的定向失效（B41）
    output logic            l1i_recall_valid_o,
    input  logic            l1i_recall_ready_i,
    output l1_recall_req_t  l1i_recall_o,
    input  l1i_recall_resp_t l1i_recall_resp_i,

    // L1D 维护探测：DMA 行协调（B08）与 inclusive 回收（B41）共用
    output logic            l1d_probe_valid_o,
    input  logic            l1d_probe_ready_i,
    output dc_probe_req_t   l1d_probe_o,
    input  dc_probe_resp_t  l1d_probe_resp_i,

    // SD DMA 行事务
    input  logic            dma_req_valid_i,
    output logic            dma_req_ready_o,
    input  dma_req_t        dma_req_i,
    output dma_resp_t       dma_resp_o,

    // DDR AXI4 主口（信号组按 AXI4，宽度待定）
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [AXI_ID_W-1:0]   m_axi_awid,
    output logic [PADDR_W-1:0]    m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [AXI_DATA_W-1:0] m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [AXI_ID_W-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [AXI_ID_W-1:0]   m_axi_arid,
    output logic [PADDR_W-1:0]    m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [AXI_ID_W-1:0]   m_axi_rid,
    input  logic [AXI_DATA_W-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,

    output logic            inclusion_err_o,      // B41：L1D 写回既无驻留项又无同行在途事务
    output fatal_evt_t      fatal_o,              // B39：写回 DDR 失败
    output be_perf_t        perf_o
);
    localparam int SETS = CFG.l2.sets;
    localparam int WAYS = CFG.l2.ways;
    localparam int LINE_BYTES = CFG.l2.line_bytes;
    localparam int LINE_BITS = LINE_BYTES * 8;
    localparam int BEAT_BYTES = AXI_DATA_W / 8;
    localparam int BEATS = LINE_BYTES / BEAT_BYTES;
    localparam int SET_W = $clog2(SETS);
    localparam int TAG_W = PADDR_W - 6 - SET_W;
    typedef logic [SET_W-1:0] set_t;
    typedef logic [TAG_W-1:0] tag_t;
    typedef logic [1:0] way_t;
    typedef logic [1:0] beat_t;
    typedef enum logic [3:0] {
        S_IDLE, S_RECALL, S_WAIT_RECALL, S_WB_AW, S_WB_W,
        S_WB_B, S_AR, S_R, S_SEND, S_FAULT
    } state_t;

    state_t state_q;
    logic valid_q [SETS][WAYS];
    logic dirty_q [SETS][WAYS];
    tag_t tag_q [SETS][WAYS];
    logic [LINE_BITS-1:0] data_q [SETS][WAYS];
    logic [2:0] plru_q [SETS];
    logic source_d_q;
    l2_req_t req_q;
    set_t set_q;
    way_t way_q;
    beat_t beat_q;
    logic error_q;
    logic i_sent_q, d_sent_q, i_done_q, d_done_q, evict_dirty_q;
    logic [PADDR_W-1:0] victim_line_q;
    logic inclusion_error_q;
    fatal_evt_t fatal_q;

    set_t lookup_set;
    tag_t lookup_tag;
    logic [WAYS-1:0] lookup_hit;
    logic lookup_found;
    way_t lookup_way, victim_way;
    logic [PADDR_W-1:0] lookup_addr;
    logic lookup_source_d;
    logic lookup_valid;
    logic [WAYS-1:0] wb_hit;

    initial begin
        assert (WAYS == 4 && SETS > 1 && (SETS & (SETS-1)) == 0)
            else $fatal(1, "L2: current tree-PLRU implementation requires 4 ways and power-of-two sets");
        assert (LINE_BYTES == 64 && BEAT_BYTES == 16 && BEATS == 4
             && DC_LINE_BYTES == LINE_BYTES && ICACHE_LINE_BYTES == LINE_BYTES)
            else $fatal(1, "L2: line/beat widths must match current L1 and AXI contracts");
    end

    function automatic way_t plru_victim(input logic [2:0] bits);
        if (!bits[0]) return bits[1] ? 2'd1 : 2'd0;
        return bits[2] ? 2'd3 : 2'd2;
    endfunction

    function automatic logic [2:0] plru_touch(input logic [2:0] old_bits,
                                                input way_t way);
        logic [2:0] result;
        result = old_bits;
        if (way < 2) begin
            result[0] = 1'b1;
            result[1] = (way == 0);
        end else begin
            result[0] = 1'b0;
            result[2] = (way == 2);
        end
        return result;
    endfunction

    // L1I wins a simultaneous request. A valid dirty L1D writeback is
    // accepted independently in S_IDLE; absent lines raise inclusion_err.
    assign lookup_valid = l1i_req_valid_i || l1d_req_valid_i;
    assign lookup_source_d = !l1i_req_valid_i;
    assign lookup_addr = l1i_req_valid_i ? l1i_req_i.line_paddr
                                        : l1d_req_i.line_paddr;
    assign lookup_set = set_t'(lookup_addr[6 +: SET_W]);
    assign lookup_tag = tag_t'(lookup_addr[PADDR_W-1:6+SET_W]);
    always_comb begin
        lookup_hit = '0;
        lookup_way = '0;
        victim_way = plru_victim(plru_q[lookup_set]);
        for (int way = 0; way < WAYS; way++) begin
            if (valid_q[lookup_set][way]
              && tag_q[lookup_set][way] == lookup_tag) begin
                lookup_hit[way] = 1'b1;
                lookup_way = way_t'(way);
            end
        end
        for (int way = WAYS-1; way >= 0; way--)
            if (!valid_q[lookup_set][way]) victim_way = way_t'(way);
    end
    assign lookup_found = |lookup_hit;
    assign l1i_req_ready_o = (state_q == S_IDLE) && !l1d_wb_valid_i;
    assign l1d_req_ready_o = l1i_req_ready_o && !l1i_req_valid_i;

    always_comb begin
        wb_hit = '0;
        for (int way = 0; way < WAYS; way++)
            wb_hit[way] = valid_q[set_t'(l1d_wb_line_paddr_i[6 +: SET_W])][way]
                       && tag_q[set_t'(l1d_wb_line_paddr_i[6 +: SET_W])][way]
                          == tag_t'(l1d_wb_line_paddr_i[PADDR_W-1:6+SET_W]);
    end
    assign l1d_wb_ready_o = (state_q == S_IDLE);
    assign l1d_wb_error_o = l1d_wb_valid_i && l1d_wb_ready_o && !(|wb_hit);
    assign inclusion_err_o = inclusion_error_q;
    assign fatal_o = fatal_q;
    assign perf_o = '0;
    assign dma_req_ready_o = 1'b0;
    assign dma_resp_o = '0;

    // A victim remains protected until both L1s confirm invalidation. The
    // D-side dirty data replaces the stale L2 copy before AXI writeback.
    assign l1i_recall_valid_o = (state_q == S_RECALL) && !i_sent_q;
    assign l1i_recall_o = '{line_paddr:victim_line_q, recall_id:'0};
    assign l1d_probe_valid_o = (state_q == S_RECALL) && !d_sent_q;
    assign l1d_probe_o = '{kind:PROBE_RECALL, line_paddr:victim_line_q,
                           dma_write:1'b0, recall_id:'0};

    always_comb begin
        l1i_resp_o = '0;
        l1d_resp_o = '0;
        if (state_q == S_SEND) begin
            if (source_d_q) begin
                l1d_resp_o.valid = 1'b1;
                l1d_resp_o.txn_id = req_q.txn_id;
                l1d_resp_o.data = error_q ? '0
                    : data_q[set_q][way_q][beat_q*AXI_DATA_W +: AXI_DATA_W];
                l1d_resp_o.last = (beat_q == beat_t'(BEATS-1));
                l1d_resp_o.error = error_q;
            end else begin
                l1i_resp_o.valid = 1'b1;
                l1i_resp_o.txn_id = req_q.txn_id;
                l1i_resp_o.data = error_q ? '0
                    : data_q[set_q][way_q][beat_q*AXI_DATA_W +: AXI_DATA_W];
                l1i_resp_o.last = (beat_q == beat_t'(BEATS-1));
                l1i_resp_o.error = error_q;
            end
        end
    end

    assign m_axi_awvalid = (state_q == S_WB_AW);
    assign m_axi_awid = '0;
    assign m_axi_awaddr = victim_line_q;
    assign m_axi_awlen = 8'(BEATS-1);
    assign m_axi_awsize = 3'($clog2(BEAT_BYTES));
    assign m_axi_awburst = 2'b01;
    assign m_axi_wvalid = (state_q == S_WB_W);
    assign m_axi_wdata = data_q[set_q][way_q][beat_q*AXI_DATA_W +: AXI_DATA_W];
    assign m_axi_wstrb = '1;
    assign m_axi_wlast = (beat_q == beat_t'(BEATS-1));
    assign m_axi_bready = (state_q == S_WB_B);
    assign m_axi_arvalid = (state_q == S_AR);
    assign m_axi_arid = '0;
    assign m_axi_araddr = req_q.line_paddr;
    assign m_axi_arlen = 8'(BEATS-1);
    assign m_axi_arsize = 3'($clog2(BEAT_BYTES));
    assign m_axi_arburst = 2'b01;
    assign m_axi_rready = (state_q == S_R);

    // N: accept a request and select its resident or victim way. N+1 onward:
    // recall if required, then perform an AXI burst, install, and stream four
    // response beats. Valid/ready stalls preserve the beat and its identity.
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= S_IDLE;
            source_d_q <= 1'b0;
            req_q <= '0;
            set_q <= '0;
            way_q <= '0;
            beat_q <= '0;
            error_q <= 1'b0;
            i_sent_q <= 1'b0;
            d_sent_q <= 1'b0;
            i_done_q <= 1'b0;
            d_done_q <= 1'b0;
            evict_dirty_q <= 1'b0;
            victim_line_q <= '0;
            inclusion_error_q <= 1'b0;
            fatal_q <= '0;
            for (int set_idx = 0; set_idx < SETS; set_idx++) begin
                plru_q[set_idx] <= '0;
                for (int way = 0; way < WAYS; way++) begin
                    valid_q[set_idx][way] <= 1'b0;
                    dirty_q[set_idx][way] <= 1'b0;
                end
            end
        end else begin
            if (l1d_wb_valid_i && l1d_wb_ready_o) begin
                if (!(|wb_hit)) inclusion_error_q <= 1'b1;
                else for (int way = 0; way < WAYS; way++)
                    if (wb_hit[way]) begin
                        data_q[set_t'(l1d_wb_line_paddr_i[6 +: SET_W])][way]
                            <= l1d_wb_data_i;
                        dirty_q[set_t'(l1d_wb_line_paddr_i[6 +: SET_W])][way]
                            <= 1'b1;
                    end
            end
            case (state_q)
                S_IDLE: if (lookup_valid && !l1d_wb_valid_i) begin
                    assert (lookup_addr[5:0] == '0)
                        else $fatal(1, "L2: unaligned line request");
                    source_d_q <= lookup_source_d;
                    req_q <= lookup_source_d ? l1d_req_i : l1i_req_i;
                    set_q <= lookup_set;
                    error_q <= 1'b0;
                    beat_q <= '0;
                    if (lookup_found) begin
                        way_q <= lookup_way;
                        plru_q[lookup_set] <= plru_touch(plru_q[lookup_set], lookup_way);
                        state_q <= S_SEND;
                    end else begin
                        way_q <= victim_way;
                        if (valid_q[lookup_set][victim_way]) begin
                            victim_line_q <= {tag_q[lookup_set][victim_way],
                                              lookup_set, 6'b0};
                            i_sent_q <= 1'b0;
                            d_sent_q <= 1'b0;
                            i_done_q <= 1'b0;
                            d_done_q <= 1'b0;
                            evict_dirty_q <= dirty_q[lookup_set][victim_way];
                            state_q <= S_RECALL;
                        end else state_q <= S_AR;
                    end
                end
                S_RECALL: begin
                    if (l1i_recall_valid_o && l1i_recall_ready_i) i_sent_q <= 1'b1;
                    if (l1d_probe_valid_o && l1d_probe_ready_i) d_sent_q <= 1'b1;
                    if ((i_sent_q || l1i_recall_ready_i)
                     && (d_sent_q || l1d_probe_ready_i)) state_q <= S_WAIT_RECALL;
                end
                S_WAIT_RECALL: begin
                    if (i_done_q && d_done_q) begin
                        if (evict_dirty_q) begin
                            beat_q <= '0;
                            state_q <= S_WB_AW;
                        end else begin
                            valid_q[set_q][way_q] <= 1'b0;
                            state_q <= S_AR;
                        end
                    end
                end
                S_WB_AW: if (m_axi_awready) state_q <= S_WB_W;
                S_WB_W: if (m_axi_wready) begin
                    if (beat_q == beat_t'(BEATS-1)) state_q <= S_WB_B;
                    else beat_q <= beat_q + 1'b1;
                end
                S_WB_B: if (m_axi_bvalid) begin
                    if (m_axi_bresp != 2'b00) begin
                        fatal_q <= '{valid:1'b1, src:FATAL_L2_WB,
                                     line_paddr:victim_line_q};
                        state_q <= S_FAULT;
                    end else begin
                        valid_q[set_q][way_q] <= 1'b0;
                        dirty_q[set_q][way_q] <= 1'b0;
                        state_q <= S_AR;
                    end
                end
                S_AR: if (m_axi_arready) begin
                    beat_q <= '0;
                    error_q <= 1'b0;
                    state_q <= S_R;
                end
                S_R: if (m_axi_rvalid) begin
                    data_q[set_q][way_q][beat_q*AXI_DATA_W +: AXI_DATA_W]
                        <= m_axi_rdata;
                    error_q <= error_q || (m_axi_rresp != 2'b00)
                             || (m_axi_rid != '0)
                             || (m_axi_rlast != (beat_q == beat_t'(BEATS-1)));
                    if (beat_q == beat_t'(BEATS-1)) begin
                        if (!(error_q || m_axi_rresp != 2'b00
                            || m_axi_rid != '0 || !m_axi_rlast)) begin
                            valid_q[set_q][way_q] <= 1'b1;
                            dirty_q[set_q][way_q] <= 1'b0;
                            tag_q[set_q][way_q] <= tag_t'(req_q.line_paddr[PADDR_W-1:6+SET_W]);
                            plru_q[set_q] <= plru_touch(plru_q[set_q], way_q);
                        end
                        beat_q <= '0;
                        state_q <= S_SEND;
                    end else beat_q <= beat_q + 1'b1;
                end
                S_SEND: if ((source_d_q && l1d_resp_ready_i)
                         || (!source_d_q && l1i_resp_ready_i)) begin
                    if (beat_q == beat_t'(BEATS-1)) state_q <= S_IDLE;
                    else beat_q <= beat_q + 1'b1;
                end
                default: state_q <= S_FAULT;
            endcase
            if ((state_q == S_RECALL || state_q == S_WAIT_RECALL)
              && l1i_recall_resp_i.valid && l1i_recall_resp_i.recall_id == '0)
                i_done_q <= l1i_recall_resp_i.quiesced;
            if ((state_q == S_RECALL || state_q == S_WAIT_RECALL)
              && l1d_probe_resp_i.valid && l1d_probe_resp_i.recall_id == '0) begin
                d_done_q <= 1'b1;
                if (l1d_probe_resp_i.had_dirty) begin
                    data_q[set_q][way_q] <= l1d_probe_resp_i.dirty_data;
                    dirty_q[set_q][way_q] <= 1'b1;
                    evict_dirty_q <= 1'b1;
                end
            end
        end
    end
endmodule
