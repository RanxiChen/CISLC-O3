/**
 *
 * 【2026-10-02 位置】已移到 rtl/common/：取指与数据访问共用同一份地址图。数据侧还需给出
 * 可读/可写/支持原子/是否 MMIO（不可缓存、有副作用）等属性（B05/B07/B09），当前端口只列取指属性。
 * PMA 检查 —— 物理地址属性判定
 *
 * 作用：
 * - 在 S2 判定取指物理地址的属性：是否可执行、是否可缓存、是否存在（第 8 节）。
 * - 预取也必须遵守可访问区域，不能读取有副作用的 MMIO（B07）。
 *
 * 目标机制：
 * - 已定：目标物理地址和 PMA 属性确定后才能完成访问分类（B06）。
 * - 已定：不可执行/不存在区域产生取指访问异常，异常也要完成返回队列项。
 *
 * 未设计：
 * - KCU105 整机物理地址图与属性表（DDR、MMIO、Boot ROM、ITCM 等的范围）。
 * - 不可缓存取指（例如从 Boot ROM 执行）的路径：绕过 ICache 还是单次填充，未设计。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N（S2）：组合给出属性，随 S2 寄存进入 S3。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module pma_checker
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  paddr_t paddr_i,
    output logic   exec_ok_o,
    output logic   cacheable_o,
    output logic   exists_o
);
    // 未实现：地址图与属性表（未设计）。
endmodule
