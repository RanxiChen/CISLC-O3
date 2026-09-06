/**
 * O3 Core Top
 *
 * 当前已经实现：
 * - 实例化真实 frontend 和真实 backend。
 * - 直接连接 frontend 已有 fetch_buffer 出队口到 backend fetch 输入口。
 * - 将 frontend ICache refill、ITCM初始化、DTCM初始化和LSU外部memory端口透出。
 * - 将 backend 的 done 和 retired instruction counter 透出。
 * - 将Backend分支解析和Commit FTQ释放反馈接回Frontend。
 *
 * 当前没有实现：
 * - 不在 core 层额外实例化 fetch_buffer；fetch_buffer 已经在 frontend 内部。
 * - 不实现真实data cache/总线、精确异常恢复或真实分支预测表。
 * - 不在 core 层生成 ICache refill response；下一级存储或 testbench 需要从外部接入。
 *
 * 后续扩展入口：
 * - 后续可在本层接入 L2/总线，把 refill 端口接到真实存储系统。
 * - 后续预测器可直接消费FTQ训练观察并替换默认not-taken结果。
 * - 后续可把 `done` 定义为程序结束条件，而不是直接使用 backend 当前占位输出。
 *
 * 当前阶段说明：
 * - 当前阶段只做前后端结构连接，不写测试代码和仿真代码。
 *
 * 逐周期说明：
 * - 周期 N 组合阶段：
 *   1) frontend 内部 fetch_buffer 根据 backend 的 `fetch_ready_o` 决定是否出队。
 *   2) frontend 输出最多 4 条 `fetch_entry_t` 和 `fetch_valid_o`。
 *   3) backend 根据内部 decode queue 状态组合地产生 `fetch_ready_o`。
 * - 周期 N 上升沿：
 *   1) 若 frontend/backend fetch 握手成立，backend 接收当前 fetch group。
 *   2) frontend 内部 fetch_buffer 出队同一组 fetch entry。
 *   3) backend 内部流水线、ROB、issue queue 等状态按自身逻辑推进。
 * - 周期 N+1：
 *   1) backend 开始解码上一拍接收的 fetch group。
 *   2) frontend 看到更新后的 ready/occupancy 状态，继续取指或背压。
 */
module o3_core
    import o3_pkg::*;
    import ftq_pkg::*;
(
    input  logic clk_i,
    input  logic rst_i,
    input  logic flush_i,
    input  logic [PC_WIDTH-1:0] reset_pc_i,

    output logic [PC_WIDTH-1:0] refill_req_pc_o,
    output logic                refill_req_valid_o,
    input  logic                refill_resp_valid_i,
    input  logic [PC_WIDTH-1:0] refill_resp_pc_i,
    input  logic                refill_resp_error_i,
    input  logic [ICACHE_LINE_BYTES*8-1:0] refill_resp_data_i,

    input  logic                         itcm_init_valid_i,
    input  logic [PC_WIDTH-1:0]          itcm_init_addr_i,
    input  logic [63:0]                  itcm_init_data_i,
    input  logic [7:0]                   itcm_init_wmask_i,
    input  logic                         dtcm_init_valid_i,
    input  logic [XLEN-1:0]              dtcm_init_addr_i,
    input  logic [XLEN-1:0]              dtcm_init_wdata_i,
    input  logic [7:0]                   dtcm_init_wmask_i,

    output logic                         dmem_req_valid_o,
    input  logic                         dmem_req_ready_i,
    output logic                         dmem_req_write_o,
    output logic [XLEN-1:0]              dmem_req_addr_o,
    output logic [XLEN-1:0]              dmem_req_wdata_o,
    output logic [7:0]                   dmem_req_wmask_o,
    input  logic                         dmem_rsp_valid_i,
    output logic                         dmem_rsp_ready_o,
    input  logic [XLEN-1:0]              dmem_rsp_rdata_i,
    input  logic                         dmem_rsp_error_i,

    output logic done_o,
    output logic [63:0] retired_inst_count_o
`ifdef ENABLE_RETIRE_INFO
    ,output retire_info_t retire_info_o [BACKEND_NUM_INT_ALUS-1:0]
`endif
`ifdef O3_SIM_SINGLE_INST_TRACE
    ,output logic single_inst_retired_o
`endif
);

    fetch_entry_t frontend_fetch_entry [CORE_FETCH_WIDTH];
    fetch_entry_t [CORE_FETCH_WIDTH-1:0] backend_fetch_entry;
    logic         core_fetch_valid;
    logic [CORE_FETCH_WIDTH-1:0] core_fetch_valid_mask;
    logic         core_fetch_ready;
    branch_resolution_t core_branch_resolution;
    logic [$clog2(BACKEND_MACHINE_WIDTH+1)-1:0] core_ftq_release_count;
    logic backend_redirect_valid_unused;
    logic [PC_WIDTH-1:0] backend_redirect_pc_unused;
`ifdef O3_FRONTEND_DEBUG
    logic dbg_ftq_ifu_fire_unused, dbg_ftq_bpu_fire_unused;
    ftq_idx_t dbg_ftq_alloc_tail_unused, dbg_ftq_ifu_head_unused, dbg_ftq_release_head_unused;
    logic [$clog2(FTQ_DEPTH+1)-1:0] dbg_ftq_allocated_count_unused;
`endif

    frontend u_frontend (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .flush_i             (flush_i),
        .reset_pc_i          (reset_pc_i),
        .branch_resolution_i (core_branch_resolution),
        .ftq_release_count_i (core_ftq_release_count),
        .refill_req_pc_o     (refill_req_pc_o),
        .refill_req_valid_o  (refill_req_valid_o),
        .refill_resp_valid_i (refill_resp_valid_i),
        .refill_resp_pc_i    (refill_resp_pc_i),
        .refill_resp_error_i (refill_resp_error_i),
        .refill_resp_data_i  (refill_resp_data_i),
        .itcm_init_valid_i   (itcm_init_valid_i),
        .itcm_init_addr_i    (itcm_init_addr_i),
        .itcm_init_data_i    (itcm_init_data_i),
        .itcm_init_wmask_i   (itcm_init_wmask_i),
        .fetch_entry_o       (frontend_fetch_entry),
        .fetch_valid_o       (core_fetch_valid),
        .fetch_valid_mask_o  (core_fetch_valid_mask),
        .fetch_ready_i       (core_fetch_ready)
`ifdef O3_FRONTEND_DEBUG
        ,.dbg_ftq_ifu_fire_o(dbg_ftq_ifu_fire_unused)
        ,.dbg_ftq_bpu_fire_o(dbg_ftq_bpu_fire_unused)
        ,.dbg_ftq_alloc_tail_o(dbg_ftq_alloc_tail_unused)
        ,.dbg_ftq_ifu_head_o(dbg_ftq_ifu_head_unused)
        ,.dbg_ftq_release_head_o(dbg_ftq_release_head_unused)
        ,.dbg_ftq_allocated_count_o(dbg_ftq_allocated_count_unused)
`endif
    );

    backend #(
        .MACHINE_WIDTH         (BACKEND_MACHINE_WIDTH),
        .NUM_PHYS_REGS        (BACKEND_NUM_PHYS_REGS),
        .NUM_ARCH_REGS        (BACKEND_NUM_ARCH_REGS),
        .NUM_ROB_ENTRIES      (BACKEND_NUM_ROB_ENTRIES),
        .DECODE_QUEUE_DEPTH   (BACKEND_DECODE_QUEUE_DEPTH),
        .INT_ISSUE_QUEUE_DEPTH(BACKEND_INT_ISSUE_QUEUE_DEPTH),
        .NUM_INT_ALUS         (BACKEND_NUM_INT_ALUS)
    ) u_backend (
        .clk                 (clk_i),
        .rst                 (rst_i || flush_i),
        .fetch_entry_i       (backend_fetch_entry),
        .fetch_valid_i       (core_fetch_valid),
        .fetch_ready_o       (core_fetch_ready),
        .branch_resolution_o (core_branch_resolution),
        .ftq_release_count_o (core_ftq_release_count),
        .redirect_valid_o    (backend_redirect_valid_unused),
        .redirect_pc_o       (backend_redirect_pc_unused),
        .dtcm_init_valid_i   (dtcm_init_valid_i),
        .dtcm_init_addr_i    (dtcm_init_addr_i),
        .dtcm_init_wdata_i   (dtcm_init_wdata_i),
        .dtcm_init_wmask_i   (dtcm_init_wmask_i),
        .dmem_req_valid_o    (dmem_req_valid_o),
        .dmem_req_ready_i    (dmem_req_ready_i),
        .dmem_req_write_o    (dmem_req_write_o),
        .dmem_req_addr_o     (dmem_req_addr_o),
        .dmem_req_wdata_o    (dmem_req_wdata_o),
        .dmem_req_wmask_o    (dmem_req_wmask_o),
        .dmem_rsp_valid_i    (dmem_rsp_valid_i),
        .dmem_rsp_ready_o    (dmem_rsp_ready_o),
        .dmem_rsp_rdata_i    (dmem_rsp_rdata_i),
        .dmem_rsp_error_i    (dmem_rsp_error_i),
        .done                (done_o),
        .retired_inst_count_o(retired_inst_count_o)
`ifdef ENABLE_RETIRE_INFO
        ,.retire_info_o      (retire_info_o)
`endif
`ifdef O3_SIM_SINGLE_INST_TRACE
        ,.single_inst_retired_o(single_inst_retired_o)
`endif
    );

    logic unused_fetch_valid_mask;
    assign unused_fetch_valid_mask = ^core_fetch_valid_mask
                                   ^ backend_redirect_valid_unused
                                   ^ ^backend_redirect_pc_unused
`ifdef O3_FRONTEND_DEBUG
                                   ^ dbg_ftq_ifu_fire_unused
                                   ^ dbg_ftq_bpu_fire_unused
                                   ^ ^dbg_ftq_alloc_tail_unused
                                   ^ ^dbg_ftq_ifu_head_unused
                                   ^ ^dbg_ftq_release_head_unused
                                   ^ ^dbg_ftq_allocated_count_unused
`endif
                                   ;

    genvar lane;
    generate
        for (lane = 0; lane < CORE_FETCH_WIDTH; lane++) begin : gen_fetch_entry_bridge
            assign backend_fetch_entry[lane] = frontend_fetch_entry[lane];
        end
    endgenerate

endmodule
