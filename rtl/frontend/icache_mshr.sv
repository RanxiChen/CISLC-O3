/**
 * ICache MSHR —— 未完成 miss 跟踪、同 line 合并、回填安装
 *
 * 作用：
 * - 为 demand 与预取 miss 分配行事务，合并同 line 请求，向 L2 发请求，收集回填 beat，
 *   完成后通过 ICache 写口安装整条 line，再唤醒等待该 line 的请求（第 9 节）。
 *
 * 目标机制：
 * - 已定（D13）：回填相关冲突采用等待，保留请求/状态，不靠反复重发。
 * - 已定（D14）：hit under miss；一次 miss 不全局停住 ICache。
 * - 已定（第 9.2 节）：未完整、合法安装的 line 不参与有效命中；完整 line 可用后才
 *   发布 valid；read-during-write 行为必须显式规避或定义。
 * - 已定（第 9.2 节）：refill 必须能继续推进，不被等待该 refill 的 demand 反向堵死。
 * - 已定（D17）：错误路径已发出的 miss 可以完成并安装；返回在返回队列侧丢弃。
 * - 已定（D27）：satp 切换后旧事务允许自然返回，保留身份直到返回完成，不提前复用。
 * - 已定（D25）：FENCE.I 失效前等旧取指/预取在途操作结束，避免失效后再次安装旧数据。
 *
 * 细节待定：
 * - MSHR 数量、合并 fanout、被杀请求所占资源的释放、需求与预取保留份额（第 9.3 节）。
 * - 阻塞粒度（整 bank、set、way 或 line，第 9.2 节）；替换策略。
 * - 回填 beat 宽度（第 9.1 节）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N：S3 miss 时 alloc_valid_i；已有同 line 项则合并，否则分配新项（满则 alloc_ready_o=0）。
 * - 之后：向 L2 发请求；每个 l2_resp_i beat 写入行缓冲；last 后请求写口安装。
 * - 安装完成拍：fill_done_o 广播 line 地址，ICache 唤醒等待请求重新查询。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module icache_mshr
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic          clk_i,
    input  logic          rst_i,

    // 分配/合并（来自 S3 miss 或预取）
    input  logic          alloc_valid_i,
    output logic          alloc_ready_o,
    input  paddr_t        alloc_line_paddr_i,
    input  l2_req_kind_e  alloc_kind_i,
    output logic          alloc_merged_o,

    // 在途查询：预取过滤用
    input  paddr_t        probe_line_paddr_i,
    output logic          probe_inflight_o,

    // L2
    output logic          l2_req_valid_o,
    input  logic          l2_req_ready_i,
    output l2_req_t       l2_req_o,
    input  l2_resp_t      l2_resp_i,
    output logic          l2_resp_ready_o,

    // 回填安装（经 ICache 每 bank 写口，与读口冲突时等待）
    output logic          fill_wr_valid_o,
    input  logic          fill_wr_ready_i,
    output paddr_t        fill_wr_line_paddr_o,
    output logic [ICACHE_LINE_BYTES*8-1:0] fill_wr_data_o,
    output logic          fill_wr_error_o,
    output logic          fill_done_o,
    output paddr_t        fill_done_line_paddr_o,

    output logic          idle_o,          // 无在途事务：FENCE.I/同步等待用

    output fe_perf_t      perf_o
);
    // 未实现：MSHR 表项、合并、L2 请求、beat 收集、安装与唤醒。
endmodule
