/**
 * backend_testharness
 *
 * 当前已经实现的功能：
 * - 实例化 backend，并把 MACHINE_WIDTH 固定为 4
 * - 通过 DPI-C 在仿真顶层伪造一个“虚拟前端”
 * - 每个 fetch group 固定提供 4 条彼此无关的 RV64I 整形运算指令
 * - 按 backend 的 fetch_valid / fetch_ready 握手推进 group 索引
 * - 在仿真结束时给 C++ 主循环提供 done_o
 *
 * 当前没有实现的功能：
 * - 不接真实 frontend，不接真实 icache / SRAM / 内存取指
 * - 不做执行结果检查，不做 scoreboarding，不做断言
 * - 不覆盖分支、访存、异常恢复等更完整的处理器行为
 * - 当前阶段不额外编写测试代码，只搭后端仿真入口与注释
 *
 * 后续扩展方向：
 * - 可以把 DPI-C 的固定指令流替换成从内存镜像逐条取指
 * - 可以在本顶层继续接入日志、参考模型或更真实的前端流控
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 根据 fetch_group_idx_q 调用 DPI-C，组合生成 4 个 lane 的 fetch_entry
 *   2) 若该 group 仍在指令流范围内，则 fetch_valid=1
 *   3) backend 同拍组合产生 fetch_ready_o
 * - 周期 N 上升沿：
 *   1) 若 fetch_valid && fetch_ready，则当前 4 条指令被 backend 接收
 *   2) fetch_group_idx_q 与 accepted_group_count_q 同拍递增
 *   3) 顶层记录一次已接收 group 的日志
 * - 周期 N+1：
 *   看到的是下一组 4 条固定指令；若已经送完全部 group，则 done_o 拉高
 */

`include "dpi_functions.svh"

module backend_testharness
    import o3_pkg::*;
(
    input  logic clk_i,
    input  logic rst_i,
    output logic done_o
);

    localparam int MACHINE_WIDTH = 4;

    fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry;
    logic                             fetch_valid;
    logic                             fetch_ready;
    logic                             fetch_fire;
    logic                             backend_done_unused;

    logic [31:0] cycle_counter_q;
    logic [31:0] fetch_group_idx_q;
    logic [31:0] accepted_group_count_q;
    logic [31:0] total_group_count;
    logic        group_valid;
    logic        all_lane_valid;
    logic        reset_seen_q;
    longint unsigned cycle_counter_dpi;

    longint unsigned fetch_pc_dpi   [MACHINE_WIDTH-1:0];
    int unsigned     fetch_inst_dpi [MACHINE_WIDTH-1:0];
    bit              fetch_exc_dpi  [MACHINE_WIDTH-1:0];
    bit              lane_valid_dpi [MACHINE_WIDTH-1:0];

    backend #(
        .MACHINE_WIDTH(MACHINE_WIDTH)
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
        done_o      = (!rst_i) && (accepted_group_count_q >= total_group_count) && (total_group_count != 0);
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            cycle_counter_q        <= '0;
            fetch_group_idx_q      <= '0;
            accepted_group_count_q <= '0;
            if (reset_seen_q !== 1'b1) begin
                dpi_backend_stream_reset();
            end
            reset_seen_q <= 1'b1;
        end else begin
            cycle_counter_q <= cycle_counter_q + 32'd1;
            reset_seen_q    <= 1'b0;

            if (fetch_fire) begin
                dpi_backend_log_fetch_group(
                    cycle_counter_dpi,
                    fetch_group_idx_q,
                    1'b1,
                    fetch_pc_dpi[0],
                    fetch_inst_dpi[0],
                    fetch_pc_dpi[1],
                    fetch_inst_dpi[1],
                    fetch_pc_dpi[2],
                    fetch_inst_dpi[2],
                    fetch_pc_dpi[3],
                    fetch_inst_dpi[3]
                );

                fetch_group_idx_q      <= fetch_group_idx_q + 32'd1;
                accepted_group_count_q <= accepted_group_count_q + 32'd1;
            end
        end
    end

endmodule
