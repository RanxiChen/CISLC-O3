/**
 * 分支历史 —— 推测路径的 taken 条件分支事件序列 E 与折叠值 C
 *
 * 作用：
 * - 维护沿实际采用预测路径推进的推测历史：最近 HIST_WINDOW 个 8 位事件 E，以及
 *   每张 TAGE 表的三个折叠值 C(L_i,n_i)、C(L_i,t_i)、C(L_i,t_i-1)。
 * - 为每个新分配区域给出入口快照 cur_o（写入 history_snapshot_store）。
 * - 恢复时装载出错区域的入口快照，再按正确结果注入事件。
 *
 * 目标机制：
 * - 已定（D09）：只有被实际选为 taken 且具有可用目标的条件分支推进历史；NT、JAL、
 *   JALR、call/return 不推进，NT 不插 0。预测、慢覆盖、预解码/执行恢复、提交参考
 *   历史使用同一资格规则。
 * - 暂定（D22）：e = fold_8(branch_PC >> 1) XOR rol_8(fold_8(target_PC >> 1), 1)；
 *   E_next[0] = e，E_next[a] = E[a-1]；
 *   C_next = rol_w(C, 2) XOR fold_w(e) XOR rol_w(fold_w(e_out), 2*L)，
 *   e_out = 更新前 E[L-1]，必须在写入覆盖前取得。多表同时更新只追加一次事件。
 * - 已定（D23）：恢复 E 的实际内容和 C，不能只恢复环形指针；恢复后 E 与 C 一致。
 * - 已定（D24）：恢复期间停止新预测；恢复可以多拍，用 restore_done_o 握手；
 *   恢复期间被更老请求替换时，旧恢复不得在随后覆盖新状态。
 * - 目标缺失而沿顺序路径时不更新历史（第 4.3 节）。
 *
 * 细节待定：
 * - E 用寄存器阵列、多读 mux 还是复制存储；每次更新取六个窗口边界事件的端口方案
 *   （第 5.4 节）。
 * - 恢复带宽与拍数。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N 组合：cur_o 给出当前推测历史（即下一个被分配区域的入口历史）。
 * - 周期 N 上升沿：push_valid_i 时追加一次事件并增量更新全部 C；
 *   restore_valid_i 时装载快照（优先于 push），restore_inject_i 时随后注入一次修正事件。
 * - 周期 N+1：cur_o 反映更新或恢复后的历史；restore_done_o 表示可继续预测。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module branch_history
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic           clk_i,
    input  logic           rst_i,

    // 推测推进：每拍至多一个 taken 条件分支事件（区域在 taken CFI 处结束）
    input  logic           push_valid_i,
    input  vaddr_t         push_branch_pc_i,
    input  vaddr_t         push_target_pc_i,

    // 当前推测历史：分配新区域时写入快照存储，TAGE 查询使用其 folds
    output hist_snapshot_t cur_o,

    // 恢复：装载出错区域入口快照，再按正确结果注入（D23）
    input  logic           restore_valid_i,
    input  hist_snapshot_t restore_snapshot_i,
    input  logic           restore_inject_i,
    input  vaddr_t         restore_branch_pc_i,
    input  vaddr_t         restore_target_pc_i,
    output logic           restore_done_o
);
    // 未实现：E 环形存储、折叠增量更新、快照装载与注入。
endmodule
