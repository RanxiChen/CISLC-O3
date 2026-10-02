/**
 * DCache 写回缓冲 —— 脏行排出与 DMA 脏数据交接
 *
 * 作用（B05/B08）：
 * - 替换出的脏行在此排队写回 L2；普通 store 写入 L1 成功即可释放 SQ，之后脏行排出由 cache 负责。
 * - DMA clean+invalidate：脏副本先把最新数据可靠交给 L2，再完成失效确认。
 * - 写回的硬件故障不能静默丢弃，也不能伪装成已退休 store/AMO 的精确异常（B06）。首版（B39）：
 *   L2 返回写回错误时 fatal_o 上报 sticky fatal，该缓冲项不得按成功释放，依赖它的维护/DMA/回收
 *   不得虚假完成；不做自动重试或软件恢复。
 * - 写回在途时，同一行的新 miss 必须看到最新数据（与 MSHR 协调，竞态表待闭合，B11）。
 *
 * 细节待定：缓冲数（CFG.dcache.wb_buffers）、与 MSHR 的同行竞态处理。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module dcache_writeback
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int ENTRIES = CFG.dcache.wb_buffers
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          evict_valid_i,
    output logic          evict_ready_o,
    input  paddr_t        evict_line_paddr_i,
    input  logic [DC_LINE_BYTES*8-1:0] evict_data_i,

    input  paddr_t        lookup_line_paddr_i,   // 同行 miss 查询
    output logic          lookup_hit_o,

    output logic          l2_wb_valid_o,
    input  logic          l2_wb_ready_i,
    output paddr_t        l2_wb_line_paddr_o,
    output logic [DC_LINE_BYTES*8-1:0] l2_wb_data_o,

    input  logic          l2_wb_error_i,         // B39：写回失败
    output fatal_evt_t    fatal_o,

    output logic          idle_o
);
    // 未实现。
endmodule
