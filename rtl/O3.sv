/**
 * O3 —— KCU105 整机顶层（2026-10-02 框架：空壳）
 *
 * 目标作用：单 hart RV64GC 乱序核 + 可运行 Linux 的最小 SoC。
 * - 例化 Tile（o3_core + 未来的本地外设）。
 * - DDR4：经 L2 的 AXI4 主口接 KCU105 DDR 控制器（MIG 等，选型未设计）。
 * - SD 卡：SD 控制器与其 DMA 引擎经 o3_core 的 dma_req/dma_resp 行事务入口访问内存（B08 必需）。
 * - 启动 ROM、UART、CLINT/PLIC（定时器/软件/外部中断）、MMIO 地址图：未设计。
 *
 * 原 LED 流水灯占位（circuit01.sv 的 flow_led）已删除。
 *
 * 当前实现状态：空壳，没有逻辑。本阶段不写测试代码和仿真代码。
 */
module o3 (
    input  logic       clk,
    input  logic       rst,
    output logic [3:0] led          // 板级状态指示，含义未设计
);
    // 未实现：Tile、DDR 控制器、SD 控制器、外设与地址译码。
endmodule
