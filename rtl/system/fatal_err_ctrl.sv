/**
 * 晚到不可恢复写回错误：sticky fatal + 执行隔离（B39，2026-10-02 用户确认）
 *
 * 范围（首版）：
 * - 只处理“晚到、无法归属精确指令”的写回失败（L1D 脏行写回、L2 写回 DDR、维护/回收/DMA 协调中的
 *   写回失败）。普通精确异常（page fault、PMP/PMA 拒绝、访问错误等）不得升级成 fatal。
 * - 任一 fatal 事件置 sticky fatal，保持到复位。
 * - 执行隔离：停止新指令推进和后续正常退休（isolate_o 送 Rename 放行、前端交付、commit_ctrl），
 *   但保留必要的在途总线收尾（AXI 已发事务继续完成握手，不悬挂总线）。
 * - 失败写回不能按成功释放，维护/DMA 不得虚假完成：各来源自己保持失败事务不确认成功；本模块
 *   只记录与隔离，不替来源生成成功完成。
 *
 * 不做：软件恢复、自动重试、RNMI、完整 Debug Mode；不扩展成 BEU/RAS 子系统。详细错误记录与调试
 * 后续接 FASE（record_o 只保留首个事件，作为接口占位）。
 *
 * synthesizable：fatal 状态是普通寄存器，不能用仿真 $fatal 代替；仿真可另加观测，不影响硬件行为。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：
 * - 周期 N：任一 evt_i[k].valid。
 * - 周期 N 上升沿：fatal 置 1（已为 1 则保持）；首次事件时锁存 record。
 * - 周期 N+1 起：fatal_o=isolate_o=1，直到复位。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module fatal_err_ctrl
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  int NUM_SRC                       // 由例化处给出，不写默认值
) (
    input  logic            clk,
    input  logic            rst,

    input  fatal_evt_t      evt_i [NUM_SRC],

    output logic            fatal_o,
    output logic            isolate_o,
    output fatal_evt_t      record_o            // 后续接 FASE；首版不做软件可见报告
);
    // 未实现。
endmodule
