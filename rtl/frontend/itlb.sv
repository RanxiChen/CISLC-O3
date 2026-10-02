/**
 * ITLB —— ICache S0/S1 中的指令地址翻译
 *
 * 作用：
 * - S0 与 cache 阵列访问并行启动查询，S1 完成命中比较、PPN 与权限选择（第 8 节）。
 * - miss 时向共享 PTW 发请求（B07：PTW 使用 DCache 物理访问入口），返回后安装。
 * - 也服务预取的跨页提前翻译，需求优先（D19）。
 *
 * 目标机制：
 * - 已定：TLB miss 不是错误物理地址的 cache hit；翻译/权限未完成不能交付数据。
 * - 已定（D19）：初版不加多级 TLB，不加专用预取查询端口；预取经端口仲裁。
 * - 已定（D26）：SFENCE.VMA 按 rs1/rs2 是否为 x0 选择四种范围；按每项实际页大小
 *   判断覆盖；清除所有匹配项；global 为遍历路径上的有效 G。
 * - 已定（D27）：satp 写入不自动全清 TLB；保留项按 ASID/global/模式匹配；旧 epoch
 *   的 PTW 迟到返回不安装。唯一 PTW 槽被旧事务占用时新 miss 可等待，命中路径不停。
 * - 已定（B06）：页表权限与 PMP 分开检查；本模块只给页表权限与 page fault。
 *
 * 细节待定：
 * - 容量、相联度、reg/SRAM 实现（第 8 节）。
 * - 与预取查询的仲裁公平性（第 13 节第 7 条）。
 * - A/D（B36 已定）：取指只需 A；A=0 时经共享 PTW 与旁侧 pte_ad_updater 原子置 A 后才安装/交付，
 *   常用命中路径不变。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N：s0_valid_i 查询。
 * - 周期 N+1：s1_* 给出 hit/ppn/权限/page_fault 或 miss。
 * - miss 后 ptw_req 握手，ptw_resp_i 有效且 epoch 匹配时安装，请求方重新查询。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module itlb
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic             clk_i,
    input  logic             rst_i,

    // 查询（demand 与预取已在 ICache 内仲裁）
    input  logic             s0_valid_i,
    input  vaddr_t           s0_vaddr_i,
    output logic             s1_valid_o,
    output logic             s1_hit_o,
    output logic             s1_miss_o,
    output logic [PPN_W-1:0] s1_ppn_o,
    output logic [1:0]       s1_level_o,
    output logic             s1_page_fault_o,
    output logic             s1_access_fault_o,

    // 共享 PTW
    output logic             ptw_req_valid_o,
    input  logic             ptw_req_ready_i,
    output ptw_req_t         ptw_req_o,
    input  ptw_resp_t        ptw_resp_i,

    input  fe_csr_t          csr_i,
    input  sfence_req_t      sfence_i,
    output logic             sfence_done_o,

    output fe_perf_t         perf_o
);
    // 未实现：表存储、匹配、SFENCE 范围失效、PTW 请求与安装。
endmodule
