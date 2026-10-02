/**
 * 数据 stride 预取器（B07）
 *
 * 作用：观察 load 访问（PC、物理行地址、命中情况），检测固定步长，向 DCache 发预取。
 * - 先建立需求访问基线；预取需去重、限流、遵守可访问区域（PMA），不能读取有副作用的 MMIO，
 *   不因预取失败产生普通指令异常。
 * - 跨页预取需要翻译：首版是否只在同页内预取未定。
 * - 代价：占带宽、MSHR 并污染 cache；用 useful/late/unused 与资源竞争计数评价，不称零代价。
 * - 与值预测分开：值预测不进入 CISLC-O3（B03）。
 *
 * 细节待定：表项数、训练键（PC 或地址区域）、领先距离、节流条件、MSHR 份额。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module data_prefetcher
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          train_valid_i,
    input  vaddr_t        train_pc_i,
    input  paddr_t        train_paddr_i,
    input  logic          train_miss_i,

    output logic          pf_req_valid_o,
    input  logic          pf_req_ready_i,
    output dcache_req_t   pf_req_o,

    output be_perf_t      perf_o
);
    // 未实现。
endmodule
