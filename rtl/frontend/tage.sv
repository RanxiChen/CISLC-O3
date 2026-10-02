/**
 * TAGE —— 三拍方向预测，一次产生 8 个槽位方向
 *
 * 作用：
 * - 用区域地址 P = region_base >> 4 和区域入口折叠历史 C 查询 base 表与六张 tagged
 *   表，输出 8 个槽位的条件方向（D02、D04，第 4.4 节）。
 * - 只给方向，不生成目标，也不是执行结果。
 *
 * 目标机制：
 * - 已定：8 槽位方向向量（D04）。表内可每行 8 槽位状态，SRAM 宽度另定。
 * - 暂定：六张 tagged 表窗口 4/8/16/32/64/128 次 taken 条件分支事件（D22）。
 * - 暂定：index_i = fold_n_i(P) XOR C(L_i,n_i)；
 *         tag_i = (fold_t_i(P) XOR C(L_i,t_i) XOR (C(L_i,t_i-1) << 1)) & mask（第 5.4 节）。
 * - 已定：查表使用该区域入口 E/C 上下文；被选中的 taken 条件分支不提前注入本区域查询。
 * - 已定：提交时训练，必须使用原查询上下文（train_i.ctx 与 tage_meta），
 *   不能在提交时用当前全局历史重新查询（第 6.1 节）。
 *
 * 细节待定：
 * - 各表行数、tag 宽度、base 表容量、计数器/useful 位宽、有效位与槽位共享方式。
 * - 分配/替换策略；三拍内 index 生成、阵列访问、tag/provider 选择的寄存边界。
 *
 * 不在第一版：SC、loop predictor、ITTAGE（第 4.4 节）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N：s0_valid_i 时由 P 与 s0_folds_i 生成 index。
 * - 周期 N+1：阵列访问。
 * - 周期 N+2：tag 比较、provider 选择，resp_valid_o/resp_o 有效。
 * - stall_i 保持在途查询，kill_i 丢弃在途查询。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module tage
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    input  logic                   s0_valid_i,
    input  vaddr_t                 s0_region_base_i,
    input  logic [HIST_FOLD_W-1:0] s0_folds_i,        // 本区域入口的折叠值 C
    input  logic                   stall_i,
    input  logic                   kill_i,

    output logic                   resp_valid_o,
    output tage_resp_t             resp_o,

    input  logic                   train_valid_i,
    output logic                   train_ready_o,
    input  bpu_train_t             train_i,

    output fe_perf_t               perf_o
);
    // 未实现：base/tagged 表、index/tag 计算、provider 选择、分配与训练。
endmodule
