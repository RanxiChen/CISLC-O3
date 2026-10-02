/**
 * RAS —— 推测返回地址栈，BOOM 式入口索引/占用数/栈顶快速修复（D29）
 *
 * 2026-10-02 D29 替换原 undo log 合同：取消 undo log、撤销游标、log 满回压、提交释放与逐条
 * 撤销 FSM；不采用持久化推测队列。历史 E/C 仍按 D23 完整快照恢复，与本模块无关。
 *
 * 作用：
 * - 为 return 预测提供返回地址；沿实际采用的预测路径推测 push/pop。
 * - 每个成功分配的区域在推测操作之前输出 ras_before = {top_idx,count,top_addr}（ckpt_o），
 *   由 FTQ 保存；恢复时由 redirect_arbiter 读回并送入 recover_*。
 *
 * 已定机制（第 6.2 节 D29）：
 * - 暂定 16 项小型寄存器数组，保存返回 PC；按指令原始长度计算 PC+2 / PC+4。
 * - 按 RISC-V x1/x5 的 rd/rs1 提示区分 push、pop、pop-then-push；return 优先 RAS，
 *   空栈回退 BTB；普通 JALR 先用 BTB 最后目标；无 ITTAGE（D20）。
 * - 每个成功分配的区域只应用一次实际采用路径的操作；满栈循环覆盖最旧项。
 * - 恢复：写回 top_idx/count；count!=0 时把保存的 top_addr 写回 top_idx 位置；再按核实后的
 *   类型与原始长度执行一次正确动作（条件分支无动作；误识别的 call 撤回后不再 push；
 *   真实 call 压入返回 PC；真实 return 弹栈；pop-then-push 执行组合）。
 * - 恢复拍支持两个确定写入：“旧栈顶修复”和“正确 call 压栈”。同位置以最终修正结果为准；
 *   恢复拍禁止普通推测写入，并为恢复后栈顶提供读写旁路。不能因单写口静默改回逐步撤销。
 * - 慢预测检查使用对应区域保存的 top_addr/count，不使用已前进到其他块的当前栈顶。
 * - 恢复身份：recover_id_i 标识当前恢复；被更老请求或同位置更高优先级请求替换时，旧恢复的
 *   写入与完成通知不得覆盖新状态。
 *
 * 明确接受的取舍：只修复保存的栈顶，不保证还原深层地址（例 [A,B,C] 可能变成 [A,X,C]）；
 * 真实 JALR 执行继续纠错。不得宣称 RAS 全内容精确恢复。
 *
 * 观测（第 12.2 节）：push/pop/pop-push、underflow/overflow、return 命中/错误、栈顶修复次数、
 * 恢复周期与被替换次数。已移除 undo-log 满事件。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为（普通分支恢复，从前端接受重定向起算，D29 R0～R2）：
 * - 周期 N 组合：top_o/top_valid_o 为当前推测栈顶；ckpt_o 为当前区域操作前的 ras_before。
 * - 周期 N 上升沿：op_valid_i 时执行一次动作（recover_valid_i 同拍时禁止普通推测写入）。
 * - R0：redirect_arbiter 接受赢家并发起 FTQ 检查点读取。
 * - R1：recover_valid_i 有效，本拍组合完成两个确定写入的选择，上升沿写回索引/占用数/栈顶并
 *   执行修正动作；recover_done_o 在本拍给出（属于 recover_id_i）。
 * - R2：BPU 从正确 PC 发起正常预测，top_o 通过旁路反映修复后的栈顶。
 * 以上为实现目标，不是已验证的时序或整核误预测惩罚。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module ras
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // 推测动作：每个成功分配的区域至多一次
    input  logic        op_valid_i,
    input  ras_action_e op_action_i,
    input  vaddr_t      op_push_addr_i,
    output vaddr_t      top_o,
    output logic        top_valid_o,       // 空栈时为 0，回退 BTB
    output ras_ckpt_t   ckpt_o,            // 本区域操作前的 ras_before，随 FTQ 保存

    // 恢复（来自 D24 赢家，R1 拍有效）
    input  logic        recover_valid_i,
    input  ftq_id_t     recover_id_i,      // 当前恢复身份；旧恢复不得写回
    input  ras_ckpt_t   recover_ckpt_i,
    input  ras_action_e recover_fix_i,     // 核实后的正确动作
    input  vaddr_t      recover_push_addr_i,
    output logic        recover_done_o,
    output ftq_id_t     recover_done_id_o,

    output fe_perf_t    perf_o
);
    // 未实现：16 项寄存器数组、top_idx/count、恢复拍双写选择与旁路。
endmodule
