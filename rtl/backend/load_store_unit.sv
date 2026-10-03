/**
 *
 * 【2026-10-02 框架：目标机制与缺口】
 * 目标（B03～B11）：本模块成为访存执行总装：访存发射 → AGU → DTLB → LQ/SQ 依赖检查与 replay → 多 bank DCache。
 * - Load 生命周期（B04）：翻译与 PMP/PMA/边界检查完成才允许有效结果；TLB miss 挂起并释放执行级；
 *   SQ 与 cache 并行查询、统一选择；完成后写回、唤醒、报告 ROB；取消/复用后的迟到响应不得写入。
 * - Store（B05）：地址/数据/mask 与检查齐备即完成；ROB 提交后 SQ 后台 drain；地址与数据是否分开发射未定。
 * - MMIO/不缓存访问：到 ROB 队头、满足先前排序后发出，保留 ROB 等结果，同步错误在原指令报告（B05）。
 * - AMO/LR/SC：ROB 队头交给 DCache 内原子单元（B09）。
 * - FLW/FLD 写 FP preg；FSW/FSD 使用 FP 数据源，进入既有 SQ（B15）。
 * - 精确同步异常：page fault、PMP/PMA 拒绝、对齐/边界错误保留原指令身份报告 ROB；故障 VA 与 PA 分开（B06）。
 * - 依赖（B32 已定）：更老 store 地址未知时 load 等依赖解除，不以固定超时越过；首版无推测越过。
 * - 非对齐（B31 已定）：普通可缓存标量访问同 line 内硬件支持，跨 line 报地址非对齐异常（异常身份
 *   带 crossline_misalign 标志到提交端计数）；MMIO 不走拆分；A 扩展自然对齐。
 * - A/D（B36 已定）：TLB 命中且权限、A/D 满足时走原流水，不新增流水级；store 遇 D=0 标记 needs_D。
 * - 总原则（2026-10-02）：常规 load/store 流水不为一致性/A/D/LR/SC/回收增加流水级或组合检查，
 *   慢路径都在旁侧。
 * 待定：AGU 管线条数与 load/store 组合。
 * 当前缺口：只有单发射、单 Load 在途；DTCM + 单口外部 memory（旧合同）；无 DTLB/DCache/MSHR/异常；
 * 目标端口（t_*）均未驱动；内部尚未例化 dtlb、data_prefetcher 训练逻辑。
 * Single-issue Load/Store execution unit with DTCM and external memory
 *
 * 输入已经完成PRF读取；组合AGU产生字节地址。Store把地址/数据/mask写入SQ并
 * 立即向ROB报告执行完成。Load先查询更老Store：完整覆盖则转发，未知或部分
 * 重叠则保持输入，其他情况在committed Store优先的单端口上按地址选择DTCM或
 * 外部memory。DTCM固定一拍返回；外部口允许可变延迟，但仍只允许一个Load在飞。
 * 两类响应都进入可保持的load_result_q，获得共享PRF写口后离开。
 *
 * 周期N组合阶段完成AGU、依赖判断和memory仲裁；上升沿锁存pending/load result；
 * 周期N+1可看到DTCM响应；外部响应在任意后续周期握手。错误路径pending响应会由
 * LQ generation和branch mask共同丢弃。本阶段没有MSHR/PMA/MMU/精确访问异常。
 */
module load_store_unit
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter bit USE_DCACHE = 1'b0,
    localparam int DATA_SRAM_BYTES = CFG.lsu.dtcm_bytes,                 // DTCM：现状沿用，去留未设计
    localparam logic [XLEN-1:0] DATA_SRAM_BASE = XLEN'(CFG.lsu.dtcm_base)
) (
    input logic clk,
    input logic rst,
    input mem_execute_uop_t mem_uop_i,
    output logic mem_ready_o,

    output logic lq_execute_valid_o,
    output logic [LQ_IDX_WIDTH-1:0] lq_execute_idx_o,
    output logic [XLEN-1:0] lq_execute_addr_o,
    input logic lq_execute_generation_i,
    output logic lq_request_fire_o,
    output logic [LQ_IDX_WIDTH-1:0] lq_request_idx_o,
    output logic lq_response_valid_o,
    output logic [LQ_IDX_WIDTH:0] lq_response_tag_o,
    input logic lq_response_live_i,

    output logic sq_execute_valid_o,
    output logic [SQ_IDX_WIDTH-1:0] sq_execute_idx_o,
    output logic [XLEN-1:0] sq_execute_addr_o,
    output logic [XLEN-1:0] sq_execute_data_o,
    output logic [7:0] sq_execute_mask_o,
    output logic sq_query_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] sq_query_rob_idx_o,
    output logic [XLEN-1:0] sq_query_addr_o,
    output logic [7:0] sq_query_mask_o,
    input logic sq_query_block_i,
    input logic sq_query_forward_valid_i,
    input logic [XLEN-1:0] sq_query_forward_data_i,
    input logic sq_drain_valid_i,
    output logic sq_drain_ready_o,
    input logic [XLEN-1:0] sq_drain_addr_i,
    input logic [XLEN-1:0] sq_drain_data_i,
    input logic [7:0] sq_drain_mask_i,

    output logic store_complete_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] store_complete_rob_idx_o,
    output load_result_t load_result_o,
    input logic load_result_ready_i,

    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,

    input logic dtcm_init_valid_i,
    input logic [XLEN-1:0] dtcm_init_addr_i,
    input logic [XLEN-1:0] dtcm_init_wdata_i,
    input logic [7:0] dtcm_init_wmask_i,

    output logic ext_req_valid_o,
    input logic ext_req_ready_i,
    output logic ext_req_write_o,
    output logic [XLEN-1:0] ext_req_addr_o,
    output logic [XLEN-1:0] ext_req_wdata_o,
    output logic [7:0] ext_req_wmask_o,
    input logic ext_rsp_valid_i,
    output logic ext_rsp_ready_o,
    input logic [XLEN-1:0] ext_rsp_rdata_i,
    input logic ext_rsp_error_i
,

    // ---------------- 目标合同（框架新增，未接入逻辑） ----------------
    // DTLB 与共享 PTW
    output logic                       t_ptw_req_valid_o,
    input  logic                       t_ptw_req_ready_i,
    output o3_types_pkg::ptw_req_t     t_ptw_req_o,
    input  o3_types_pkg::ptw_resp_t    t_ptw_resp_i,
    input  o3_types_pkg::dmmu_csr_t    t_csr_i,
    input  o3_types_pkg::pmp_state_t   t_pmp_i,
    input  o3_types_pkg::sfence_req_t  t_sfence_i,
    output logic                       t_sfence_done_o,
    // DCache load 管线与 store drain
    output logic                       t_dc_ld_req_valid_o [CFG.lsu.agu_pipes],
    input  logic                       t_dc_ld_req_ready_i [CFG.lsu.agu_pipes],
    output o3_types_pkg::dcache_req_t  t_dc_ld_req_o       [CFG.lsu.agu_pipes],
    input  o3_types_pkg::dcache_resp_t t_dc_ld_resp_i      [CFG.lsu.agu_pipes],
    output logic                       t_dc_st_req_valid_o,
    input  logic                       t_dc_st_req_ready_i,
    output o3_types_pkg::dcache_req_t  t_dc_st_req_o,
    input  o3_types_pkg::dcache_resp_t t_dc_st_resp_i,
    input  o3_types_pkg::dc_wake_t     t_dc_wake_i,
    // AMO（ROB 队头）
    output logic                       t_dc_amo_req_valid_o,
    input  logic                       t_dc_amo_req_ready_i,
    output o3_types_pkg::dcache_req_t  t_dc_amo_req_o,
    input  o3_types_pkg::dcache_resp_t t_dc_amo_resp_i,
    // 精确同步异常报告到原 ROB 项（B06）
    output logic                       t_exc_valid_o,
    output logic [ROB_IDX_WIDTH-1:0]   t_exc_rob_idx_o,
    output o3_types_pkg::exc_info_t    t_exc_o,
    // ROB 队头信息：MMIO/AMO/串行化访存在队头执行（B05/B09）
    input  logic [ROB_IDX_WIDTH-1:0]   t_rob_head_i,
    // stride 预取训练
    output logic                       t_pf_train_valid_o,
    output o3_types_pkg::vaddr_t       t_pf_train_pc_o,
    output o3_types_pkg::paddr_t       t_pf_train_paddr_o,
    output logic                       t_pf_train_miss_o,
    output o3_types_pkg::be_perf_t     t_perf_o
);
    localparam int SRAM_TAG_WIDTH = LQ_IDX_WIDTH + 1;
    logic [XLEN-1:0] effective_addr;
    logic [7:0] access_mask;
    logic load_can_forward, load_can_request;
    logic load_forward_fire, load_request_fire;
    logic sram_req_valid, sram_req_ready, sram_req_write;
    logic [XLEN-1:0] sram_req_addr, sram_req_wdata;
    logic [7:0] sram_req_wmask;
    logic [SRAM_TAG_WIDTH-1:0] sram_req_tag;
    logic sram_rsp_valid, sram_rsp_ready;
    logic [XLEN-1:0] sram_rsp_rdata;
    logic memory_req_valid, memory_req_write, memory_req_targets_dtcm;
    logic memory_req_ready;
    logic memory_rsp_valid, memory_rsp_ready, memory_rsp_error;
    logic [XLEN-1:0] memory_rsp_rdata;
    logic dcache_load_req;
    logic dcache_load_rsp;

    logic pending_valid_q;
    logic [INST_ID_WIDTH-1:0] pending_instruction_id_q;
`ifdef O3_SIM
    logic [63:0] pending_kanata_id_q;
`endif
    logic [ROB_IDX_WIDTH-1:0] pending_rob_idx_q;
    logic [LQ_IDX_WIDTH-1:0] pending_lq_idx_q;
    logic [PREG_IDX_WIDTH-1:0] pending_dst_preg_q;
    mem_size_t pending_mem_size_q;
    logic pending_mem_unsigned_q;
    branch_mask_t pending_branch_mask_q;
    logic pending_external_q;
    logic [SRAM_TAG_WIDTH-1:0] pending_response_tag_q;
    load_result_t load_result_q;

    function automatic logic access_in_dtcm(
        input logic [XLEN-1:0] addr,
        input logic [7:0] mask
    );
        logic all_bytes_local;
        begin
            all_bytes_local = 1'b1;
            for (int byte_idx = 0; byte_idx < 8; byte_idx++) begin
                if (mask[byte_idx]
                 && !(((addr + XLEN'(byte_idx)) >= DATA_SRAM_BASE)
                   && ((addr + XLEN'(byte_idx))
                       < (DATA_SRAM_BASE + XLEN'(DATA_SRAM_BYTES))))) begin
                    all_bytes_local = 1'b0;
                end
            end
            access_in_dtcm = all_bytes_local;
        end
    endfunction

    function automatic logic [7:0] size_mask(input mem_size_t size);
        case (size)
            MEM_SIZE_1B: size_mask = 8'b0000_0001;
            MEM_SIZE_2B: size_mask = 8'b0000_0011;
            MEM_SIZE_4B: size_mask = 8'b0000_1111;
            default:     size_mask = 8'b1111_1111;
        endcase
    endfunction

    function automatic logic [XLEN-1:0] format_load(
        input logic [XLEN-1:0] raw,
        input mem_size_t size,
        input logic is_unsigned
    );
        case (size)
            MEM_SIZE_1B: format_load = is_unsigned
                                     ? XLEN'(raw[7:0])
                                     : XLEN'($signed(raw[7:0]));
            MEM_SIZE_2B: format_load = is_unsigned
                                     ? XLEN'(raw[15:0])
                                     : XLEN'($signed(raw[15:0]));
            MEM_SIZE_4B: format_load = is_unsigned
                                     ? XLEN'(raw[31:0])
                                     : XLEN'($signed(raw[31:0]));
            default:     format_load = raw;
        endcase
    endfunction

    function automatic logic killed(input branch_mask_t mask);
        killed = resolution_valid_i && resolution_mispredict_i
              && mask[resolution_tag_i];
    endfunction

    function automatic branch_mask_t resolved_mask(input branch_mask_t mask);
        branch_mask_t result;
        begin
            result = mask;
            if (resolution_valid_i) result[resolution_tag_i] = 1'b0;
            resolved_mask = result;
        end
    endfunction

    assign effective_addr = mem_uop_i.base_value + mem_uop_i.imm_value;
    assign access_mask = size_mask(mem_uop_i.mem_size);
    assign load_result_o = load_result_q;

    assign lq_execute_valid_o = mem_uop_i.valid && mem_uop_i.is_load
                              && !killed(mem_uop_i.branch_mask);
    assign lq_execute_idx_o = mem_uop_i.lq_idx;
    assign lq_execute_addr_o = effective_addr;
    assign sq_query_valid_o = lq_execute_valid_o;
    assign sq_query_rob_idx_o = mem_uop_i.rob_idx;
    assign sq_query_addr_o = effective_addr;
    assign sq_query_mask_o = access_mask;

    assign load_can_forward = lq_execute_valid_o && !pending_valid_q && !sq_query_block_i
                            && sq_query_forward_valid_i
                            && (!load_result_q.valid || load_result_ready_i);
    assign load_can_request = lq_execute_valid_o && !sq_query_block_i
                            && !sq_query_forward_valid_i && !pending_valid_q
                            && (!load_result_q.valid || load_result_ready_i);
    assign load_forward_fire = load_can_forward;

    // committed Store永远优先占用本拍统一请求口；完整落在DTCM窗口内才访问本地
    // SRAM，否则整笔事务交给外部memory，跨边界请求不会拆成两笔。
    assign memory_req_valid = sq_drain_valid_i || load_can_request;
    assign memory_req_write = sq_drain_valid_i;
    assign sram_req_addr = sq_drain_valid_i ? sq_drain_addr_i : effective_addr;
    assign sram_req_wdata = sq_drain_valid_i ? sq_drain_data_i : '0;
    assign sram_req_wmask = sq_drain_valid_i ? sq_drain_mask_i : access_mask;
    assign sram_req_tag = {lq_execute_generation_i, mem_uop_i.lq_idx};
    assign memory_req_targets_dtcm = access_in_dtcm(sram_req_addr, sram_req_wmask);
    assign sram_req_valid = memory_req_valid && memory_req_targets_dtcm;
    assign sram_req_write = memory_req_write;
    assign dcache_load_req = USE_DCACHE && load_can_request
                          && !sq_drain_valid_i && !memory_req_targets_dtcm;
    for (genvar port = 0; port < CFG.lsu.agu_pipes; port++) begin : g_dcache_load
        assign t_dc_ld_req_valid_o[port] = (port == 0) && dcache_load_req;
        if (port == 0) begin : g_active
            always_comb begin
                t_dc_ld_req_o[port] = '0;
                t_dc_ld_req_o[port].src = o3_types_pkg::DC_SRC_LOAD;
                t_dc_ld_req_o[port].paddr = o3_types_pkg::paddr_t'(effective_addr);
                t_dc_ld_req_o[port].size = 2'(mem_uop_i.mem_size);
                t_dc_ld_req_o[port].lq_tag.idx = o3_types_pkg::lq_idx_t'(mem_uop_i.lq_idx);
                t_dc_ld_req_o[port].lq_tag.gen = o3_types_pkg::LQ_GEN_W'(lq_execute_generation_i);
            end
        end else begin : g_inactive
            assign t_dc_ld_req_o[port] = '0;
        end
    end
    assign ext_req_valid_o = !USE_DCACHE && memory_req_valid && !memory_req_targets_dtcm;
    assign ext_req_write_o = memory_req_write;
    assign ext_req_addr_o = sram_req_addr;
    assign ext_req_wdata_o = sram_req_wdata;
    assign ext_req_wmask_o = sram_req_wmask;
    assign memory_req_ready = memory_req_targets_dtcm ? sram_req_ready
                            : USE_DCACHE ? t_dc_ld_req_ready_i[0] : ext_req_ready_i;
    assign sq_drain_ready_o = sq_drain_valid_i && memory_req_ready;
    assign load_request_fire = load_can_request && !sq_drain_valid_i && memory_req_ready;
    assign lq_request_fire_o = load_request_fire;
    assign lq_request_idx_o = mem_uop_i.lq_idx;

    // Store在SQ成功接收AGU结果后即可离开；Load在转发或目标memory请求握手后离开。
    assign mem_ready_o = !mem_uop_i.valid
                       || (mem_uop_i.is_store && !killed(mem_uop_i.branch_mask))
                       || load_forward_fire || load_request_fire
                       || killed(mem_uop_i.branch_mask);
    assign sq_execute_valid_o = mem_uop_i.valid && mem_uop_i.is_store
                              && mem_ready_o && !killed(mem_uop_i.branch_mask);
    assign sq_execute_idx_o = mem_uop_i.sq_idx;
    assign sq_execute_addr_o = effective_addr;
    assign sq_execute_data_o = mem_uop_i.store_value;
    assign sq_execute_mask_o = access_mask;
    assign store_complete_valid_o = sq_execute_valid_o;
    assign store_complete_rob_idx_o = mem_uop_i.rob_idx;

    assign dcache_load_rsp = USE_DCACHE && pending_external_q
                           && t_dc_ld_resp_i[0].valid
                           && t_dc_ld_resp_i[0].src == o3_types_pkg::DC_SRC_LOAD;
    assign memory_rsp_valid = pending_external_q
                            ? (USE_DCACHE ? dcache_load_rsp : ext_rsp_valid_i)
                            : sram_rsp_valid;
    assign memory_rsp_rdata = pending_external_q
                            ? (USE_DCACHE ? t_dc_ld_resp_i[0].rdata : ext_rsp_rdata_i)
                            : sram_rsp_rdata;
    assign memory_rsp_error = pending_external_q
                            && (USE_DCACHE
                                ? t_dc_ld_resp_i[0].status == o3_types_pkg::DC_ERROR
                                : ext_rsp_error_i);
    assign memory_rsp_ready = !memory_rsp_valid || !lq_response_live_i
                            || killed(pending_branch_mask_q)
                            || !load_result_q.valid || load_result_ready_i;
    assign sram_rsp_ready = !pending_external_q && memory_rsp_ready;
    assign ext_rsp_ready_o = !USE_DCACHE && pending_external_q && memory_rsp_ready;
    assign lq_response_valid_o = memory_rsp_valid && memory_rsp_ready;
    assign lq_response_tag_o = pending_response_tag_q;

    simple_data_sram #(
        .DEPTH_BYTES(DATA_SRAM_BYTES),
        .BASE_ADDR(DATA_SRAM_BASE),
        .TAG_WIDTH(SRAM_TAG_WIDTH)
    ) u_data_sram (
        .clk(clk), .rst(rst),
        .req_valid_i(sram_req_valid), .req_ready_o(sram_req_ready),
        .req_write_i(sram_req_write), .req_addr_i(sram_req_addr),
        .req_wdata_i(sram_req_wdata), .req_wmask_i(sram_req_wmask),
        .req_tag_i(sram_req_tag),
        .init_valid_i(dtcm_init_valid_i), .init_addr_i(dtcm_init_addr_i),
        .init_wdata_i(dtcm_init_wdata_i), .init_wmask_i(dtcm_init_wmask_i),
        .rsp_valid_o(sram_rsp_valid), .rsp_ready_i(sram_rsp_ready),
        .rsp_rdata_o(sram_rsp_rdata), .rsp_tag_o()
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            pending_valid_q <= 1'b0;
            pending_instruction_id_q <= '0;
`ifdef O3_SIM
            pending_kanata_id_q <= '0;
`endif
            pending_rob_idx_q <= '0;
            pending_lq_idx_q <= '0;
            pending_dst_preg_q <= '0;
            pending_mem_size_q <= MEM_SIZE_1B;
            pending_mem_unsigned_q <= 1'b0;
            pending_branch_mask_q <= '0;
            pending_external_q <= 1'b0;
            pending_response_tag_q <= '0;
            load_result_q <= '0;
        end else begin
            if (load_result_q.valid && load_result_ready_i) begin
                load_result_q.valid <= 1'b0;
            end
            if (resolution_valid_i) begin
                load_result_q.branch_mask[resolution_tag_i] <= 1'b0;
                pending_branch_mask_q[resolution_tag_i] <= 1'b0;
                if (resolution_mispredict_i
                 && load_result_q.branch_mask[resolution_tag_i]) begin
                    load_result_q.valid <= 1'b0;
                end
            end

            if (load_request_fire) begin
                pending_valid_q <= 1'b1;
                pending_instruction_id_q <= mem_uop_i.instruction_id;
`ifdef O3_SIM
                pending_kanata_id_q <= mem_uop_i.kanata_id;
`endif
                pending_rob_idx_q <= mem_uop_i.rob_idx;
                pending_lq_idx_q <= mem_uop_i.lq_idx;
                pending_dst_preg_q <= mem_uop_i.dst_preg;
                pending_mem_size_q <= mem_uop_i.mem_size;
                pending_mem_unsigned_q <= mem_uop_i.mem_unsigned;
                pending_branch_mask_q <= resolved_mask(mem_uop_i.branch_mask);
                pending_external_q <= !memory_req_targets_dtcm;
                pending_response_tag_q <= sram_req_tag;
            end

            if (memory_rsp_valid && memory_rsp_ready) begin
                pending_valid_q <= 1'b0;
                if (pending_valid_q && lq_response_live_i
                 && !killed(pending_branch_mask_q)) begin
                    load_result_q.valid <= 1'b1;
                    load_result_q.instruction_id <= pending_instruction_id_q;
`ifdef O3_SIM
                    load_result_q.kanata_id <= pending_kanata_id_q;
`endif
                    load_result_q.rob_idx <= pending_rob_idx_q;
                    load_result_q.lq_idx <= pending_lq_idx_q;
                    load_result_q.dst_preg <= pending_dst_preg_q;
                    load_result_q.result <= format_load(
                        memory_rsp_error ? '0 : memory_rsp_rdata,
                        pending_mem_size_q, pending_mem_unsigned_q);
                    load_result_q.branch_mask <= resolved_mask(pending_branch_mask_q);
                end
            end

            if (load_forward_fire) begin
                load_result_q.valid <= 1'b1;
                load_result_q.instruction_id <= mem_uop_i.instruction_id;
`ifdef O3_SIM
                load_result_q.kanata_id <= mem_uop_i.kanata_id;
`endif
                load_result_q.rob_idx <= mem_uop_i.rob_idx;
                load_result_q.lq_idx <= mem_uop_i.lq_idx;
                load_result_q.dst_preg <= mem_uop_i.dst_preg;
                load_result_q.result <= format_load(
                    sq_query_forward_data_i, mem_uop_i.mem_size, mem_uop_i.mem_unsigned);
                load_result_q.branch_mask <= resolved_mask(mem_uop_i.branch_mask);
            end
        end
    end
endmodule
