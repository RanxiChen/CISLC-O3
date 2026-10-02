/**
 * IFU F1 —— 预解码、直接目标核对、预测修正
 *
 * 作用：
 * - 对 F0 输出的指令预解码控制流类型，计算 branch/JAL 的直接目标，与 FTQ 最终预测
 *   （选中 CFI 槽位、类型、目标、RAS 动作）核对。
 * - 发现预测错误（类型错误、目标错误、预测了不存在的分支、漏掉 JAL 等）时发出
 *   D24 预解码修正请求，并截断本块中被修正出口之后的指令。
 * - 生成 fetch_entry_t（含 ftq_id、slot、pred_taken、predicted_next_pc）写入指令 buffer。
 *
 * 目标机制：
 * - 已定：BTB 中的类型信息是预测信息，最终需要预解码验证（第 3.2 节）。
 * - 已定：后续预解码可计算 branch/JAL 的直接目标并修正（第 4.3 节）；普通 JALR
 *   无可用目标时等待执行得出真实目标。
 * - 已定：同位置优先级执行 > 预解码 > 慢预测（D24）。
 * - 已定：有效目标必须属于当前选中 CFI；一个 BTB target 不能冒充其他槽位（第 14 节）。
 * - 修正请求的历史动作遵守 D09：只有修正后为 taken 条件分支才 hist_inject。
 *
 * 细节待定：
 * - 每拍输出条数 F1_W（第 10 节）。
 * - ftq_last 的产生规则：目标为“区域内最后一条有效指令”，与 ROB 回收合同核对。
 * - 预测类型经预解码改变时 RAS 的精确修复（第 6.2 节待定）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N 组合：in_valid_i 时预解码并核对；需要修正时 predecode_o.valid=1。
 * - 周期 N 上升沿：out 握手后写入指令 buffer；修正请求由 redirect_arbiter 仲裁。
 * - 周期 N+1：若本请求获胜，kill_i 清除比修正位置年轻的项（包括 F0、返回队列）。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module ifu_f1
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic            clk_i,
    input  logic            rst_i,

    input  logic [F0_SLOTS-1:0] in_valid_i,
    output logic            in_ready_o,
    input  f0_inst_t        in_i [F0_SLOTS],
    input  ftq_pred_brief_t in_brief_i,

    output fetch_entry_t    out_o [F1_W],
    output logic [F1_W-1:0] out_valid_o,
    input  logic            out_ready_i,

    output redirect_req_t   predecode_o,

    input  fe_kill_t        kill_i,

    output fe_perf_t        perf_o
);
    // 未实现：预解码、直接目标计算、预测核对与修正请求。
endmodule
