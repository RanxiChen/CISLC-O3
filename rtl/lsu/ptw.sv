/**
 * PTW —— 共享页表遍历器（ITLB 与 DTLB 共用），经 DCache 物理入口读页表
 *
 * 作用（已定方向，B07）：
 * - 接收 ITLB（前端）与 DTLB 的 miss 请求；Sv39 遍历；使用 DCache 物理访问入口读取 PTE，
 *   不递归翻译页表地址，与需求访问仲裁，共享最新数据、miss 处理与下级接口。
 *   独立 PTW 接 L2/Home 的旧建议不采用。
 * - 小型 walk cache 减少重复遍历；必须具有满足 D26 VA/ASID 定向失效的上下文。
 * - 前进保证：PTW 仲裁与资源分配不能被等待翻译的请求占尽其依赖的 cache/MSHR/回填资源；
 *   具体保留份额待定。
 * - PTW 读取页表的物理权限检查与最终目标访问权限分开（B06）。
 * - SFENCE.VMA：先前页表写入需到达 PTW 可见的位置；必须等待或取消相关旧 PTW，防止失效后
 *   重新安装旧翻译（D26）。satp 切换：取消旧 PTW 状态、隔离迟到返回，不强制等待旧遍历结束（D27）。
 *
 * - 硬件 A/D（B36）：叶 PTE A=0 时经 pte_ad_updater 原子置 A，完成更新后才交付可使用的翻译；
 *   store 需要 D 而 D=0 时不在推测遍历中写 D：返回翻译并标记需要 D（resp 中 perm_d=0），释放
 *   PTW 槽位，由 LSU 标记 needs_D，到 ROB 队首后非推测更新。mismatch 时按 updater 请求重新遍历。
 *   取消/SFENCE.VMA/satp 切换既过滤旧响应，也阻止失效上下文发起新的 PTE 写入。
 *
 * 细节待定：在途遍历数（CFG.mmu.ptw_slots）、walk cache 层级/组织、大页/ASID/global 处理细节、
 * 与 SFENCE 的等待-取消握手。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 目标周期行为：请求握手后进入遍历状态机；每级发 DCache 物理读，响应后检查 PTE；
 * 叶子或故障时广播 resp_o（src 字段区分 ITLB/DTLB），idle_o 表示无在途遍历。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module ptw
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic          clk,
    input  logic          rst,

    // ITLB（前端 ICache）与 DTLB 请求
    input  logic          itlb_req_valid_i,
    output logic          itlb_req_ready_o,
    input  ptw_req_t      itlb_req_i,
    input  logic          dtlb_req_valid_i,
    output logic          dtlb_req_ready_o,
    input  ptw_req_t      dtlb_req_i,
    output ptw_resp_t     resp_o,                 // 广播；ITLB/DTLB 按 src 与 epoch 过滤

    // DCache 物理访问入口（src = DC_SRC_PTW）
    output logic          mem_req_valid_o,
    input  logic          mem_req_ready_i,
    output dcache_req_t   mem_req_o,
    input  dcache_resp_t  mem_resp_i,

    input  dmmu_csr_t     csr_i,
    input  pmp_state_t    pmp_i,                  // 页表访问的物理权限检查
    input  sfence_req_t   sfence_i,
    output logic          sfence_done_o,
    output logic          idle_o,

    // A 位更新（B36）与 updater 发起的重新遍历
    output logic          a_upd_req_valid_o,
    input  logic          a_upd_req_ready_i,
    output pte_ad_req_t   a_upd_req_o,
    input  pte_ad_resp_t  a_upd_resp_i,
    input  logic          rewalk_req_valid_i,
    output logic          rewalk_req_ready_o,
    input  ptw_req_t      rewalk_req_i,

    output be_perf_t      perf_o
);
    // 未实现：遍历状态机、walk_cache 例化、PTE 检查、epoch 隔离。
endmodule
