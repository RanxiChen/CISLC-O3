/**
 * 后端性能事件计数（B10）
 *
 * 作用：汇总后端各模块的事件增量（be_perf_t）到常驻硬件计数器；仿真另加事件轨迹。
 * 口径（已确认，B10）：
 * - dma_conflict_loads/stores：请求因行保护首次进入等待的次数，重试去重；同一 load 等十拍记一次。
 * - dma_conflict_cycles：至少一项 CPU 请求被行保护阻塞的周期，同拍不按请求数重复累计。
 * - ROB/SQ 等资源满独立统计，不能因 DMA 同时活跃就全归因 DMA；load 等待周期不等于整核停顿周期。
 * - 另保留 bank 冲突、MSHR 占用/满、miss 在途时 hit 完成、SQ 转发与等待、PTW/walk cache、预取效果。
 * - B12 建议：branch-ready 等待读口、结果槽阻塞、解析暂停周期、误预测到正确路径重新交付的周期。
 * - 已确认新增（逻辑 64 位）：B22 csr_retired / csr_wait_empty_cycles / csr_block_younger_cycles；
 *   B23 fencei_retired / fencei_dcache_evict_cycles；B31 misaligned_crossline_traps（只在 trap 接受握手
 *   计一次，错误路径、重放、valid 保持多拍不重复计）。B34 融合对数为观测项，口径待定。
 *
 * 未设计：读取/清零/统一快照接口与 ABI、计数位宽（CFG.perf.counter_bits）。rd_* 为占位。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module backend_perf_events
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic        clk,
    input  logic        rst,
    input  be_perf_t    evt_i,
    input  logic        rd_valid_i,
    input  logic [$clog2(BE_PERF_NUM)-1:0] rd_idx_i,
    output logic [CFG.perf.counter_bits-1:0] rd_data_o,
    input  logic        clear_i,
    input  logic        snapshot_i
);
    // 未实现。
endmodule
