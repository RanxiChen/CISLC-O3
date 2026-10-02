/**
 * uBTB —— 快速预测器，每拍给出下一预测区域
 *
 * 作用：
 * - 用当前预测区域 PC 查询，同拍末给出下一区域入口，使 BPU 不必等待主 BTB/TAGE
 *   就能每拍推进并为每个区域分配 FTQ entry（D01、D02，第 4.1 节）。
 * - 结果只是快预测；主 BTB（两拍）与 TAGE（三拍）在慢预测出口检查并可覆盖。
 *
 * 目标机制：
 * - 已定：uBTB 快速、每拍连续推进；慢预测覆盖（D02）。
 * - 已定：表在提交时训练（D08）；执行误预测立即恢复推测状态，但不回滚表内容。
 * - 已定：只对实际选中且成功分配的区域产生一次动作（第 6.2 节、第 14 节不变量）。
 *
 * 细节待定（不能当作已决定）：
 * - 容量、映射方式（直接映射 / 全相联 / 链接后继 / 提前读下一 entry），字段与训练
 *   细则（第 4.1 节）。16.3 节讨论过全相联、优先空项、满时 round-robin 替换、预存
 *   8 位 event_hash，均未确认。
 * - 训练规则不能直接套用主 BTB 的 D07 规则（第 16.3 节）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为（相对 C0 示意，第 4.1 节）：
 * - 周期 N 组合：lookup_valid_i 时用 lookup_pc_i 查表，给出 pred_o（下一区域入口及
 *   本区域选中出口）。
 * - 周期 N 上升沿：BPU 在 FTQ 接受分配时把 pred_o.next_pc 作为下一拍查询 PC；
 *   stall_i 期间保持查询不推进。训练写入（train_valid_i）在不冲突时更新表项。
 * - 周期 N+1：查询下一区域。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module ubtb
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic       clk_i,
    input  logic       rst_i,

    // 查询：每拍一个区域
    input  logic       lookup_valid_i,
    input  vaddr_t     lookup_pc_i,
    input  logic       stall_i,          // FTQ 满或恢复期间暂停新预测
    output logic       hit_o,
    output bpu_pred_t  pred_o,

    // 提交训练（来自 FTQ 训练出口，经 BPU 分发）
    input  logic       train_valid_i,
    output logic       train_ready_o,
    input  bpu_train_t train_i,

    output fe_perf_t   perf_o
);
    // 未实现：表存储、匹配、替换与训练写入。
endmodule
