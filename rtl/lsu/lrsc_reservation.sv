/**
 * LR/SC reservation（B35，2026-10-02 用户确认）
 *
 * 每 hart 一条独立 reservation，与 cache tag 分开，由 dcache_amo_unit 读写、DCache 内部事件清除。
 * 普通 load/store 流水不读本模块；只有 store drain/AMO/PTE A/D 的实际写和 DMA 写的行保护事件
 * 通过已有路径旁路送入冲突端口。
 *
 * 状态：valid、物理 line 地址（冲突检测粒度）、LR 的物理地址与大小（配对用）。
 *
 * 规则：
 * - LR：在 ROB 队首执行，读取数据与建立 reservation 处于一致的访问边界（同一拍完成数据读取
 *   确认与 set）。新 LR 替换旧记录。
 * - SC：先在 amo_unit 完成地址/权限/对齐/PMA 检查；miss 可以取行等待。最终在短保护窗口内
 *   重新检查 reservation 并条件写入，不能提前锁定成功。首版只有同物理地址、同大小才成功。
 *   SC 成功或失败都清除。
 * - 不设固定超时；不从 LR 到 SC 一直锁住 cache line。
 * - 清除事件（rsv_clear_e）：SC；本核 store/AMO 写到保留行；DMA 写取得行保护权并与保留行冲突；
 *   PTW A/D 实际更新写到保留行；reset；trap 入口；合法 xRET；进入 debug；首版 SFENCE.VMA/地址
 *   空间切换。
 * - 不清：普通分支恢复；cache 替换、clean、writeback、DMA 读引起的失效；L2 inclusive 容量回收。
 * - DMA 写排序：只有 DCache 接受 PROBE_DMA(dma_write=1)、即 DMA 取得行保护权的那一拍（不是看到
 *   L2 排队请求 valid），dma_conflict_i 才有效；它与 SC 的最终检查在同一仲裁点明确排序：SC 保护窗口先占有该行则 SC 先完成，
 *   DMA 写保护在其后生效；DMA 先取得保护权则 reservation 先清除，SC 失败。
 * - 没抢到资源（bank/行保护/写口）应等待，不能用 SC 失败替代公平仲裁。
 * - 前进保障：SC 回填及最终执行不能被重复替换或 DMA 读无限抢占；具体保障由 amo_unit 与 DCache
 *   替换/维护仲裁共同提供（例如 SC 在途行暂不选为 victim、维护请求有限次让出），机制待实现时细化。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：
 * - 周期 N 组合：check_ok_o = valid && paddr/size 与 SC 匹配 && 本拍无同行清除事件。
 * - 周期 N 上升沿：set_i 时装入新记录；任一 clear 事件或冲突命中时 valid 清零；同拍 set 与
 *   clear 的优先级：clear 来自更老已生效事件时先清后设（LR 在队首执行，比任何未提交写更年轻），
 *   精确优先级随 amo_unit 时序确定。
 * - 周期 N+1：新的 valid 状态可见。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module lrsc_reservation
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic            clk,
    input  logic            rst,

    // LR 建立
    input  logic            set_i,
    input  paddr_t          set_paddr_i,
    input  logic [1:0]      set_size_i,

    // SC 最终检查（保护窗口内）
    input  logic            check_i,
    input  paddr_t          check_paddr_i,
    input  logic [1:0]      check_size_i,
    output logic            check_ok_o,

    // 清除事件
    input  logic            clear_valid_i,
    input  rsv_clear_e      clear_reason_i,
    input  rsv_conflict_t   store_conflict_i,   // store drain / AMO 实际写
    input  rsv_conflict_t   pte_ad_conflict_i,  // PTW A/D 实际更新写
    input  rsv_conflict_t   dma_conflict_i,     // DCache 接受 PROBE_DMA(dma_write=1) 的那一拍

    output logic            valid_o,
    output paddr_t          line_paddr_o        // 供替换/前进保障参考
);
    // 未实现。
endmodule
