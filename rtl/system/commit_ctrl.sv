/**
 * 提交控制 —— ROB 队头之后的按序副作用、系统同步编排、trap/xRET 发起
 *
 * 主流程均已定（B22～B27、B31、B37～B40），本模块 RTL 尚未实现。
 *
 * 按序副作用（每拍对实际退休前缀）：
 * - ftq_commit_t（region_last：区域有效指令全部提交，FTQ 交接训练后回收，前端 16.2）。
 * - SQ committed 标记（B05）；committed RAT 更新与 old preg 按目的域归还（B15）。
 * - committed_next_pc（B37）：维护“已退休前缀之后的下一架构 PC”。普通指令 = 原始 PC + 真实长度，
 *   控制流 = 真实后继 PC（rob_commit_t.succ_pc）；同拍多条取最后一条实际退休指令的 succ_pc；
 *   正式 trap/xRET 生效后更新为入口/返回目标；普通分支恢复不修改；复位初始化到启动入口。
 *   用于中断精确 EPC（尤其 ROB 为空时）；同步异常仍用故障指令 PC；不允许用推测取指 PC 代替。
 * - FP 架构状态（B40）：fflags 按实际退休项 OR 合并，一次交给 csr_file；退休写架构 FPR 或退休项
 *   带非零 fflags 时置 FS Dirty（不比较新旧数据）；错误路径与 trap 拍不更新。与 CSR 串行更新、
 *   trap 的互斥：trap 拍无正常退休（B26），CSR 串行执行期间 ROB 无其他退休项，因此同拍不会同时
 *   有 fp_retire_evt 与 CSR 写或 trap 更新；不给普通 FP 执行增加状态阶段。
 *
 * 队头串行操作编排（Decode→Rename 串行阻塞见 B22，年轻指令在其退休前不进入 Rename）：
 * - CSR（B22）：队头且更老已退休后经 csr_file 执行；写回容量在架构写入前保证；架构写入后不可取消，
 *   必须退休。改变取指/翻译状态的写入经 sys_redirect + 前端同步重取。
 * - FENCE（B23）：pred.W 且需排序时等 SQ 正常 drain 至空（DCache 写完成确认）；否则队头即完成。
 * - FENCE.I（B23/D25，本模块统一编排，2026-10-02 确认）：
 *     1) 等 SQ 中老 store 全部写入 DCache 并确认；
 *     2) dcache_clean_all：遍历 L1D tag/meta，脏行写回 L2 并逐出（干净行保留），等全部确认；
 *     3) 发 fe_sync（SYS_FENCE_I）：前端停取指/预取、隔离旧请求、ICache 全失效、清 F0/返回队列/
 *        指令 buffer；
 *     4) fe_sync_done 后该 ROB 项完成并退休，sys_redirect 从下一条重取。
 *   前端 frontend_sync_ctrl 不再自行发起 DCache clean。
 * - SFENCE.VMA（B24/D26）：先全量 SQ drain；再 sfence 送 DTLB/PTW/walk cache 并 fe_sync 送 ITLB/
 *   预取翻译记录；隔离旧 PTW；两侧完成后退休。不做 L1D 脏行扫描。首版同时清 LR/SC reservation。
 * - satp/PMP 写（D27/D28）：随 CSR 执行完成后经 fe_sync 与 sys_redirect 同步；satp 切换清 reservation。
 * - WFI（B38）：合法 WFI 正常退休后交给 wfi_ctrl 进入等待；committed_next_pc 指向后继。
 * - MRET/SRET（B27）：合法队首指令自身正常退休直接触发返回（可与退休同拍），清 reservation。
 *
 * 异常与中断（B26）：
 * - 同步异常：退休停在故障指令之前；下一拍故障指令为最老项时在无正常退休的 trap 拍接受；
 *   故障项不退休。B31 跨 line 非对齐在 trap 接受握手计一次（BE_MISALIGNED_CROSSLINE_TRAP）。
 * - 中断：只在指令边界；串行 CSR 已更新架构状态时先退休再复核；不可撤销 AMO/MMIO 先到安全边界。
 *   EPC = committed_next_pc。
 * - trap 入口与合法 xRET 均清 LR/SC reservation（B35）。
 *
 * fatal（B39）：isolate_i 有效后停止后续正常退休与新串行操作，保留在途总线收尾。
 *
 * 观测（B22/B23/B31）：csr_retired、csr_wait_empty_cycles、csr_block_younger_cycles、
 * fencei_retired、fencei_dcache_evict_cycles、misaligned_crossline_traps，经 perf_o 输出增量。
 *
 * 细节待定：各同步握手的信号编码与拍数；free list 提交态恢复记录的结构；串行项是否与 CSR 共用。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 * 现有 backend 内由组合逻辑直接把 ROB 退休转成 SQ committed / free list 释放 / FTQ release_count（旧合同）。
 *
 * 逐周期说明（目标）：
 * - 周期 N 组合：选定实际退休前缀（或 trap，二者不同拍；合法 xRET 可与自身退休同拍）；
 *   形成 sq_commit、ftq_commit、fp_retire_evt、committed_next_pc_nxt、trap_req。
 * - 周期 N 上升沿：committed_next_pc 更新；串行编排状态推进；trap 接受时锁存请求。
 * - 周期 N+1：trap 接受后前端按入口 PC 取指（B26 目标）；committed_next_pc 为新边界。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module commit_ctrl
    import o3_types_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width
) (
    input  logic            clk,
    input  logic            rst,
    input  vaddr_t          boot_pc_i,           // committed_next_pc 复位值

    input  rob_commit_t     commit_i [COMMIT_WIDTH],
    input  logic            head_valid_i,
    input  rob_commit_t     head_i,
    output logic            head_serial_done_o,
    output logic            commit_block_o,      // 本拍禁止正常退休（trap 拍 / fatal / 串行等待）

    // 按序副作用
    output ftq_commit_t     ftq_commit_o [COMMIT_WIDTH],
    output logic            sq_commit_valid_o [COMMIT_WIDTH],
    output sq_idx_t         sq_commit_idx_o   [COMMIT_WIDTH],
    output fp_retire_evt_t  fp_retire_o,         // B40：fflags OR 合并 + FS Dirty
    output vaddr_t          committed_next_pc_o, // B37

    // 系统重定向与前端同步（本模块编排）
    output sys_redirect_t   sys_redirect_o,
    output logic            fe_sync_valid_o,
    input  logic            fe_sync_ready_i,
    output fe_sync_req_t    fe_sync_o,
    input  logic            fe_sync_done_i,

    // 数据侧同步
    input  logic            sq_committed_empty_i,
    output logic            dcache_clean_all_o,  // FENCE.I：L1D 脏行扫描写回逐出
    input  logic            dcache_clean_all_done_i,
    input  logic            dcache_clean_all_busy_i, // fencei_dcache_evict_cycles 口径
    output sfence_req_t     sfence_o,
    input  logic            sfence_done_i,       // DTLB + PTW/walk cache

    // 队首 store 的 D 位非推测更新（B36）
    output logic            st_d_req_valid_o,
    input  logic            st_d_req_ready_i,
    input  logic            st_d_done_i,

    // CSR 与 trap
    output logic            csr_req_valid_o,
    output csr_req_t        csr_req_o,
    input  csr_resp_t       csr_resp_i,
    input  logic            irq_take_i,          // csr_file 按正式中断条件给出（含委托/全局使能）
    output trap_req_t       trap_req_o,
    input  logic            trap_redirect_valid_i,
    input  vaddr_t          trap_redirect_pc_i,

    // LR/SC reservation 清除（trap 入口 / 合法 xRET / SFENCE.VMA / satp 切换）
    output logic            rsv_clear_valid_o,
    output rsv_clear_e      rsv_clear_reason_o,

    // WFI 与 fatal
    output logic            wfi_retire_o,
    input  logic            wfi_stall_i,
    input  logic            isolate_i,

    output logic            flush_all_o,         // 提交端整体清空（异常/xRET/同步重启）
    output be_perf_t        perf_o
);
    // 未实现。
endmodule
