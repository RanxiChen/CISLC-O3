/**
 * 预取近期页翻译复用记录
 *
 * 作用：
 * - 保存少量近期有效翻译，使同页预取无需再查 ITLB，直接拼接页内偏移得到物理地址
 *   （D19，第 11.2 节）。
 *
 * 目标机制：
 * - 已定：同虚拟页、匹配地址空间/权限上下文及页大小时才可复用；不能只比较 VPN。
 * - 已定：“同页不查 TLB”不意味着跳过权限、PMP/PMA 检查。
 * - 已定：SFENCE.VMA（按 D26 范围）、satp 上下文变化使记录正确失效（D27：带 epoch/ASID）。
 * - 已定：预取翻译失败不产生架构异常。
 *
 * 细节待定：
 * - 项数、替换方式。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N 组合：lookup 给出 hit 与 paddr。
 * - 周期 N 上升沿：fill_valid_i 安装；sfence_i/epoch 变化时失效匹配项。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module prefetch_xlate_cache
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic             clk_i,
    input  logic             rst_i,

    input  vaddr_t           lookup_vaddr_i,
    output logic             lookup_hit_o,
    output paddr_t           lookup_paddr_o,

    input  logic             fill_valid_i,
    input  logic [VPN_W-1:0] fill_vpn_i,
    input  logic [PPN_W-1:0] fill_ppn_i,
    input  logic [1:0]       fill_level_i,

    input  fe_csr_t          csr_i,
    input  sfence_req_t      sfence_i
);
    // 未实现：记录存储、上下文匹配、失效。
endmodule
