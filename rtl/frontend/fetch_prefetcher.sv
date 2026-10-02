/**
 * FTQ 驱动的指令预取器
 *
 * 作用：
 * - 跟随 FTQ 独立 prefetch 游标，把预测路径上的地址按 64B line 去重，经复用翻译或
 *   ITLB 得到物理地址，交给 ICache 查询 L1/在途；需要时由 MSHR 向 L2 预取，返回填入
 *   ICache（D18，第 11.1 节）。预取数据不进入 demand 返回队列。
 *
 * 目标机制：
 * - 已定（D18）：L1→L2→总线，单核范围。
 * - 已定（D19）：同页复用翻译，跨页提前查询 ITLB；已有翻译不无条件 PTW；预取查询
 *   需求优先。
 * - 已定（第 11.3 节）：L1 本地过滤及在途合并为方向；L2 跟踪 L1I 驻留未选。
 * - 已定（D25～D28）：同步期间暂停预取（hold_i）；被取消路径的预取无需撤销，
 *   但不得在 FENCE.I 失效后安装旧数据（由 MSHR 等待在途结束保证）。
 *
 * 细节待定（第 11.1 节、第 13 节第 7 条）：
 * - 领先距离、是否只看 slow_done 的 FTQ entry、触发与节流条件。
 * - 跨页翻译公平性、去重结构、资源保留份额。
 * - useful/late/unused 的严格定义及 line 上 provenance 元数据（第 12.2 节）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N：ftq_pf_valid_i 时取出一个区域地址，若与上次 line 相同则丢弃（去重）。
 * - 之后：查复用记录，形成 pf_req；pf 握手后由 ICache 处理；pf_resp_i 给出结果并
 *   可能返回新翻译用于安装。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module fetch_prefetcher
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // FTQ prefetch 游标
    input  logic        ftq_pf_valid_i,
    output logic        ftq_pf_ready_o,
    input  vaddr_t      ftq_pf_region_base_i,
    input  ftq_id_t     ftq_pf_ftq_id_i,

    // 到 ICache 的预取通道
    output logic        pf_req_valid_o,
    input  logic        pf_req_ready_i,
    output pf_req_t     pf_req_o,
    input  pf_resp_t    pf_resp_i,

    input  fe_csr_t     csr_i,
    input  sfence_req_t sfence_i,
    input  fe_kill_t    kill_i,
    input  logic        hold_i,

    output fe_perf_t    perf_o
);
    // 未实现：游标消费、去重、节流；内部应例化 prefetch_xlate_cache。
endmodule
