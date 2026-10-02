/**
 * DTLB —— 数据访问地址翻译与页表权限
 *
 * 作用（B04/B06/B07）：
 * - load/store/AMO 地址执行后查询；命中给出 PPN、页大小与页表权限，miss 向共享 PTW 请求。
 * - TLB miss 不是异常：挂起相关 load 并释放执行流水级，PTW 完成后重试，成功后与 hit 路径资格相同。
 * - page fault 按访问类型（load / store-AMO）报告到原 ROB 项；故障 VA 与内部 PA 分开保存。
 * - TLB hit 不等于访问许可：PMP/PMA 另查，PMP 成功也不能替代页表权限（B06）。
 * - SFENCE.VMA 按 D26 四种范围定向失效；satp 切换按 D27 用 epoch 隔离迟到 PTW 返回。
 *
 * - A/D（B36）：命中且 A=1、权限满足、store 时 D=1 才走原流水完成；store 命中 D=0 的项返回
 *   perm_d=0，由 LSU 标记 needs_D（不报 page fault、不在推测路径写 D）；A=0 的项不交付，视同需要
 *   PTW（PTW 置 A 后安装）。D 位更新完成后对应翻译需更新或失效重装（方式待实现时确定）。
 * - 普通非对齐/跨页（B31）：同 line 非对齐硬件支持，跨 line 报异常；普通访问跨页必然跨 line，
 *   无需双页翻译。
 *
 * 细节待定：容量、相联度、reg/SRAM 实现。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 目标周期行为：周期 N 查询，周期 N+1 给出 resp（hit/miss/fault）；miss 后 ptw 握手，
 * ptw_resp_i 有效且 epoch 匹配时安装，等待者由 LSU 重放。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module dtlb
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int PORTS = CFG.lsu.agu_pipes
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          lookup_valid_i [PORTS],
    input  vaddr_t        lookup_vaddr_i [PORTS],
    input  logic          lookup_is_store_i [PORTS],   // store/AMO 需写权限
    output logic          resp_valid_o [PORTS],
    output tlb_resp_t     resp_o [PORTS],

    output logic          ptw_req_valid_o,
    input  logic          ptw_req_ready_i,
    output ptw_req_t      ptw_req_o,
    input  ptw_resp_t     ptw_resp_i,

    input  dmmu_csr_t     csr_i,
    input  sfence_req_t   sfence_i,
    output logic          sfence_done_o,

    output be_perf_t      perf_o
);
    // 未实现。
endmodule
