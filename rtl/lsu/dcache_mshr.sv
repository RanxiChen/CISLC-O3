/**
 * DCache MSHR —— 行事务跟踪、同 line 合并、回填与唤醒
 *
 * 作用（B04 6.2 节）：
 * - MSHR 跟踪行事务（地址、下级事务身份、回填状态）；LQ/重放记录跟踪 load 身份、目标 preg、
 *   等待原因与唤醒关系，两者职责分开。
 * - miss 分配或合并；资源不足返回 full，等待可用事件，不能伪造已发出状态。
 *   多个 load 可等待同一行，各有指令身份。
 * - 首版先完成回填安装，再唤醒 load 重查 SQ/cache；MSHR 完成不等于 load 已完成。
 * - 被取消请求所占 MSHR：行事务照常完成（行可安装），等待记录在 LQ 侧丢弃。
 * - DMA 行保护期间：目标行已有 miss/refill 必须继续获得服务并协调到不会迟到重新安装旧数据（B08）。
 *
 * 细节待定：MSHR 数、合并 fanout、需求与预取保留份额、PTW 保留份额（B07 前进保证）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module dcache_mshr
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int ENTRIES = CFG.dcache.mshrs
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          alloc_valid_i,
    output logic          alloc_ready_o,       // 0：MSHR 满
    input  paddr_t        alloc_line_paddr_i,
    input  dc_src_e       alloc_src_i,
    output logic          alloc_merged_o,

    input  paddr_t        probe_line_paddr_i,  // DMA / 预取查询在途
    output logic          probe_inflight_o,

    output logic          l2_req_valid_o,
    input  logic          l2_req_ready_i,
    output l2_req_t       l2_req_o,
    input  l2_resp_t      l2_resp_i,
    output logic          l2_resp_ready_o,

    output logic          fill_valid_o,        // 请求写口安装整行
    input  logic          fill_ready_i,
    output paddr_t        fill_line_paddr_o,
    output logic [DC_LINE_BYTES*8-1:0] fill_data_o,
    output dc_wake_t      wake_o,

    output logic          idle_o
);
    // 未实现。
endmodule
