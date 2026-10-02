/**
 * DMA 行协调器 —— SD DMA 按行 clean+invalidate（B08，已确认首版方案）
 *
 * 行事务流程（已定）：
 * 1) 登记目标物理行（busy + line address）；向 L1D 发保护/探测请求，L1D 接受后阻止该行新的
 *    普通 CPU 访问与 AMO，其他行继续。
 * 2) 目标行已接受的访问完成到安全边界；已有 miss/refill/writeback 继续获得服务，并协调到不会
 *    有旧数据迟到重新安装。
 * 3) clean+invalidate：缺失则确认无副本；干净副本失效；脏副本先把最新数据可靠交给 L2，再确认。
 * 4) L1D 返回 quiesced 后，L2 执行 DMA 读或写；部分行写保留未覆盖字节。
 * 5) 完成后解除行保护，唤醒 CPU 等待者，返回 DMA 完成。
 * - 首版只允许一笔行事务在途（CFG.l2.dma_inflight_lines=1）；DMA 读也清理并失效，
 *   接受随后 CPU 再 miss 的代价（以后由探针决定是否增加不失效读取）。
 * - 不能仅靠扣住 L2 响应实现保护（L1 hit 不经过 L2）；不能堵住完成旧事务所需的响应/回填/
 *   写回/探测应答；跨行替换造成的资源依赖也要列入验证。
 * - DMA 协议不替代软件缓冲区交接与 FENCE；不替代 FENCE.I 或 SFENCE.VMA。
 * - 观测（B10）：dma_line_transactions、dma_line_lock_cycles、dma_wait_dcache_cycles 等，口径见 B10。
 *
 * - LR/SC 排序（B35）：DMA 写取得行保护权的时刻是 L1D 接受 PROBE_DMA(dma_write=1) 的那一拍；
 *   reservation 冲突由 DCache 在该接受点内部产生，与 SC 最终检查在同一维护/行保护仲裁点排序。
 *   不能仅看到本模块排队请求 valid 就清除 reservation。DMA 读不清 reservation。
 * - 同行统一事务（B41）：DMA 与回填、L1D 写回、L2 淘汰回收对同一物理行由 l2_cache 的统一行事务
 *   状态排序，不各自独立修改同行状态；本模块的 L1D 探测与回收探测在 l2_cache 内仲裁进入同一
 *   维护入口。
 * - 写回失败（B39）：DMA 不得虚假完成；失败按 fatal 处理，dma_resp 不报成功。
 *
 * 细节待定：保护记录字段与握手编码；与 L2 自身 MSHR 的竞态表（B11）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module dma_line_coord
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic            clk,
    input  logic            rst,

    input  logic            dma_req_valid_i,
    output logic            dma_req_ready_o,
    input  dma_req_t        dma_req_i,
    output dma_resp_t       dma_resp_o,

    output logic            l1d_probe_valid_o,
    input  logic            l1d_probe_ready_i,
    output dc_probe_req_t   l1d_probe_o,
    input  dc_probe_resp_t  l1d_probe_resp_i,

    // L2 内部行访问（读出最新数据 / 写入 DMA 数据）
    output logic            l2_line_req_valid_o,
    input  logic            l2_line_req_ready_i,
    output dma_req_t        l2_line_req_o,
    input  dma_resp_t       l2_line_resp_i,

    output logic            lock_valid_o,         // 行保护有效（观测）
    output paddr_t          lock_line_paddr_o,
    output be_perf_t        perf_o
);
    // 未实现：行事务状态机。
endmodule
