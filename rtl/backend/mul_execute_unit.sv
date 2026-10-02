/**
 * 整数乘法 FU 包装 —— 身份、结果容量、选择性取消（RV64M 乘法）
 *
 * 2026-10-02 框架：原“请求时组合 `*` + 固定拍数返回”的占位实现已移除（见 HEAD 06462b0），
 * 它不是真实多拍微结构，也没有结果 ready、身份或取消接口（B13）。
 *
 * 已定（B20/B21）：
 * - 数据通路沿用 Breeze SignedMul65x65：signed 65×65，Booth/Dadda/末级加法，三级真实流水，
 *   启动间隔 1；未来把 Chisel 实现转写为 SV（signed_mul65x65.sv），不例化 Vivado IP 或 DSP primitive。
 * - 本包装负责：MUL/MULH/MULHSU/MULHU/MULW 的输入符号/零扩展到 65 位与结果选择
 *   （MUL/MULW 取低位，MULW 结果符号扩展；高位变体取 [127:64]）。
 * - 每笔已接受请求的身份（fu_tag_t：ROB、目的 preg、分支依赖）随相同寄存边界推进。
 * - 误预测时逐条取消年轻操作、保留老操作；不能整体 flush（同一流水中可能同时有老/年轻操作）。
 * - 结果遇写回竞争可保持；迟到/已取消结果不得更新 PRF/ROB。
 *
 * 完成端（B33，2026-10-02 已定）：
 * - 流水不停顿；接受请求的同拍在 fu_completion_fifo 中预留完成空间（融合请求预留两项），
 *   无空间时 req_ready_o=0。结果到达必有位置。
 * - 交付时间确定：出口前一拍发出 wake_promise_t，依赖指令可被提前一拍安排；结果被写回仲裁推迟时
 *   留在 FIFO 头作为 bypass 源，不破坏已发出的承诺。
 * - FIFO 深度 CFG.exec.mul_result_slots 待定。
 *
 * MULH 类 + MUL 融合（B34，本项目方案）：
 * - req_i.fuse.valid=1 时只做一次 65×65 乘法，产生两个结果：高位归 req_i.tag（FUSE_HEAD），
 *   低位归 req_i.fuse.lo_tag（FUSE_MEMBER），两项进入完成 FIFO，可分拍交付；取消、迟到结果按各自
 *   身份过滤。融合时输入扩展按 FUSE_HEAD 的 MULH/MULHU/MULHSU 符号规则；MUL 低 64 位与符号扩展
 *   方式无关，因此复用同一乘积。
 *
 * 仍待定：发射归属（M FU IQ 归属）、身份代际、写回公平性；被取消运算在流水中清 valid 还是出口
 * 丢弃（两者都必须归还预留空间）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 目标周期行为（相对，不冻结延迟）：
 * - 周期 N：req 握手，输入扩展与身份进入流水 S0。
 * - 周期 N+1..N+3：三级实际运算流水；每拍检查 kill 并清除被取消项的 valid（方案待定）。
 * - 周期 N+STAGES-1：wake_o 发出承诺（提前一拍）。
 * - 之后：结果进入完成 FIFO（融合时两项），头部 resp_valid_o 直到 resp_ready_i（写口 grant），
 *   期间 bypass_o 持续有效。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module mul_execute_unit
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int STAGES       = CFG.exec.mul_stages,
    localparam int RESULT_SLOTS = CFG.exec.mul_result_slots
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       req_valid_i,
    output logic                       req_ready_o,     // 完成 FIFO 可预留（融合需两项）
    input  o3_types_pkg::mdu_req_t     req_i,

    // 完成 FIFO 头：写回候选、bypass 源与提前唤醒承诺（B33）
    output logic                       resp_valid_o,
    input  logic                       resp_ready_i,    // 取得整数写口或被取消
    output o3_types_pkg::mdu_resp_t    resp_o,
    output o3_types_pkg::cpl_bypass_t  bypass_o,
    output o3_types_pkg::wake_promise_t wake_o,

    input  branch_resolution_t         resolution_i,    // 选择性取消依据（br_mask）

    output logic                       busy_o           // 有在途请求：观测/同步用
);
    // 未实现：输入扩展、signed_mul65x65 例化、身份流水、fu_completion_fifo 例化（预留/承诺/bypass）、
    // 融合双结果拆分与选择性取消。
endmodule
