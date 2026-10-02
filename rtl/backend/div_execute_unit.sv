/**
 * 整数除法/取余 FU 包装 —— 单请求迭代、特殊值、身份与取消（RV64M 除法）
 *
 * 2026-10-02 框架：原“请求时组合 `/`、`%` + 固定拍数返回”的占位实现已移除（见 HEAD 06462b0）。
 *
 * 已定（B21）：
 * - 数据通路沿用 Breeze UnsignedRadix4Divider：单请求迭代，按操作数最高有效位对齐，
 *   每次迭代两步 restoring 运算处理两位商，最多 32 次迭代；该数字不是整个 FU 固定延迟。
 *   未来转写为 SV（unsigned_radix4_divider.sv）；不换 radix-2，不做全流水除法。
 * - 本包装负责：输入有效位/绝对值预处理、除零（商全 1、余数=被除数）、signed overflow
 *   （商=被除数、余数=0）、商/余数符号恢复、DIVW/DIVUW/REMW/REMUW 的 32 位输入与结果符号扩展。
 * - 除法忙不阻塞乘法或普通 ALU（B13）。
 * - 一次只有一个在途请求：可按其身份判断是否被误预测取消，被取消时可提前终止（abort）。
 * - 结果保持到取得整数写口；被取消结果不得写回。
 *
 * 完成端（B33）：结果进入完成 FIFO / 保持槽；迭代除法不能从启动时假定固定延迟，只有在剩余迭代
 * 数确定、结束时间已确定时才可发出 wake_o 承诺（例如最后一次迭代的前一拍）；无法确定时不提前唤醒。
 * 除法恒不参与 B34 融合（req_i.fuse.valid=0）。
 *
 * 待定：特殊值是否走快速完成路径；IQ 归属与“忙”时的发射约束；写回公平性。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N：req 握手（仅空闲时 req_ready_o=1），锁存操作数、op 与身份，预处理。
 * - 之后每拍一次迭代，最多 CFG.exec.div_max_iters 次；期间 resolution 杀死本请求则终止。
 * - 完成：符号恢复后进入保持槽，resp_valid_o 直到 resp_ready_i。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module div_execute_unit
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int MAX_ITERS = CFG.exec.div_max_iters
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       req_valid_i,
    output logic                       req_ready_o,
    input  o3_types_pkg::mdu_req_t     req_i,

    output logic                       resp_valid_o,
    input  logic                       resp_ready_i,
    output o3_types_pkg::mdu_resp_t    resp_o,
    output o3_types_pkg::cpl_bypass_t  bypass_o,
    output o3_types_pkg::wake_promise_t wake_o,      // 仅结束时间已确定时有效

    input  branch_resolution_t         resolution_i,

    output logic                       busy_o
);
    // 未实现：预处理、unsigned_radix4_divider 例化、特殊值、符号恢复、取消。
endmodule
