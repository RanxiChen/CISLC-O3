/**
 * 一个统一的后端，后面将会将代码进行拆分
 *
 * 当前已经实现的功能：
 * - 维护一个 fetch-entry buffer，用于承接 frontend 输入
 * - 对 fetch-entry buffer 中的指令做基础解码，并组装成 decoded uop
 * - 接入 decode 后、rename 前的 uop queue，形成前两拍骨架
 * - 在 rename 阶段接入 free list、rename map table 和最小 ROB
 * - Rename从Decode Queue最老端每拍接受0..MACHINE_WIDTH条连续前缀，并联合检查ROB、preg、LQ、SQ、checkpoint和Rename/Dispatch Queue容量
 * - 接入完整Rename Map checkpoint、每分支preg allocation mask、Load Queue、Store Queue和Rename/Dispatch Queue
 * - Dispatch从Rename/Dispatch Queue接受0..DISPATCH_WIDTH条最老连续前缀，并按类型并行分流到Integer/Memory/Branch三个IQ
 * - 三个IQ分别提供容量反压、preg ready跟踪、最老ready候选和branch-mask恢复
 * - Branch IQ经共享PRF读口进入单发射BRU；结果寄存后广播解析，错误预测恢复并输出redirect
 * - 在 backend 内维护最小 preg_ready table，并把 rename 完成后的整数 uop 按 lane 顺序压入单一 integer issue queue
 * - 在 issue queue 内基于 preg_ready table 做最小真实 wakeup
 * - 在 issue queue 内实现按年龄顺序的 select，并把最靠前的 ready uop 发给多个整数 ALU
 * - Integer/Memory/Branch候选按ROB年龄共同竞争逻辑8读口；拿不到全部读口时留在IQ
 * - 整数RegRead与execute result均为可反压槽；结果没获得写口时保持并阻塞该ALU前级
 * - Memory IQ只允许物理队头发射，已接单发射RegRead/AGU/LQ/SQ、Store forwarding、DTCM和外部memory口
 * - 接入多个 `int_execute_unit`，完成 RV64I R/I 整数算术指令的最小执行链路
 * - 四个ALU、一个Load和JAL/JALR链接结果按ROB年龄竞争4个PRF写口
 * - Store在AGU完成后complete ROB，退休时转为committed SQ entry，memory请求接受后才释放
 * - 接入4-wide in-order retire：从ROB队头连续退休最多4条，并把old_dst_preg回收到Free List
 * - 维护从 reset 开始累计的 retired instruction counter，按每拍真实退休条数累加
 * - 支持按 MACHINE_WIDTH 参数化并行处理多个 lane
 * - 在 `O3_SIM` 宏下新增逐周期文本日志，按周期块展示 DECODE/RENAME/WAKEUP/ISSUE/REGREAD/EXECUTE/WRITEBACK 阶段
 * - 在 backend 内部为每条被接收的指令生成调试用 instruction_id
 *   - 高位表示“第几批被 backend 接收的 fetch group”
 *   - 低位表示“该组内的 lane 编号”
 * - 统一 x0/p0 语义：x0 固定映射到 p0，p0 在 physical_regfile 中读恒为 0、写忽略
 *
 * 当前没有实现的功能：
 * - 当前预测器固定not-taken，不实现BTB/BHT/RAS训练表
 * - 不实现多BRU并发、分支执行旁路和预测表训练
 * - DTCM/外部memory路径不实现DCache/MSHR/PMA/MMU、访问异常或对齐异常
 * - Store forwarding只处理单个更老Store完整覆盖；未知地址/数据和部分重叠保守阻塞
 * - 四路整数写回向三个IQ广播目的preg；ready在上升沿记入IQ，下一拍参与Select，不做同拍wakeup-select旁路
 * - 不实现精确异常恢复、Load replay和更完整的内存序模型
 * - done 仍然只是占位信号
 * - 整核仿真已覆盖DTCM初始化与范围外软件memory读写；尚未形成Spike差分闭环
 *
 * 时序行为：
 * - 周期 N 开始时：
 *   1) fetch_entry_q / fetch_entry_valid_q 保存“上一拍已经接住”的 fetch 组
 *   2) uop_queue 保存按程序顺序连续排列的 decoded uop，并在队头展示最多 MACHINE_WIDTH 条
 *   3) Integer/Memory/Branch IQ分别保存已经Dispatch、等待未来执行端口的uop
 *   4) preg_ready_q 保存当前每个物理寄存器是否已经持有可读值
 *   5) ROB 持有当前的队头/队尾、complete 位以及可供 retire 的最老指令
 *   6) alu_regread_q / alu_result_q保存整数操作数和可能等待写口的结果，mem_execute_q保存LSU当前uop
 * - 周期 N 组合阶段：
 *   1) decoder 组合地产生 rs1/rs2/rd、use_imm、imm_type、imm_raw、int_alu_op 和最小 uop 语义
 *   2) rename 阶段从 uop_queue 展示的最老有效前缀组合读取 alloc_req / rob_req / rename map 结果
 *   3) Dispatch按三个IQ拍初空位计算队头最大连续前缀；三个IQ产生ready候选
 *   4) 全局读仲裁按ROB年龄分配8个PRF读口，FU忙或端口不足的候选不握手
 *   5) grant候选的PRF读值和扩展立即数锁存进对应RegRead槽
 *   6) int_execute_unit 基于 alu_regread_q 中的真实操作数组合地产生执行结果
 *   7) ALU/Load/Branch链接结果共同竞争4个写口；只有grant驱动写回和ROB complete
 *   8) LSU组合执行AGU、SQ依赖查询和Store优先的DTCM/外部memory仲裁
 *   9) ROB 当前会从队头开始连续检查最多4项，决定本拍retire的前缀长度
 * - 周期 N 上升沿：
 *   1) 若 decode_fire=1，则当前 fetch 组以 decoded uop 形式进入 uop_queue
 *   2) 若 rename_accept_count非零，则该最老前缀原子获得全部资源、进入Rename/Dispatch Queue，并从Decode Queue删除相同条数
 *   3) 三个IQ分别压紧写入本拍分流给自己的uop，并更新旧表项ready状态
 *   4) 获得全部读口的Integer/Memory uop离开IQ并锁存操作数；Branch不出队
 *   5) 能向结果槽前进的alu_regread_q经执行单元进入alu_result_q
 *   6) 写口grant结果写PRF并complete；未grant结果及其前级保持
 *   7) Store AGU写SQ并complete；Load请求进入SRAM或把转发值写入Load结果槽
 *   8) 本拍从 ROB 队头退休的指令会把 old_dst_preg 返还给 free list；这些释放回来的寄存器从下一拍起重新参与分配
 *   9) 若 fetch_fire=1，则同时把 frontend 新送来的指令写入 fetch_entry_q
 * - 周期 N+1：
 *   1) issue_queue 中看到唤醒、压缩补位、追加入队后的新队列内容
 *   2) 刚刚被写回的目的物理寄存器在 preg_ready_q 中表现为 ready，可继续唤醒后继指令
 *   3) Load响应进入可保持的Load结果槽；committed Store被目标memory接受后释放SQ
 *   4) 日志中可看到同一条 instruction_id 按阶段继续向后流动，并在退休后离开 ROB
 */

`ifdef O3_SIM
`include "dpi_functions.svh"
`endif

module backend
    import o3_pkg::*;
    #(
        parameter int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,
        parameter int NUM_PHYS_REGS = BACKEND_NUM_PHYS_REGS,
        parameter int NUM_ARCH_REGS = BACKEND_NUM_ARCH_REGS,
        parameter int NUM_ROB_ENTRIES = BACKEND_NUM_ROB_ENTRIES,
        parameter int DECODE_QUEUE_DEPTH = BACKEND_DECODE_QUEUE_DEPTH,
        parameter int DISPATCH_WIDTH = BACKEND_DISPATCH_WIDTH,
        parameter int INT_ISSUE_QUEUE_DEPTH = BACKEND_INT_ISSUE_QUEUE_DEPTH,
        parameter int MEM_ISSUE_QUEUE_DEPTH = BACKEND_MEM_ISSUE_QUEUE_DEPTH,
        parameter int BRANCH_ISSUE_QUEUE_DEPTH = BACKEND_BRANCH_ISSUE_QUEUE_DEPTH,
        parameter int NUM_INT_ALUS = BACKEND_NUM_INT_ALUS,
        parameter int NUM_BRANCH_CHECKPOINTS = BACKEND_NUM_BRANCH_CHECKPOINTS,
        parameter int LOAD_QUEUE_DEPTH = BACKEND_LOAD_QUEUE_DEPTH,
        parameter int STORE_QUEUE_DEPTH = BACKEND_STORE_QUEUE_DEPTH,
        parameter int RENAME_DISPATCH_QUEUE_DEPTH = BACKEND_RENAME_DISPATCH_QUEUE_DEPTH
    )
(
    input  logic clk,
    input  logic rst,
    input  fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry_i,
    input  logic                             fetch_valid_i,
    output logic                             fetch_ready_o,
    output branch_resolution_t               branch_resolution_o,
    output logic [$clog2(MACHINE_WIDTH+1)-1:0] ftq_release_count_o,
    output logic                             redirect_valid_o,
    output logic [PC_WIDTH-1:0]              redirect_pc_o,
    input  logic                             dtcm_init_valid_i,
    input  logic [XLEN-1:0]                  dtcm_init_addr_i,
    input  logic [XLEN-1:0]                  dtcm_init_wdata_i,
    input  logic [7:0]                       dtcm_init_wmask_i,
    output logic                             dmem_req_valid_o,
    input  logic                             dmem_req_ready_i,
    output logic                             dmem_req_write_o,
    output logic [XLEN-1:0]                  dmem_req_addr_o,
    output logic [XLEN-1:0]                  dmem_req_wdata_o,
    output logic [7:0]                       dmem_req_wmask_o,
    input  logic                             dmem_rsp_valid_i,
    output logic                             dmem_rsp_ready_o,
    input  logic [XLEN-1:0]                  dmem_rsp_rdata_i,
    input  logic                             dmem_rsp_error_i,
    output logic                             done,
    output logic [63:0]                      retired_inst_count_o
`ifdef ENABLE_RETIRE_INFO
    ,output retire_info_t                    retire_info_o [NUM_INT_ALUS-1:0]
`endif
`ifdef O3_SIM_SINGLE_INST_TRACE
    ,output logic                            single_inst_retired_o
`endif
);

    localparam int BACKEND_PREG_IDX_WIDTH = $clog2(NUM_PHYS_REGS);
    localparam int BACKEND_ROB_IDX_WIDTH  = $clog2(NUM_ROB_ENTRIES);
    localparam int BACKEND_LANE_COUNT_WIDTH = $clog2(MACHINE_WIDTH + 1);
    localparam int BACKEND_ROB_COUNT_WIDTH = $clog2(NUM_ROB_ENTRIES + 1);
    localparam int BACKEND_PREG_COUNT_WIDTH = $clog2(NUM_PHYS_REGS + 1);
    localparam int BACKEND_LQ_IDX_WIDTH = $clog2(LOAD_QUEUE_DEPTH);
    localparam int BACKEND_SQ_IDX_WIDTH = $clog2(STORE_QUEUE_DEPTH);
    localparam int INST_ID_LANE_BITS      = (MACHINE_WIDTH <= 1) ? 1 : $clog2(MACHINE_WIDTH);
    localparam int PRF_READ_PORTS         = NUM_INT_ALUS * 2;
    localparam int PRF_WRITE_PORTS        = NUM_INT_ALUS;

    fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry_q;
    logic                             fetch_entry_valid_q;
    logic [INST_ID_WIDTH-1:0]         fetch_instruction_id_q [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]         fetch_instruction_id_d [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]         fetch_group_seq_q;

    decode_in_t    [MACHINE_WIDTH-1:0] decode_in;
    decode_out_t   [MACHINE_WIDTH-1:0] decode_out;
    decoded_uop_t  [MACHINE_WIDTH-1:0] decoded_uop;
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
    logic rob_exception [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rs1_addr    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rs2_addr    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rd_addr     [MACHINE_WIDTH-1:0];
    logic                      rename_lane_valid  [MACHINE_WIDTH-1:0];
    logic                      rename_rs1_read_en [MACHINE_WIDTH-1:0];
    logic                      rename_rs2_read_en [MACHINE_WIDTH-1:0];
    logic                      rename_rd_write_en [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]  rob_alloc_instruction_id [MACHINE_WIDTH-1:0];
    logic [FTQ_INDEX_WIDTH-1:0] rob_alloc_ftq_idx [MACHINE_WIDTH-1:0];
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
    branch_execute_uop_t    branch_regread_q;
    branch_result_t         branch_execute_result;
    branch_result_t         branch_result_q;
    logic                   branch_resolution_sent_q;
    branch_resolution_t     branch_resolution_i;

    logic alu_result_consume [NUM_INT_ALUS-1:0];
    logic load_result_consume;
    logic branch_result_consume;
    logic branch_execute_ready;
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

    logic                              exec_valid   [NUM_INT_ALUS-1:0];
    logic [XLEN-1:0]                   exec_result  [NUM_INT_ALUS-1:0];
    logic                              exec_cmp_true[NUM_INT_ALUS-1:0];
    logic                              preg_ready_q [NUM_PHYS_REGS-1:0];
    logic                              rob_complete_valid [NUM_INT_ALUS+2:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_complete_idx   [NUM_INT_ALUS+2:0];
    logic                              wb_complete_valid [NUM_INT_ALUS+1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  wb_complete_idx [NUM_INT_ALUS+1:0];
    logic [XLEN-1:0]                   wb_complete_data [NUM_INT_ALUS+1:0];
    logic                              rob_retire_valid   [NUM_INT_ALUS-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_retire_idx     [NUM_INT_ALUS-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] rob_retire_old_dst_preg [NUM_INT_ALUS-1:0];
    logic [INST_ID_WIDTH-1:0]          rob_retire_instruction_id [NUM_INT_ALUS-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] rob_retire_new_dst_preg [NUM_INT_ALUS-1:0];
    logic [REG_ADDR_WIDTH-1:0] rob_retire_rd [NUM_INT_ALUS-1:0];
    logic rob_retire_rd_write_en [NUM_INT_ALUS-1:0];
    logic rob_retire_is_load [NUM_INT_ALUS-1:0];
    logic rob_retire_is_store [NUM_INT_ALUS-1:0];
    logic [LQ_IDX_WIDTH-1:0] rob_retire_lq_idx [NUM_INT_ALUS-1:0];
    logic [SQ_IDX_WIDTH-1:0] rob_retire_sq_idx [NUM_INT_ALUS-1:0];
    logic [FTQ_INDEX_WIDTH-1:0] rob_retire_ftq_idx [NUM_INT_ALUS-1:0];
    logic rob_retire_ftq_last [NUM_INT_ALUS-1:0];
    logic free_release_valid [NUM_INT_ALUS-1:0];
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
    logic sq_commit_valid [NUM_INT_ALUS-1:0];
    logic store_complete_valid;
    logic [BACKEND_ROB_IDX_WIDTH-1:0] store_complete_rob_idx;
    logic mem_execute_ready;

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
        killed_by_resolution = branch_resolution_i.valid
                            && branch_resolution_i.mispredict
                            && mask[branch_resolution_i.branch_tag];
    endfunction

    function automatic int unsigned rob_age(
        input logic [BACKEND_ROB_IDX_WIDTH-1:0] idx
    );
        rob_age = (int'(idx) + NUM_ROB_ENTRIES - int'(rob_head)) % NUM_ROB_ENTRIES;
    endfunction

    function automatic branch_mask_t resolved_branch_mask(input branch_mask_t mask);
        branch_mask_t result;
        begin
            result = mask;
            if (branch_resolution_i.valid) begin
                result[branch_resolution_i.branch_tag] = 1'b0;
            end
            resolved_branch_mask = result;
        end
    endfunction

    function automatic logic [XLEN-1:0] expand_imm_value(
        input imm_type_t                imm_type,
        input logic [IMM_RAW_WIDTH-1:0] imm_raw
    );
        logic signed [XLEN-1:0] imm_sext;
        begin
            imm_sext = '0;
            unique case (imm_type)
                IMM_TYPE_I,
                IMM_TYPE_S: imm_sext = XLEN'($signed({{(XLEN-12){imm_raw[11]}}, imm_raw[11:0]}));
                IMM_TYPE_B: imm_sext = XLEN'($signed({{(XLEN-13){imm_raw[12]}}, imm_raw[12:0]}));
                IMM_TYPE_U: imm_sext = XLEN'($signed({{(XLEN-32){imm_raw[20]}}, imm_raw[20:0], 11'b0}));
                IMM_TYPE_J: imm_sext = XLEN'($signed({{(XLEN-21){imm_raw[20]}}, imm_raw[20:0]}));
                default:    imm_sext = '0;
            endcase
            expand_imm_value = imm_sext;
        end
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
        for (i = 0; i < MACHINE_WIDTH; i++) begin : decode_input_assign
            assign decode_in[i].instruction = fetch_entry_q[i].instruction;
        end
    endgenerate

    generate
        for (i = 0; i < MACHINE_WIDTH; i++) begin : decoder_array
            decoder u_decoder (
                .decode_i(decode_in[i]),
                .decode_o(decode_out[i])
            );
        end
    endgenerate

    generate
        for (i = 0; i < MACHINE_WIDTH; i++) begin : decoded_uop_assign
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
            assign decoded_uop[i].ftq_idx        = fetch_entry_q[i].ftq_idx;
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
            assign fetch_instruction_id_d[i] = make_instruction_id(fetch_group_seq_q, i);
            assign rename_rs1_addr[i]        = rename_uop_head[i].rs1;
            assign rename_rs2_addr[i]        = rename_uop_head[i].rs2;
            assign rename_rd_addr[i]         = rename_uop_head[i].rd;
            assign rename_rs1_read_en[i]     = rename_uop_head[i].rs1_read_en;
            assign rename_rs2_read_en[i]     = rename_uop_head[i].rs2_read_en;
            assign rename_rd_write_en[i]     = rename_uop_head[i].rd_write_en;
            assign checkpoint_req[i]         = rename_uop_head[i].valid
                                               && rename_uop_head[i].needs_checkpoint;
            assign rob_exception[i] = renamed_uop[i].exception_valid;
            assign rob_alloc_instruction_id[i] = rename_uop_head[i].instruction_id;
            assign rob_alloc_ftq_idx[i] = rename_uop_head[i].ftq_idx;
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
            int_iq_enq_uop[lane].valid = dispatch_int_lane[lane];
            mem_iq_enq_uop[lane].valid = dispatch_mem_lane[lane];
            br_iq_enq_uop[lane].valid = dispatch_br_lane[lane];
        end
    end

    assign decode_ready    = uopq_enq_ready && !branch_resolution_i.valid;
    assign decode_fire     = decode_valid && decode_ready;
    assign fetch_ready_o   = !branch_resolution_i.valid
                           && ((!fetch_entry_valid_q) || decode_ready);
    assign fetch_fire      = fetch_valid_i && fetch_ready_o;
    assign rename_valid    = (uopq_deq_count != '0);
    assign rename_fire     = (rename_accept_count != '0);
    assign uopq_deq_accept_count = rename_accept_count;
    assign redirect_valid_o = branch_resolution_i.valid && branch_resolution_i.mispredict;
    assign redirect_pc_o = branch_resolution_i.redirect_pc;
    assign branch_resolution_o = branch_resolution_i;
    assign branch_resolution_i.valid = branch_result_q.valid && !branch_resolution_sent_q;
    assign branch_resolution_i.mispredict = branch_result_q.mispredict;
    assign branch_resolution_i.branch_tag = branch_result_q.branch_tag;
    assign branch_resolution_i.branch_rob_idx = branch_result_q.rob_idx;
    assign branch_resolution_i.ftq_idx = branch_result_q.ftq_idx;
    assign branch_resolution_i.branch_pc = branch_result_q.branch_pc;
    assign branch_resolution_i.is_branch = branch_result_q.is_branch;
    assign branch_resolution_i.is_jal = branch_result_q.is_jal;
    assign branch_resolution_i.is_jalr = branch_result_q.is_jalr;
    assign branch_resolution_i.actual_taken = branch_result_q.actual_taken;
    assign branch_resolution_i.actual_target = branch_result_q.actual_target;
    assign branch_resolution_i.redirect_pc = branch_result_q.actual_next_pc;
    assign branch_resolution_i.completes_rob = !branch_result_q.dst_write_en;
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
        ftq_release_count_o = '0;
        for (int port = 0; port < NUM_INT_ALUS; port++) begin
            sq_commit_valid[port] = rob_retire_valid[port] && rob_retire_is_store[port];
            free_release_valid[port] = rob_retire_valid[port]
                                    && rob_retire_rd_write_en[port]
                                    && (rob_retire_old_dst_preg[port] != '0);
            if (rob_retire_valid[port] && rob_retire_is_load[port]) begin
                lq_release_count = lq_release_count + BACKEND_LANE_COUNT_WIDTH'(1);
            end
            if (rob_retire_valid[port] && rob_retire_ftq_last[port]) begin
                ftq_release_count_o = ftq_release_count_o + BACKEND_LANE_COUNT_WIDTH'(1);
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

    // Wakeup/select、FU空闲和PRF读口在同一个组合仲裁中联合决定。候选按ROB年龄
    // 从老到年轻贪心扫描；一条uop所需的1/2个读口必须原子取得，否则留在IQ。
    always_comb begin
        logic [NUM_INT_ALUS-1:0] considered_int;
        logic considered_mem;
        logic considered_branch;
        int unsigned read_used;

        prf_rd_addr = '{default: '0};
        int_read_grant = '0;
        mem_read_grant = 1'b0;
        branch_read_grant = 1'b0;
        int_src1_port = '{default: '0};
        int_src2_port = '{default: '0};
        mem_src1_port = '0;
        mem_src2_port = '0;
        branch_src1_port = '0;
        branch_src2_port = '0;
        considered_int = '0;
        considered_mem = 1'b0;
        considered_branch = 1'b0;
        read_used = 0;

        for (int choice = 0; choice < NUM_INT_ALUS + 2; choice++) begin
            int chosen_kind;
            int chosen_idx;
            int unsigned chosen_age;
            int unsigned read_need;
            chosen_kind = -1;
            chosen_idx = -1;
            chosen_age = NUM_ROB_ENTRIES;
            read_need = 0;

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (!branch_resolution_i.valid
                 && !considered_int[alu] && int_iq_issue_valid[alu]
                 && alu_regread_ready[alu]
                 && (rob_age(int_iq_issue_uop[alu].rob_idx) < chosen_age)) begin
                    chosen_kind = 0;
                    chosen_idx = alu;
                    chosen_age = rob_age(int_iq_issue_uop[alu].rob_idx);
                end
            end
            if (!branch_resolution_i.valid && !considered_mem && mem_iq_issue_valid[0]
             && (!mem_execute_q.valid || mem_execute_ready)
             && ((chosen_kind < 0) || (rob_age(mem_iq_issue_uop[0].rob_idx) < chosen_age))) begin
                chosen_kind = 1;
                chosen_idx = 0;
                chosen_age = rob_age(mem_iq_issue_uop[0].rob_idx);
            end
            if (!branch_resolution_i.valid && !considered_branch && br_iq_issue_valid[0]
             && branch_regread_ready
             && ((chosen_kind < 0) || (rob_age(br_iq_issue_uop[0].rob_idx) < chosen_age))) begin
                chosen_kind = 2;
                chosen_idx = 0;
                chosen_age = rob_age(br_iq_issue_uop[0].rob_idx);
            end

            if (chosen_kind == 0) begin
                considered_int[chosen_idx] = 1'b1;
                read_need = int'(int_iq_issue_uop[chosen_idx].rs1_read_en)
                          + int'(int_iq_issue_uop[chosen_idx].rs2_read_en
                                 && !int_iq_issue_uop[chosen_idx].use_imm);
                if ((read_used + read_need) <= PRF_READ_PORTS) begin
                    int_read_grant[chosen_idx] = 1'b1;
                    if (int_iq_issue_uop[chosen_idx].rs1_read_en) begin
                        int_src1_port[chosen_idx] = $clog2(PRF_READ_PORTS)'(read_used);
                        prf_rd_addr[read_used] = int_iq_issue_uop[chosen_idx].src1_preg;
                        read_used++;
                    end
                    if (int_iq_issue_uop[chosen_idx].rs2_read_en
                     && !int_iq_issue_uop[chosen_idx].use_imm) begin
                        int_src2_port[chosen_idx] = $clog2(PRF_READ_PORTS)'(read_used);
                        prf_rd_addr[read_used] = int_iq_issue_uop[chosen_idx].src2_preg;
                        read_used++;
                    end
                end
            end else if (chosen_kind == 1) begin
                considered_mem = 1'b1;
                read_need = int'(mem_iq_issue_uop[0].rs1_read_en)
                          + int'(mem_iq_issue_uop[0].rs2_read_en);
                if ((read_used + read_need) <= PRF_READ_PORTS) begin
                    mem_read_grant = 1'b1;
                    if (mem_iq_issue_uop[0].rs1_read_en) begin
                        mem_src1_port = $clog2(PRF_READ_PORTS)'(read_used);
                        prf_rd_addr[read_used] = mem_iq_issue_uop[0].src1_preg;
                        read_used++;
                    end
                    if (mem_iq_issue_uop[0].rs2_read_en) begin
                        mem_src2_port = $clog2(PRF_READ_PORTS)'(read_used);
                        prf_rd_addr[read_used] = mem_iq_issue_uop[0].src2_preg;
                        read_used++;
                    end
                end
            end else if (chosen_kind == 2) begin
                considered_branch = 1'b1;
                read_need = int'(br_iq_issue_uop[0].rs1_read_en)
                          + int'(br_iq_issue_uop[0].rs2_read_en);
                if ((read_used + read_need) <= PRF_READ_PORTS) begin
                    branch_read_grant = 1'b1;
                    if (br_iq_issue_uop[0].rs1_read_en) begin
                        branch_src1_port = $clog2(PRF_READ_PORTS)'(read_used);
                        prf_rd_addr[read_used] = br_iq_issue_uop[0].src1_preg;
                        read_used++;
                    end
                    if (br_iq_issue_uop[0].rs2_read_en) begin
                        branch_src2_port = $clog2(PRF_READ_PORTS)'(read_used);
                        prf_rd_addr[read_used] = br_iq_issue_uop[0].src2_preg;
                        read_used++;
                    end
                end
            end
        end

        int_iq_issue_ready = int_read_grant;
        mem_iq_issue_ready[0] = mem_read_grant;
        br_iq_issue_ready[0] = branch_read_grant;
    end

    always_comb begin
        rob_retire_any = 1'b0;
        for (int port = 0; port < NUM_INT_ALUS; port++) begin
            rob_retire_any |= rob_retire_valid[port];
        end
    end

    always_comb begin
        retire_count_this_cycle = '0;
        for (int port = 0; port < NUM_INT_ALUS; port++) begin
            if (rob_retire_valid[port]) begin
                retire_count_this_cycle = retire_count_this_cycle
                                        + BACKEND_LANE_COUNT_WIDTH'(1);
            end
        end

        retired_inst_count_next = retired_inst_count_q + 64'(retire_count_this_cycle);
    end

    uop_queue #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .DEPTH(DECODE_QUEUE_DEPTH)
    ) u_decode_queue (
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

    branch_checkpoint_file #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_CHECKPOINTS(NUM_BRANCH_CHECKPOINTS),
        .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES),
        .LQ_DEPTH(LOAD_QUEUE_DEPTH),
        .SQ_DEPTH(STORE_QUEUE_DEPTH)
    ) u_branch_checkpoint_file (
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

    rename_stage #(
        .WIDTH(MACHINE_WIDTH),
        .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES),
        .LQ_DEPTH(LOAD_QUEUE_DEPTH),
        .SQ_DEPTH(STORE_QUEUE_DEPTH),
        .RDQ_DEPTH(RENAME_DISPATCH_QUEUE_DEPTH)
    ) u_rename_stage (
        .decoded_i(rename_uop_head),
        .visible_count_i(uopq_deq_count),
        .recovery_block_i(branch_resolution_i.valid),
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

    free_list #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .NUM_ARCH_REGS(NUM_ARCH_REGS),
        .RELEASE_WIDTH(NUM_INT_ALUS),
        .NUM_CHECKPOINTS(NUM_BRANCH_CHECKPOINTS)
    ) u_free_list (
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

    rob #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES),
        .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .COMPLETE_WIDTH(NUM_INT_ALUS + 3),
        .RETIRE_WIDTH(NUM_INT_ALUS)
    ) u_rob (
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
        .retire_ftq_last_o(rob_retire_ftq_last)
`ifdef ENABLE_RETIRE_INFO
        ,.retire_info_o(retire_info_o)
`endif
    );

    rename_map_table #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_ARCH_REGS(NUM_ARCH_REGS),
        .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .NUM_CHECKPOINTS(NUM_BRANCH_CHECKPOINTS),
        .COMMIT_WIDTH(NUM_INT_ALUS)
    ) u_rename_map_table (
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

    load_queue #(
        .RENAME_WIDTH(MACHINE_WIDTH), .DEPTH(LOAD_QUEUE_DEPTH), .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES)
    ) u_load_queue (
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

    store_queue #(
        .RENAME_WIDTH(MACHINE_WIDTH), .COMMIT_WIDTH(NUM_INT_ALUS),
        .DEPTH(STORE_QUEUE_DEPTH), .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES)
    ) u_store_queue (
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
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag), .restore_tail_i(restore_sq_tail)
    );

    rename_dispatch_queue #(
        .ENQ_WIDTH(MACHINE_WIDTH), .DEQ_WIDTH(DISPATCH_WIDTH),
        .DEPTH(RENAME_DISPATCH_QUEUE_DEPTH)
    ) u_rename_dispatch_queue (
        .clk(clk), .rst(rst), .enq_uop_i(renamed_uop), .enq_count_i(rename_accept_count),
        .enq_fire_i(rename_fire), .free_count_o(rdq_free_count),
        .deq_uop_o(dispatch_uop_head), .deq_count_o(dispatch_count),
        .deq_accept_count_i(dispatch_accept_count),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    dispatch_stage #(
        .DISPATCH_WIDTH(DISPATCH_WIDTH),
        .INT_IQ_DEPTH(INT_ISSUE_QUEUE_DEPTH),
        .MEM_IQ_DEPTH(MEM_ISSUE_QUEUE_DEPTH),
        .BR_IQ_DEPTH(BRANCH_ISSUE_QUEUE_DEPTH)
    ) u_dispatch_stage (
        .uop_i(dispatch_uop_head),
        .visible_count_i(dispatch_count),
        .recovery_block_i(branch_resolution_i.valid),
        .int_free_count_i(int_iq_free_count),
        .mem_free_count_i(mem_iq_free_count),
        .br_free_count_i(br_iq_free_count),
        .int_lane_o(dispatch_int_lane),
        .mem_lane_o(dispatch_mem_lane),
        .br_lane_o(dispatch_br_lane),
        .accept_count_o(dispatch_accept_count)
    );

    backend_issue_queue #(
        .ENQ_WIDTH(DISPATCH_WIDTH), .ISSUE_WIDTH(NUM_INT_ALUS),
        .WAKEUP_WIDTH(NUM_INT_ALUS),
        .DEPTH(INT_ISSUE_QUEUE_DEPTH),
        .NUM_PHYS_REGS(NUM_PHYS_REGS)
    ) u_int_issue_queue (
        .clk(clk),
        .rst(rst),
        .enq_uop_i(int_iq_enq_uop),
        .enq_fire_i(dispatch_accept_count != '0),
        .free_count_o(int_iq_free_count),
        .preg_ready_i(preg_ready_q),
        .wakeup_valid_i(prf_wr_en),
        .wakeup_preg_i(prf_wr_addr),
        .issue_uop_o(int_iq_issue_uop),
        .issue_valid_o(int_iq_issue_valid),
        .issue_ready_i(int_iq_issue_ready),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    backend_issue_queue #(
        .ENQ_WIDTH(DISPATCH_WIDTH), .ISSUE_WIDTH(1),
        .WAKEUP_WIDTH(NUM_INT_ALUS),
        .DEPTH(MEM_ISSUE_QUEUE_DEPTH), .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .OLDEST_ONLY(1'b1)
    ) u_mem_issue_queue (
        .clk(clk), .rst(rst), .enq_uop_i(mem_iq_enq_uop),
        .enq_fire_i(dispatch_accept_count != '0), .free_count_o(mem_iq_free_count),
        .preg_ready_i(preg_ready_q), .wakeup_valid_i(prf_wr_en),
        .wakeup_preg_i(prf_wr_addr), .issue_uop_o(mem_iq_issue_uop),
        .issue_valid_o(mem_iq_issue_valid), .issue_ready_i(mem_iq_issue_ready),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    backend_issue_queue #(
        .ENQ_WIDTH(DISPATCH_WIDTH), .ISSUE_WIDTH(1),
        .WAKEUP_WIDTH(NUM_INT_ALUS),
        .DEPTH(BRANCH_ISSUE_QUEUE_DEPTH), .NUM_PHYS_REGS(NUM_PHYS_REGS)
    ) u_branch_issue_queue (
        .clk(clk), .rst(rst), .enq_uop_i(br_iq_enq_uop),
        .enq_fire_i(dispatch_accept_count != '0), .free_count_o(br_iq_free_count),
        .preg_ready_i(preg_ready_q), .wakeup_valid_i(prf_wr_en),
        .wakeup_preg_i(prf_wr_addr), .issue_uop_o(br_iq_issue_uop),
        .issue_valid_o(br_iq_issue_valid), .issue_ready_i(br_iq_issue_ready),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag)
    );

    // LSU拥有单发射Memory流水、LQ/SQ依赖查询后的统一memory请求以及可保持的Load结果。
    load_store_unit u_load_store_unit (
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
        .store_complete_valid_o(store_complete_valid),
        .store_complete_rob_idx_o(store_complete_rob_idx),
        .load_result_o(load_result), .load_result_ready_i(load_result_consume),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag),
        .dtcm_init_valid_i(dtcm_init_valid_i), .dtcm_init_addr_i(dtcm_init_addr_i),
        .dtcm_init_wdata_i(dtcm_init_wdata_i), .dtcm_init_wmask_i(dtcm_init_wmask_i),
        .ext_req_valid_o(dmem_req_valid_o), .ext_req_ready_i(dmem_req_ready_i),
        .ext_req_write_o(dmem_req_write_o), .ext_req_addr_o(dmem_req_addr_o),
        .ext_req_wdata_o(dmem_req_wdata_o), .ext_req_wmask_o(dmem_req_wmask_o),
        .ext_rsp_valid_i(dmem_rsp_valid_i), .ext_rsp_ready_o(dmem_rsp_ready_o),
        .ext_rsp_rdata_i(dmem_rsp_rdata_i), .ext_rsp_error_i(dmem_rsp_error_i)
    );

    branch_execute_unit u_branch_execute_unit (
        .uop_i(branch_regread_q),
        .result_o(branch_execute_result)
    );

    writeback_arbiter #(
        .NUM_ALUS(NUM_INT_ALUS), .PRF_WRITE_PORTS(PRF_WRITE_PORTS),
        .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES)
    ) u_writeback_arbiter (
        .alu_result_i(alu_result_q), .load_result_i(load_result),
        .branch_result_i(branch_result_q), .rob_head_i(rob_head),
        .resolution_valid_i(branch_resolution_i.valid),
        .resolution_mispredict_i(branch_resolution_i.mispredict),
        .resolution_tag_i(branch_resolution_i.branch_tag),
        .alu_consume_o(alu_result_consume), .load_consume_o(load_result_consume),
        .branch_consume_o(branch_result_consume),
        .prf_wr_en_o(prf_wr_en), .prf_wr_addr_o(prf_wr_addr), .prf_wr_data_o(prf_wr_data),
        .complete_valid_o(wb_complete_valid), .complete_idx_o(wb_complete_idx),
        .complete_data_o(wb_complete_data)
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

    generate
        for (i = 0; i < NUM_INT_ALUS; i++) begin : result_backpressure
            assign alu_regread_ready[i] = !alu_regread_q[i].valid || alu_result_consume[i];
        end
    endgenerate
    assign branch_execute_ready = !branch_result_q.valid || branch_result_consume;
    assign branch_regread_ready = !branch_regread_q.valid || branch_execute_ready;

    physical_regfile #(
        .NUM_READ_PORTS(PRF_READ_PORTS),
        .NUM_WRITE_PORTS(PRF_WRITE_PORTS),
        .NUM_ENTRIES(NUM_PHYS_REGS),
        .DATA_WIDTH(XLEN)
    ) u_physical_regfile (
        .clk(clk),
        .rst(rst),
        .rd_addr_i(prf_rd_addr),
        .rd_data_o(prf_rd_data),
        .wr_en_i(prf_wr_en),
        .wr_addr_i(prf_wr_addr),
        .wr_data_i(prf_wr_data)
    );

    generate
        for (i = 0; i < NUM_INT_ALUS; i++) begin : int_execute_array
            int_execute_unit #(
                .DATA_WIDTH(XLEN)
            ) u_int_execute_unit (
                .op_i(int_alu_op_t'(alu_regread_q[i].int_alu_op)),
                .valid_i(alu_regread_q[i].valid),
                .src1_value_i(alu_regread_q[i].src1_value),
                .src2_value_i(alu_regread_q[i].src2_value),
                .imm_value_i(alu_regread_q[i].imm_value),
                .use_imm_i(alu_regread_q[i].imm_valid),
                .is_word_op_i(alu_regread_q[i].is_word_op),
                .valid_o(exec_valid[i]),
                .result_o(exec_result[i]),
                .cmp_true_o(exec_cmp_true[i])
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
            alu_regread_q          <= '{default: '0};
            alu_result_q           <= '{default: '0};
            mem_execute_q          <= '0;
            branch_regread_q       <= '0;
            branch_result_q        <= '0;
            branch_resolution_sent_q <= 1'b0;
            retired_inst_count_q   <= 64'd0;
            for (int preg = 0; preg < NUM_PHYS_REGS; preg++) begin
                preg_ready_q[preg] <= (preg < NUM_ARCH_REGS);
            end
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
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
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
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
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
                for (int port = 0; port < NUM_INT_ALUS; port++) begin
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
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
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

                for (int port = 0; port < NUM_INT_ALUS; port++) begin
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
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
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
                for (int port = 0; port < NUM_INT_ALUS; port++) begin
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

            // rename 成功时，新分配的真实目的 preg 要先标记为 not-ready；
            // 写回阶段再把它置回 ready。这样 issue queue 才会等到真实结果返回再唤醒。
            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (rename_fire
                 && rename_lane_valid[lane]
                 && rename_uop_head[lane].rd_write_en
                 && (rename_uop_head[lane].rd != REG_ADDR_WIDTH'(0))) begin
                    preg_ready_q[dst_new_preg[lane]] <= 1'b0;
                end
            end

            // 只有真正获得共享PRF写口的结果才变为全局ready并形成wakeup广播。
            for (int port = 0; port < PRF_WRITE_PORTS; port++) begin
                if (prf_wr_en[port]) begin
                    preg_ready_q[prf_wr_addr[port]] <= 1'b1;
                end
            end

            // 退休计数器按本拍真正退休的 ROB 条数累加，用于后续性能观察和日志统计。
            retired_inst_count_q <= retired_inst_count_next;
`ifdef O3_SIM
            if (decode_fire) begin
                kanata_id_counter_q <= kanata_id_counter_q + 64'(MACHINE_WIDTH);
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
                // Result槽只有在旧结果被消费/杀死/为空时才能被Execute覆盖。
                if (alu_result_consume[alu]) begin
                    alu_result_q[alu].valid <= exec_valid[alu]
                                               && !killed_by_resolution(alu_regread_q[alu].branch_mask);
                    alu_result_q[alu].instruction_id <= alu_regread_q[alu].instruction_id;
`ifdef O3_SIM
                    alu_result_q[alu].kanata_id <= alu_regread_q[alu].kanata_id;
`endif
                    alu_result_q[alu].rob_idx <= alu_regread_q[alu].rob_idx;
                    alu_result_q[alu].dst_preg <= alu_regread_q[alu].dst_preg;
                    alu_result_q[alu].dst_write_en <= alu_regread_q[alu].dst_write_en;
                    alu_result_q[alu].result <= exec_result[alu];
                    alu_result_q[alu].branch_mask <= resolved_branch_mask(alu_regread_q[alu].branch_mask);
                end else if (branch_resolution_i.valid) begin
                    alu_result_q[alu].branch_mask <= resolved_branch_mask(alu_result_q[alu].branch_mask);
                end

                // 读口grant与IQ删除原子发生；组合PRF读值直接锁存到RegRead槽。
                if (alu_regread_ready[alu]) begin
                    alu_regread_q[alu].valid <= int_read_grant[alu];
                    alu_regread_q[alu].instruction_id <= int_iq_issue_uop[alu].instruction_id;
`ifdef O3_SIM
                    alu_regread_q[alu].kanata_id <= int_iq_issue_uop[alu].kanata_id;
`endif
                    alu_regread_q[alu].rob_idx <= int_iq_issue_uop[alu].rob_idx;
                    alu_regread_q[alu].dst_preg <= int_iq_issue_uop[alu].dst_preg;
                    alu_regread_q[alu].dst_write_en <= int_iq_issue_uop[alu].rd_write_en
                                                     && (int_iq_issue_uop[alu].rd != '0);
                    alu_regread_q[alu].src1_value <= int_iq_issue_uop[alu].src1_is_pc
                                                  ? XLEN'(int_iq_issue_uop[alu].pc)
                                                  : (int_iq_issue_uop[alu].rs1_read_en
                                                     ? prf_rd_data[int_src1_port[alu]] : '0);
                    alu_regread_q[alu].src2_value <= int_iq_issue_uop[alu].rs2_read_en
                                                  && !int_iq_issue_uop[alu].use_imm
                                                  ? prf_rd_data[int_src2_port[alu]] : '0;
                    alu_regread_q[alu].imm_value <= int_iq_issue_uop[alu].use_imm
                                                ? expand_imm_value(int_iq_issue_uop[alu].imm_type,
                                                                   int_iq_issue_uop[alu].imm_raw) : '0;
                    alu_regread_q[alu].imm_valid <= int_iq_issue_uop[alu].use_imm;
                    alu_regread_q[alu].int_alu_op <= int_iq_issue_uop[alu].int_alu_op;
                    alu_regread_q[alu].is_word_op <= int_iq_issue_uop[alu].is_word_op;
                    alu_regread_q[alu].branch_mask <= resolved_branch_mask(
                        int_iq_issue_uop[alu].branch_mask);
                end else if (branch_resolution_i.valid) begin
                    alu_regread_q[alu].branch_mask <= resolved_branch_mask(alu_regread_q[alu].branch_mask);
                end

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

            // BRU结果槽把解析广播与JAL/JALR链接值写回解耦。解析只发一次；
            // 链接值未取得共享写口时，结果槽继续保持并反压Branch流水线。
            if (branch_execute_ready) begin
                branch_result_q <= branch_execute_result;
                branch_result_q.valid <= branch_execute_result.valid
                                      && !killed_by_resolution(branch_execute_result.branch_mask);
                branch_result_q.branch_mask <= resolved_branch_mask(branch_execute_result.branch_mask);
                branch_resolution_sent_q <= 1'b0;
            end else if (branch_resolution_i.valid) begin
                branch_resolution_sent_q <= 1'b1;
            end

            // Branch候选只有同时获得全部所需PRF读口后才从IQ删除并锁存。
            if (branch_resolution_i.valid && branch_resolution_i.mispredict
             && branch_regread_q.branch_mask[branch_resolution_i.branch_tag]) begin
                branch_regread_q.valid <= 1'b0;
            end else if (branch_regread_ready) begin
                branch_regread_q.valid <= branch_read_grant;
                branch_regread_q.instruction_id <= br_iq_issue_uop[0].instruction_id;
                branch_regread_q.rob_idx <= br_iq_issue_uop[0].rob_idx;
                branch_regread_q.ftq_idx <= br_iq_issue_uop[0].ftq_idx;
                branch_regread_q.branch_tag <= br_iq_issue_uop[0].branch_tag;
                branch_regread_q.branch_mask <= resolved_branch_mask(br_iq_issue_uop[0].branch_mask);
                branch_regread_q.pc <= br_iq_issue_uop[0].pc;
                branch_regread_q.inst_len <= br_iq_issue_uop[0].inst_len;
                branch_regread_q.predicted_next_pc <= br_iq_issue_uop[0].predicted_next_pc;
                branch_regread_q.is_branch <= br_iq_issue_uop[0].is_branch;
                branch_regread_q.is_jal <= br_iq_issue_uop[0].is_jal;
                branch_regread_q.is_jalr <= br_iq_issue_uop[0].is_jalr;
                branch_regread_q.branch_cond <= br_iq_issue_uop[0].branch_cond;
                branch_regread_q.src1_value <= br_iq_issue_uop[0].rs1_read_en
                                             ? prf_rd_data[branch_src1_port] : '0;
                branch_regread_q.src2_value <= br_iq_issue_uop[0].rs2_read_en
                                             ? prf_rd_data[branch_src2_port] : '0;
                branch_regread_q.imm_value <= expand_imm_value(
                    br_iq_issue_uop[0].imm_type, br_iq_issue_uop[0].imm_raw);
                branch_regread_q.dst_preg <= br_iq_issue_uop[0].dst_preg;
                branch_regread_q.dst_write_en <= br_iq_issue_uop[0].rd_write_en
                                               && (br_iq_issue_uop[0].rd != '0);
            end else if (branch_resolution_i.valid) begin
                branch_regread_q.branch_mask <= resolved_branch_mask(branch_regread_q.branch_mask);
            end

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

endmodule
