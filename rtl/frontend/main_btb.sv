/**
 * 主 BTB —— 两拍查询，每个区域 entry 只存一个跳转目标
 *
 * 作用：
 * - 给出区域内预测的条件分支/JAL 位置 mask、唯一目标归属槽位、类型与目标，
 *   与 TAGE 方向结果在慢预测出口联合选择下一 PC（D02、D05，第 4.2 节）。
 *
 * 目标机制：
 * - 已定：一个区域 entry 一个目标（D05）。mask 知道多个分支位置，不代表拥有它们
 *   的全部目标；所选 taken 分支只有在 cfi_slot 匹配时才能使用 target。
 * - 已定：无可用目标时继续顺序取指，后续修正（D06）；保留 raw_pred_taken 与
 *   target_missing 统计口径（第 4.3 节），由 bpu_slow_check 生成。
 * - 已定：目标更新为该区域最近一次提交的 taken CFI；无 taken 时保留旧目标（D07）。
 * - 已定：提交时训练（D08）。
 * - 已定：“单目标”与“组相联”是独立维度。
 *
 * 细节待定：
 * - 容量、路数、替换策略、表项位宽与 SRAM 端口（第 4.2 节、第 13 节第 2 条）。
 * - masks 与目标归属的完整更新规则（第 13 节第 2 条）。
 * - RAS action / length 字段的实际编码（第 4.2 节）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为（第 4.1 节）：
 * - 周期 N：s0_valid_i 时以区域地址启动阵列读。
 * - 周期 N+1：得到 resp_o（resp_valid_o），并在 N+2 与 TAGE 结果对齐。
 * - stall_i 时在途查询保持；kill_i 时丢弃在途查询（错误路径的慢预测不再写回）。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module main_btb
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic       clk_i,
    input  logic       rst_i,

    input  logic       s0_valid_i,
    input  vaddr_t     s0_region_base_i,
    input  logic       stall_i,
    input  logic       kill_i,

    output logic       resp_valid_o,
    output btb_resp_t  resp_o,

    input  logic       train_valid_i,
    output logic       train_ready_o,
    input  bpu_train_t train_i,

    output fe_perf_t   perf_o
);
    // 未实现：tag/目标阵列、匹配、替换和 D07 训练更新。
endmodule
