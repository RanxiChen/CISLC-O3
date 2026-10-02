/**
 * L1 DCache —— 组相联、写回、多 bank、非阻塞数据缓存
 *
 * 作用（已定方向，B03/B04/B05/B08/B09）：
 * - 普通 load/store、PTW 页表读取、L1 原子操作复用本 cache；L2 缓冲 DDR 访问。
 * - hit-under-miss；多个独立 miss 在途与同 line 合并（dcache_mshr）。流水线等待与事务等待分开；
 *   一次 miss 不把整个访问流水线置忙。
 * - 多 bank 提供实际并行带宽；同 bank 仲裁，tag/meta 访问能力必须配套；
 *   不同 line 不保证不同 bank，不承诺两读一写无冲突。
 * - Load：翻译与 PMP/PMA 检查完成后才允许产生有效结果；SQ 与 cache 可并行查询，结果统一选择；
 *   SQ 完整提供数据时不因 cache miss 无条件申请下级取数。miss 分配或合并 MSHR；资源不足等待
 *   可用事件；回填安装后经 wake_o 唤醒 load 重查（不要求回填直接写 preg）。
 * - Store drain：请求接受与写完成分开；命中写完确认后 SQ 释放；miss/冲突/DMA 行保护时 SQ 保留项，
 *   等事件后重试，不重复发送在途请求；store 等 miss 不占 bank 流水级（B05）。
 * - 响应区分等待原因（dc_status_e），避免盲目重试（B04）。
 * - B31：普通可缓存标量非对齐访问同 line 内硬件支持（内部可跨 bank 拆分/拼接，仍是一次访问）；
 *   跨 line 由 LSU 在发出前报地址非对齐异常，不进入本 cache。
 * - DMA 行协调（B08）：接受 probe 后阻止该行新的 CPU 访问与 AMO，其他行继续；已接受访问完成到
 *   安全边界；clean+invalidate 后返回 quiesced；不得堵住完成旧事务所需的响应/回填/写回/探测应答；
 *   probe 使用维护队列与 bank 仲裁，持续 CPU 请求下也不能永久饥饿。
 * - AMO/LR/SC：内含 dcache_amo_unit 与独立 lrsc_reservation（B09/B35）。store drain/AMO 实际写、
 *   PTE A/D 实际写、DMA 写取得行保护权时向 reservation 送冲突事件；替换/clean/writeback/DMA 读/
 *   L2 容量回收不清除。SC 在途行不被重复选为 victim、维护请求不得无限抢占 SC（前进保障）。
 * - FENCE.I（B23/D25，commit_ctrl 编排）：clean_all_req_i 后遍历全部 tag/meta，跳过非脏行，每个
 *   脏行复用按行 clean+invalidate 写回 L2 并失效，等全部写回确认后 clean_all_done_o；
 *   clean_all_busy_o 供 fencei_dcache_evict_cycles 计数。干净行不逐出。
 * - 维护入口（2026-10-02 确认，常规流水不变）：probe_* 同时承载 DMA 行协调（PROBE_DMA）与 L2
 *   inclusive 回收（PROBE_RECALL）；均经维护队列与 bank 仲裁，不新增普通访问的查询口或流水级；
 *   探测应答不依赖普通 miss 的空闲 MSHR；同行在途回填须标记为不可安装，旧响应不得重新装回；
 *   脏副本先交回最新数据再确认。RECALL 不清 reservation。
 * - PTE A/D（B36）：pte_ad_* 是内部“完整 64 位 PTE 比较 + 条件置 A/D”入口，只供旁侧
 *   pte_ad_updater 使用；普通 load/store 不经过它。比较不匹配返回 mismatch；epoch 失效不写入。
 *   该入口不经 dcache_amo_unit 的 ROB 队首原子门控，避免被外部 AMO 卡死。
 * - 写回错误（B39）：脏行写回 L2 失败时 fatal_o 上报，失败写回不得按成功释放，维护/DMA 不得
 *   虚假完成。
 * - TLB 命中、权限与 A/D 均满足时 load/store 照常走原流水；store 遇 D=0 由 LSU 标记 needs_D（B36）。
 *
 * 细节待定（不能当作已决定）：容量、路数、line 大小、bank 数与映射（整行或行内 word 交错）、
 * 端口、流水级数、BRAM 映射、MSHR 与写回缓冲数、替换策略；FENCE.I 数据侧接口的具体形式。
 * 建议配置 16KiB/4-way/64B/4 bank/8 MSHR 仅为建议（B03）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 * 现有 LSU 仍访问 DTCM 与单口外部 memory（旧合同）。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module dcache
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int LOAD_PORTS = CFG.lsu.agu_pipes      // load/AGU 管线数待定（B03）
) (
    input  logic            clk,
    input  logic            rst,

    // load 管线（每条 AGU 管线一个）
    input  logic            ld_req_valid_i [LOAD_PORTS],
    output logic            ld_req_ready_o [LOAD_PORTS],
    input  dcache_req_t     ld_req_i       [LOAD_PORTS],
    output dcache_resp_t    ld_resp_o      [LOAD_PORTS],

    // committed store drain（SQ 按序，首版一次一笔，B05）
    input  logic            st_req_valid_i,
    output logic            st_req_ready_o,
    input  dcache_req_t     st_req_i,
    output dcache_resp_t    st_resp_o,

    // AMO / LR / SC（ROB 队头，B09）
    input  logic            amo_req_valid_i,
    output logic            amo_req_ready_o,
    input  dcache_req_t     amo_req_i,
    output dcache_resp_t    amo_resp_o,

    // PTW 物理读（B07）
    input  logic            ptw_req_valid_i,
    output logic            ptw_req_ready_o,
    input  dcache_req_t     ptw_req_i,
    output dcache_resp_t    ptw_resp_o,

    // stride 预取（B07）
    input  logic            pf_req_valid_i,
    output logic            pf_req_ready_o,
    input  dcache_req_t     pf_req_i,

    // MSHR 回填完成唤醒
    output dc_wake_t        wake_o,

    // DMA 行协调探测（来自 L2 协调器，B08）
    input  logic            probe_valid_i,
    output logic            probe_ready_o,
    input  dc_probe_req_t   probe_i,
    output dc_probe_resp_t  probe_resp_o,       // quiesced

    // FENCE.I 数据侧：L1D 全行扫描，脏行写回 L2 并逐出（B23，commit_ctrl 发起）
    input  logic            clean_all_req_i,
    output logic            clean_all_done_o,
    output logic            clean_all_busy_o,

    // PTE 比较 + 条件置 A/D 内部入口（B36，旁侧 pte_ad_updater）
    input  logic            pte_ad_req_valid_i,
    output logic            pte_ad_req_ready_o,
    input  pte_ad_req_t     pte_ad_req_i,
    output pte_ad_resp_t    pte_ad_resp_o,
    input  xlate_epoch_t    cur_epoch_i,

    // reservation 清除（trap/xRET/SFENCE.VMA/satp，来自 commit_ctrl）与 PTW A/D 写冲突
    input  logic            rsv_clear_valid_i,
    input  rsv_clear_e      rsv_clear_reason_i,
    input  rsv_conflict_t   rsv_pte_ad_conflict_i,

    // L1D ↔ L2：回填请求/响应、脏行写回
    output logic            l2_req_valid_o,
    input  logic            l2_req_ready_i,
    output l2_req_t         l2_req_o,
    input  l2_resp_t        l2_resp_i,
    output logic            l2_resp_ready_o,
    output logic            l2_wb_valid_o,
    input  logic            l2_wb_ready_i,
    output paddr_t          l2_wb_line_paddr_o,
    output logic [DC_LINE_BYTES*8-1:0] l2_wb_data_o,
    input  logic            l2_wb_error_i,       // B39：L2 拒绝/失败的写回（含包含关系错误）

    output logic            idle_o,
    output fatal_evt_t      fatal_o,             // B39：脏行写回 L2 失败
    output be_perf_t        perf_o
);
    // 未实现：tag/meta/data bank 阵列、主流水、bank 仲裁、行保护、维护队列（DMA/回收/FENCE.I
    // 共用）、PTE 条件更新入口；内部应例化 dcache_mshr、dcache_writeback、dcache_amo_unit、
    // lrsc_reservation。
endmodule
