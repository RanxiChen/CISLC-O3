/**
 * 前端性能事件计数
 *
 * 作用：
 * - 汇总各前端模块每拍给出的事件增量（fe_perf_t），累加到常驻硬件计数器，供仿真与
 *   FPGA 读出（D21，第 12 节）。
 *
 * 目标机制（第 12.1 节，已接受的观测需求）：
 * - 同拍多个事件不能被一个 Boolean 丢掉：输入为增量。
 * - 区分“发生几次”与“阻塞几拍”；共享阻塞原因可多热记录，互斥归因另行定义，
 *   不能直接相加当总停顿。
 * - 区分提交路径准确率、所有推测访问流量、取消流量，明确分子分母。
 * - 硬件常驻计数与仿真详细 trace 分开，避免为日志增加关键路径。
 *
 * 未设计：
 * - CSR/MMIO 读取 ABI、计数位宽、溢出规则、清零与一致快照机制（第 12.1 节）。
 *   rd_* 端口只是占位。
 * - 第 12.2 节完整事件清单尚未全部列入 fe_perf_evt_e。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module frontend_perf_events
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic     clk_i,
    input  logic     rst_i,

    input  fe_perf_t evt_i,

    // 读取占位（ABI 未设计）
    input  logic     rd_valid_i,
    input  logic [$clog2(PE_NUM)-1:0] rd_idx_i,
    output logic [CFG.perf.counter_bits-1:0] rd_data_o,
    input  logic     clear_i,
    input  logic     snapshot_i
);
    // 未实现：计数器阵列、清零与快照。
endmodule
