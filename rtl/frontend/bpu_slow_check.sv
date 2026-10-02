/**
 * 慢预测检查 —— 对齐主 BTB/TAGE/RAS 结果，确认或覆盖快预测
 *
 * 作用：
 * - 在慢预测出口把主 BTB 的位置/目标/类型与 TAGE 的 8 槽位方向对齐，按程序顺序
 *   选出该区域的有效控制流出口，生成慢预测结果 slow_o 写回 FTQ（第 4.1、6.3 节）。
 * - 与该区域的快预测比较；路径改变时发出 D24 慢覆盖请求 override_o。
 *
 * 目标机制：
 * - 已定：TAGE 给方向，主 BTB 给位置和唯一目标；taken 但目标归属槽位不匹配时
 *   target_missing=1、继续顺序路径（D05/D06，第 4.3 节）。
 * - 已定：return 优先 RAS 栈顶，空栈回退 BTB（第 6.2 节）。
 * - 已定（第 6.3 节）：保留 A 的原始 16B 数据，修正 A 的预测元数据与有效范围；路径
 *   改变时杀掉 A 之后的错误路径，恢复到 A 的检查点并应用修正结果。override 请求的
 *   kill_self=0（只清除其后），历史注入按修正后的 taken 条件分支决定。
 * - 已定：慢预测查询使用该区域保存的 C 与 RAS 上下文（D23，第 6.2 节）。D29 后 RAS 上下文即
 *   fast_ras_ckpt_i（该区域操作前的 {top_idx,count,top_addr}）：count!=0 时 return 取 top_addr，
 *   count==0 回退 BTB；不使用已前进到其他块的当前栈顶（原 ras_top_* 端口删除）。
 * - 慢预测完成（slow_o.valid）是返回队列出队条件 slow_done 的来源（D16）。
 *
 * 细节待定：
 * - 快慢比较的精确口径（第 12.2 节四类计数），寄存边界统一口径（第 4.1 节）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N：主 BTB 与 TAGE 对同一区域的结果同时有效，组合选择出口并与 fast_i 比较。
 * - 周期 N 上升沿：slow_o 写入 FTQ；override_o 送 redirect_arbiter。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module bpu_slow_check
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic          clk_i,
    input  logic          rst_i,

    // 与慢结果对齐的同一区域快预测及其身份
    input  logic          fast_valid_i,
    input  ftq_id_t       fast_ftq_id_i,
    input  bpu_pred_t     fast_i,
    input  ras_ckpt_t     fast_ras_ckpt_i,

    input  logic          btb_valid_i,
    input  btb_resp_t     btb_i,
    input  logic          tage_valid_i,
    input  tage_resp_t    tage_i,

    input  fe_kill_t      kill_i,

    output bpu_slow_t     slow_o,
    output redirect_req_t override_o,

    output fe_perf_t      perf_o
);
    // 未实现：出口选择、快慢比较、覆盖请求生成。
endmodule
