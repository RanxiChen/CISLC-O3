/**
 * PTE A/D 硬件更新旁侧状态机（B36，2026-10-02 用户确认）
 *
 * 总原则：常用路径保持流水线。TLB 命中且权限与 A/D 满足时，load/store 照原流水线执行，不新增
 * 流水级，也不经过本模块。本模块只处理需要写 PTE 的慢路径，位于 PTW/DCache 旁侧。
 *
 * A 位（推测翻译中允许）：
 * - PTW 遍历得到叶 PTE 且 A=0 时，由本模块经 DCache 内部入口原子更新 A（完整 64 位 PTE 比较 +
 *   条件置位）；完成更新后 PTW 才交付可使用的翻译。
 *
 * D 位（非推测）：
 * - store 遇到 D=0：LSU 将该 SQ 项标记 needs_D，PTW 槽位被释放；该 store 到达 ROB 队首后，
 *   本模块进行非推测更新。首版慢路径可重新遍历，不要求每个 SQ 项保存完整 PTE 快照。
 * - needs_D 慢路径未完成前阻止年轻访存越过；已经执行的年轻访问纳入重放/排序处理（LDW_AD_ORDER）。
 *
 * 比较与错误：
 * - 比较不匹配（PTE 已被改变）时重新遍历检查，不能直接 OR 后覆盖，也不是立即报 page fault。
 * - 更新错误（物理访问错误等）归属原指令，在其退休前处理。
 * - A/D 实际写到 LR/SC 保留行时清除 reservation（pte_ad_resp 后送 rsv 冲突事件）。
 *
 * 取消与上下文：
 * - 取消、SFENCE.VMA、satp 切换不仅过滤旧响应，也必须阻止失效上下文发起新的 PTE 写入：
 *   请求携带 epoch，DCache 写入前与 cur_epoch_i 比对，不匹配不写。
 * - 内部 PTW 更新不能被外部 AMO 的 ROB 队首门控卡死：本模块使用 DC_SRC_PTE_AD 独立入口，
 *   不走 dcache_amo_unit 的队首原子请求路径。
 *
 * 细节待定：并发更新数（首版 1）；重新遍历次数上限是否需要前进保障；与 walk cache 的关系。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：
 * - 周期 N：req 握手（PTW 的 A 更新或队首 store 的 D 更新），锁存 PTE 物理地址、期望值与 epoch。
 * - 之后：向 DCache 发 pte_ad_req_t；mismatch 时请求 PTW 重新遍历；updated 时回复请求方。
 * - 任一拍 epoch 失效：不再发出写请求，已发出的响应只作为完成，不安装翻译。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module pte_ad_updater
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic            clk,
    input  logic            rst,

    // PTW：推测翻译中的 A 位更新
    input  logic            ptw_a_req_valid_i,
    output logic            ptw_a_req_ready_o,
    input  pte_ad_req_t     ptw_a_req_i,
    output pte_ad_resp_t    ptw_a_resp_o,

    // 队首 store 的 D 位非推测更新（来自 commit/LSU 的 needs_D 慢路径）
    input  logic            st_d_req_valid_i,
    output logic            st_d_req_ready_o,
    input  vaddr_t          st_d_vaddr_i,
    input  sq_idx_t         st_d_sq_idx_i,
    output logic            st_d_done_o,
    output exc_info_t       st_d_exc_o,        // 更新错误归属原指令

    // 重新遍历（首版慢路径不保存 PTE 快照）
    output logic            rewalk_req_valid_o,
    input  logic            rewalk_req_ready_i,
    output ptw_req_t        rewalk_req_o,
    input  ptw_resp_t       rewalk_resp_i,

    // DCache 内部 PTE 比较 + 条件置 A/D 入口
    output logic            dc_req_valid_o,
    input  logic            dc_req_ready_i,
    output pte_ad_req_t     dc_req_o,
    input  pte_ad_resp_t    dc_resp_i,

    input  xlate_epoch_t    cur_epoch_i,
    input  logic            kill_i,            // 取消 / SFENCE.VMA / satp：阻止失效上下文的新写入

    output rsv_conflict_t   rsv_conflict_o,    // A/D 实际写入地址（reservation 清除）
    output logic            busy_o
);
    // 未实现。
endmodule
