/**
 * O3 Core Top
 *
 * 当前已经实现：
 * - 实例化真实 frontend 和真实 backend。
 * - 直接连接 frontend 已有 fetch_buffer 出队口到 backend fetch 输入口。
 * - 将 frontend ICache refill request/response 端口从 core 顶层透出。
 * - 将 backend 的 done 和 retired instruction counter 透出。
 *
 * 当前没有实现：
 * - 不在 core 层额外实例化 fetch_buffer；fetch_buffer 已经在 frontend 内部。
 * - 不实现 data cache、LSU、外部总线、异常恢复、分支 redirect 或精确 flush。
 * - 不在 core 层生成 ICache refill response；下一级存储或 testbench 需要从外部接入。
 *
 * 后续扩展入口：
 * - 后续可在本层接入 L2/总线，把 refill 端口接到真实存储系统。
 * - 后续 redirect/flush 接口补齐后，可在本层统一连接 backend 恢复信号到 frontend。
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

    frontend u_frontend (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .flush_i             (flush_i),
        .reset_pc_i          (reset_pc_i),
        .refill_req_pc_o     (refill_req_pc_o),
        .refill_req_valid_o  (refill_req_valid_o),
        .refill_resp_valid_i (refill_resp_valid_i),
        .refill_resp_pc_i    (refill_resp_pc_i),
        .refill_resp_error_i (refill_resp_error_i),
        .refill_resp_data_i  (refill_resp_data_i),
        .fetch_entry_o       (frontend_fetch_entry),
        .fetch_valid_o       (core_fetch_valid),
        .fetch_valid_mask_o  (core_fetch_valid_mask),
        .fetch_ready_i       (core_fetch_ready)
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
    assign unused_fetch_valid_mask = ^core_fetch_valid_mask;

    genvar lane;
    generate
        for (lane = 0; lane < CORE_FETCH_WIDTH; lane++) begin : gen_fetch_entry_bridge
            assign backend_fetch_entry[lane] = frontend_fetch_entry[lane];
        end
    endgenerate

endmodule
