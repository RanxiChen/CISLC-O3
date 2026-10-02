/**
 * L2 inclusive 回收控制（B41，2026-10-02 用户确认）
 *
 * L2 已纳入首版；inclusive，覆盖 L1I 与 L1D；组相联；tree-PLRU 替换。本模块负责“淘汰一行之前
 * 让两个 L1 都不再持有它”的回收事务，是 L2 内部模块，由 l2_cache 例化。
 *
 * 一致性总原则：不改常规 load/store 与取指命中流水线。回收探测经 L1 的维护入口（L1D 与 DMA 探测
 * 共用的 dc_probe 维护队列；L1I 的 recall 维护入口），不新增普通访问的查询口或流水级。
 *
 * 回收事务流程：
 * 1) 启动前预留资源：探测应答接收位置、L1D 脏数据接收缓冲，以及必要时写回 DDR 的可靠保存位置
 *    （CFG.l2.wb_buffers）。资源不足时推迟新回收（受害行仍有效、way 不复用），不堵旧事务完成。
 * 2) 在 L2 同行统一事务状态中登记该行为 RECALL：保护目标行，阻止新的 L1 回填从该行安装；
 *    同行已在途的回填由 L1 侧标记为不可安装，防止旧响应在失效后重新装回。
 * 3) 定向失效两个 L1（首版每次都探测两个，不建精确 L1 驻留目录）。
 * 4) L1D 脏副本先交回最新数据（dc_probe_resp_t.had_dirty），再确认失效；inclusive 不代表 L2
 *    数据始终最新，接管 L1D 数据后才可视为本行最新内容。
 * 5) 收齐两个 L1 的确认、接管最新数据，并为必要写回提供可靠保存位置后，才把该 way 交还给
 *    分配者复用（way_free_o）。
 * - 探测应答不依赖普通 miss 的空闲 MSHR。
 * - 容量替换不清 LR/SC reservation（探测类型 PROBE_RECALL，L1D 侧不得据此清除）。
 * - 写回失败按 B39 报 fatal，不按成功释放，不虚假完成。
 *
 * 与同行其他事务（由 l2_cache 内统一行事务状态确定顺序，不同行继续并行）：
 * - 回填、L1D 写回、淘汰、DMA 不能各自独立修改同行状态；读 miss 合并兼容。
 * - 正在回收时到达的同行 L1D 写回并入回收事务，不重新分配。
 * - 完整 L1D 行写回不需要先读 DDR；正常 inclusive 情况下应命中 L2 项或同行在途事务；既无驻留项
 *   又无在途事务时由 l2_cache 暴露包含关系错误（inclusion_err），不能用自动重新分配掩盖。
 *
 * 未冻结：回收槽数（CFG.l2.recall_slots）、写回缓冲数、L2 容量/路数/bank/MSHR、AXI 宽度/ID、
 * 具体流水拍数；“L2 整行收齐、无错误并安装后再交付 L1，暂不 early restart”仍是建议，未确认。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：
 * - 周期 N：start_valid_i && start_ready_o（资源已预留）握手，上升沿登记回收槽与 recall_id。
 * - 之后：并行发出 L1I/L1D 探测；各自应答按 recall_id 归属，旧 id 应答丢弃。
 * - 收齐且数据已接管、写回位置已落实的那一拍 done 有效，上升沿释放回收槽，way_free_o 指出可复用
 *   的 set/way。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module l2_recall_ctrl
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG
) (
    input  logic              clk,
    input  logic              rst,

    // 来自 L2 分配/替换：选中的 victim（tree-PLRU 已跳过回收中/在途/受保护的 way）
    input  logic              start_valid_i,
    output logic              start_ready_o,      // 0：资源不足，推迟新回收
    input  paddr_t            start_line_paddr_i,
    input  logic              start_l2_dirty_i,   // L2 本身是否脏（决定是否必然写回 DDR）

    // 同行查询：L2 统一行事务状态用来把同行 L1D 写回并入回收事务
    input  paddr_t            lookup_line_paddr_i,
    output logic              lookup_hit_o,

    // L1I 定向失效
    output logic              l1i_recall_valid_o,
    input  logic              l1i_recall_ready_i,
    output l1_recall_req_t    l1i_recall_o,
    input  l1i_recall_resp_t  l1i_recall_resp_i,

    // L1D 定向失效（与 DMA 探测在 l2_cache 内仲裁进入同一维护入口）
    output logic              l1d_probe_valid_o,
    input  logic              l1d_probe_ready_i,
    output dc_probe_req_t     l1d_probe_o,
    input  dc_probe_resp_t    l1d_probe_resp_i,

    // 接管的最新数据与写回
    output logic              wb_valid_o,
    input  logic              wb_ready_i,
    output paddr_t            wb_line_paddr_o,
    output logic [L2_LINE_BYTES*8-1:0] wb_data_o,

    // way 可复用
    output logic              way_free_o,
    output paddr_t            way_free_line_paddr_o,

    output fatal_evt_t        fatal_o,
    output logic              idle_o
);
    // 未实现。
endmodule
