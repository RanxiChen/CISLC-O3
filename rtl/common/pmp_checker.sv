/**
 *
 * 【2026-10-02 位置】已移到 rtl/common/：前端 ICache 与数据侧 LSU/PTW 各自实例化（参数 CFG 仍取前端配置中的
 * PMP 项数来源 core.pmp_entries）。数据侧需要读/写/执行三类权限与 PTW 页表访问检查（B06）；
 * 当前端口只按取指执行权限描述，数据侧权限输入待补。
 * PMP 检查 —— S2 范围匹配，S3 优先级与权限汇总
 *
 * 作用：
 * - 对取指物理地址检查 PMP 执行权限（第 8 节）。
 * - 将范围计算与优先级/权限汇总分开两级，避免串在一级（第 8 节时序分工目标）。
 * - PMP 有效修改时更新范围预解码派生状态（D28）。
 *
 * 目标机制：
 * - 已定：S2 PMP 范围匹配候选；S3 优先级与权限汇总（第 8 节）。
 * - 已定：预解码/配置派生状态可在 CSR 修改时更新（cfg_i.update）。
 * - 已定（D28）：ICache 数据保留，命中仍必须通过当前 PMP 权限检查；旧请求迟到返回
 *   按取消标记隔离。
 * - 已定（B06）：PMP 成功不能替代页表权限检查。
 *
 * 细节待定：
 * - PMP 项数（core.pmp_entries）；派生状态更新需要几拍以及期间的取指阻塞方式。
 * - 访问跨 PMP 区域边界（16B 请求）的判定方式。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N（S2）：s2_valid_i 时对各项计算匹配候选，寄存。
 * - 周期 N+1（S3）：按优先级与特权级汇总，s3_allow_o / s3_fault_o 有效。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module pmp_checker
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic       clk_i,
    input  logic       rst_i,

    input  logic       s2_valid_i,
    input  paddr_t     s2_paddr_i,
    input  logic       stall_i,

    output logic       s3_valid_o,
    output logic       s3_allow_o,
    output logic       s3_fault_o,       // 映射为 instruction access fault

    input  pmp_state_t cfg_i,
    input  logic [1:0] priv_i,
    output logic       cfg_update_done_o
);
    // 未实现：范围预解码、匹配、优先级与权限汇总。
endmodule
