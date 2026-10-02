/**
 * ICache —— 四级流水、两 bank、非阻塞指令缓存（目标），含 ITLB/PMP/PMA
 *
 * 作用（目标，第 8～9 节）：
 * - 正常命中、无资源冲突时每拍接受一个 demand 请求，四拍返回（D10）。
 *     S0：并行启动 ITLB 与 tag/data 阵列访问；
 *     S1：ITLB 命中比较、PPN/权限选择；
 *     S2：way tag 比较、PMP 范围匹配、PMA 属性判定；
 *     S3：PMP 优先级/权限汇总、数据选择，形成响应或 miss 请求。
 * - 响应按 rq_idx 写回返回队列，允许 hit under miss（D14）；异常也完成队列项。
 * - 接受 FTQ 预取请求：查询 L1/在途，必要时由 MSHR 向 L2 预取（D18、第 11.3 节）。
 *
 * 需要补充实现的机制（基线已定）：
 * 1) D11/D12：64B line 整条交错到 2 个 bank，bank = addr[6]；每 bank 一读口一写口；
 *    16B 内不再分 bank。tag/status 阵列端口也要核对。
 * 2) VIPT 思路：4KiB 页下 index 与 bank 位必须落在页内偏移，或另行处理同义地址（第 8 节）。
 * 3) 翻译/权限/PMP 未完成时不能把数据交给指令流；TLB miss 不是错误物理地址的 hit。
 * 4) D13：回填冲突等待，优先在 S0 用 ready=0 阻止已知危险访问；已进流水的请求遇到
 *    必须等待的条件时保持所在阶段并正确回压，不靠取消重发。
 * 5) 未完整安装的 line 不参与命中；完整可用后才发布 valid；read-during-write 显式定义。
 * 6) refill 必须能前进，不被等待它的 demand 反向堵死。
 * 7) D17：错误路径已接受请求照常完成，由返回队列丢弃；本模块无需按年龄 kill。
 * 8) D27：请求携带 epoch，旧 epoch 结果被隔离；D28：命中仍按当前 PMP 检查。
 * 9) D25：inv_all_i 使整个 ICache 失效（清 valid，不写零 data）；调用前由
 *    frontend_sync_ctrl 保证在途结束（idle_o）。
 * 10) 预取与 demand 不同 bank 时可并行查 tag；同 bank 两读竞争读口（第 11.3 节）。
 * 11) B41 L2 inclusive 回收（2026-10-02 确认）：recall_* 收到 L2 定向失效某物理行时，
 *     经本模块自己的维护入口（与回填写口仲裁，不进入 S0 demand 查询路径，不增加普通命中
 *     的流水级）清该行 valid；若同行回填仍在 MSHR 中，标记为不可安装，旧响应不得在失效后
 *     重新装回；完成后回复 quiesced。L1I 无脏数据。回收应答不得依赖普通 miss 的空闲 MSHR，
 *     也不能被等待中的 demand 反向堵死。
 *
 * 细节待定：容量、路数、替换、ITLB 组织、MSHR 数、refill beat 宽度、冲突等待粒度
 * （第 13 节第 5 条）；预取查询仲裁与公平性。
 *
 * 未设计：
 * - ITCM：不在设计基线中，去留未定。当前实现及 itcm_init_* 端口沿用现状。
 * - 不可缓存取指路径（与 pma_checker 一同未设计）。
 *
 * 当前实现状态与缺口：
 * - 保留 HEAD 06462b0 的阻塞式实现：固定地址 ITCM、组相联 Cache、64B line、16B 窗口、
 *   单 miss refill 状态机；flush 失效 Cache line；kill 清查找/replay 并丢弃迟到 refill。
 *   对应端口（s0_*、refill_*、out_*、flush、kill）标为“旧合同”，目标总装不再连接。
 * - 旧实现缺口：只有一个 miss；没有 S0～S3 流水；没有请求身份；内部“bank”是行内按 16B
 *   切分（NUM_BANKS=line/fetch），不符合 D11 的整行交错两 bank；无 ITLB/PMP/PMA；
 *   refill 一次返回整条 line；PC 当作物理地址使用。
 * - 参数已改为由 CFG 推导，模块不再有默认值。目标端口与子模块例化已列出，均未驱动。
 *
 * 旧实现逐周期说明：
 * 周期N组合产生ready与范围判断，周期N上升沿锁存ITCM数据或推进Cache miss状态，
 * 周期N+1可见ITCM/Cache命中返回、等待状态或refill完成数据。
 *
 * 目标周期行为：
 * - 周期 N：req 握手进入 S0；N+1 S1；N+2 S2；N+3 S3 产生 resp_o 或 miss 分配 MSHR。
 * - miss 请求在 MSHR 安装完成后重新查询（或由 MSHR 数据直接响应，方式待定）。
 *
 * 本阶段不写测试代码和仿真代码。
 */

module ICache
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::frontend_cfg_t CFG,
    // 旧实现使用的名称，全部由 CFG 推导，不再有默认值。
    localparam int ADDR_WIDTH = o3_pkg::PC_WIDTH,              // 旧合同：未区分 VA/PA
    localparam int ICACHE_WAYS = CFG.icache.ways,
    localparam int ICACHE_BLOCK_SIZE_BYTES = CFG.icache.line_bytes,
    localparam int FETCH_BYTES = CFG.fetch.region_bytes,
    localparam int NUM_SETS = CFG.icache.sets,
    localparam logic [ADDR_WIDTH-1:0] ITCM_BASE = ADDR_WIDTH'(CFG.icache.itcm_base),
    localparam int ITCM_BYTES = CFG.icache.itcm_bytes
) (

    input  logic                      clk,
    input  logic                      rst,

    // ---------------- 旧合同（迁移后删除；itcm_init_* 去留未设计） ----------------
    input  logic                      flush,
    input  logic                      kill,
    input  logic                      s0_valid,
    output logic                      s0_ready,
    input  logic [ADDR_WIDTH-1:0]     s0_pc,
    output logic                      refill_req_valid,
    output logic [ADDR_WIDTH-1:0]     refill_req_pc,
    input  logic                      refill_resp_valid,
    input  logic [ADDR_WIDTH-1:0]     refill_resp_pc,
    input  logic                      refill_resp_error,
    input  logic [ICACHE_BLOCK_SIZE_BYTES*8-1:0] refill_resp_data,
    input  logic                      itcm_init_valid_i,
    input  logic [ADDR_WIDTH-1:0]     itcm_init_addr_i,
    input  logic [63:0]               itcm_init_data_i,
    input  logic [7:0]                itcm_init_wmask_i,
    output logic                      out_valid,
    output logic                      out_hit,
    output logic [ADDR_WIDTH-1:0]     out_pc,
    output logic [FETCH_BYTES*8-1:0]  out_data,
    output logic                      out_error,

    // ---------------- 目标合同 ----------------
    // demand：FTQ → S0；响应按 rq_idx 写回返回队列
    input  logic                      req_valid_i,
    output logic                      req_ready_o,
    input  icache_req_t               req_i,
    output icache_resp_t              resp_o,

    // 预取查询（已翻译或需翻译）
    input  logic                      pf_req_valid_i,
    output logic                      pf_req_ready_o,
    input  pf_req_t                   pf_req_i,
    output pf_resp_t                  pf_resp_o,

    // 共享 PTW（经 ITLB）
    output logic                      ptw_req_valid_o,
    input  logic                      ptw_req_ready_i,
    output ptw_req_t                  ptw_req_o,
    input  ptw_resp_t                 ptw_resp_i,

    // L2
    output logic                      l2_req_valid_o,
    input  logic                      l2_req_ready_i,
    output l2_req_t                   l2_req_o,
    input  l2_resp_t                  l2_resp_i,
    output logic                      l2_resp_ready_o,

    // CSR 派生状态与系统同步
    input  fe_csr_t                   csr_i,
    input  pmp_state_t                pmp_i,
    output logic                      pmp_update_done_o,
    input  sfence_req_t               sfence_i,
    output logic                      sfence_done_o,
    input  logic                      inv_all_i,
    output logic                      inv_done_o,
    output logic                      idle_o,

    // L2 inclusive 回收的定向失效（B41）
    input  logic                      recall_valid_i,
    output logic                      recall_ready_o,
    input  l1_recall_req_t            recall_i,
    output l1i_recall_resp_t          recall_resp_o,

    output fe_perf_t                  perf_o
`ifdef O3_ICACHE_DEBUG
    ,
    output logic                      dbg_s0_fire,
    output logic                      dbg_s1_valid,
    output logic [ADDR_WIDTH-1:0]     dbg_s1_pc,
    output logic [$clog2(NUM_SETS)-1:0] dbg_s1_set_idx,
    output logic [$clog2(ICACHE_BLOCK_SIZE_BYTES / FETCH_BYTES)-1:0] dbg_s1_bank_idx,
    output logic [ADDR_WIDTH - (2 + $clog2(FETCH_BYTES / 4) + $clog2(ICACHE_BLOCK_SIZE_BYTES / FETCH_BYTES) + $clog2(NUM_SETS)) - 1:0] dbg_s1_tag,
    output logic [ICACHE_WAYS-1:0]    dbg_s1_way_hit,
    output logic                      dbg_out_valid,
    output logic                      dbg_out_hit,
    output logic [1:0]                dbg_state,
    output logic [FETCH_BYTES*8-1:0]  dbg_done_data,
    output logic [ADDR_WIDTH-1:0]     dbg_miss_pc,
    output logic [ADDR_WIDTH-1:0]     dbg_miss_refill_pc
`endif
);

    // ============================================================
    // 目标结构：子模块例化。S0～S3 流水、阵列 bank 化、仲裁均未实现。
    // ============================================================
    logic             t_itlb_s0_valid;          // 未实现：S0 demand/预取仲裁结果
    vaddr_t           t_itlb_s0_vaddr;
    logic             t_itlb_s1_valid, t_itlb_s1_hit, t_itlb_s1_miss;
    logic [PPN_W-1:0] t_itlb_s1_ppn;
    logic [1:0]       t_itlb_s1_level;
    logic             t_itlb_s1_pf, t_itlb_s1_af;
    paddr_t           t_s2_paddr;               // 未实现：S2 物理地址寄存
    logic             t_s2_valid, t_stall;
    logic             t_pmp_s3_valid, t_pmp_s3_allow, t_pmp_s3_fault;
    logic             t_pma_exec_ok, t_pma_cacheable, t_pma_exists;
    logic             t_mshr_alloc_valid, t_mshr_alloc_ready, t_mshr_alloc_merged;
    paddr_t           t_mshr_alloc_paddr, t_mshr_probe_paddr;
    l2_req_kind_e     t_mshr_alloc_kind;
    logic             t_mshr_probe_inflight;
    logic             t_fill_wr_valid, t_fill_wr_ready, t_fill_wr_error, t_fill_done;
    paddr_t           t_fill_wr_paddr, t_fill_done_paddr;
    logic [ICACHE_LINE_BYTES*8-1:0] t_fill_wr_data;
    logic             t_mshr_idle;
    fe_perf_t         t_perf_itlb, t_perf_mshr;

    itlb #(.CFG(CFG)) u_itlb (
        .clk_i(clk), .rst_i(rst),
        .s0_valid_i(t_itlb_s0_valid), .s0_vaddr_i(t_itlb_s0_vaddr),
        .s1_valid_o(t_itlb_s1_valid), .s1_hit_o(t_itlb_s1_hit), .s1_miss_o(t_itlb_s1_miss),
        .s1_ppn_o(t_itlb_s1_ppn), .s1_level_o(t_itlb_s1_level),
        .s1_page_fault_o(t_itlb_s1_pf), .s1_access_fault_o(t_itlb_s1_af),
        .ptw_req_valid_o(ptw_req_valid_o), .ptw_req_ready_i(ptw_req_ready_i),
        .ptw_req_o(ptw_req_o), .ptw_resp_i(ptw_resp_i),
        .csr_i(csr_i), .sfence_i(sfence_i), .sfence_done_o(sfence_done_o),
        .perf_o(t_perf_itlb)
    );

    pmp_checker #(.CFG(CFG)) u_pmp_checker (
        .clk_i(clk), .rst_i(rst),
        .s2_valid_i(t_s2_valid), .s2_paddr_i(t_s2_paddr), .stall_i(t_stall),
        .s3_valid_o(t_pmp_s3_valid), .s3_allow_o(t_pmp_s3_allow), .s3_fault_o(t_pmp_s3_fault),
        .cfg_i(pmp_i), .priv_i(csr_i.priv), .cfg_update_done_o(pmp_update_done_o)
    );

    pma_checker #(.CFG(CFG)) u_pma_checker (
        .paddr_i(t_s2_paddr),
        .exec_ok_o(t_pma_exec_ok), .cacheable_o(t_pma_cacheable), .exists_o(t_pma_exists)
    );

    icache_mshr #(.CFG(CFG)) u_icache_mshr (
        .clk_i(clk), .rst_i(rst),
        .alloc_valid_i(t_mshr_alloc_valid), .alloc_ready_o(t_mshr_alloc_ready),
        .alloc_line_paddr_i(t_mshr_alloc_paddr), .alloc_kind_i(t_mshr_alloc_kind),
        .alloc_merged_o(t_mshr_alloc_merged),
        .probe_line_paddr_i(t_mshr_probe_paddr), .probe_inflight_o(t_mshr_probe_inflight),
        .l2_req_valid_o(l2_req_valid_o), .l2_req_ready_i(l2_req_ready_i), .l2_req_o(l2_req_o),
        .l2_resp_i(l2_resp_i), .l2_resp_ready_o(l2_resp_ready_o),
        .fill_wr_valid_o(t_fill_wr_valid), .fill_wr_ready_i(t_fill_wr_ready),
        .fill_wr_line_paddr_o(t_fill_wr_paddr), .fill_wr_data_o(t_fill_wr_data),
        .fill_wr_error_o(t_fill_wr_error),
        .fill_done_o(t_fill_done), .fill_done_line_paddr_o(t_fill_done_paddr),
        .idle_o(t_mshr_idle),
        .perf_o(t_perf_mshr)
    );

    // 未实现：req_ready_o/resp_o/pf_*/inv_done_o/idle_o/recall_*/perf_o 的驱动。

    // ============================================================
    // 旧合同实现（HEAD 06462b0），迁移后删除或改造。
    // 注意：下面的 NUM_BANKS 是行内 16B 切分数，不是 D11 的两 bank。
    // ============================================================

    // 一条 cache line 按 FETCH_BYTES 横向切分得到的 bank 数
    localparam int NUM_BANKS = ICACHE_BLOCK_SIZE_BYTES / FETCH_BYTES;
    localparam int DATA_BANK_WIDTH = FETCH_BYTES * 8;
    localparam int BYTE_OFFSET_BITS = 2;
    localparam int WORD_INDEX_BITS = $clog2(FETCH_BYTES / 4);
    localparam int BANK_INDEX_BITS = $clog2(NUM_BANKS);
    localparam int SET_INDEX_BITS = $clog2(NUM_SETS);
    localparam int BANK_INDEX_LSB = BYTE_OFFSET_BITS + WORD_INDEX_BITS;
    localparam int SET_INDEX_LSB = BANK_INDEX_LSB + BANK_INDEX_BITS;
    localparam int TAG_LSB = SET_INDEX_LSB + SET_INDEX_BITS;
    localparam int TAG_WIDTH = ADDR_WIDTH - TAG_LSB;
    localparam int TAG_ARRAY_WIDTH = TAG_WIDTH;
    localparam int WAY_INDEX_BITS = (ICACHE_WAYS > 1) ? $clog2(ICACHE_WAYS) : 1;

    typedef enum logic [1:0] {
        ICACHE_WORK,
        ICACHE_REQ,
        ICACHE_WAIT,
        ICACHE_DONE
    } icache_state_e;

    logic                               data_bank_we   [ICACHE_WAYS][NUM_BANKS];
    logic [$clog2(NUM_SETS)-1:0]        data_bank_addr [ICACHE_WAYS][NUM_BANKS];
    logic [DATA_BANK_WIDTH-1:0]         data_bank_wdata[ICACHE_WAYS][NUM_BANKS];
    logic [DATA_BANK_WIDTH-1:0]         data_bank_rdata[ICACHE_WAYS][NUM_BANKS];
    logic                               tag_array_we   [ICACHE_WAYS];
    logic [$clog2(NUM_SETS)-1:0]        tag_array_addr [ICACHE_WAYS];
    logic [TAG_ARRAY_WIDTH-1:0]         tag_array_wdata[ICACHE_WAYS];
    logic [TAG_ARRAY_WIDTH-1:0]         tag_array_rdata[ICACHE_WAYS];
    logic                               valid_array_q  [ICACHE_WAYS][NUM_SETS];
    logic                               valid_array_d  [ICACHE_WAYS][NUM_SETS];
    logic                               s0_fire;
    logic                               s1_valid_q;
    logic [ADDR_WIDTH-1:0]              s1_pc_q;
    logic [SET_INDEX_BITS-1:0]          s1_set_idx_q;
    logic [BANK_INDEX_BITS-1:0]         s1_bank_idx_q;
    logic [TAG_WIDTH-1:0]               s1_tag_q;
    logic [ICACHE_WAYS-1:0]             s1_way_hit;
    logic [ICACHE_WAYS-1:0]             s1_way_valid;
    logic [DATA_BANK_WIDTH-1:0]         s1_way_data [ICACHE_WAYS];
    logic [DATA_BANK_WIDTH-1:0]         s1_selected_data;
    logic                               s1_hit;
    logic                               work_miss;
    logic                               replay_fire;
    logic                               lookup_fire;
    logic [ADDR_WIDTH-1:0]              lookup_pc;
    logic [SET_INDEX_BITS-1:0]          lookup_set_idx;
    logic [BANK_INDEX_BITS-1:0]         lookup_bank_idx;
    logic [TAG_WIDTH-1:0]               lookup_tag;
    icache_state_e                      state_q;
    logic [ADDR_WIDTH-1:0]              miss_pc_q;
    logic [ADDR_WIDTH-1:0]              miss_refill_pc_q;
    logic [SET_INDEX_BITS-1:0]          miss_set_idx_q;
    logic [BANK_INDEX_BITS-1:0]         miss_bank_idx_q;
    logic [TAG_WIDTH-1:0]               miss_tag_q;
    logic [WAY_INDEX_BITS-1:0]          miss_victim_way_q;
    logic                               refill_discard_q;
    logic [DATA_BANK_WIDTH-1:0]         done_data_q;
    logic                               done_error_q;
    logic                               replay_valid_q;
    logic [ADDR_WIDTH-1:0]              replay_pc_q;
    logic [WAY_INDEX_BITS-1:0]          selected_victim_way;
    logic [15:0]                        lfsr_out;
    logic                               lfsr_enable;
    logic [7:0]                         itcm_mem_q [0:ITCM_BYTES-1];
    logic                               s1_itcm_q;
    logic [DATA_BANK_WIDTH-1:0]         s1_itcm_data_q;

    function automatic logic access_in_itcm(input logic [ADDR_WIDTH-1:0] pc);
        logic [ADDR_WIDTH:0] access_end;
        begin
            access_end = {1'b0, pc} + (ADDR_WIDTH + 1)'(FETCH_BYTES - 1);
            access_in_itcm = (pc >= ITCM_BASE)
                          && (access_end < ({1'b0, ITCM_BASE}
                              + (ADDR_WIDTH + 1)'(ITCM_BYTES)));
        end
    endfunction

    function automatic logic [SET_INDEX_BITS-1:0] get_set_index(input logic [ADDR_WIDTH-1:0] pc);
        return pc[SET_INDEX_LSB +: SET_INDEX_BITS];
    endfunction

    function automatic logic [BANK_INDEX_BITS-1:0] get_bank_index(input logic [ADDR_WIDTH-1:0] pc);
        return pc[BANK_INDEX_LSB +: BANK_INDEX_BITS];
    endfunction

    function automatic logic [TAG_WIDTH-1:0] get_tag(input logic [ADDR_WIDTH-1:0] pc);
        return pc[TAG_LSB +: TAG_WIDTH];
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] get_line_pc(input logic [ADDR_WIDTH-1:0] pc);
        return {pc[ADDR_WIDTH-1:SET_INDEX_LSB], {SET_INDEX_LSB{1'b0}}};
    endfunction

    function automatic logic [DATA_BANK_WIDTH-1:0] get_refill_bank(
        input logic [ICACHE_BLOCK_SIZE_BYTES*8-1:0] line,
        input logic [BANK_INDEX_BITS-1:0] bank_idx
    );
        return line[bank_idx * DATA_BANK_WIDTH +: DATA_BANK_WIDTH];
    endfunction

    // ---- 参数合法性检查 ----
    initial begin
        assert (ICACHE_BLOCK_SIZE_BYTES % FETCH_BYTES == 0)
            else $fatal(1, "ICache: ICACHE_BLOCK_SIZE_BYTES (%0d) must be an integer multiple of FETCH_BYTES (%0d)",
                        ICACHE_BLOCK_SIZE_BYTES, FETCH_BYTES);

        assert ((FETCH_BYTES & (FETCH_BYTES - 1)) == 0)
            else $fatal(1, "ICache: FETCH_BYTES (%0d) must be a power of 2", FETCH_BYTES);

        assert ((ICACHE_BLOCK_SIZE_BYTES & (ICACHE_BLOCK_SIZE_BYTES - 1)) == 0)
            else $fatal(1, "ICache: ICACHE_BLOCK_SIZE_BYTES (%0d) must be a power of 2", ICACHE_BLOCK_SIZE_BYTES);

        assert ((NUM_SETS & (NUM_SETS - 1)) == 0)
            else $fatal(1, "ICache: NUM_SETS (%0d) must be a power of 2", NUM_SETS);

        assert (ICACHE_WAYS > 0)
            else $fatal(1, "ICache: ICACHE_WAYS (%0d) must be greater than 0", ICACHE_WAYS);

        // 当前实现仅支持每周期取 4 条指令（4 * 4B = 16B），详见 doc/icache.md
        assert (FETCH_BYTES == 16)
            else $fatal(1, "ICache: only FETCH_BYTES == 16 (4 instructions per fetch) is supported, got %0d", FETCH_BYTES);

        assert (ITCM_BYTES > 0)
            else $fatal(1, "ICache: ITCM_BYTES must be greater than 0");
    end

    assign s0_ready = (state_q == ICACHE_WORK);
    assign s0_fire = s0_valid && s0_ready;
    assign replay_fire = (state_q == ICACHE_DONE) && replay_valid_q && !flush && !kill;
    assign lookup_fire = s0_fire || replay_fire;
    assign lookup_pc = replay_fire ? replay_pc_q : s0_pc;
    assign lookup_set_idx = get_set_index(lookup_pc);
    assign lookup_bank_idx = get_bank_index(lookup_pc);
    assign lookup_tag = get_tag(lookup_pc);

    assign refill_req_valid = (state_q == ICACHE_REQ) && !refill_discard_q;
    assign refill_req_pc = miss_refill_pc_q;

    assign out_hit = (state_q == ICACHE_WORK) && s1_hit;
    assign out_valid = ((state_q == ICACHE_WORK) && s1_valid_q && s1_hit && !flush && !kill) ||
                       ((state_q == ICACHE_DONE) && !refill_discard_q && !flush && !kill);
    assign out_pc = (state_q == ICACHE_DONE) ? miss_pc_q : s1_pc_q;
    assign out_data = (state_q == ICACHE_DONE) ? done_data_q
                                               : (s1_itcm_q ? s1_itcm_data_q : s1_selected_data);
    assign out_error = (state_q == ICACHE_DONE) ? done_error_q : 1'b0;
    assign work_miss = (state_q == ICACHE_WORK) && s1_valid_q && !s1_hit && !flush && !kill;
    assign lfsr_enable = (state_q == ICACHE_DONE);
`ifdef O3_ICACHE_DEBUG
    assign dbg_s0_fire = s0_fire;
    assign dbg_s1_valid = s1_valid_q;
    assign dbg_s1_pc = s1_pc_q;
    assign dbg_s1_set_idx = s1_set_idx_q;
    assign dbg_s1_bank_idx = s1_bank_idx_q;
    assign dbg_s1_tag = s1_tag_q;
    assign dbg_s1_way_hit = s1_way_hit;
    assign dbg_out_valid = out_valid;
    assign dbg_out_hit = out_hit;
    assign dbg_state = state_q;
    assign dbg_done_data = done_data_q;
    assign dbg_miss_pc = miss_pc_q;
    assign dbg_miss_refill_pc = miss_refill_pc_q;
`endif

    always_comb begin
        selected_victim_way = WAY_INDEX_BITS'(int'(lfsr_out) % ICACHE_WAYS);

        for (int way = 0; way < ICACHE_WAYS; way++) begin
            for (int bank = 0; bank < NUM_BANKS; bank++) begin
                data_bank_we[way][bank]    = 1'b0;
                data_bank_addr[way][bank]  = lookup_set_idx;
                data_bank_wdata[way][bank] = '0;
            end

            tag_array_we[way]    = 1'b0;
            tag_array_addr[way]  = lookup_set_idx;
            tag_array_wdata[way] = '0;

            for (int set = 0; set < NUM_SETS; set++) begin
                valid_array_d[way][set] = valid_array_q[way][set];
            end
        end

        for (int way = 0; way < ICACHE_WAYS; way++) begin
            s1_way_valid[way] = valid_array_q[way][s1_set_idx_q];
            s1_way_hit[way] = s1_valid_q && s1_way_valid[way] && (tag_array_rdata[way] == s1_tag_q);
            s1_way_data[way] = data_bank_rdata[way][s1_bank_idx_q];
        end

        s1_selected_data = '0;
        for (int way = 0; way < ICACHE_WAYS; way++) begin
            if (s1_way_hit[way]) begin
                s1_selected_data = s1_way_data[way];
            end
        end

        for (int way = ICACHE_WAYS - 1; way >= 0; way--) begin
            if (!valid_array_q[way][s1_set_idx_q]) begin
                selected_victim_way = WAY_INDEX_BITS'(way);
            end
        end

        if ((state_q == ICACHE_WAIT) && refill_resp_valid && !refill_resp_error && !refill_discard_q) begin
            for (int bank = 0; bank < NUM_BANKS; bank++) begin
                data_bank_we[miss_victim_way_q][bank]    = 1'b1;
                data_bank_addr[miss_victim_way_q][bank]  = miss_set_idx_q;
                data_bank_wdata[miss_victim_way_q][bank] = get_refill_bank(refill_resp_data, bank[BANK_INDEX_BITS-1:0]);
            end

            tag_array_we[miss_victim_way_q]    = 1'b1;
            tag_array_addr[miss_victim_way_q]  = miss_set_idx_q;
            tag_array_wdata[miss_victim_way_q] = miss_tag_q;
            valid_array_d[miss_victim_way_q][miss_set_idx_q] = 1'b1;
        end
    end

    assign s1_hit = s1_itcm_q || |s1_way_hit;

    // 仿真/调试初始化口使用绝对物理地址。初始化不依赖reset状态，因此testbench
    // 可以在保持核心reset时逐拍装入ELF的ITCM字节。
    always_ff @(posedge clk) begin
        if (itcm_init_valid_i) begin
            for (int byte_idx = 0; byte_idx < 8; byte_idx++) begin
                if (itcm_init_wmask_i[byte_idx]
                 && ((itcm_init_addr_i + ADDR_WIDTH'(byte_idx)) >= ITCM_BASE)
                 && ((itcm_init_addr_i + ADDR_WIDTH'(byte_idx))
                     < (ITCM_BASE + ADDR_WIDTH'(ITCM_BYTES)))) begin
                    itcm_mem_q[$clog2(ITCM_BYTES)'(
                        itcm_init_addr_i + ADDR_WIDTH'(byte_idx) - ITCM_BASE)]
                        <= itcm_init_data_i[(8*byte_idx) +: 8];
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ICACHE_WORK;
            s1_valid_q <= 1'b0;
            s1_pc_q <= '0;
            s1_set_idx_q <= '0;
            s1_bank_idx_q <= '0;
            s1_tag_q <= '0;
            miss_pc_q <= '0;
            miss_refill_pc_q <= '0;
            miss_set_idx_q <= '0;
            miss_bank_idx_q <= '0;
            miss_tag_q <= '0;
            miss_victim_way_q <= '0;
            refill_discard_q <= 1'b0;
            done_data_q <= '0;
            done_error_q <= 1'b0;
            replay_valid_q <= 1'b0;
            replay_pc_q <= '0;
            s1_itcm_q <= 1'b0;
            s1_itcm_data_q <= '0;

            for (int way = 0; way < ICACHE_WAYS; way++) begin
                for (int set = 0; set < NUM_SETS; set++) begin
                    `ifdef O3_ICACHE_WAY0_VALID
                    valid_array_q[way][set] <= (way == 0) ? valid_array_q[way][set] : 1'b0;
                    `else
                    valid_array_q[way][set] <= 1'b0;
                    `endif
                end
            end
        end else if (flush || kill) begin
            s1_valid_q <= 1'b0;
            s1_pc_q <= '0;
            s1_set_idx_q <= '0;
            s1_bank_idx_q <= '0;
            s1_tag_q <= '0;
            replay_valid_q <= 1'b0;
            replay_pc_q <= '0;
            s1_itcm_q <= 1'b0;

            unique case (state_q)
                ICACHE_REQ: begin
                    state_q <= ICACHE_WAIT;
                    refill_discard_q <= 1'b1;
                end
                ICACHE_WAIT: begin
                    state_q <= refill_resp_valid ? ICACHE_WORK : ICACHE_WAIT;
                    refill_discard_q <= refill_resp_valid ? 1'b0 : 1'b1;
                end
                default: begin
                    state_q <= ICACHE_WORK;
                    refill_discard_q <= 1'b0;
                end
            endcase

            if (flush) begin
                for (int way = 0; way < ICACHE_WAYS; way++) begin
                    for (int set = 0; set < NUM_SETS; set++) begin
                        `ifdef O3_ICACHE_WAY0_VALID
                        valid_array_q[way][set] <= (way == 0) ? valid_array_q[way][set] : 1'b0;
                        `else
                        valid_array_q[way][set] <= 1'b0;
                        `endif
                    end
                end
            end
        end else begin
            s1_valid_q <= 1'b0;

            unique case (state_q)
                ICACHE_WORK: begin
                    if (work_miss) begin
                        state_q <= ICACHE_REQ;
                        miss_pc_q <= s1_pc_q;
                        miss_refill_pc_q <= get_line_pc(s1_pc_q);
                        miss_set_idx_q <= s1_set_idx_q;
                        miss_bank_idx_q <= s1_bank_idx_q;
                        miss_tag_q <= s1_tag_q;
                        miss_victim_way_q <= selected_victim_way;
                        refill_discard_q <= 1'b0;
                        replay_valid_q <= s0_fire;
                        if (s0_fire) begin
                            replay_pc_q <= s0_pc;
                        end
                    end else begin
                        state_q <= ICACHE_WORK;
                        s1_valid_q <= lookup_fire;
                        s1_itcm_q <= lookup_fire && access_in_itcm(lookup_pc);
                        if (lookup_fire) begin
                            s1_pc_q <= lookup_pc;
                            s1_set_idx_q <= lookup_set_idx;
                            s1_bank_idx_q <= lookup_bank_idx;
                            s1_tag_q <= lookup_tag;
                            if (access_in_itcm(lookup_pc)) begin
                                for (int byte_idx = 0; byte_idx < FETCH_BYTES; byte_idx++) begin
                                    s1_itcm_data_q[(8*byte_idx) +: 8]
                                        <= itcm_mem_q[$clog2(ITCM_BYTES)'(
                                            lookup_pc + ADDR_WIDTH'(byte_idx) - ITCM_BASE)];
                                end
                            end
                        end
                    end
                end

                ICACHE_REQ: begin
                    state_q <= ICACHE_WAIT;
                end

                ICACHE_WAIT: begin
                    if (refill_resp_valid) begin
                        assert (refill_resp_pc == miss_refill_pc_q)
                            else $fatal(1, "ICache: refill response PC mismatch");
                        if (refill_discard_q) begin
                            state_q <= ICACHE_WORK;
                            refill_discard_q <= 1'b0;
                        end else begin
                            state_q <= ICACHE_DONE;
                            done_error_q <= refill_resp_error;
                            done_data_q <= refill_resp_error ?
                                           {DATA_BANK_WIDTH{1'b1}} :
                                           get_refill_bank(refill_resp_data, miss_bank_idx_q);
                        end
                    end
                end

                ICACHE_DONE: begin
                    state_q <= ICACHE_WORK;
                    refill_discard_q <= 1'b0;
                    replay_valid_q <= 1'b0;
                    s1_valid_q <= replay_fire;
                    s1_itcm_q <= replay_fire && access_in_itcm(lookup_pc);
                    if (replay_fire) begin
                        s1_pc_q <= lookup_pc;
                        s1_set_idx_q <= lookup_set_idx;
                        s1_bank_idx_q <= lookup_bank_idx;
                        s1_tag_q <= lookup_tag;
                    end
                end

                default: begin
                    state_q <= ICACHE_WORK;
                end
            endcase

            for (int way = 0; way < ICACHE_WAYS; way++) begin
                for (int set = 0; set < NUM_SETS; set++) begin
                    valid_array_q[way][set] <= valid_array_d[way][set];
                end
            end
        end
    end

    lfsr u_replacement_lfsr (
        .clk      (clk),
        .rst      (rst),
        .enable   (lfsr_enable),
        .lfsr_out (lfsr_out)
    );

    for (genvar way = 0; way < ICACHE_WAYS; way++) begin : gen_data_way
        for (genvar bank = 0; bank < NUM_BANKS; bank++) begin : gen_data_bank
            `ifdef O3_SIM
            o3_sram #(
                .DATA_WIDTH(DATA_BANK_WIDTH),
                .SRAM_ENTRIES(NUM_SETS),
                `ifdef O3_ICACHE_WAY0_VALID
                .INIT_FILE(
                    (way == 0 && bank == 0) ? "hex/data_way0_bank0.hex" :
                    (way == 0 && bank == 1) ? "hex/data_way0_bank1.hex" :
                    (way == 0 && bank == 2) ? "hex/data_way0_bank2.hex" :
                    (way == 0 && bank == 3) ? "hex/data_way0_bank3.hex" :
                    ""
                )
                `else
                .INIT_FILE("")
                `endif
            ) u_data_sram (
                .clk_i  (clk),
                .rst_i  (rst),
                .we_i   (data_bank_we[way][bank]),
                .data_o (data_bank_rdata[way][bank]),
                .data_i (data_bank_wdata[way][bank]),
                .addr_i (data_bank_addr[way][bank])
            );
            `else
            o3_sram #(
                .DATA_WIDTH(DATA_BANK_WIDTH),
                .SRAM_ENTRIES(NUM_SETS)
            ) u_data_sram (
                .clk_i  (clk),
                .rst_i  (rst),
                .we_i   (data_bank_we[way][bank]),
                .data_o (data_bank_rdata[way][bank]),
                .data_i (data_bank_wdata[way][bank]),
                .addr_i (data_bank_addr[way][bank])
            );
            `endif
        end

        `ifdef O3_SIM
        o3_sram #(
            .DATA_WIDTH(TAG_ARRAY_WIDTH),
            .SRAM_ENTRIES(NUM_SETS),
            `ifdef O3_ICACHE_WAY0_VALID
            .INIT_FILE((way == 0) ? "hex/tag_way0.hex" : "")
            `else
            .INIT_FILE("")
            `endif
        ) u_tag_sram (
            .clk_i  (clk),
            .rst_i  (rst),
            .we_i   (tag_array_we[way]),
            .data_o (tag_array_rdata[way]),
            .data_i (tag_array_wdata[way]),
            .addr_i (tag_array_addr[way])
        );
        `else
        o3_sram #(
            .DATA_WIDTH(TAG_ARRAY_WIDTH),
            .SRAM_ENTRIES(NUM_SETS)
        ) u_tag_sram (
            .clk_i  (clk),
            .rst_i  (rst),
            .we_i   (tag_array_we[way]),
            .data_o (tag_array_rdata[way]),
            .data_i (tag_array_wdata[way]),
            .addr_i (tag_array_addr[way])
        );
        `endif
    end

    `ifdef O3_ICACHE_WAY0_VALID
    initial begin
        for (int s = 0; s < NUM_SETS; s++) begin
            valid_array_q[0][s] = 1'b1;
        end
    end
    `endif

endmodule
