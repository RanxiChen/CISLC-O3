/**
 * Tile —— 单 hart 计算瓦片（2026-10-02 框架：空壳）
 *
 * 目标作用：包住 o3_core，向整机提供 DDR AXI 主口、DMA 行事务入口与中断输入；
 * 本地 CLINT（mtime/mtimecmp/msip）是否放在 Tile 内未设计。
 * 原状态灯逻辑（count==0 判 ERROR）已删除。
 *
 * 当前实现状态：空壳，没有逻辑。本阶段不写测试代码和仿真代码。
 */
module Tile (
    input  logic clk,
    input  logic rst,
    output logic status
);
    // 未实现：o3_core 例化与 Tile 级端口。
endmodule
