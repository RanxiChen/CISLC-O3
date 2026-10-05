/**
 * Backend Top —— 后端总装（2026-10-02 框架）
 *
 * 目标数据流（后端基线 B01～B15、B21；前端第 16 节）：
 *
 *   前端交付（每拍 ≤4，fetch_entry_t：PC/长度/动态 FTQ 身份/槽位）
 *     → Decode（decoder ×4）→ Decode Queue（uop_queue）
 *     → R1 依赖预处理（rename_dep_r1）→ 级间暂存（rename_stage_buffer）
 *     → R2 原子 rename（rename_stage：INT/FP RAT、两域 free list、ROB、LQ/SQ、checkpoint、RDQ）
 *     → Rename/Dispatch Queue → Dispatch → IQ（INT / MEM / BR / M FU 归属待定 / FP 组织待定）
 *     → prf_read_arbiter（INT 域；FP 域读口待定）
 *     → 执行：alu_pipe ×N、branch_unit、mul/div_execute_unit、LSU（DTLB/LQ/SQ/DCache）、
 *             fpu_fma_fu ×2、fpu_divsqrt_fu、fpu_misc_fu、fpu_conv_fu
 *     → 写回：writeback_arbiter（INT 域）、fp_writeback_arbiter（FP 域）
 *     → ROB 按序提交 → commit_ctrl（FTQ 回收、SQ committed、fflags、系统同步、sys_redirect）
 *     → csr_file / trap_ctrl（CSR、精确异常入口、xRET、特权切换、中断：未设计）
 *   共享：ptw（ITLB+DTLB，经 DCache 物理入口）；dcache ↔ L2（在 o3_core）；SD DMA 经 L2 探测 L1D。
 *
 * 当前实现状态：闭环简化（L3）
 * - B42：4 宽 Decode/Rename/Dispatch/Commit，16 项 Decode Queue。
 * - INT/MEM/BR IQ → PRF → ALU/BRU/LSU → ROB；SQ/DCache/L2 真实路径保留。
 * - U3 ROB 退休直接通知 FTQ；U4 M/Bare/PMP 静态常量集中在本模块末尾。
 * - 不在本级的空壳实例已移除；R1/R2 按综合时序触发；M/FP/系统见后续阶梯。
 * - 缺口 1：只有误预测 M 阻塞 Decode/rename/dispatch/读口/退休；正确解析 C 正常推进并清 mask。
 * - 缺口 2：ALU 独立 RegRead kill 已存在，具名/随机测试待本任务补齐。
 * - exec_resolve_o 已由 BRU 驱动，解析与 JAL 链接结果写回解耦。
 * - 异常队头仍停住，无精确 trap（L5）；JALR/RVC、完整地址边界后续补齐。
 * - 测试：sim/cocotb/backend/、sim/o3/。
 *
 * 主流程已定、RTL 未实现（2026-10-02 框架接线见文件末尾）：B22～B27 串行/屏障/trap/xRET，
 * B31 非对齐，B32～B41（load 依赖等待、提前唤醒与完成 FIFO、MULH+MUL 融合、LR/SC reservation、
 * 硬件 A/D、committed_next_pc、WFI、fatal 隔离、FP 状态退休、L2 inclusive 回收）。
 * 系统同步由 commit_ctrl 统一编排（FENCE.I 数据侧 clean 由 commit_ctrl 发起，前端不再发起）。
 * 未设计（不能当作已定接口）：CSR 集合细节；各同步握手的信号编码与拍数；后端恢复与前端 D24
 * 赢家的取消边界归属；系统 committed 预测上下文来源。
 *
 * 逐周期说明（旧数据流，保持原文件描述）：
 * - 周期 N 开始：fetch_entry_q 保存上一拍接住的 fetch 组；Decode Queue 展示最老 uop；
 *   三个 IQ 保存待发射 uop；preg_ready 表、ROB、RegRead/Result 槽保存当前状态。
 * - 周期 N 组合：decoder 产生语义；rename 规划最老可行前缀；Dispatch 计算前缀；IQ 给出候选；
 *   prf_read_arbiter 按 ROB 年龄分配读口；ALU/BRU/LSU 组合执行；写回仲裁选出 grant；
 *   ROB 计算退休前缀。
 * - 周期 N 上升沿：各队列与表按握手原子更新；grant 结果写 PRF、置 ready、complete ROB；
 *   退休指令归还 old_dst_preg；fetch_fire 时接收新 fetch 组。
 * - 周期 N+1：可见新的队列、ready、ROB 与日志状态。
 *
 */

`ifdef O3_SIM
`include "dpi_functions.svh"
`endif
module backend
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    // 旧代码使用的名字，全部由 CFG 推导
    localparam int DECODE_WIDTH = CFG.decode.width,
    localparam int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,      // 现有 rename/ROB 分配 lane 数
    localparam int RETIRE_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    localparam int NUM_PHYS_REGS = CFG.rename.int_phys_regs,
    localparam int NUM_ARCH_REGS = o3_isa_pkg::NUM_ARCH_REGS,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int DECODE_QUEUE_DEPTH = CFG.decode.queue_depth,
    localparam int DISPATCH_WIDTH = CFG.dispatch.width,
    localparam int INT_ISSUE_QUEUE_DEPTH = CFG.dispatch.int_iq_depth,
    localparam int MEM_ISSUE_QUEUE_DEPTH = CFG.dispatch.mem_iq_depth,
    localparam int BRANCH_ISSUE_QUEUE_DEPTH = CFG.dispatch.br_iq_depth,
    localparam int NUM_INT_ALUS = CFG.exec.num_alu,
    localparam int NUM_BRANCH_CHECKPOINTS = CFG.rename.checkpoints,
    localparam int LOAD_QUEUE_DEPTH = CFG.lsu.lq_depth,
    localparam int STORE_QUEUE_DEPTH = CFG.lsu.sq_depth,
    localparam int RENAME_DISPATCH_QUEUE_DEPTH = CFG.rename.rdq_depth,
    localparam int AGU_PIPES = CFG.lsu.agu_pipes
)
(
    input  logic clk,
    input  logic rst,
    input  o3_types_pkg::vaddr_t             boot_pc_i,            // committed_next_pc 复位值（B37）

    // ---------------- 前端交付（前端 16.2 节） ----------------
    input  o3_types_pkg::fetch_entry_t [DECODE_WIDTH-1:0] fetch_entry_i,
    input  logic                             fetch_valid_i,
    output logic                             fetch_ready_o,

    // ---------------- 送前端 ----------------
    output o3_types_pkg::bru_resolve_t       exec_resolve_o,       // BRU one-shot 解析（B12）
    output o3_types_pkg::sys_redirect_t      sys_redirect_o,       // L3 tie-off；L5 由 commit_ctrl 驱动
    output o3_types_pkg::ftq_commit_t        ftq_commit_o [RETIRE_WIDTH],
    input  o3_types_pkg::redirect_req_t      fe_redirect_i,        // 前端 D24 赢家观测口（归属未设计）
    output logic                             fe_sync_valid_o,
    input  logic                             fe_sync_ready_i,
    output o3_types_pkg::fe_sync_req_t       fe_sync_o,
    input  logic                             fe_sync_done_i,
    output logic                             ptw_idle_o,
    output o3_types_pkg::fe_csr_t            fe_csr_o,
    output o3_types_pkg::pmp_state_t         fe_pmp_o,

    // ---------------- 前端 ITLB → 共享 PTW（B07） ----------------
    input  logic                             itlb_ptw_req_valid_i,
    output logic                             itlb_ptw_req_ready_o,
    input  o3_types_pkg::ptw_req_t           itlb_ptw_req_i,
    output o3_types_pkg::ptw_resp_t          itlb_ptw_resp_o,

    // ---------------- L1D ↔ L2（L2 在 o3_core） ----------------
    output logic                             l2_req_valid_o,
    input  logic                             l2_req_ready_i,
    output o3_types_pkg::l2_req_t            l2_req_o,
    input  o3_types_pkg::l2_resp_t           l2_resp_i,
    output logic                             l2_resp_ready_o,
    output logic                             l2_wb_valid_o,
    input  logic                             l2_wb_ready_i,
    output o3_types_pkg::paddr_t             l2_wb_line_paddr_o,
    output logic [o3_types_pkg::DC_LINE_BYTES*8-1:0] l2_wb_data_o,
    input  logic                             l2_wb_error_i,        // B39
    input  logic                             l1d_probe_valid_i,    // DMA 行协调（B08）+ L2 回收（B41）
    output logic                             l1d_probe_ready_o,
    input  o3_types_pkg::dc_probe_req_t      l1d_probe_i,
    output o3_types_pkg::dc_probe_resp_t     l1d_probe_resp_o,

    // ---------------- 中断（B26/B29：进入 csr_file 的 mip；WFI 唤醒见 B38） ----------------
    input  logic                             irq_m_ext_i,
    input  logic                             irq_m_timer_i,
    input  logic                             irq_m_soft_i,
    input  logic                             irq_s_ext_i,

    // ---------------- fatal（B39） ----------------
    input  o3_types_pkg::fatal_evt_t         l2_fatal_i,           // L2 写回 DDR 失败
    output logic                             fatal_o,

    // ---------------- DTCM 装载（现状沿用，基线未设计） ----------------
    input  logic                             dtcm_init_valid_i,
    input  logic [XLEN-1:0]                  dtcm_init_addr_i,
    input  logic [XLEN-1:0]                  dtcm_init_wdata_i,
    input  logic [7:0]                       dtcm_init_wmask_i,

    // ---------------- 观测 ----------------
    input  logic                             perf_rd_valid_i,
    input  logic [$clog2(o3_types_pkg::BE_PERF_NUM)-1:0] perf_rd_idx_i,
    output logic [CFG.perf.counter_bits-1:0] perf_rd_data_o,
    input  logic                             perf_clear_i,
    input  logic                             perf_snapshot_i,
    output logic                             done,
    output logic [63:0]                      retired_inst_count_o
`ifdef ENABLE_RETIRE_INFO
    ,output retire_info_t                    retire_info_o [RETIRE_WIDTH-1:0]
`endif
`ifdef O3_SIM_SINGLE_INST_TRACE
    ,output logic                            single_inst_retired_o
`endif
);

    localparam int BACKEND_PREG_IDX_WIDTH = PREG_IDX_WIDTH;   // 两域共用 preg 字段宽度（o3_types_pkg::PREG_W）
    localparam int BACKEND_ROB_IDX_WIDTH  = $clog2(NUM_ROB_ENTRIES);
    localparam int BACKEND_LANE_COUNT_WIDTH = $clog2(MACHINE_WIDTH + 1);
    localparam int BACKEND_ROB_COUNT_WIDTH = $clog2(NUM_ROB_ENTRIES + 1);
    localparam int BACKEND_PREG_COUNT_WIDTH = $clog2(NUM_PHYS_REGS + 1);
    localparam int BACKEND_LQ_IDX_WIDTH = $clog2(LOAD_QUEUE_DEPTH);
    localparam int BACKEND_SQ_IDX_WIDTH = $clog2(STORE_QUEUE_DEPTH);
    localparam int INST_ID_LANE_BITS      = (DECODE_WIDTH <= 1) ? 1 : $clog2(DECODE_WIDTH);
    localparam int PRF_READ_PORTS         = CFG.exec.int_prf_read_ports;
    localparam int PRF_WRITE_PORTS        = CFG.exec.int_prf_write_ports;

    o3_types_pkg::fetch_entry_t [DECODE_WIDTH-1:0] fetch_entry_q;
    logic                             fetch_entry_valid_q;
    logic [INST_ID_WIDTH-1:0]         fetch_instruction_id_q [DECODE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]         fetch_instruction_id_d [DECODE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]         fetch_group_seq_q;

    decode_in_t    [DECODE_WIDTH-1:0] decode_in;
    decode_out_t   [DECODE_WIDTH-1:0] decode_out;
    decoded_uop_t  [DECODE_WIDTH-1:0] decoded_uop;
    o3_types_pkg::uop_ext_t decoded_ext [DECODE_WIDTH-1:0];  // decoder ext + FTQ 槽位
    decoded_uop_t  [MACHINE_WIDTH-1:0] rename_uop_head;
    renamed_uop_t  [MACHINE_WIDTH-1:0] renamed_uop;
    renamed_uop_t  [DISPATCH_WIDTH-1:0] dispatch_uop_head;

    logic decode_valid;
    logic decode_ready;
    logic decode_fire;
    logic rename_valid;
    logic rename_ready;
    logic rename_fire;
    logic alloc_valid;
    logic rob_valid;
    logic uopq_enq_ready;
    logic [BACKEND_LANE_COUNT_WIDTH-1:0] uopq_deq_count;
    logic [BACKEND_LANE_COUNT_WIDTH-1:0] uopq_deq_accept_count;
    logic fetch_fire;
    logic alloc_req [MACHINE_WIDTH-1:0];
    logic rob_req   [MACHINE_WIDTH-1:0];
    logic lq_alloc_req [MACHINE_WIDTH-1:0];
    logic sq_alloc_req [MACHINE_WIDTH-1:0];
    logic checkpoint_create [MACHINE_WIDTH-1:0];
    logic checkpoint_req [MACHINE_WIDTH-1:0];
    logic checkpoint_grant [MACHINE_WIDTH-1:0];
    branch_tag_t checkpoint_tag [MACHINE_WIDTH-1:0];
    branch_mask_t rename_branch_mask [MACHINE_WIDTH-1:0];
    branch_mask_t active_branch_mask;
    logic branch_mispredict;
    assign branch_mispredict = branch_resolution_i.valid && branch_resolution_i.mispredict;
    logic rob_exception [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rs1_addr    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rs2_addr    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rd_addr     [MACHINE_WIDTH-1:0];
    logic                      rename_lane_valid  [MACHINE_WIDTH-1:0];
    logic                      rename_rs1_read_en [MACHINE_WIDTH-1:0];
    logic                      rename_rs2_read_en [MACHINE_WIDTH-1:0];
    logic                      rename_rd_write_en [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]  rob_alloc_instruction_id [MACHINE_WIDTH-1:0];
    o3_types_pkg::ftq_id_t      rob_alloc_ftq_idx [MACHINE_WIDTH-1:0];
    o3_types_pkg::fetch_slot_t rob_alloc_ftq_slot [MACHINE_WIDTH-1:0];
    logic                       rob_alloc_ftq_last [MACHINE_WIDTH-1:0];
`ifdef ENABLE_RETIRE_INFO
    logic [PC_WIDTH-1:0]       rob_alloc_pc          [MACHINE_WIDTH-1:0];
    logic [ILEN-1:0]           rob_alloc_instruction [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rob_alloc_rd          [MACHINE_WIDTH-1:0];
    logic                      rob_alloc_rd_write_en [MACHINE_WIDTH-1:0];
    logic [XLEN-1:0]           rob_complete_rd_wdata [NUM_INT_ALUS+2:0];
`endif

    logic [BACKEND_PREG_IDX_WIDTH-1:0] dst_new_preg [MACHINE_WIDTH-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_idx      [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] src1_preg    [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] src2_preg    [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] dst_old_preg [MACHINE_WIDTH-1:0];
    logic                              src1_from_older_lane [MACHINE_WIDTH-1:0];
    logic                              src2_from_older_lane [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_COUNT_WIDTH-1:0] free_preg_count;
    logic [BACKEND_ROB_COUNT_WIDTH-1:0] rob_free_count;
    logic [BACKEND_ROB_IDX_WIDTH-1:0] rob_tail;
    logic [BACKEND_ROB_IDX_WIDTH-1:0] rob_head;
    logic [$clog2(LOAD_QUEUE_DEPTH+1)-1:0] lq_free_count;
    logic [$clog2(STORE_QUEUE_DEPTH+1)-1:0] sq_free_count;
    logic [$clog2(RENAME_DISPATCH_QUEUE_DEPTH+1)-1:0] rdq_free_count;
    logic [BACKEND_LQ_IDX_WIDTH-1:0] lq_tail;
    logic [BACKEND_SQ_IDX_WIDTH-1:0] sq_tail;
    logic [BACKEND_LQ_IDX_WIDTH-1:0] lq_idx [MACHINE_WIDTH-1:0];
    logic [BACKEND_SQ_IDX_WIDTH-1:0] sq_idx [MACHINE_WIDTH-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0] checkpoint_rob_tail [MACHINE_WIDTH-1:0];
    logic [BACKEND_LQ_IDX_WIDTH-1:0] checkpoint_lq_tail [MACHINE_WIDTH-1:0];
    logic [BACKEND_SQ_IDX_WIDTH-1:0] checkpoint_sq_tail [MACHINE_WIDTH-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0] restore_rob_tail;
    logic [BACKEND_LQ_IDX_WIDTH-1:0] restore_lq_tail;
    logic [BACKEND_SQ_IDX_WIDTH-1:0] restore_sq_tail;
    logic [BACKEND_LANE_COUNT_WIDTH-1:0] rename_accept_count;
    logic [$clog2(DISPATCH_WIDTH+1)-1:0] dispatch_count;
    logic [$clog2(DISPATCH_WIDTH+1)-1:0] dispatch_accept_count;
    logic dispatch_int_lane [DISPATCH_WIDTH-1:0];
    logic dispatch_mem_lane [DISPATCH_WIDTH-1:0];
    logic dispatch_br_lane [DISPATCH_WIDTH-1:0];
    renamed_uop_t [DISPATCH_WIDTH-1:0] int_iq_enq_uop;
    renamed_uop_t [DISPATCH_WIDTH-1:0] mem_iq_enq_uop;
    renamed_uop_t [DISPATCH_WIDTH-1:0] br_iq_enq_uop;
    logic [$clog2(INT_ISSUE_QUEUE_DEPTH+1)-1:0] int_iq_free_count;
    logic [$clog2(MEM_ISSUE_QUEUE_DEPTH+1)-1:0] mem_iq_free_count;
    logic [$clog2(BRANCH_ISSUE_QUEUE_DEPTH+1)-1:0] br_iq_free_count;
    renamed_uop_t [NUM_INT_ALUS-1:0] int_iq_issue_uop;
    logic [NUM_INT_ALUS-1:0] int_iq_issue_valid;
    logic [NUM_INT_ALUS-1:0] int_iq_issue_ready;
    renamed_uop_t [0:0] mem_iq_issue_uop;
    logic [0:0] mem_iq_issue_valid;
    logic [0:0] mem_iq_issue_ready;
    renamed_uop_t [0:0] br_iq_issue_uop;
    logic [0:0] br_iq_issue_valid;
    logic [0:0] br_iq_issue_ready;

    issue_queue_entry_t [NUM_INT_ALUS-1:0] issueq_issue_entry;
    logic               [NUM_INT_ALUS-1:0] issueq_issue_valid;
    logic               [NUM_INT_ALUS-1:0] issueq_issue_ready;
    issue_queue_entry_t [INT_ISSUE_QUEUE_DEPTH-1:0] issueq_wakeup_entry;
    logic               [INT_ISSUE_QUEUE_DEPTH-1:0] issueq_wakeup_valid;

    int_issue_pipe_uop_t    alu_issue_q   [NUM_INT_ALUS-1:0];
    int_regread_pipe_uop_t  alu_regread_q [NUM_INT_ALUS-1:0];
    int_execute_result_t    alu_result_q  [NUM_INT_ALUS-1:0];
    mem_execute_uop_t       mem_execute_q;
    load_result_t           load_result;
    // branch_regread_q 已迁入 branch_unit
    branch_result_t         branch_execute_result;
    branch_result_t         branch_result_q;
    // branch_regread_q / branch_resolution_sent_q 已迁入 branch_unit
    branch_resolution_t     branch_resolution_i;

    logic alu_result_consume [NUM_INT_ALUS-1:0];
    logic load_result_consume;
    logic branch_result_consume;
    // branch_execute_ready 已迁入 branch_unit
    logic branch_regread_ready;
    logic alu_regread_ready [NUM_INT_ALUS-1:0];
    logic [NUM_INT_ALUS-1:0] int_read_grant;
    logic mem_read_grant;
    logic branch_read_grant;
    logic [$clog2(PRF_READ_PORTS)-1:0] int_src1_port [NUM_INT_ALUS-1:0];
    logic [$clog2(PRF_READ_PORTS)-1:0] int_src2_port [NUM_INT_ALUS-1:0];
    logic [$clog2(PRF_READ_PORTS)-1:0] mem_src1_port, mem_src2_port;
    logic [$clog2(PRF_READ_PORTS)-1:0] branch_src1_port, branch_src2_port;

    logic [BACKEND_PREG_IDX_WIDTH-1:0] prf_rd_addr [PRF_READ_PORTS-1:0];
    logic [XLEN-1:0]                   prf_rd_data [PRF_READ_PORTS-1:0];
    logic                              prf_wr_en   [PRF_WRITE_PORTS-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] prf_wr_addr [PRF_WRITE_PORTS-1:0];
    logic [XLEN-1:0]                   prf_wr_data [PRF_WRITE_PORTS-1:0];

    // exec_valid/exec_cmp_true 已迁入 alu_pipe
    logic [XLEN-1:0]                   exec_result  [NUM_INT_ALUS-1:0];
    logic                              preg_ready_q [NUM_PHYS_REGS-1:0];  // preg_ready_table 输出
    logic                              rob_complete_valid [NUM_INT_ALUS+2:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_complete_idx   [NUM_INT_ALUS+2:0];
    logic                              wb_complete_valid [NUM_INT_ALUS+1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  wb_complete_idx [NUM_INT_ALUS+1:0];
    logic [XLEN-1:0]                   wb_complete_data [NUM_INT_ALUS+1:0];
    logic                              rob_retire_valid   [RETIRE_WIDTH-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_retire_idx     [RETIRE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] rob_retire_old_dst_preg [RETIRE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]          rob_retire_instruction_id [RETIRE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] rob_retire_new_dst_preg [RETIRE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rob_retire_rd [RETIRE_WIDTH-1:0];
    logic rob_retire_rd_write_en [RETIRE_WIDTH-1:0];
    logic rob_retire_is_load [RETIRE_WIDTH-1:0];
    logic rob_retire_is_store [RETIRE_WIDTH-1:0];
    logic [LQ_IDX_WIDTH-1:0] rob_retire_lq_idx [RETIRE_WIDTH-1:0];
    logic [SQ_IDX_WIDTH-1:0] rob_retire_sq_idx [RETIRE_WIDTH-1:0];
    o3_types_pkg::ftq_id_t      rob_retire_ftq_idx [RETIRE_WIDTH-1:0];
    o3_types_pkg::fetch_slot_t rob_retire_ftq_slot [RETIRE_WIDTH-1:0];
    logic rob_retire_ftq_last [RETIRE_WIDTH-1:0];
    logic free_release_valid [RETIRE_WIDTH-1:0];
    logic [BACKEND_LANE_COUNT_WIDTH-1:0] lq_release_count;
    logic                              rob_retire_any;

    logic lq_execute_valid, lq_execute_generation, lq_request_fire;
    logic [BACKEND_LQ_IDX_WIDTH-1:0] lq_execute_idx, lq_request_idx;
    logic [XLEN-1:0] lq_execute_addr;
    logic lq_response_valid, lq_response_live;
    logic [BACKEND_LQ_IDX_WIDTH:0] lq_response_tag;
    logic sq_execute_valid;
    logic [BACKEND_SQ_IDX_WIDTH-1:0] sq_execute_idx;
    logic [XLEN-1:0] sq_execute_addr, sq_execute_data;
    logic [7:0] sq_execute_mask;
    logic sq_query_valid, sq_query_block, sq_query_forward_valid;
    logic [BACKEND_ROB_IDX_WIDTH-1:0] sq_query_rob_idx;
    logic [XLEN-1:0] sq_query_addr, sq_query_forward_data;
    logic [7:0] sq_query_mask;
    logic sq_drain_valid, sq_drain_ready;
    logic [XLEN-1:0] sq_drain_addr, sq_drain_data;
    logic [7:0] sq_drain_mask;
    logic sq_commit_valid [RETIRE_WIDTH-1:0];
    logic store_complete_valid;
    logic [BACKEND_ROB_IDX_WIDTH-1:0] store_complete_rob_idx;
    logic mem_execute_ready;
    logic mem_replay_busy, mem_replay_capture;

`ifdef O3_SIM
    logic [63:0] sim_cycle_q;
    logic [63:0] kanata_id_counter_q;
    logic [63:0] rob_kanata_id_q [NUM_ROB_ENTRIES-1:0];
    logic        kanata_header_printed_q;
    integer      kanata_fd;
    string       kanata_log_path;
`ifdef O3_SIM_SINGLE_INST_TRACE
    logic                              single_trace_active_q;
    logic                              single_trace_done_q;
    logic [INST_ID_WIDTH-1:0]          single_trace_id_q;
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  single_trace_rob_idx_q;
    logic [PC_WIDTH-1:0]              single_trace_pc_q;
    logic [ILEN-1:0]                  single_trace_inst_q;
    int                                single_trace_lane_q;
`endif
`endif
    logic [63:0] retired_inst_count_q;
    logic [63:0] retired_inst_count_next;
    logic [BACKEND_LANE_COUNT_WIDTH-1:0] retire_count_this_cycle;
    logic                              rename_alloc_valid [MACHINE_WIDTH-1:0];  // 送 preg_ready_table

    function automatic logic [INST_ID_WIDTH-1:0] make_instruction_id(
        input logic [INST_ID_WIDTH-1:0] fetch_group_seq,
        input int unsigned              lane_idx
    );
        logic [INST_ID_WIDTH-1:0] instruction_id;
        begin
            instruction_id      = (fetch_group_seq << INST_ID_LANE_BITS);
            instruction_id      = instruction_id | INST_ID_WIDTH'(lane_idx);
            make_instruction_id = instruction_id;
        end
    endfunction

    function automatic logic killed_by_resolution(input branch_mask_t mask);
        killed_by_resolution = br_killed(mask, branch_resolution_i);
    endfunction

    function automatic int unsigned rob_age(
        input logic [BACKEND_ROB_IDX_WIDTH-1:0] idx
    );
        rob_age = (int'(idx) + NUM_ROB_ENTRIES - int'(rob_head)) % NUM_ROB_ENTRIES;
    endfunction

    function automatic branch_mask_t resolved_branch_mask(input branch_mask_t mask);
        resolved_branch_mask = br_resolved_mask(mask, branch_resolution_i);
    endfunction


`ifdef O3_SIM
    function automatic string int_alu_op_name(input int_alu_op_t op);
        begin
            unique case (op)
                INT_ALU_OP_ADD:  int_alu_op_name = "ADD";
                INT_ALU_OP_SUB:  int_alu_op_name = "SUB";
                INT_ALU_OP_SLL:  int_alu_op_name = "SLL";
                INT_ALU_OP_SLT:  int_alu_op_name = "SLT";
                INT_ALU_OP_SLTU: int_alu_op_name = "SLTU";
                INT_ALU_OP_XOR:  int_alu_op_name = "XOR";
                INT_ALU_OP_SRL:  int_alu_op_name = "SRL";
                INT_ALU_OP_SRA:  int_alu_op_name = "SRA";
                INT_ALU_OP_OR:   int_alu_op_name = "OR";
                INT_ALU_OP_AND:  int_alu_op_name = "AND";
                default:         int_alu_op_name = "UNK";
            endcase
        end
    endfunction

    function automatic string imm_type_name(input imm_type_t imm_type);
        begin
            unique case (imm_type)
                IMM_TYPE_NONE: imm_type_name = "NONE";
                IMM_TYPE_I:    imm_type_name = "I";
                default:       imm_type_name = "UNK";
            endcase
        end
    endfunction
`endif
    assign decode_valid = fetch_entry_valid_q;

    genvar i;
    generate
        for (i = 0; i < DECODE_WIDTH; i++) begin : decode_input_assign
            assign decode_in[i].instruction = fetch_entry_q[i].instruction;
        end
    endgenerate

    generate
        for (i = 0; i < DECODE_WIDTH; i++) begin : decoder_array
            decoder u_decoder (
                .decode_i(decode_in[i]),
                .decode_o(decode_out[i])
            );
        end
    endgenerate

    generate
        for (i = 0; i < DECODE_WIDTH; i++) begin : decoded_uop_assign
            logic decoded_exception;

            assign decoded_exception = fetch_entry_q[i].exception_valid
                                     || decode_out[i].illegal_instruction;
            assign decoded_uop[i].valid          = decode_valid && fetch_entry_q[i].valid;
            assign decoded_uop[i].instruction_id = fetch_instruction_id_q[i];
`ifdef O3_SIM
            assign decoded_uop[i].kanata_id      = kanata_id_counter_q + 64'(i);
`endif
            assign decoded_uop[i].pc             = fetch_entry_q[i].pc;
            assign decoded_uop[i].raw_instruction = fetch_entry_q[i].raw_instruction;
            assign decoded_uop[i].instruction    = fetch_entry_q[i].instruction;
            assign decoded_uop[i].inst_len       = fetch_entry_q[i].inst_len;
            assign decoded_uop[i].is_rvc         = fetch_entry_q[i].is_rvc;
            assign decoded_uop[i].exception_valid = decoded_uop[i].valid
                                                  && decoded_exception;
            assign decoded_uop[i].exception_cause = fetch_entry_q[i].exception_valid
                                                   ? fetch_entry_q[i].exception_cause
                                                   : (decode_out[i].illegal_instruction
                                                      ? EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION
                                                      : '0);
            assign decoded_uop[i].exception_tval = fetch_entry_q[i].exception_valid
                                                  ? fetch_entry_q[i].exception_tval
                                                  : (decode_out[i].illegal_instruction
                                                     ? XLEN'(fetch_entry_q[i].raw_instruction)
                                                     : '0);
            assign decoded_uop[i].ftq_id         = fetch_entry_q[i].ftq_id;
            // 框架新增：ext 来自 decoder（当前未产生），FTQ 槽位来自前端交付。
            always_comb begin
                decoded_ext[i]          = decode_out[i].ext;
                decoded_ext[i].ftq_slot = fetch_entry_q[i].slot;
            end
            assign decoded_uop[i].ext            = decoded_ext[i];
            assign fetch_instruction_id_d[i]     = make_instruction_id(fetch_group_seq_q, i);
            assign decoded_uop[i].ftq_last       = fetch_entry_q[i].ftq_last;
            assign decoded_uop[i].predicted_next_pc = fetch_entry_q[i].predicted_next_pc;
            assign decoded_uop[i].rs1            = decode_out[i].rs1;
            assign decoded_uop[i].rs2            = decode_out[i].rs2;
            assign decoded_uop[i].rd             = decode_out[i].rd;
            assign decoded_uop[i].rs1_read_en    = !decoded_exception && decode_out[i].rs1_read_en;
            assign decoded_uop[i].rs2_read_en    = !decoded_exception && decode_out[i].rs2_read_en;
            assign decoded_uop[i].rd_write_en    = !decoded_exception && decode_out[i].rd_write_en;
            assign decoded_uop[i].src1_is_pc     = !decoded_exception && decode_out[i].src1_is_pc;
            assign decoded_uop[i].use_imm        = !decoded_exception && decode_out[i].use_imm;
            assign decoded_uop[i].imm_type       = decode_out[i].imm_type;
            assign decoded_uop[i].imm_raw        = decode_out[i].imm_raw;
            assign decoded_uop[i].int_alu_op     = decode_out[i].int_alu_op;
            assign decoded_uop[i].is_word_op     = !decoded_exception && decode_out[i].is_word_op;
            assign decoded_uop[i].is_int_uop     = !decoded_exception && decode_out[i].is_int_uop;
            assign decoded_uop[i].is_load        = !decoded_exception && decode_out[i].is_load;
            assign decoded_uop[i].is_store       = !decoded_exception && decode_out[i].is_store;
            assign decoded_uop[i].mem_size       = decode_out[i].mem_size;
            assign decoded_uop[i].mem_unsigned   = decode_out[i].mem_unsigned;
            assign decoded_uop[i].is_branch      = !decoded_exception && decode_out[i].is_branch;
            assign decoded_uop[i].is_jal         = !decoded_exception && decode_out[i].is_jal;
            assign decoded_uop[i].is_jalr        = !decoded_exception && decode_out[i].is_jalr;
            assign decoded_uop[i].branch_cond    = decode_out[i].branch_cond;
            assign decoded_uop[i].needs_checkpoint = !decoded_exception && decode_out[i].needs_checkpoint;
        end
    endgenerate

    generate
        for (i = 0; i < MACHINE_WIDTH; i++) begin : rename_req_assign
            assign rename_rs1_addr[i]        = rename_uop_head[i].rs1;
            assign rename_rs2_addr[i]        = rename_uop_head[i].rs2;
            assign rename_rd_addr[i]         = rename_uop_head[i].rd;
            assign rename_rs1_read_en[i]     = rename_uop_head[i].rs1_read_en;
            assign rename_rs2_read_en[i]     = rename_uop_head[i].rs2_read_en;
            assign rename_rd_write_en[i]     = rename_uop_head[i].rd_write_en;
            assign checkpoint_req[i]         = rename_uop_head[i].valid
                                               && rename_uop_head[i].needs_checkpoint;
            assign rob_exception[i] = renamed_uop[i].exception_valid;
            assign rename_alloc_valid[i] = rename_fire && rename_lane_valid[i]
                                         && rename_uop_head[i].rd_write_en
                                         && (rename_uop_head[i].rd != REG_ADDR_WIDTH'(0));
            assign rob_alloc_instruction_id[i] = rename_uop_head[i].instruction_id;
            assign rob_alloc_ftq_idx[i] = rename_uop_head[i].ftq_id;
            assign rob_alloc_ftq_slot[i] = rename_uop_head[i].ext.ftq_slot;
            assign rob_alloc_ftq_last[i] = rename_uop_head[i].ftq_last;
`ifdef ENABLE_RETIRE_INFO
            assign rob_alloc_pc[i]          = rename_uop_head[i].pc;
            assign rob_alloc_instruction[i] = rename_uop_head[i].instruction;
            assign rob_alloc_rd[i]          = rename_uop_head[i].rd;
            assign rob_alloc_rd_write_en[i] = renamed_uop[i].rd_write_en && (renamed_uop[i].rd != '0);
`endif

        end
    endgenerate

    // 接受前缀内部按类型并行分流。未被某类选中的lane以valid=0送入该IQ，
    // 各IQ在上升沿只压紧写入属于自己的uop。
    always_comb begin
        for (int lane = 0; lane < DISPATCH_WIDTH; lane++) begin
            int_iq_enq_uop[lane] = dispatch_uop_head[lane];
            mem_iq_enq_uop[lane] = dispatch_uop_head[lane];
            br_iq_enq_uop[lane] = dispatch_uop_head[lane];
            int_iq_enq_uop[lane].branch_mask = resolved_branch_mask(dispatch_uop_head[lane].branch_mask);
            int_iq_enq_uop[lane].valid = dispatch_int_lane[lane];
            mem_iq_enq_uop[lane].branch_mask = resolved_branch_mask(dispatch_uop_head[lane].branch_mask);
            mem_iq_enq_uop[lane].valid = dispatch_mem_lane[lane];
            br_iq_enq_uop[lane].branch_mask = resolved_branch_mask(dispatch_uop_head[lane].branch_mask);
            br_iq_enq_uop[lane].valid = dispatch_br_lane[lane];
        end
    end

    assign decode_ready    = uopq_enq_ready && !branch_mispredict;
    assign decode_fire     = decode_valid && decode_ready;
    assign fetch_ready_o   = !branch_mispredict
                           && ((!fetch_entry_valid_q) || decode_ready);
    assign fetch_fire      = fetch_valid_i && fetch_ready_o;
    assign rename_valid    = (uopq_deq_count != '0);
    assign rename_fire     = (rename_accept_count != '0);
    assign uopq_deq_accept_count = rename_accept_count;
    // branch_resolution_i 由 branch_unit 产生（旧合同，仍是后端恢复的驱动源）。
    assign done            = 1'b0;
    // Integer、Memory与Branch候选共享8个逻辑PRF读口；真正grant由年龄优先仲裁产生。
    assign issueq_issue_ready = int_read_grant;
    assign retired_inst_count_o = retired_inst_count_q;

    always_comb begin
        // 把通用Integer IQ候选转换成已有整数Issue Register使用的最小载荷。
        issueq_issue_entry = '{default: '0};
        issueq_issue_valid = int_iq_issue_valid & int_read_grant;
        issueq_wakeup_entry = '{default: '0};
        issueq_wakeup_valid = '0;
        for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
            issueq_issue_entry[alu].valid = int_iq_issue_valid[alu];
            issueq_issue_entry[alu].instruction_id = int_iq_issue_uop[alu].instruction_id;
`ifdef O3_SIM
            issueq_issue_entry[alu].kanata_id = int_iq_issue_uop[alu].kanata_id;
`endif
            issueq_issue_entry[alu].src1_preg = int_iq_issue_uop[alu].src1_preg;
            issueq_issue_entry[alu].src2_preg = int_iq_issue_uop[alu].src2_preg;
            issueq_issue_entry[alu].src1_valid = int_iq_issue_uop[alu].rs1_read_en;
            issueq_issue_entry[alu].src2_valid = int_iq_issue_uop[alu].rs2_read_en;
            issueq_issue_entry[alu].src1_ready = 1'b1;
            issueq_issue_entry[alu].src2_ready = 1'b1;
            issueq_issue_entry[alu].rob_idx = int_iq_issue_uop[alu].rob_idx;
            issueq_issue_entry[alu].dst_preg = int_iq_issue_uop[alu].dst_preg;
            issueq_issue_entry[alu].dst_write_en = int_iq_issue_uop[alu].rd_write_en
                                                    && (int_iq_issue_uop[alu].rd != '0);
            issueq_issue_entry[alu].imm_raw = int_iq_issue_uop[alu].imm_raw;
            issueq_issue_entry[alu].imm_valid = int_iq_issue_uop[alu].use_imm;
            issueq_issue_entry[alu].imm_type = int_iq_issue_uop[alu].imm_type;
            issueq_issue_entry[alu].int_alu_op = int_iq_issue_uop[alu].int_alu_op;
            issueq_issue_entry[alu].branch_mask = int_iq_issue_uop[alu].branch_mask;
        end
    end

    always_comb begin
        lq_release_count = '0;
        for (int port = 0; port < RETIRE_WIDTH; port++) begin
            sq_commit_valid[port] = rob_retire_valid[port] && rob_retire_is_store[port];
            free_release_valid[port] = rob_retire_valid[port]
                                    && rob_retire_rd_write_en[port]
                                    && (rob_retire_old_dst_preg[port] != '0);
            if (rob_retire_valid[port] && rob_retire_is_load[port]) begin
                lq_release_count = lq_release_count + BACKEND_LANE_COUNT_WIDTH'(1);
            end
        end
    end

    always_comb begin
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            int unsigned lq_before_or_self;
            int unsigned sq_before_or_self;
            lq_before_or_self = 0;
            sq_before_or_self = 0;
            for (int older_or_self = 0; older_or_self <= lane; older_or_self++) begin
                if (lq_alloc_req[older_or_self]) lq_before_or_self++;
                if (sq_alloc_req[older_or_self]) sq_before_or_self++;
            end
            checkpoint_rob_tail[lane] = BACKEND_ROB_IDX_WIDTH'((int'(rob_idx[lane]) + 1) % NUM_ROB_ENTRIES);
            checkpoint_lq_tail[lane] = BACKEND_LQ_IDX_WIDTH'((int'(lq_tail) + lq_before_or_self) % LOAD_QUEUE_DEPTH);
            checkpoint_sq_tail[lane] = BACKEND_SQ_IDX_WIDTH'((int'(sq_tail) + sq_before_or_self) % STORE_QUEUE_DEPTH);
        end
    end

`ifdef O3_SIM_SINGLE_INST_TRACE
    assign single_inst_retired_o = single_trace_done_q;
`endif

    // 读口仲裁（原样迁出到 prf_read_arbiter）。issue_block 仅为 M；C 保留正常年龄/读口仲裁。
    prf_read_arbiter #(.CFG(CFG)) u_prf_read_arbiter (
        .issue_block_i        (branch_mispredict),
        .rob_head_i           (rob_head),
        .int_issue_uop_i      (int_iq_issue_uop),
        .int_issue_valid_i    (int_iq_issue_valid),
        .alu_regread_ready_i  (alu_regread_ready),
        .mem_issue_uop_i      (mem_iq_issue_uop[0]),
        .mem_issue_valid_i    (mem_iq_issue_valid[0]),
        .mem_accept_i         (!mem_execute_q.valid || mem_execute_ready),
        .br_issue_uop_i       (br_iq_issue_uop[0]),
        .br_issue_valid_i     (br_iq_issue_valid[0]),
        .branch_regread_ready_i(branch_regread_ready),
        .int_read_grant_o     (int_read_grant),
        .mem_read_grant_o     (mem_read_grant),
        .branch_read_grant_o  (branch_read_grant),
        .int_src1_port_o      (int_src1_port),
        .int_src2_port_o      (int_src2_port),
        .mem_src1_port_o      (mem_src1_port),
        .mem_src2_port_o      (mem_src2_port),
        .branch_src1_port_o   (branch_src1_port),
        .branch_src2_port_o   (branch_src2_port),
        .prf_rd_addr_o        (prf_rd_addr)
    );
    always_comb begin
        int_iq_issue_ready = int_read_grant;
        mem_iq_issue_ready[0] = mem_read_grant;
        br_iq_issue_ready[0] = branch_read_grant;
    end


    always_comb begin
        rob_retire_any = 1'b0;
        for (int port = 0; port < RETIRE_WIDTH; port++) begin
            rob_retire_any |= rob_retire_valid[port];
        end
    end

    always_comb begin
        retire_count_this_cycle = '0;
        for (int port = 0; port < RETIRE_WIDTH; port++) begin
            if (rob_retire_valid[port]) begin
                retire_count_this_cycle = retire_count_this_cycle
                                        + BACKEND_LANE_COUNT_WIDTH'(1);
            end
        end

        retired_inst_count_next = retired_inst_count_q + 64'(retire_count_this_cycle);
    end

    uop_queue #(.CFG(CFG)) u_decode_queue (
        .clk(clk),
        .rst(rst),
        .flush_i(branch_resolution_i.valid && branch_resolution_i.mispredict),
        .enq_uop_i(decoded_uop),
        .enq_valid_i(decode_valid),
        .enq_ready_o(uopq_enq_ready),
        .deq_uop_o(rename_uop_head),
        .deq_count_o(uopq_deq_count),
        .deq_accept_count_i(uopq_deq_accept_count)
    );

    branch_checkpoint_file #(.CFG(CFG)) u_branch_checkpoint_file (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(checkpoint_req),
        .alloc_grant_o(checkpoint_grant),
        .alloc_tag_o(checkpoint_tag),
        .create_i(checkpoint_create),
        .create_parent_mask_i(rename_branch_mask),
        .create_rob_tail_i(checkpoint_rob_tail),
        .create_lq_tail_i(checkpoint_lq_tail),
        .create_sq_tail_i(checkpoint_sq_tail),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag),
        .active_mask_o(active_branch_mask),
        .restore_rob_tail_o(restore_rob_tail),
        .restore_lq_tail_o(restore_lq_tail),
        .restore_sq_tail_o(restore_sq_tail)
    );

    rename_stage #(.CFG(CFG)) u_rename_stage (
        .decoded_i(rename_uop_head),
        .visible_count_i(uopq_deq_count),
        .recovery_block_i(branch_mispredict),
        .preg_free_count_i(free_preg_count),
        .rob_free_count_i(rob_free_count),
        .lq_free_count_i(lq_free_count),
        .sq_free_count_i(sq_free_count),
        .rdq_free_count_i(rdq_free_count),
        .active_branch_mask_i(active_branch_mask),
        .checkpoint_grant_i(checkpoint_grant),
        .checkpoint_tag_i(checkpoint_tag),
        .src1_preg_i(src1_preg),
        .src2_preg_i(src2_preg),
        .old_dst_preg_i(dst_old_preg),
        .new_dst_preg_i(dst_new_preg),
        .rob_idx_i(rob_idx),
        .lq_idx_i(lq_idx),
        .sq_idx_i(sq_idx),
        .src1_from_older_lane_i(src1_from_older_lane),
        .src2_from_older_lane_i(src2_from_older_lane),
        .lane_accept_o(rename_lane_valid),
        .dst_alloc_req_o(alloc_req),
        .rob_alloc_req_o(rob_req),
        .lq_alloc_req_o(lq_alloc_req),
        .sq_alloc_req_o(sq_alloc_req),
        .checkpoint_create_o(checkpoint_create),
        .lane_branch_mask_o(rename_branch_mask),
        .accept_count_o(rename_accept_count),
        .renamed_uop_o(renamed_uop)
    );

    free_list #(.CFG(CFG), .DOMAIN(o3_types_pkg::RD_INT)) u_free_list (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(alloc_req),
        .alloc_fire_i(rename_fire),
        .alloc_available_o(alloc_valid),
        .alloc_preg_o(dst_new_preg),
        .free_count_o(free_preg_count),
        .release_valid_i(free_release_valid),
        .release_preg_i(rob_retire_old_dst_preg),
        .checkpoint_create_i(checkpoint_create),
        .checkpoint_create_tag_i(checkpoint_tag),
        .alloc_branch_mask_i(rename_branch_mask),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    rob #(.CFG(CFG), .COMPLETE_WIDTH(NUM_INT_ALUS + 3)) u_rob (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(rob_req),
        .alloc_exception_i(rob_exception),
        .alloc_old_dst_preg_i(dst_old_preg),
        .alloc_new_dst_preg_i(dst_new_preg),
        .alloc_rd_i(rename_rd_addr),
        .alloc_rd_write_en_i(alloc_req),
        .alloc_is_load_i(lq_alloc_req),
        .alloc_is_store_i(sq_alloc_req),
        .alloc_lq_idx_i(lq_idx),
        .alloc_sq_idx_i(sq_idx),
        .alloc_branch_mask_i(rename_branch_mask),
        .alloc_ftq_idx_i(rob_alloc_ftq_idx),
        .alloc_ftq_slot_i(rob_alloc_ftq_slot),
        .alloc_ftq_last_i(rob_alloc_ftq_last),
        .alloc_instruction_id_i(rob_alloc_instruction_id),
`ifdef ENABLE_RETIRE_INFO
        .alloc_pc_i(rob_alloc_pc),
        .alloc_instruction_i(rob_alloc_instruction),
`endif
        .alloc_ready_i(rename_fire),
        .complete_valid_i(rob_complete_valid),
        .complete_idx_i(rob_complete_idx),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag),
        .resolution_rob_idx_i(branch_resolution_i.branch_rob_idx),
        .resolution_completes_rob_i(branch_resolution_i.completes_rob),
        .restore_tail_i(restore_rob_tail),
`ifdef ENABLE_RETIRE_INFO
        .complete_rd_wdata_i(rob_complete_rd_wdata),
`endif
        .alloc_valid_o(rob_valid),
        .free_count_o(rob_free_count),
        .head_o(rob_head),
        .tail_o(rob_tail),
        .alloc_idx_o(rob_idx),
        .retire_valid_o(rob_retire_valid),
        .retire_idx_o(rob_retire_idx),
        .retire_old_dst_preg_o(rob_retire_old_dst_preg),
        .retire_new_dst_preg_o(rob_retire_new_dst_preg),
        .retire_rd_o(rob_retire_rd),
        .retire_rd_write_en_o(rob_retire_rd_write_en),
        .retire_is_load_o(rob_retire_is_load),
        .retire_is_store_o(rob_retire_is_store),
        .retire_lq_idx_o(rob_retire_lq_idx),
        .retire_sq_idx_o(rob_retire_sq_idx),
        .retire_instruction_id_o(rob_retire_instruction_id),
        .retire_ftq_idx_o(rob_retire_ftq_idx),
        .retire_ftq_slot_o(rob_retire_ftq_slot),
        .retire_ftq_last_o(rob_retire_ftq_last)
`ifdef ENABLE_RETIRE_INFO
        ,.retire_info_o(retire_info_o)
`endif
    );

    rename_map_table #(.CFG(CFG), .DOMAIN(o3_types_pkg::RD_INT)) u_rename_map_table (
        .clk(clk),
        .rst(rst),
        .rename_fire_i(rename_fire),
        .lane_valid_i(rename_lane_valid),
        .rs1_addr_i(rename_rs1_addr),
        .rs2_addr_i(rename_rs2_addr),
        .rd_addr_i(rename_rd_addr),
        .rs1_read_en_i(rename_rs1_read_en),
        .rs2_read_en_i(rename_rs2_read_en),
        .rd_write_en_i(rename_rd_write_en),
        .new_dst_preg_i(dst_new_preg),
        .checkpoint_create_i(checkpoint_create),
        .checkpoint_create_tag_i(checkpoint_tag),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag),
        .commit_valid_i(rob_retire_valid),
        .commit_rd_i(rob_retire_rd),
        .commit_rd_write_en_i(rob_retire_rd_write_en),
        .commit_new_preg_i(rob_retire_new_dst_preg),
        .src1_preg_o(src1_preg),
        .src2_preg_o(src2_preg),
        .old_dst_preg_o(dst_old_preg),
        .src1_from_older_lane_o(src1_from_older_lane),
        .src2_from_older_lane_o(src2_from_older_lane)
    );

    load_queue #(.CFG(CFG)) u_load_queue (
        .clk(clk), .rst(rst), .alloc_req_i(lq_alloc_req), .alloc_fire_i(rename_fire),
        .alloc_rob_idx_i(rob_idx), .alloc_branch_mask_i(rename_branch_mask),
        .alloc_idx_o(lq_idx), .free_count_o(lq_free_count), .tail_o(lq_tail),
        .execute_valid_i(lq_execute_valid), .execute_idx_i(lq_execute_idx),
        .execute_addr_i(lq_execute_addr), .execute_generation_o(lq_execute_generation),
        .request_fire_i(lq_request_fire), .request_idx_i(lq_request_idx),
        .response_valid_i(lq_response_valid), .response_tag_i(lq_response_tag),
        .response_live_o(lq_response_live),
        .release_count_i(lq_release_count),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag), .restore_tail_i(restore_lq_tail)
    );

    store_queue #(.CFG(CFG), .DCACHE_DRAIN(1'b1)) u_store_queue (
        .clk(clk), .rst(rst), .alloc_req_i(sq_alloc_req), .alloc_fire_i(rename_fire),
        .alloc_rob_idx_i(rob_idx), .alloc_branch_mask_i(rename_branch_mask),
        .alloc_idx_o(sq_idx), .free_count_o(sq_free_count), .tail_o(sq_tail),
        .execute_valid_i(sq_execute_valid), .execute_idx_i(sq_execute_idx),
        .execute_addr_i(sq_execute_addr), .execute_data_i(sq_execute_data),
        .execute_mask_i(sq_execute_mask),
        .commit_valid_i(sq_commit_valid), .commit_idx_i(rob_retire_sq_idx),
        .query_valid_i(sq_query_valid), .query_rob_idx_i(sq_query_rob_idx),
        .rob_head_i(rob_head), .query_addr_i(sq_query_addr), .query_mask_i(sq_query_mask),
        .query_block_o(sq_query_block), .query_forward_valid_o(sq_query_forward_valid),
        .query_forward_data_o(sq_query_forward_data),
        .drain_valid_o(sq_drain_valid), .drain_ready_i(sq_drain_ready),
        .drain_addr_o(sq_drain_addr), .drain_data_o(sq_drain_data),
        .drain_mask_o(sq_drain_mask),
        .t_dc_req_valid_o(t_sq_dc_req_valid), .t_dc_req_ready_i(t_sq_dc_req_ready),
        .t_dc_req_o(t_sq_dc_req), .t_dc_resp_i(t_sq_dc_resp),
        .t_committed_empty_o(t_sq_committed_empty),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag), .restore_tail_i(restore_sq_tail)
    );

    rename_dispatch_queue #(.CFG(CFG)) u_rename_dispatch_queue (
        .clk(clk), .rst(rst), .enq_uop_i(renamed_uop), .enq_count_i(rename_accept_count),
        .enq_fire_i(rename_fire), .free_count_o(rdq_free_count),
        .deq_uop_o(dispatch_uop_head), .deq_count_o(dispatch_count),
        .deq_accept_count_i(dispatch_accept_count),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    dispatch_stage #(.CFG(CFG)) u_dispatch_stage (
        .uop_i(dispatch_uop_head),
        .visible_count_i(dispatch_count),
        .recovery_block_i(branch_mispredict),
        .int_free_count_i(int_iq_free_count),
        .mem_free_count_i(mem_iq_free_count),
        .br_free_count_i(br_iq_free_count),
        .int_lane_o(dispatch_int_lane),
        .mem_lane_o(dispatch_mem_lane),
        .br_lane_o(dispatch_br_lane),
        .accept_count_o(dispatch_accept_count)
    );

    // L1 integer instructions must enter a live IQ after dispatch. These
    // candidates drive the existing PRF read arbiter and ALU pipelines.
    backend_issue_queue #(.CFG(CFG), .KIND(o3_types_pkg::IQ_INT)) u_int_issue_queue (
        .clk(clk), .rst(rst), .enq_uop_i(int_iq_enq_uop),
        .enq_fire_i(dispatch_accept_count != '0), .free_count_o(int_iq_free_count),
        .preg_ready_i(preg_ready_q), .allow_load_i(1'b1), .wakeup_valid_i(prf_wr_en),
        .wakeup_preg_i(prf_wr_addr), .issue_uop_o(int_iq_issue_uop),
        .issue_valid_o(int_iq_issue_valid), .issue_ready_i(int_iq_issue_ready),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    backend_issue_queue #(.CFG(CFG), .KIND(o3_types_pkg::IQ_MEM)) u_mem_issue_queue (
        .clk(clk), .rst(rst), .enq_uop_i(mem_iq_enq_uop),
        .enq_fire_i(dispatch_accept_count != '0), .free_count_o(mem_iq_free_count),
        .preg_ready_i(preg_ready_q),
        .allow_load_i(!mem_replay_busy && !mem_replay_capture),
        .wakeup_valid_i(prf_wr_en),
        .wakeup_preg_i(prf_wr_addr), .issue_uop_o(mem_iq_issue_uop),
        .issue_valid_o(mem_iq_issue_valid), .issue_ready_i(mem_iq_issue_ready),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    backend_issue_queue #(.CFG(CFG), .KIND(o3_types_pkg::IQ_BR)) u_branch_issue_queue (
        .clk(clk), .rst(rst), .enq_uop_i(br_iq_enq_uop),
        .enq_fire_i(dispatch_accept_count != '0), .free_count_o(br_iq_free_count),
        .preg_ready_i(preg_ready_q), .allow_load_i(1'b1), .wakeup_valid_i(prf_wr_en),
        .wakeup_preg_i(prf_wr_addr), .issue_uop_o(br_iq_issue_uop),
        .issue_valid_o(br_iq_issue_valid), .issue_ready_i(br_iq_issue_ready),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    // LSU拥有单发射Memory流水、LQ/SQ依赖查询后的统一memory请求以及可保持的Load结果。
    load_store_unit #(.CFG(CFG), .USE_DCACHE(1'b1)) u_load_store_unit (
        .clk(clk), .rst(rst), .mem_uop_i(mem_execute_q), .mem_ready_o(mem_execute_ready),
        .lq_execute_valid_o(lq_execute_valid), .lq_execute_idx_o(lq_execute_idx),
        .lq_execute_addr_o(lq_execute_addr), .lq_execute_generation_i(lq_execute_generation),
        .lq_request_fire_o(lq_request_fire), .lq_request_idx_o(lq_request_idx),
        .lq_response_valid_o(lq_response_valid), .lq_response_tag_o(lq_response_tag),
        .lq_response_live_i(lq_response_live),
        .sq_execute_valid_o(sq_execute_valid), .sq_execute_idx_o(sq_execute_idx),
        .sq_execute_addr_o(sq_execute_addr), .sq_execute_data_o(sq_execute_data),
        .sq_execute_mask_o(sq_execute_mask),
        .sq_query_valid_o(sq_query_valid), .sq_query_rob_idx_o(sq_query_rob_idx),
        .sq_query_addr_o(sq_query_addr), .sq_query_mask_o(sq_query_mask),
        .sq_query_block_i(sq_query_block), .sq_query_forward_valid_i(sq_query_forward_valid),
        .sq_query_forward_data_i(sq_query_forward_data),
        .sq_drain_valid_i(sq_drain_valid), .sq_drain_ready_o(sq_drain_ready),
        .sq_drain_addr_i(sq_drain_addr), .sq_drain_data_i(sq_drain_data),
        .sq_drain_mask_i(sq_drain_mask),
        .sq_change_i(sq_execute_valid || (sq_drain_valid && sq_drain_ready)
                   || t_sq_dc_resp.valid || branch_resolution_i.valid),
        .replay_busy_o(mem_replay_busy), .replay_capture_o(mem_replay_capture),
        .store_complete_valid_o(store_complete_valid),
        .store_complete_rob_idx_o(store_complete_rob_idx),
        .load_result_o(load_result), .load_result_ready_i(load_result_consume),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag),
        .dtcm_init_valid_i(dtcm_init_valid_i), .dtcm_init_addr_i(dtcm_init_addr_i),
        .dtcm_init_wdata_i(dtcm_init_wdata_i), .dtcm_init_wmask_i(dtcm_init_wmask_i),
        // 旧合同 ext_* 外部 memory 口不再连接（目标经 DCache/L2）。
        // 目标合同（t_*）：只连接共享 PTW，其余未接入。
        .t_ptw_req_valid_o(t_dtlb_ptw_req_valid), .t_ptw_req_ready_i(t_dtlb_ptw_req_ready),
        .t_ptw_req_o(t_dtlb_ptw_req), .t_ptw_resp_i(t_ptw_resp),
        .t_csr_i(t_dmmu_csr), .t_pmp_i(t_pmp), .t_sfence_i(t_sfence),
        .t_dc_ld_req_valid_o(t_dc_ld_req_valid), .t_dc_ld_req_ready_i(t_dc_ld_req_ready),
        .t_dc_ld_req_o(t_dc_ld_req), .t_dc_ld_resp_i(t_dc_ld_resp)
    );

    // 分支单元（原样迁出到 branch_unit；内部例化 branch_execute_unit）。
    branch_unit #(.CFG(CFG)) u_branch_unit (
        .clk(clk), .rst(rst),
        .issue_uop_i(br_iq_issue_uop[0]), .read_grant_i(branch_read_grant),
        .src1_data_i(prf_rd_data[branch_src1_port]), .src2_data_i(prf_rd_data[branch_src2_port]),
        .result_consume_i(branch_result_consume),
        .regread_ready_o(branch_regread_ready), .result_o(branch_result_q),
        .resolution_o(branch_resolution_i), .resolve_o(exec_resolve_o)
    );

    writeback_arbiter #(.CFG(CFG)) u_writeback_arbiter (
        .alu_result_i(alu_result_q), .load_result_i(load_result),
        .branch_result_i(branch_result_q), .rob_head_i(rob_head),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag),
        .alu_consume_o(alu_result_consume), .load_consume_o(load_result_consume),
        .branch_consume_o(branch_result_consume),
        .prf_wr_en_o(prf_wr_en), .prf_wr_addr_o(prf_wr_addr), .prf_wr_data_o(prf_wr_data),
        .complete_valid_o(wb_complete_valid), .complete_idx_o(wb_complete_idx),
        .complete_data_o(wb_complete_data),
        .extra_src_i(/* MUL/DIV/FP→INT/CSR/AMO：未接入 */), .extra_consume_o()
    );

    // ready 表（原样迁出到 preg_ready_table）。
    preg_ready_table #(.CFG(CFG), .DOMAIN(o3_types_pkg::RD_INT)) u_int_preg_ready_table (
        .clk(clk), .rst(rst),
        .alloc_valid_i(rename_alloc_valid), .alloc_preg_i(dst_new_preg),
        .wr_en_i(prf_wr_en), .wr_addr_i(prf_wr_addr),
        .ready_o(preg_ready_q)
    );

    always_comb begin
        for (int source = 0; source < NUM_INT_ALUS + 2; source++) begin
            rob_complete_valid[source] = wb_complete_valid[source];
            rob_complete_idx[source] = wb_complete_idx[source];
`ifdef ENABLE_RETIRE_INFO
            rob_complete_rd_wdata[source] = wb_complete_data[source];
`endif
        end
        rob_complete_valid[NUM_INT_ALUS+2] = store_complete_valid;
        rob_complete_idx[NUM_INT_ALUS+2] = store_complete_rob_idx;
`ifdef ENABLE_RETIRE_INFO
        rob_complete_rd_wdata[NUM_INT_ALUS+2] = '0;
`endif
    end

    physical_regfile #(.CFG(CFG), .DOMAIN(o3_types_pkg::RD_INT)) u_physical_regfile (
        .clk(clk),
        .rst(rst),
        .rd_addr_i(prf_rd_addr),
        .rd_data_o(prf_rd_data),
        .wr_en_i(prf_wr_en),
        .wr_addr_i(prf_wr_addr),
        .wr_data_i(prf_wr_data)
    );

    // ALU 管线（原样迁出到 alu_pipe，每个 ALU 一个实例）。B12 缺口 2 见 alu_pipe 注释。
    generate
        for (i = 0; i < NUM_INT_ALUS; i++) begin : alu_pipe_array
            alu_pipe #(.CFG(CFG)) u_alu_pipe (
                .clk(clk), .rst(rst),
                .issue_uop_i(int_iq_issue_uop[i]), .read_grant_i(int_read_grant[i]),
                .src1_data_i(prf_rd_data[int_src1_port[i]]),
                .src2_data_i(prf_rd_data[int_src2_port[i]]),
                .resolution_i(branch_resolution_i), .result_consume_i(alu_result_consume[i]),
                .regread_ready_o(alu_regread_ready[i]), .result_o(alu_result_q[i]),
                .obs_regread_o(alu_regread_q[i]), .obs_exec_result_o(exec_result[i])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            fetch_entry_q          <= '0;
            fetch_entry_valid_q    <= 1'b0;
            fetch_instruction_id_q <= '{default: '0};
            fetch_group_seq_q      <= '0;
            alu_issue_q            <= '{default: '0};
            mem_execute_q          <= '0;
            retired_inst_count_q   <= 64'd0;
`ifdef O3_SIM
            sim_cycle_q             <= 64'd0;
            kanata_id_counter_q     <= 64'd0;
            rob_kanata_id_q         <= '{default: '0};
            kanata_header_printed_q <= 1'b0;
            kanata_fd               <= 0;
            kanata_log_path         <= "";
`ifdef O3_SIM_SINGLE_INST_TRACE
            single_trace_active_q   <= 1'b0;
            single_trace_done_q     <= 1'b0;
            single_trace_id_q       <= '0;
            single_trace_rob_idx_q  <= '0;
            single_trace_pc_q       <= '0;
            single_trace_inst_q     <= '0;
            single_trace_lane_q     <= 0;
`endif
`endif
        end else begin
`ifdef O3_SIM
            // Backend 输入 bundle 采用 packed-lane 合同：lane0 最老，
            // 有效 lane 必须是连续前缀。如果上游在空洞之后再提供有效指令，
            // 立即报错，避免 Rename/ROB 年龄顺序在不可见的前提下工作。
            if (fetch_fire) begin
                bit saw_invalid_lane;
                saw_invalid_lane = 1'b0;
                for (int lane = 0; lane < DECODE_WIDTH; lane++) begin
                    if (!fetch_entry_i[lane].valid) begin
                        saw_invalid_lane = 1'b1;
                    end else if (saw_invalid_lane) begin
                        $fatal(1,
                               "[O3_SIM][backend] packed-lane violation: lane%0d is valid after an invalid lane",
                               lane);
                    end
                end
            end

`ifdef O3_SIM_KANATA
            if (!kanata_header_printed_q) begin
                integer fd_next;
                string  path_next;
                fd_next = kanata_fd;
                if (fd_next == 0) begin
`ifdef O3_SIM_KANATA_LOG_NAME
                    path_next = {`O3_SIM_KANATA_LOG_NAME, ".log"};
`else
                    path_next = "backend.log";
`endif
                    fd_next = $fopen(path_next, "w");
                    kanata_log_path <= path_next;
                    kanata_fd <= fd_next;
                    if (fd_next == 0) begin
                        $display("[O3_SIM][backend] Failed to open kanata log file: %s", path_next);
                    end
                end
                if (fd_next != 0) begin
                    $fdisplay(fd_next, "Kanata\t0004");
                    $fdisplay(fd_next, "C=\t%0d", sim_cycle_q);
                end
                kanata_header_printed_q <= 1'b1;
            end else begin
                if (kanata_fd != 0) begin
                    $fdisplay(kanata_fd, "C\t1");
                end
            end

            if (decode_fire && (kanata_fd != 0)) begin
                for (int lane = 0; lane < DECODE_WIDTH; lane++) begin
                    logic [63:0] kanata_id;
                    kanata_id = kanata_id_counter_q + 64'(lane);
                    $fdisplay(kanata_fd, "I\t%0d\t%0d\t0",
                              kanata_id,
                              fetch_instruction_id_q[lane]);
                    $fdisplay(kanata_fd, "L\t%0d\t0\t%0h: %s",
                              kanata_id,
                              fetch_entry_q[lane].pc,
                              dpi_backend_disasm_rv64i(fetch_entry_q[lane].instruction));
                    $fdisplay(kanata_fd, "S\t%0d\t%0d\tD",
                              kanata_id,
                              lane);
                    $fdisplay(kanata_fd, "L\t%0d\t1\tpc=0x%0h inst=0x%08h asm=%s",
                              kanata_id,
                              fetch_entry_q[lane].pc,
                              fetch_entry_q[lane].instruction,
                              dpi_backend_disasm_rv64i(fetch_entry_q[lane].instruction));
                end
            end

            if (rename_fire && (kanata_fd != 0)) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (rename_lane_valid[lane]) begin
                        $fdisplay(kanata_fd, "S\t%0d\t%0d\tR",
                                  rename_uop_head[lane].kanata_id,
                                  lane);
                        $fdisplay(kanata_fd, "L\t%0d\t1\trs1:x%0d->p%0d rs2:x%0d->p%0d rd:x%0d old:p%0d new:p%0d rob:%0d",
                                  rename_uop_head[lane].kanata_id,
                                  rename_uop_head[lane].rs1, src1_preg[lane],
                                  rename_uop_head[lane].rs2, src2_preg[lane],
                                  rename_uop_head[lane].rd, dst_old_preg[lane], dst_new_preg[lane],
                                  rob_idx[lane]);
                        if (rename_uop_head[lane].is_int_uop) begin
                            $fdisplay(kanata_fd, "S\t%0d\t%0d\tIQ",
                                      rename_uop_head[lane].kanata_id,
                                      lane);
                        end
                    end
                end
            end

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (issueq_issue_valid[alu] && (kanata_fd != 0)) begin
                    $fdisplay(kanata_fd, "S\t%0d\t%0d\tIS",
                              issueq_issue_entry[alu].kanata_id,
                              alu);
                    $fdisplay(kanata_fd, "L\t%0d\t1\tsrc1:p%0d src2:p%0d dst:p%0d rob:%0d op=%s",
                              issueq_issue_entry[alu].kanata_id,
                              issueq_issue_entry[alu].src1_preg,
                              issueq_issue_entry[alu].src2_preg,
                              issueq_issue_entry[alu].dst_preg,
                              issueq_issue_entry[alu].rob_idx,
                              int_alu_op_name(issueq_issue_entry[alu].int_alu_op));
                end
            end

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (alu_issue_q[alu].valid && (kanata_fd != 0)) begin
                    string src2_desc;
                    if (alu_issue_q[alu].imm_valid) begin
                        src2_desc = $sformatf("imm[%s]=0x%0h->0x%0h",
                                              imm_type_name(alu_issue_q[alu].imm_type),
                                              alu_issue_q[alu].imm_raw,
                                              expand_imm_value(alu_issue_q[alu].imm_type, alu_issue_q[alu].imm_raw));
                    end else if (alu_issue_q[alu].src2_valid) begin
                        src2_desc = $sformatf("p%0d=0x%0h",
                                              alu_issue_q[alu].src2_preg,
                                              prf_rd_data[(2*alu)+1]);
                    end else begin
                        src2_desc = "zero";
                    end
                    $fdisplay(kanata_fd, "S\t%0d\t%0d\tRR",
                              alu_issue_q[alu].kanata_id,
                              alu);
                    $fdisplay(kanata_fd, "L\t%0d\t1\tsrc1:p%0d=0x%0h src2:%s rob:%0d",
                              alu_issue_q[alu].kanata_id,
                              alu_issue_q[alu].src1_preg,
                              prf_rd_data[(2*alu)+0],
                              src2_desc,
                              alu_issue_q[alu].rob_idx);
                end
            end

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (alu_regread_q[alu].valid && (kanata_fd != 0)) begin
                    $fdisplay(kanata_fd, "S\t%0d\t%0d\tEX",
                              alu_regread_q[alu].kanata_id,
                              alu);
                    $fdisplay(kanata_fd, "L\t%0d\t1\top=%s src1=0x%0h src2=0x%0h result=0x%0h",
                              alu_regread_q[alu].kanata_id,
                              int_alu_op_name(alu_regread_q[alu].int_alu_op),
                              alu_regread_q[alu].src1_value,
                              alu_regread_q[alu].src2_value,
                              exec_result[alu]);
                end
            end

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (alu_result_q[alu].valid && (kanata_fd != 0)) begin
                    $fdisplay(kanata_fd, "S\t%0d\t%0d\tWB",
                              alu_result_q[alu].kanata_id,
                              alu);
                    $fdisplay(kanata_fd, "L\t%0d\t1\tdst:p%0d data=0x%0h rob:%0d dst_write=%0d",
                              alu_result_q[alu].kanata_id,
                              alu_result_q[alu].dst_preg,
                              alu_result_q[alu].result,
                              alu_result_q[alu].rob_idx,
                              alu_result_q[alu].dst_write_en);
                end
            end

            if (kanata_fd != 0) begin
                longint retire_id;
                retire_id = longint'(retired_inst_count_q);
                for (int port = 0; port < RETIRE_WIDTH; port++) begin
                    if (rob_retire_valid[port]) begin
                        $fdisplay(kanata_fd, "R\t%0d\t%0d\t0",
                                  rob_kanata_id_q[rob_retire_idx[port]],
                                  retire_id);
                        $fdisplay(kanata_fd, "L\t%0d\t1\tretire_id=%0d old:p%0d",
                                  rob_kanata_id_q[rob_retire_idx[port]],
                                  retire_id,
                                  rob_retire_old_dst_preg[port]);
                        retire_id = retire_id + 1;
                    end
                end
            end
`elsif O3_SIM_SINGLE_INST_TRACE
            if (!single_trace_active_q && !single_trace_done_q && fetch_fire) begin
                bit trace_found;
                int trace_lane;
                trace_found = 0;
                trace_lane  = 0;
                for (int lane = 0; lane < DECODE_WIDTH; lane++) begin
                    if (fetch_entry_i[lane].valid && !trace_found) begin
                        trace_found = 1;
                        trace_lane  = lane;
                    end
                end
                if (trace_found) begin
                    single_trace_active_q  <= 1'b1;
                    single_trace_id_q      <= fetch_instruction_id_d[trace_lane];
                    single_trace_pc_q      <= fetch_entry_i[trace_lane].pc;
                    single_trace_inst_q    <= fetch_entry_i[trace_lane].instruction;
                    single_trace_lane_q    <= trace_lane;
                    $display("[SINGLE][cycle=%0d] ACCEPT pc=0x%0h inst=0x%08h id=0x%0h",
                             sim_cycle_q,
                             fetch_entry_i[trace_lane].pc,
                             fetch_entry_i[trace_lane].instruction,
                             fetch_instruction_id_d[trace_lane]);
                end
            end

            if (single_trace_active_q) begin
                if (fetch_entry_valid_q
                 && fetch_entry_q[single_trace_lane_q].valid
                 && fetch_instruction_id_q[single_trace_lane_q] == single_trace_id_q) begin
                    $display("[SINGLE][cycle=%0d] DECODE pc=0x%0h inst=0x%08h id=0x%0h",
                             sim_cycle_q,
                             single_trace_pc_q,
                             single_trace_inst_q,
                             single_trace_id_q);
                end

                if (rename_fire
                 && rename_lane_valid[single_trace_lane_q]
                 && rename_uop_head[single_trace_lane_q].instruction_id == single_trace_id_q) begin
                    single_trace_rob_idx_q <= rob_idx[single_trace_lane_q];
                    $display("[SINGLE][cycle=%0d] RENAME id=0x%0h rd=x%0d old=p%0d new=p%0d rob=%0d",
                             sim_cycle_q,
                             single_trace_id_q,
                             rename_uop_head[single_trace_lane_q].rd,
                             dst_old_preg[single_trace_lane_q],
                             dst_new_preg[single_trace_lane_q],
                             rob_idx[single_trace_lane_q]);
                end

                for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                    if (issueq_issue_valid[alu]
                     && issueq_issue_entry[alu].instruction_id == single_trace_id_q) begin
                        string src2_str;
                        if (issueq_issue_entry[alu].imm_valid) begin
                            src2_str = $sformatf("imm(0x%0h)",
                                                  expand_imm_value(issueq_issue_entry[alu].imm_type,
                                                                   issueq_issue_entry[alu].imm_raw));
                        end else begin
                            src2_str = $sformatf("p%0d", issueq_issue_entry[alu].src2_preg);
                        end
                        $display("[SINGLE][cycle=%0d] ISSUE id=0x%0h alu=%0d src1=p%0d src2=%s dst=p%0d rob=%0d op=%s",
                                 sim_cycle_q,
                                 single_trace_id_q,
                                 alu,
                                 issueq_issue_entry[alu].src1_preg,
                                 src2_str,
                                 issueq_issue_entry[alu].dst_preg,
                                 issueq_issue_entry[alu].rob_idx,
                                 int_alu_op_name(issueq_issue_entry[alu].int_alu_op));
                    end
                end

                for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                    if (alu_issue_q[alu].valid
                     && alu_issue_q[alu].instruction_id == single_trace_id_q) begin
                        $display("[SINGLE][cycle=%0d] REGREAD id=0x%0h alu=%0d src1=0x%0h src2=0x%0h",
                                 sim_cycle_q,
                                 single_trace_id_q,
                                 alu,
                                 prf_rd_data[(2*alu)+0],
                                 alu_issue_q[alu].imm_valid
                                    ? expand_imm_value(alu_issue_q[alu].imm_type, alu_issue_q[alu].imm_raw)
                                    : (alu_issue_q[alu].src2_valid
                                        ? prf_rd_data[(2*alu)+1]
                                        : '0));
                    end
                end

                for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                    if (alu_regread_q[alu].valid
                     && alu_regread_q[alu].instruction_id == single_trace_id_q) begin
                        $display("[SINGLE][cycle=%0d] EXECUTE id=0x%0h alu=%0d op=%s result=0x%0h",
                                 sim_cycle_q,
                                 single_trace_id_q,
                                 alu,
                                 int_alu_op_name(alu_regread_q[alu].int_alu_op),
                                 exec_result[alu]);
                    end
                end

                for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                    if (alu_result_q[alu].valid
                     && alu_result_q[alu].instruction_id == single_trace_id_q) begin
                        $display("[SINGLE][cycle=%0d] WRITEBACK id=0x%0h dst=p%0d data=0x%0h rob=%0d",
                                 sim_cycle_q,
                                 single_trace_id_q,
                                 alu_result_q[alu].dst_preg,
                                 alu_result_q[alu].result,
                                 alu_result_q[alu].rob_idx);
                    end
                end

                for (int port = 0; port < RETIRE_WIDTH; port++) begin
                    if (rob_retire_valid[port]
                     && rob_retire_instruction_id[port] == single_trace_id_q) begin
                        single_trace_active_q <= 1'b0;
                        single_trace_done_q   <= 1'b1;
                        $display("[SINGLE][cycle=%0d] RETIRE id=0x%0h rob=%0d old=p%0d",
                                 sim_cycle_q,
                                 single_trace_id_q,
                                 rob_retire_idx[port],
                                 rob_retire_old_dst_preg[port]);
                    end
                end
            end
`else
            $display("[O3_SIM][backend][cycle=%0d] ----------------", sim_cycle_q);

            if (fetch_entry_valid_q) begin
                for (int lane = 0; lane < DECODE_WIDTH; lane++) begin
                    if (fetch_entry_q[lane].valid) begin
                        $display("[O3_SIM][backend][cycle=%0d] DECODE lane%0d id=0x%0h pc=0x%0h inst=0x%08h",
                                 sim_cycle_q,
                                 lane,
                                 fetch_instruction_id_q[lane],
                                 fetch_entry_q[lane].pc,
                                 fetch_entry_q[lane].instruction);
                    end else begin
                        $display("[O3_SIM][backend][cycle=%0d] DECODE lane%0d empty",
                                 sim_cycle_q,
                                 lane);
                    end
                end
            end else begin
                $display("[O3_SIM][backend][cycle=%0d] DECODE empty", sim_cycle_q);
            end

            if (rename_valid) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (rename_uop_head[lane].valid) begin
                        $display("[O3_SIM][backend][cycle=%0d] RENAME lane%0d id=0x%0h asm=%s src1:x%0d->p%0d src2:x%0d->p%0d rd:x%0d old:p%0d new:p%0d rob:%0d",
                                 sim_cycle_q,
                                 lane,
                                 rename_uop_head[lane].instruction_id,
                                 dpi_backend_disasm_rv64i(rename_uop_head[lane].instruction),
                                 rename_uop_head[lane].rs1, src1_preg[lane],
                                 rename_uop_head[lane].rs2, src2_preg[lane],
                                 rename_uop_head[lane].rd, dst_old_preg[lane], dst_new_preg[lane],
                                 rob_idx[lane]);
                    end else begin
                        $display("[O3_SIM][backend][cycle=%0d] RENAME lane%0d empty",
                                 sim_cycle_q,
                                 lane);
                    end
                end
            end else begin
                $display("[O3_SIM][backend][cycle=%0d] RENAME empty", sim_cycle_q);
            end

            if (|issueq_wakeup_valid) begin
                $write("[O3_SIM][backend][cycle=%0d] WAKEUP", sim_cycle_q);
                for (int idx = 0; idx < INT_ISSUE_QUEUE_DEPTH; idx++) begin
                    if (issueq_wakeup_valid[idx]) begin
                        $write(" id=0x%0h", issueq_wakeup_entry[idx].instruction_id);
                    end
                end
                $write("\n");
            end else begin
                $display("[O3_SIM][backend][cycle=%0d] WAKEUP empty", sim_cycle_q);
            end

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (issueq_issue_valid[alu]) begin
                    $display("[O3_SIM][backend][cycle=%0d] ISSUE alu%0d id=0x%0h src1:p%0d src2:p%0d dst:p%0d rob:%0d op=%s",
                             sim_cycle_q,
                             alu,
                             issueq_issue_entry[alu].instruction_id,
                             issueq_issue_entry[alu].src1_preg,
                             issueq_issue_entry[alu].src2_preg,
                             issueq_issue_entry[alu].dst_preg,
                             issueq_issue_entry[alu].rob_idx,
                             int_alu_op_name(issueq_issue_entry[alu].int_alu_op));
                end else begin
                    $display("[O3_SIM][backend][cycle=%0d] ISSUE alu%0d empty", sim_cycle_q, alu);
                end
            end

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (alu_issue_q[alu].valid) begin
                    $display("[O3_SIM][backend][cycle=%0d] REGREAD alu%0d id=0x%0h src1:p%0d->0x%0h src2:%s rob:%0d",
                             sim_cycle_q,
                             alu,
                             alu_issue_q[alu].instruction_id,
                             alu_issue_q[alu].src1_preg,
                             prf_rd_data[(2*alu)+0],
                             alu_issue_q[alu].imm_valid
                                ? $sformatf("imm[%s]=0x%0h -> 0x%0h",
                                            imm_type_name(alu_issue_q[alu].imm_type),
                                            alu_issue_q[alu].imm_raw,
                                            expand_imm_value(alu_issue_q[alu].imm_type, alu_issue_q[alu].imm_raw))
                                : (alu_issue_q[alu].src2_valid
                                    ? $sformatf("p%0d->0x%0h", alu_issue_q[alu].src2_preg, prf_rd_data[(2*alu)+1])
                                    : "zero"),
                             alu_issue_q[alu].rob_idx);
                end else begin
                    $display("[O3_SIM][backend][cycle=%0d] REGREAD alu%0d empty", sim_cycle_q, alu);
                end
            end

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (alu_regread_q[alu].valid) begin
                    $display("[O3_SIM][backend][cycle=%0d] EXECUTE alu%0d id=0x%0h op=%s src1=0x%0h src2=0x%0h result=0x%0h",
                             sim_cycle_q,
                             alu,
                             alu_regread_q[alu].instruction_id,
                             int_alu_op_name(alu_regread_q[alu].int_alu_op),
                             alu_regread_q[alu].src1_value,
                             alu_regread_q[alu].src2_value,
                             exec_result[alu]);
                end else begin
                    $display("[O3_SIM][backend][cycle=%0d] EXECUTE alu%0d empty", sim_cycle_q, alu);
                end
            end

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (alu_result_q[alu].valid) begin
                    $display("[O3_SIM][backend][cycle=%0d] WRITEBACK alu%0d id=0x%0h dst:p%0d data=0x%0h rob:%0d dst_write=%0d",
                             sim_cycle_q,
                             alu,
                             alu_result_q[alu].instruction_id,
                             alu_result_q[alu].dst_preg,
                             alu_result_q[alu].result,
                             alu_result_q[alu].rob_idx,
                             alu_result_q[alu].dst_write_en);
                end else begin
                    $display("[O3_SIM][backend][cycle=%0d] WRITEBACK alu%0d empty", sim_cycle_q, alu);
                end
            end

            if (rob_retire_any) begin
                $write("[O3_SIM][backend][cycle=%0d] RETIRE", sim_cycle_q);
                for (int port = 0; port < RETIRE_WIDTH; port++) begin
                    if (rob_retire_valid[port]) begin
                        $write(" id=0x%0h rob:%0d old:p%0d",
                               rob_retire_instruction_id[port],
                               rob_retire_idx[port],
                               rob_retire_old_dst_preg[port]);
                    end
                end
                $write("\n");
            end else begin
                $display("[O3_SIM][backend][cycle=%0d] RETIRE empty", sim_cycle_q);
            end

            $display("[O3_SIM][backend][cycle=%0d] RETIRE_COUNT inc=%0d total=%0d",
                     sim_cycle_q,
                     retire_count_this_cycle,
                     retired_inst_count_next);

            $display("[O3_SIM][backend][cycle=%0d] ----------------", sim_cycle_q);
`endif
`endif

            // preg ready 更新已迁入 preg_ready_table。

            // 退休计数器按本拍真正退休的 ROB 条数累加，用于后续性能观察和日志统计。
            retired_inst_count_q <= retired_inst_count_next;
`ifdef O3_SIM
            if (decode_fire) begin
                kanata_id_counter_q <= kanata_id_counter_q + 64'(DECODE_WIDTH);
            end
            if (rename_fire) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (rename_lane_valid[lane]) begin
                        rob_kanata_id_q[rob_idx[lane]] <= rename_uop_head[lane].kanata_id;
                    end
                end
            end
`endif

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                // RegRead/Result 槽更新已迁入 alu_pipe。
                // 保留Issue观察寄存器供现有调试日志使用；执行数据直接进入RegRead槽。
                alu_issue_q[alu].valid <= int_read_grant[alu];
                alu_issue_q[alu].instruction_id <= issueq_issue_entry[alu].instruction_id;
`ifdef O3_SIM
                alu_issue_q[alu].kanata_id <= issueq_issue_entry[alu].kanata_id;
`endif
                alu_issue_q[alu].src1_preg <= issueq_issue_entry[alu].src1_preg;
                alu_issue_q[alu].src2_preg <= issueq_issue_entry[alu].src2_preg;
                alu_issue_q[alu].src1_valid <= issueq_issue_entry[alu].src1_valid;
                alu_issue_q[alu].src2_valid <= issueq_issue_entry[alu].src2_valid;
                alu_issue_q[alu].rob_idx <= issueq_issue_entry[alu].rob_idx;
                alu_issue_q[alu].dst_preg <= issueq_issue_entry[alu].dst_preg;
                alu_issue_q[alu].dst_write_en <= issueq_issue_entry[alu].dst_write_en;
                alu_issue_q[alu].imm_raw <= issueq_issue_entry[alu].imm_raw;
                alu_issue_q[alu].imm_valid <= issueq_issue_entry[alu].imm_valid;
                alu_issue_q[alu].imm_type <= issueq_issue_entry[alu].imm_type;
                alu_issue_q[alu].int_alu_op <= issueq_issue_entry[alu].int_alu_op;
                alu_issue_q[alu].branch_mask <= resolved_branch_mask(issueq_issue_entry[alu].branch_mask);
            end

            // Branch RegRead/Result 槽更新已迁入 branch_unit。

            if (!mem_execute_q.valid || mem_execute_ready) begin
                mem_execute_q.valid <= mem_read_grant;
                mem_execute_q.instruction_id <= mem_iq_issue_uop[0].instruction_id;
`ifdef O3_SIM
                mem_execute_q.kanata_id <= mem_iq_issue_uop[0].kanata_id;
`endif
                mem_execute_q.rob_idx <= mem_iq_issue_uop[0].rob_idx;
                mem_execute_q.lq_idx <= mem_iq_issue_uop[0].lq_idx;
                mem_execute_q.sq_idx <= mem_iq_issue_uop[0].sq_idx;
                mem_execute_q.dst_preg <= mem_iq_issue_uop[0].dst_preg;
                mem_execute_q.dst_write_en <= mem_iq_issue_uop[0].rd_write_en
                                                && (mem_iq_issue_uop[0].rd != '0);
                mem_execute_q.is_load <= mem_iq_issue_uop[0].is_load;
                mem_execute_q.is_store <= mem_iq_issue_uop[0].is_store;
                mem_execute_q.mem_size <= mem_iq_issue_uop[0].mem_size;
                mem_execute_q.mem_unsigned <= mem_iq_issue_uop[0].mem_unsigned;
                mem_execute_q.base_value <= mem_iq_issue_uop[0].rs1_read_en
                                          ? prf_rd_data[mem_src1_port] : '0;
                mem_execute_q.store_value <= mem_iq_issue_uop[0].rs2_read_en
                                           ? prf_rd_data[mem_src2_port] : '0;
                mem_execute_q.imm_value <= expand_imm_value(
                    mem_iq_issue_uop[0].imm_type, mem_iq_issue_uop[0].imm_raw);
                mem_execute_q.branch_mask <= resolved_branch_mask(mem_iq_issue_uop[0].branch_mask);
            end else if (branch_resolution_i.valid) begin
                mem_execute_q.branch_mask <= resolved_branch_mask(mem_execute_q.branch_mask);
            end

            if (branch_resolution_i.valid && branch_resolution_i.mispredict) begin
                fetch_entry_valid_q <= 1'b0;
            end else if (fetch_fire) begin
                fetch_entry_q          <= fetch_entry_i;
                fetch_entry_valid_q    <= 1'b1;
                fetch_instruction_id_q <= fetch_instruction_id_d;
                fetch_group_seq_q      <= fetch_group_seq_q + INST_ID_WIDTH'(1);
            end else if (decode_fire) begin
                fetch_entry_valid_q <= 1'b0;
            end

`ifdef O3_SIM
            sim_cycle_q <= sim_cycle_q + 64'd1;
`endif
        end
    end

    // ---------------- 访存：DCache、共享 PTW、A/D 旁侧更新、预取（B03～B11、B31、B35、B36） ----------------
    // 总原则（2026-10-02）：常规 load/store 流水不变；A/D、LR/SC、DMA/回收探测、FENCE.I 维护都在旁侧。
    logic                       t_dtlb_ptw_req_valid, t_dtlb_ptw_req_ready;
    o3_types_pkg::ptw_req_t     t_dtlb_ptw_req;
    o3_types_pkg::ptw_resp_t    t_ptw_resp;
    logic                       t_ptw_mem_req_valid, t_ptw_mem_req_ready;
    o3_types_pkg::dcache_req_t  t_ptw_mem_req;
    o3_types_pkg::dcache_resp_t t_ptw_mem_resp;
    logic                       t_pf_req_valid, t_pf_req_ready;
    o3_types_pkg::dcache_req_t  t_pf_req;
    o3_types_pkg::dmmu_csr_t    t_dmmu_csr;
    o3_types_pkg::pmp_state_t   t_pmp;
    o3_types_pkg::sfence_req_t  t_sfence;
    logic                       t_dc_clean_all_req, t_dc_clean_all_done, t_dc_clean_all_busy;
    logic                       t_dc_ld_req_valid [CFG.lsu.agu_pipes];
    logic                       t_dc_ld_req_ready [CFG.lsu.agu_pipes];
    o3_types_pkg::dcache_req_t  t_dc_ld_req [CFG.lsu.agu_pipes];
    o3_types_pkg::dcache_resp_t t_dc_ld_resp [CFG.lsu.agu_pipes];
    logic                       t_sq_dc_req_valid, t_sq_dc_req_ready, t_sq_committed_empty;
    o3_types_pkg::dcache_req_t  t_sq_dc_req;
    o3_types_pkg::dcache_resp_t t_sq_dc_resp;
    // A/D
    logic                       t_dc_pte_ad_valid, t_dc_pte_ad_ready;
    o3_types_pkg::pte_ad_req_t  t_dc_pte_ad_req;
    o3_types_pkg::pte_ad_resp_t t_dc_pte_ad_resp;
    o3_types_pkg::rsv_conflict_t t_rsv_pte_ad_conflict;
    // reservation 清除与 fatal
    logic                       t_rsv_clear_valid;
    o3_types_pkg::rsv_clear_e   t_rsv_clear_reason;
    o3_types_pkg::fatal_evt_t   t_dc_fatal;

    // 不在 L3：PTW/A-D（L10）、数据预取（L8）、系统提交/CSR（L5 起）。
    // 禁用请求不伪造应答；idle 仅表示没有 walker 在途。
    assign itlb_ptw_req_ready_o = 1'b0;
    assign itlb_ptw_resp_o = '0;
    assign ptw_idle_o = 1'b1;
    assign t_dtlb_ptw_req_ready = 1'b0;
    assign t_ptw_resp = '0;
    assign t_ptw_mem_req_valid = 1'b0;
    assign t_ptw_mem_req = '0;
    assign t_dc_pte_ad_valid = 1'b0;
    assign t_dc_pte_ad_req = '0;
    assign t_rsv_pte_ad_conflict = '0;
    assign t_pf_req_valid = 1'b0;
    assign t_pf_req = '0;
    assign t_sfence = '0;
    assign t_dc_clean_all_req = 1'b0;
    assign t_rsv_clear_valid = 1'b0;
    assign t_rsv_clear_reason = o3_types_pkg::RSV_CLR_SC; // valid=0；合法编码无事件
    assign sys_redirect_o = '0;
    assign fe_sync_valid_o = 1'b0;
    assign fe_sync_o = '0;
    assign fatal_o = 1'b0; // L11 才实现 fatal 隔离，不能据此声称处理了故障
    assign perf_rd_data_o = '0; // 硬件计数器 L7；保留 retired_inst_count_o

    // U4：静态 M/Bare。L5 起由 csr_file 取代，PMP 检查待 L10。
    localparam logic [1:0] PRIV_M = 2'b11;
    localparam logic [3:0] SATP_BARE = 4'b0000;
    localparam logic MSTATUS_MPRV = 1'b0, MSTATUS_SUM = 1'b0, MSTATUS_MXR = 1'b0;
    localparam o3_types_pkg::fe_csr_t L3_FE_CSR =
        '{priv:PRIV_M, satp_mode:SATP_BARE, default:'0};
    // MPRV=0 => priv_eff=当前 M；dmmu_csr_t 保存派生特权，无独立 MPRV 位。
    localparam o3_types_pkg::dmmu_csr_t L3_DMMU_CSR =
        '{priv_eff:PRIV_M, sum:MSTATUS_SUM, mxr:MSTATUS_MXR,
          satp_mode:SATP_BARE, default:'0};
    localparam o3_types_pkg::pmp_state_t L3_PMP = '{update:1'b0, entries:'0};
    assign fe_csr_o = L3_FE_CSR;
    assign t_dmmu_csr = L3_DMMU_CSR;
    assign t_pmp = L3_PMP;
    assign fe_pmp_o = L3_PMP;
    always_ff @(posedge clk) begin
        assert (!fe_pmp_o.update && !t_pmp.update)
            else $error("L3 static PMP must never start D28 synchronization");
    end

    // U3：每条实际 ROB 退休通知携带完整动态身份、槽位和区域末项。
    // N 组合读取拍初已完成的退休前缀；N 边沿 ROB 删除这些项，前端记账；
    // N+1 前端据 region_last 回收区域。L5 原样并入 commit_ctrl。
    for (genvar lane = 0; lane < RETIRE_WIDTH; lane++) begin : gen_ftq_commit
        always_comb begin
            ftq_commit_o[lane] = '0;
            ftq_commit_o[lane].valid = rob_retire_valid[lane];
            ftq_commit_o[lane].ftq_id = rob_retire_ftq_idx[lane];
            ftq_commit_o[lane].slot = rob_retire_ftq_slot[lane];
            ftq_commit_o[lane].region_last = rob_retire_ftq_last[lane];
        end
    end

    dcache #(.CFG(CFG)) u_dcache (
        .clk(clk), .rst(rst),
        .ld_req_valid_i(t_dc_ld_req_valid), .ld_req_ready_o(t_dc_ld_req_ready),
        .ld_req_i(t_dc_ld_req), .ld_resp_o(t_dc_ld_resp),
        .st_req_valid_i(t_sq_dc_req_valid), .st_req_ready_o(t_sq_dc_req_ready),
        .st_req_i(t_sq_dc_req), .st_resp_o(t_sq_dc_resp),
        .ptw_req_valid_i(t_ptw_mem_req_valid), .ptw_req_ready_o(t_ptw_mem_req_ready),
        .ptw_req_i(t_ptw_mem_req), .ptw_resp_o(t_ptw_mem_resp),
        .pf_req_valid_i(t_pf_req_valid), .pf_req_ready_o(t_pf_req_ready), .pf_req_i(t_pf_req),
        // 维护入口：DMA 行协调 + L2 inclusive 回收共用（B08/B41）
        .probe_valid_i(l1d_probe_valid_i), .probe_ready_o(l1d_probe_ready_o),
        .probe_i(l1d_probe_i), .probe_resp_o(l1d_probe_resp_o),
        .clean_all_req_i(t_dc_clean_all_req), .clean_all_done_o(t_dc_clean_all_done),
        .clean_all_busy_o(t_dc_clean_all_busy),
        .pte_ad_req_valid_i(t_dc_pte_ad_valid), .pte_ad_req_ready_o(t_dc_pte_ad_ready),
        .pte_ad_req_i(t_dc_pte_ad_req), .pte_ad_resp_o(t_dc_pte_ad_resp),
        .cur_epoch_i(t_dmmu_csr.epoch),
        .rsv_clear_valid_i(t_rsv_clear_valid), .rsv_clear_reason_i(t_rsv_clear_reason),
        .rsv_pte_ad_conflict_i(t_rsv_pte_ad_conflict),
        .l2_req_valid_o(l2_req_valid_o), .l2_req_ready_i(l2_req_ready_i), .l2_req_o(l2_req_o),
        .l2_resp_i(l2_resp_i), .l2_resp_ready_o(l2_resp_ready_o),
        .l2_wb_valid_o(l2_wb_valid_o), .l2_wb_ready_i(l2_wb_ready_i),
        .l2_wb_line_paddr_o(l2_wb_line_paddr_o), .l2_wb_data_o(l2_wb_data_o),
        .l2_wb_error_i(l2_wb_error_i),
        .idle_o(), .fatal_o(t_dc_fatal), .perf_o()
    );

    // 冻结 §4.4：R 仍广播；M 是唯一恢复 block，资源回压保持独立。
    always_ff @(posedge clk) begin
        if (!rst) begin
            assert (rename_accept_count <= MACHINE_WIDTH && dispatch_accept_count <= DISPATCH_WIDTH);
            if (branch_mispredict) begin
                assert (int_read_grant == '0 && !mem_read_grant && !branch_read_grant);
                assert (rename_accept_count == '0 && dispatch_accept_count == '0);
                for (int lane=0; lane<RETIRE_WIDTH; lane++) assert (!rob_retire_valid[lane]);
            end
            if (branch_resolution_i.valid && !branch_resolution_i.mispredict) begin
                assert (decode_ready == uopq_enq_ready);
                assert (!u_prf_read_arbiter.issue_block_i);
                assert (!u_rename_stage.recovery_block_i && !u_dispatch_stage.recovery_block_i);
                for (int lane=0; lane<MACHINE_WIDTH; lane++) begin
                    if (rename_lane_valid[lane]) begin
                        assert (!rename_branch_mask[lane][branch_resolution_i.branch_tag]);
                        assert (rob_req[lane]);
                        assert (lq_alloc_req[lane] == rename_uop_head[lane].is_load);
                        assert (sq_alloc_req[lane] == rename_uop_head[lane].is_store);
                        assert (checkpoint_create[lane] == rename_uop_head[lane].needs_checkpoint);
                    end
                end
                for (int lane=0; lane<DISPATCH_WIDTH; lane++) begin
                    if (int_iq_enq_uop[lane].valid) assert (!int_iq_enq_uop[lane].branch_mask[branch_resolution_i.branch_tag]);
                    if (mem_iq_enq_uop[lane].valid) assert (!mem_iq_enq_uop[lane].branch_mask[branch_resolution_i.branch_tag]);
                    if (br_iq_enq_uop[lane].valid) assert (!br_iq_enq_uop[lane].branch_mask[branch_resolution_i.branch_tag]);
                end
            end
        end
    end

endmodule
