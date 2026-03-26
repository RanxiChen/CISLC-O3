/**
 * backend_testharness
 *
 * 当前已经实现的功能：
 * - 实例化 backend，并把 MACHINE_WIDTH 固定为 6、NUM_INT_ALUS 固定为 3
 * - 通过 DPI-C 在仿真顶层伪造一个“虚拟前端”
 * - 每个 fetch group 固定提供 6 条彼此无关的 RV64I 整形运算指令
 * - 按 backend 的 fetch_valid / fetch_ready 握手推进 group 索引
 * - 在全部 fetch group 被 backend 接收后继续保留一个排空窗口，让 decode/rename/issue/regread/execute 日志有时间向后流动
 * - 在仿真结束时给 C++ 主循环提供 done_o
 *
 * 当前没有实现的功能：
 * - 不接真实 frontend，不接真实 icache / SRAM / 内存取指
 * - 不做执行结果检查，不做 scoreboarding，不做断言
 * - 不覆盖分支、访存、异常恢复等更完整的处理器行为
 * - 不根据 backend 内部流水线真实空闲状态精确判定结束，只采用“最后一组被接收后再等待固定拍数”的最小排空策略
 * - 当前阶段不额外编写测试代码，只搭后端仿真入口与注释
 *
 * 后续扩展方向：
 * - 可以把 DPI-C 的固定指令流替换成从内存镜像逐条取指
 * - 可以在本顶层继续接入日志、参考模型或更真实的前端流控
 * - 如果后续 backend 导出“流水线全空”观测信号，可以把当前固定排空窗口替换成真实 drain 条件
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 根据 fetch_group_idx_q 调用 DPI-C，组合生成 6 个 lane 的 fetch_entry
 *   2) 若该 group 仍在指令流范围内，则 fetch_valid=1
 *   3) backend 同拍组合产生 fetch_ready_o
 *   4) 若所有 group 都已被接收完，则组合地根据 drain_counter_q 判断 done_o 是否拉高
 * - 周期 N 上升沿：
 *   1) 若 fetch_valid && fetch_ready，则当前 6 条指令被 backend 接收
 *   2) fetch_group_idx_q 与 accepted_group_count_q 同拍递增
 *   3) 顶层按 lane 逐条记录一次已接收 group 的日志
 *   4) 若已经没有新的 group 可送，则 drain_counter_q 递增，直到达到排空窗口上限
 * - 周期 N+1：
 *   看到的是下一组 6 条固定指令；若已经送完全部 group，则进入仅排空、不再送新 fetch 的阶段
 */

`include "dpi_functions.svh"

module backend_testharness
    import o3_pkg::*;
(
    input  logic clk_i,
    input  logic rst_i,
    output logic done_o
);

    localparam int MACHINE_WIDTH = 6;
    localparam int NUM_INT_ALUS = 3;
    localparam int DRAIN_CYCLES = 16;

    fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry;
    logic                             fetch_valid;
    logic                             fetch_ready;
    logic                             fetch_fire;
    logic                             backend_done_unused;

    logic [31:0] cycle_counter_q;
    logic [31:0] fetch_group_idx_q;
    logic [31:0] accepted_group_count_q;
    logic [31:0] drain_counter_q;
    logic [31:0] total_group_count;
    logic        group_valid;
    logic        all_lane_valid;
    logic        all_groups_accepted;
    logic        drain_done;
    logic        reset_seen_q;
    longint unsigned cycle_counter_dpi;

    longint unsigned fetch_pc_dpi   [MACHINE_WIDTH-1:0];
    int unsigned     fetch_inst_dpi [MACHINE_WIDTH-1:0];
    bit              fetch_exc_dpi  [MACHINE_WIDTH-1:0];
    bit              lane_valid_dpi [MACHINE_WIDTH-1:0];

    backend #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_INT_ALUS(NUM_INT_ALUS)
    ) u_backend (
        .clk(clk_i),
        .rst(rst_i),
        .fetch_entry_i(fetch_entry),
        .fetch_valid_i(fetch_valid),
        .fetch_ready_o(fetch_ready),
        .done(backend_done_unused)
    );

    assign fetch_fire = fetch_valid && fetch_ready;

    always_comb begin
        total_group_count = dpi_backend_get_total_groups();
        group_valid       = dpi_backend_has_group(fetch_group_idx_q);
        all_lane_valid    = 1'b1;
        all_groups_accepted = (accepted_group_count_q >= total_group_count) && (total_group_count != 0);
        drain_done        = (drain_counter_q >= DRAIN_CYCLES);
        cycle_counter_dpi = {32'b0, cycle_counter_q};

        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            dpi_backend_get_fetch_entry(
                fetch_group_idx_q,
                lane,
                fetch_pc_dpi[lane],
                fetch_inst_dpi[lane],
                fetch_exc_dpi[lane],
                lane_valid_dpi[lane]
            );

            fetch_entry[lane].pc          = fetch_pc_dpi[lane][PC_WIDTH-1:0];
            fetch_entry[lane].instruction = fetch_inst_dpi[lane];
            fetch_entry[lane].exception   = fetch_exc_dpi[lane];

            if (!lane_valid_dpi[lane]) begin
                all_lane_valid = 1'b0;
            end
        end

        fetch_valid = group_valid && all_lane_valid;
        done_o      = (!rst_i) && all_groups_accepted && drain_done;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            cycle_counter_q        <= '0;
            fetch_group_idx_q      <= '0;
            accepted_group_count_q <= '0;
            drain_counter_q        <= '0;
            if (reset_seen_q !== 1'b1) begin
                dpi_backend_stream_reset();
            end
            reset_seen_q <= 1'b1;
        end else begin
            cycle_counter_q <= cycle_counter_q + 32'd1;
            reset_seen_q    <= 1'b0;

            if (fetch_fire) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    dpi_backend_log_fetch_lane(
                        cycle_counter_dpi,
                        fetch_group_idx_q,
                        lane,
                        1'b1,
                        fetch_pc_dpi[lane],
                        fetch_inst_dpi[lane]
                    );
                end

                fetch_group_idx_q      <= fetch_group_idx_q + 32'd1;
                accepted_group_count_q <= accepted_group_count_q + 32'd1;
                drain_counter_q        <= '0;
            end else if ((accepted_group_count_q >= total_group_count) && (total_group_count != 0) && (drain_counter_q < DRAIN_CYCLES)) begin
                drain_counter_q <= drain_counter_q + 32'd1;
            end
        end
    end

endmodule
