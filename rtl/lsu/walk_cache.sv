/**
 * Walk cache —— 页表遍历中间级缓存
 *
 * 作用（B07）：缓存非叶 PTE（下一级页表物理地址），减少重复遍历。
 * 必须保存 ASID、global、层级等足够上下文，使 SFENCE.VMA 按 D26 的 VA/ASID 规则定向失效，
 * 不擅自改为全清；satp 切换后的旧遍历结果不得安装（D27 epoch）。
 *
 * 细节待定：缓存层级（只缓存第一级还是多级）、条目组织/容量（CFG.mmu.walk_cache_entries）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module walk_cache
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic             clk,
    input  logic             rst,

    input  logic             lookup_valid_i,
    input  logic [VPN_W-1:0] lookup_vpn_i,
    input  asid_t            lookup_asid_i,
    output logic             hit_o,
    output logic [1:0]       hit_level_o,        // 命中的中间级
    output logic [PPN_W-1:0] hit_next_ppn_o,     // 下一级页表 PPN

    input  logic             fill_valid_i,
    input  logic [VPN_W-1:0] fill_vpn_i,
    input  asid_t            fill_asid_i,
    input  logic             fill_global_i,
    input  logic [1:0]       fill_level_i,
    input  logic [PPN_W-1:0] fill_next_ppn_i,
    input  xlate_epoch_t     fill_epoch_i,

    input  xlate_epoch_t     cur_epoch_i,
    input  sfence_req_t      sfence_i
);
    // 未实现。
endmodule
