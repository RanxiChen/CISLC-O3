/**
 * Trap 控制 —— 精确 trap/xRET 请求整理与系统重定向
 *
 * 主流程已定（B26/B27/B29/B37），L5 同步异常/MRET 已接入：
 * - commit_ctrl 在精确边界锁存一次 trap 请求（异常/中断区分、EPC、cause、tval）：同步异常 EPC 为
 *   故障指令 PC；中断 EPC 为 committed_next_pc（B37，ROB 为空时同样成立）。
 * - 本模块把请求交给 csr_file 专用硬件更新（epc/cause/tval/状态位/特权级），等其给出入口或返回 PC
 *   与完成确认后，形成提交端系统重定向（D24 规则 2）。不另存任何架构 CSR 状态。
 * - 时序目标：周期 N 接受 trap，flush/恢复与 CSR 专用更新、入口 PC 计算并行；N 末锁存重定向；
 *   N+1 前端按入口 PC 发起首笔取指（与历史/RAS 恢复解耦，前端 16.4/B30）。
 * - 合法 xRET 由自身正常退休触发；不合法走同步异常且不退休。
 * - 晚到硬件错误不伪装成已退休 store/AMO 的精确异常：走 B39 fatal，不经本模块。
 * - AMO/MMIO 不可撤销窗口内普通中断延后到安全边界（B09/B26），由 commit_ctrl 决定 irq 接受时机。
 *
 * 仍待闭合（不在本框架冻结）：系统事件对应的 committed 预测上下文来源；入口取指的返回槽与元数据
 * 绑定；异常/中断/xRET/分支恢复同时出现时整套请求选择的信号级实现。
 *
 * 当前实现状态：闭环简化（L5）：M/Bare 单 hart；后续级的中断/S/U/FP 接口显式 tie-off。
 *
 * 逐周期说明（目标）：
 * - 周期 N：req_i.valid 时向 csr_file 发 csr_update，同拍组合取得 target_pc。
 * - 周期 N 上升沿：锁存 redirect；csr_file 完成架构状态更新。
 * - 周期 N+1：redirect_valid_o 有效，前端接受系统重定向。
 *
 * 测试：sim/cocotb/trap_ctrl/。
 */
module trap_ctrl
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic            clk,
    input  logic            rst,

    input  trap_req_t       req_i,

    output logic            csr_update_valid_o,
    output trap_req_t       csr_update_o,
    input  vaddr_t          csr_target_pc_i,
    input  logic            csr_update_done_i,

    output logic            redirect_valid_o,
    output vaddr_t          redirect_pc_o
);
    // N: the accepted commit boundary updates CSR and cancels speculation.
    // Edge N captures only the target. N+1 emits one system redirect; no retry.
    assign csr_update_valid_o = req_i.valid;
    assign csr_update_o = req_i;
    always_ff @(posedge clk) begin
        if (rst) begin redirect_valid_o <= 1'b0; redirect_pc_o <= '0; end
        else begin
            redirect_valid_o <= req_i.valid && csr_update_done_i;
            if (req_i.valid && csr_update_done_i) redirect_pc_o <= csr_target_pc_i;
            if (req_i.valid) assert (csr_update_done_i);
        end
    end
endmodule
