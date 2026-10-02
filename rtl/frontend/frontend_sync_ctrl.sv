/**
 * 前端系统同步控制 —— FENCE.I / SFENCE.VMA / satp / PMP 的前端部分
 *
 * 归属（2026-10-02 确认）：系统同步由后端 commit_ctrl 统一编排，本模块只执行前端部分：
 * 停取指/预取、隔离旧请求、失效前端翻译/指令状态、更新 PMP 派生状态，完成后报告 sync_done_o。
 * 本模块不再发起 DCache clean；FENCE.I 的 SQ drain 与 L1D 脏行扫描写回逐出由 commit_ctrl
 * 在发出本请求之前完成（B23/D25 顺序）。年轻路径清除与重新取指由同一指令的 sys_redirect（D24）
 * 完成，本模块只负责状态同步。
 *
 * 目标机制：
 * - D25 FENCE.I（前端部分，commit_ctrl 已确认 SQ drain + L1D 脏行写回逐出完成之后才发出）：
 *   暂停取指与预取；等旧取指/预取在途结束（icache_idle_i），保证失效后不会再安装旧指令数据；
 *   整个 ICache 清 valid；清除 F0 残留半字、返回队列与指令 buffer 旧内容；全部确认后 sync_done_o，
 *   commit_ctrl 随后让 FENCE.I 退休并从下一条指令重取。
 * - D26/B24 SFENCE.VMA：commit_ctrl 已先等 SQ 全量排空；ITLB、预取翻译复用记录接收同一范围
 *   描述，匹配项清 valid；旧 PTW 的等待/隔离由后端 PTW 与本请求共同完成（ptw_idle_i 为观测）；
 *   不清 ICache 数据，不做 L1D 脏行扫描。
 * - D27 satp：推进翻译 epoch，取消旧 PTW 状态并隔离迟到返回；不把所有旧事务返回作为重启前提；
 *   satp 写入本身不全清 TLB。
 * - D28 PMP：更新 PMP 范围派生状态，清除旧权限结果；保留 ICache 数据。
 *
 * 细节待定：各步骤拍数、失效遍历方式、与 sys_redirect 同拍关系的信号编码。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N：sync_req_valid_i && sync_req_ready_o 握手，上升沿锁存请求，hold_o 在 N+1 起为 1。
 * - 之后：按种类依次等待 icache_idle_i / 发出失效 / 等待 done；全部完成的那一拍 sync_done_o
 *   脉冲一拍，下一拍 hold_o 释放。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module frontend_sync_ctrl
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic         clk_i,
    input  logic         rst_i,

    input  logic         sync_req_valid_i,
    output logic         sync_req_ready_o,
    input  fe_sync_req_t sync_req_i,
    output logic         sync_done_o,

    // 暂停新取指与预取
    output logic         hold_o,

    // 在途状态
    input  logic         icache_idle_i,
    input  logic         ptw_idle_i,

    // 失效动作
    output logic         icache_inv_all_o,
    input  logic         icache_inv_done_i,
    output sfence_req_t  sfence_o,
    input  logic         sfence_done_i,
    output logic         pmp_update_o,
    input  logic         pmp_update_done_i,
    output logic         f0_clear_o
);
    // 未实现：同步状态机。
endmodule
