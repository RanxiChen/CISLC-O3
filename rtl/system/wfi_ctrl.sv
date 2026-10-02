/**
 * WFI 等待控制（B38，2026-10-02 用户确认）
 *
 * 流程：
 * - Decode→Rename 串行阻塞年轻指令（ext.block_younger，同 B22 机制）。
 * - 合法 WFI 到 ROB 队首正常退休；退休后进入等待，committed_next_pc 指向其后继（B37）。
 *   权限/TW 等合法性按既有特权规则处理（不合法走 B26 同步异常，不进入等待）。
 * - 等待期间暂停新指令推进（Rename 放行与前端交付保持阻塞），不关闭整核时钟；
 *   SQ drain、cache 回填、DMA 协调、中断检测继续工作。WFI 不额外充当 FENCE。
 * - 唤醒条件与正式中断条件分开：对应单项使能且 pending 的中断即可唤醒（|(mip & mie)），
 *   不额外要求全局 MIE/SIE 打开，也不按委托结果屏蔽唤醒。
 * - 醒后若满足正式 trap 条件则由 commit_ctrl/trap_ctrl 进入中断（EPC=committed_next_pc），
 *   否则从后继继续。
 * - 入睡同拍已有唤醒条件则不睡；不能只检测后续边沿（唤醒为电平条件）。
 *
 * 不负责：正式中断仲裁（trap_ctrl）；合法性检查（csr_file/commit_ctrl）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：
 * - 周期 N：wfi_retire_i（合法 WFI 退休握手）；若本拍 wake_cond 已成立，不进入等待。
 * - 周期 N 上升沿：否则 sleeping 置 1。
 * - 之后每拍组合：sleeping && !wake_cond 时 stall_o=1；wake_cond 成立的那一拍上升沿 sleeping
 *   清零，下一拍 commit_ctrl 按正式中断条件决定进入 trap 或继续。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module wfi_ctrl
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic            clk,
    input  logic            rst,

    input  logic            wfi_retire_i,     // 合法 WFI 正常退休
    input  irq_view_t       irq_i,            // 单项 mip/mie
    input  logic            debug_req_i,      // 完整 Debug Mode 不在首版范围，保留唤醒输入

    output logic            sleeping_o,
    output logic            stall_o           // 暂停新指令推进（不门控时钟）
);
    // 未实现。
endmodule
