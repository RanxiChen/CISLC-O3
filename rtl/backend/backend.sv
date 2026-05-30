/**
 * 一个统一的后端，后面将会将代码进行拆分
 *
 * 当前已经实现的功能：
 * - 维护一个 fetch-entry buffer，用于承接 frontend 输入
 * - 对 fetch-entry buffer 中的指令做基础解码，并组装成 decoded uop
 * - 接入 decode 后、rename 前的 uop queue，形成前两拍骨架
 * - 在 rename 阶段接入 free list、rename map table 和最小 ROB
 * - 在 backend 内维护最小 preg_ready table，并把 rename 完成后的整数 uop 按 lane 顺序压入单一 integer issue queue
 * - 在 issue queue 内基于 preg_ready table 做最小真实 wakeup
 * - 在 issue queue 内实现按年龄顺序的 select，并把最靠前的 ready uop 发给多个整数 ALU
 * - 在 backend 内接入 3 级整数流水寄存器：issue -> regread -> execute result
 * - 在 regread 阶段根据物理寄存器编号读取 physical_regfile，并对当前 I-type 立即数做 64 位符号扩展
 * - 接入多个 `int_execute_unit`，完成 RV64I R/I 整数算术指令的最小执行链路
 * - 在 execute result 后接入整数 writeback：把结果写回 physical_regfile、更新 preg_ready table、并把对应 ROB 项标记为 complete
 * - 接入最小 3-wide in-order retire：从 ROB 队头连续退休最多 3 条，并把 old_dst_preg 回收到 free list
 * - 维护从 reset 开始累计的 retired instruction counter，按每拍真实退休条数累加
 * - 支持按 MACHINE_WIDTH 参数化并行处理多个 lane
 * - 在 `O3_SIM` 宏下新增逐周期文本日志，按周期块展示 DECODE/RENAME/WAKEUP/ISSUE/REGREAD/EXECUTE/WRITEBACK 阶段
 * - 在 backend 内部为每条被接收的指令生成调试用 instruction_id
 *   - 高位表示“第几批被 backend 接收的 fetch group”
 *   - 低位表示“该组内的 lane 编号”
 * - 统一 x0/p0 语义：x0 固定映射到 p0，p0 在 physical_regfile 中读恒为 0、写忽略
 *
 * 当前没有实现的功能：
 * - 不处理组内依赖、组内覆盖、分支恢复、checkpoint、commit
 * - ROB 当前只做 entry 编号分配、old_dst_preg/exception 存储与 complete 标记，不做提交、回收、恢复
 * - issue queue 当前不接写回旁路广播；本拍写回结果只会在下一拍体现在 wakeup 上
 * - 不实现异常恢复、分支恢复、store 提交等更复杂的 retire/commit 约束
 * - 当前 retire 只覆盖最小整数主链路
 * - done 仍然只是占位信号
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 时序行为：
 * - 周期 N 开始时：
 *   1) fetch_entry_q / fetch_entry_valid_q 保存“上一拍已经接住”的 fetch 组
 *   2) uop_queue 队头保存“上一拍已经解码完成、待 rename”的一组 uop
 *   3) issue_queue 中保存更早已经 rename 完成、等待 wakeup/select 的整数 uop
 *   4) preg_ready_q 保存当前每个物理寄存器是否已经持有可读值
 *   5) ROB 持有当前的队头/队尾、complete 位以及可供 retire 的最老指令
 *   6) alu_issue_q / alu_regread_q / alu_result_q 分别保存前几拍进入整数流水线的 uop
 * - 周期 N 组合阶段：
 *   1) decoder 组合地产生 rs1/rs2/rd、use_imm、imm_type、imm_raw、int_alu_op 和最小 uop 语义
 *   2) rename 阶段从 uop_queue 队头组合读取 alloc_req / rob_req / rename map 结果
 *   3) issue queue 对旧表项做基于 preg_ready_q 的 wakeup 视图，并从前往后选择最靠前的 ready 表项送往可接收的 ALU issue 端口
 *   4) alu_issue_q 当前持有的物理寄存器编号直接驱动 physical_regfile 读端口
 *   5) regread 阶段把 physical_regfile 读值与立即数扩展后的值整理成真正的 src1/src2 操作数
 *   6) int_execute_unit 基于 alu_regread_q 中的真实操作数组合地产生执行结果
 *   7) alu_result_q 当前持有的上一拍执行结果会在本拍作为 writeback 源，同时驱动 preg_ready_q 和 ROB complete 更新
 *   8) ROB 当前会从队头开始连续检查最多 3 项，决定本拍 retire 的前缀长度
 * - 周期 N 上升沿：
 *   1) 若 decode_fire=1，则当前 fetch 组以 decoded uop 形式进入 uop_queue
 *   2) 若 rename_fire=1，则当前 uop_queue 队头这组 uop 完成 rename，并把其中整数 uop 按 lane 顺序压入 issue_queue；其中 rd!=0 的真实目的寄存器会清掉对应 preg_ready
 *   3) issue_queue 把上一拍已经在队列中的表项按 preg_ready 计算出的新 ready 位写回，并删除本拍已经被接受发射的表项
 *   4) 本拍被 select 的整数 uop 进入 alu_issue_q
 *   5) 上一拍的 alu_issue_q 进入 alu_regread_q
 *   6) 上一拍的 alu_regread_q 经执行单元计算后进入 alu_result_q
 *   7) 本拍有效的 alu_result_q 会把执行结果写回 physical_regfile，并把目的 preg 的 ready 位置 1，同时把对应 ROB 项标记为 complete
 *   8) 本拍从 ROB 队头退休的指令会把 old_dst_preg 返还给 free list；这些释放回来的寄存器从下一拍起重新参与分配
 *   9) 若 fetch_fire=1，则同时把 frontend 新送来的指令写入 fetch_entry_q
 * - 周期 N+1：
 *   1) issue_queue 中看到唤醒、压缩补位、追加入队后的新队列内容
 *   2) 刚刚被写回的目的物理寄存器在 preg_ready_q 中表现为 ready，可继续唤醒后继指令
 *   3) alu_issue_q / alu_regread_q / alu_result_q 分别前进一步
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
        parameter int INT_ISSUE_QUEUE_DEPTH = BACKEND_INT_ISSUE_QUEUE_DEPTH,
        parameter int NUM_INT_ALUS = BACKEND_NUM_INT_ALUS
    )
(
    input  logic clk,
    input  logic rst,
    input  fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry_i,
    input  logic                             fetch_valid_i,
    output logic                             fetch_ready_o,
    output branch_redirect_t                 branch_redirect_o,
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
    localparam int INST_ID_LANE_BITS      = (MACHINE_WIDTH <= 1) ? 1 : $clog2(MACHINE_WIDTH);
    localparam int NUM_BRANCH_UNITS       = 1;
    localparam int RETIRE_WIDTH           = NUM_INT_ALUS;
    localparam int COMPLETE_WIDTH         = NUM_INT_ALUS + NUM_BRANCH_UNITS;
    localparam int BRANCH_COMPLETE_PORT   = NUM_INT_ALUS;
    localparam int BRANCH_PRF_RD_BASE     = NUM_INT_ALUS * 2;
    localparam int PRF_READ_PORTS         = (NUM_INT_ALUS * 2) + 2;
    localparam int PRF_WRITE_PORTS        = NUM_INT_ALUS + 1;
    localparam int BRANCH_PRF_WR_PORT     = NUM_INT_ALUS;
    localparam int CHECKPOINT_COUNT       = 4;
    localparam int CHECKPOINT_ID_WIDTH    = (CHECKPOINT_COUNT > 1) ? $clog2(CHECKPOINT_COUNT) : 1;
    localparam int FREE_DEPTH             = NUM_PHYS_REGS - NUM_ARCH_REGS;
    localparam int FREE_PTR_WIDTH         = (FREE_DEPTH > 1) ? $clog2(FREE_DEPTH) : 1;
    localparam int FREE_COUNT_WIDTH       = $clog2(FREE_DEPTH + 1);

    fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry_q;
    logic                             fetch_entry_valid_q;
    logic [INST_ID_WIDTH-1:0]         fetch_instruction_id_q [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]         fetch_instruction_id_d [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]         fetch_group_seq_q;

    decode_in_t    [MACHINE_WIDTH-1:0] decode_in;
    decode_out_t   [MACHINE_WIDTH-1:0] decode_out;
    decoded_uop_t  [MACHINE_WIDTH-1:0] decoded_uop;
    decoded_uop_t  [MACHINE_WIDTH-1:0] rename_uop_head;

    logic decode_valid;
    logic decode_ready;
    logic decode_fire;
    logic rename_valid;
    logic rename_ready;
    logic rename_fire;
    logic alloc_valid;
    logic alloc_ready;
    logic rob_valid;
    logic rob_ready;
    logic uopq_enq_ready;
    logic uopq_deq_valid;
    logic issueq_enq_valid;
    logic issueq_enq_ready;
    logic branch_issueq_enq_valid;
    logic branch_issueq_enq_ready;
    logic fetch_fire;
    logic alloc_req [MACHINE_WIDTH-1:0];
    logic rob_req   [MACHINE_WIDTH-1:0];
    logic rob_exception [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rs1_addr    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rs2_addr    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rename_rd_addr     [MACHINE_WIDTH-1:0];
    logic                      rename_rs1_read_en [MACHINE_WIDTH-1:0];
    logic                      rename_rs2_read_en [MACHINE_WIDTH-1:0];
    logic                      rename_rd_write_en [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]  rob_alloc_instruction_id [MACHINE_WIDTH-1:0];
`ifdef ENABLE_RETIRE_INFO
    logic [PC_WIDTH-1:0]       rob_alloc_pc          [MACHINE_WIDTH-1:0];
    logic [ILEN-1:0]           rob_alloc_instruction [MACHINE_WIDTH-1:0];
    retire_uop_type_t          rob_alloc_uop_type    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0] rob_alloc_rd          [MACHINE_WIDTH-1:0];
    logic                      rob_alloc_rd_write_en [MACHINE_WIDTH-1:0];
    logic [XLEN-1:0]           rob_complete_rd_wdata [COMPLETE_WIDTH-1:0];
    logic                      rob_complete_branch_taken [COMPLETE_WIDTH-1:0];
    logic                      rob_complete_branch_mispredict [COMPLETE_WIDTH-1:0];
    logic [PC_WIDTH-1:0]       rob_complete_branch_target_pc [COMPLETE_WIDTH-1:0];
    logic [PC_WIDTH-1:0]       rob_complete_branch_fallthrough_pc [COMPLETE_WIDTH-1:0];
`endif

    logic [BACKEND_PREG_IDX_WIDTH-1:0] dst_new_preg [MACHINE_WIDTH-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_idx      [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] src1_preg    [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] src2_preg    [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] dst_old_preg [MACHINE_WIDTH-1:0];
    issue_queue_entry_t [MACHINE_WIDTH-1:0] issueq_enq_entry;
    branch_issue_entry_t [MACHINE_WIDTH-1:0] branch_issueq_enq_entry;

    issue_queue_entry_t [NUM_INT_ALUS-1:0] issueq_issue_entry;
    logic               [NUM_INT_ALUS-1:0] issueq_issue_valid;
    logic               [NUM_INT_ALUS-1:0] issueq_issue_ready;
    issue_queue_entry_t [INT_ISSUE_QUEUE_DEPTH-1:0] issueq_wakeup_entry;
    logic               [INT_ISSUE_QUEUE_DEPTH-1:0] issueq_wakeup_valid;

    int_issue_pipe_uop_t    alu_issue_q   [NUM_INT_ALUS-1:0];
    int_regread_pipe_uop_t  alu_regread_q [NUM_INT_ALUS-1:0];
    int_execute_result_t    alu_result_q  [NUM_INT_ALUS-1:0];
    branch_issue_entry_t        branch_issueq_issue_entry;
    logic                       branch_issueq_issue_valid;
    logic                       branch_issueq_issue_ready;
    branch_issue_pipe_uop_t     branch_issue_q;
    branch_regread_pipe_uop_t   branch_regread_q;
    branch_execute_result_t     branch_result_q;

    logic [BACKEND_PREG_IDX_WIDTH-1:0] prf_rd_addr [PRF_READ_PORTS-1:0];
    logic [XLEN-1:0]                   prf_rd_data [PRF_READ_PORTS-1:0];
    logic                              prf_wr_en   [PRF_WRITE_PORTS-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] prf_wr_addr [PRF_WRITE_PORTS-1:0];
    logic [XLEN-1:0]                   prf_wr_data [PRF_WRITE_PORTS-1:0];

    logic                              exec_valid   [NUM_INT_ALUS-1:0];
    logic [XLEN-1:0]                   exec_result  [NUM_INT_ALUS-1:0];
    logic                              exec_cmp_true[NUM_INT_ALUS-1:0];
    logic                              branch_exec_valid;
    logic                              branch_exec_taken;
    logic                              branch_exec_mispredict;
    logic [PC_WIDTH-1:0]               branch_exec_target_pc;
    logic [PC_WIDTH-1:0]               branch_exec_fallthrough_pc;
    logic [BACKEND_PREG_IDX_WIDTH-1:0] branch_exec_dst_preg;
    logic                              branch_exec_dst_write_en;
    logic [XLEN-1:0]                   branch_exec_rd_wdata;
    logic                              preg_ready_q [NUM_PHYS_REGS-1:0];
    logic                              rob_complete_valid [COMPLETE_WIDTH-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_complete_idx   [COMPLETE_WIDTH-1:0];
    logic                              rob_retire_valid   [RETIRE_WIDTH-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_retire_idx     [RETIRE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] rob_retire_old_dst_preg [RETIRE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]          rob_retire_instruction_id [RETIRE_WIDTH-1:0];
    logic                              rob_retire_any;
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_head;
    logic                              branch_squash_valid;
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  branch_squash_rob_idx;
    logic [FTQ_INDEX_WIDTH-1:0]        branch_squash_ftq_idx;
    logic [PC_WIDTH-1:0]               branch_squash_pc;
    logic [PC_WIDTH-1:0]               branch_squash_target_pc;
    logic [PC_WIDTH-1:0]               branch_squash_fallthrough_pc;
    logic                              decode_queue_flush;
    logic                              int_issue_queue_flush;
    logic                              branch_issue_queue_flush;
    logic                              rename_recover_valid;
    logic [BACKEND_PREG_IDX_WIDTH-1:0] rename_recover_map [NUM_ARCH_REGS-1:0];
    logic                              free_list_recover_valid;
    logic [FREE_PTR_WIDTH-1:0]         free_list_recover_head;
    logic [FREE_PTR_WIDTH-1:0]         free_list_recover_tail;
    logic [FREE_COUNT_WIDTH-1:0]       free_list_recover_count;
    logic [FREE_PTR_WIDTH-1:0]         free_list_head;
    logic [FREE_PTR_WIDTH-1:0]         free_list_tail;
    logic [FREE_COUNT_WIDTH-1:0]       free_list_count;
    logic [BACKEND_PREG_IDX_WIDTH-1:0] rename_map_current [NUM_ARCH_REGS-1:0];
    logic                              filtered_retire_valid [RETIRE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] filtered_retire_preg [RETIRE_WIDTH-1:0];
    logic                              checkpoint_valid_q [CHECKPOINT_COUNT-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  checkpoint_branch_rob_idx_q [CHECKPOINT_COUNT-1:0];
    logic [PC_WIDTH-1:0]               checkpoint_branch_pc_q [CHECKPOINT_COUNT-1:0];
    logic [FREE_PTR_WIDTH-1:0]         checkpoint_free_head_q [CHECKPOINT_COUNT-1:0];
    logic [FREE_PTR_WIDTH-1:0]         checkpoint_free_tail_q [CHECKPOINT_COUNT-1:0];
    logic [FREE_COUNT_WIDTH-1:0]       checkpoint_free_count_q [CHECKPOINT_COUNT-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] checkpoint_rename_map_q [CHECKPOINT_COUNT-1:0][NUM_ARCH_REGS-1:0];
    logic                              rob_has_checkpoint_q [NUM_ROB_ENTRIES-1:0];
    logic [CHECKPOINT_ID_WIDTH-1:0]    rob_checkpoint_id_q [NUM_ROB_ENTRIES-1:0];
    logic                              checkpoint_alloc_en;
    logic [CHECKPOINT_ID_WIDTH-1:0]    checkpoint_alloc_id;
    logic                              checkpoint_alloc_found;
    logic [MACHINE_WIDTH-1:0]          rename_branch_req;
    logic [$clog2(MACHINE_WIDTH+1)-1:0] rename_branch_count;
    logic                              rename_checkpoint_hazard;
    logic                              mispredict_has_checkpoint;
    logic [CHECKPOINT_ID_WIDTH-1:0]    mispredict_checkpoint_id;

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
    logic [1:0]  retire_count_this_cycle;

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

    function automatic logic [XLEN-1:0] expand_imm_value(
        input imm_type_t                imm_type,
        input logic [IMM_RAW_WIDTH-1:0] imm_raw
    );
        logic signed [XLEN-1:0] imm_sext;
        begin
            imm_sext = '0;
            unique case (imm_type)
                IMM_TYPE_I: imm_sext = XLEN'($signed({{(XLEN-12){imm_raw[11]}}, imm_raw[11:0]}));
                IMM_TYPE_B: imm_sext = XLEN'($signed({{(XLEN-13){imm_raw[12]}}, imm_raw[12:0]}));
                IMM_TYPE_U: imm_sext = XLEN'($signed({{(XLEN-32){imm_raw[19]}}, imm_raw[19:0], 12'b0}));
                IMM_TYPE_J: imm_sext = XLEN'($signed({{(XLEN-21){imm_raw[20]}}, imm_raw[20:0]}));
                default:    imm_sext = '0;
            endcase
            expand_imm_value = imm_sext;
        end
    endfunction

    function automatic logic src_depends_on_older_lane(
        input int unsigned              lane_idx,
        input logic [REG_ADDR_WIDTH-1:0] src_arch,
        input logic                      src_read_en
    );
        begin
            src_depends_on_older_lane = 1'b0;
            if (src_read_en) begin
                for (int older = 0; older < MACHINE_WIDTH; older++) begin
                    if (older < int'(lane_idx)
                     && rename_uop_head[older].valid
                     && rename_uop_head[older].rd_write_en
                     && (rename_uop_head[older].rd != REG_ADDR_WIDTH'(0))
                     && (rename_uop_head[older].rd == src_arch)) begin
                        src_depends_on_older_lane = 1'b1;
                    end
                end
            end
        end
    endfunction

    function automatic logic rob_is_older_or_same(
        input logic [BACKEND_ROB_IDX_WIDTH-1:0] candidate,
        input logic [BACKEND_ROB_IDX_WIDTH-1:0] branch_idx,
        input logic [BACKEND_ROB_IDX_WIDTH-1:0] head_idx
    );
        int unsigned cand_age;
        int unsigned branch_age;
        begin
            cand_age = (int'(candidate) + NUM_ROB_ENTRIES - int'(head_idx)) % NUM_ROB_ENTRIES;
            branch_age = (int'(branch_idx) + NUM_ROB_ENTRIES - int'(head_idx)) % NUM_ROB_ENTRIES;
            rob_is_older_or_same = (cand_age <= branch_age);
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
                IMM_TYPE_B:    imm_type_name = "B";
                IMM_TYPE_U:    imm_type_name = "U";
                IMM_TYPE_J:    imm_type_name = "J";
                default:       imm_type_name = "UNK";
            endcase
        end
    endfunction

    function automatic string branch_op_name(input branch_op_t op);
        begin
            unique case (op)
                BRANCH_OP_BEQ:  branch_op_name = "BEQ";
                BRANCH_OP_BNE:  branch_op_name = "BNE";
                BRANCH_OP_BLT:  branch_op_name = "BLT";
                BRANCH_OP_BGE:  branch_op_name = "BGE";
                BRANCH_OP_BLTU: branch_op_name = "BLTU";
                BRANCH_OP_BGEU: branch_op_name = "BGEU";
                BRANCH_OP_JAL:  branch_op_name = "JAL";
                BRANCH_OP_JALR: branch_op_name = "JALR";
                default:        branch_op_name = "BR_UNK";
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
            assign decoded_uop[i].valid          = decode_valid && fetch_entry_q[i].valid;
            assign decoded_uop[i].instruction_id = fetch_instruction_id_q[i];
`ifdef O3_SIM
            assign decoded_uop[i].kanata_id      = kanata_id_counter_q + 64'(i);
`endif
            assign decoded_uop[i].pc             = fetch_entry_q[i].pc;
            assign decoded_uop[i].ftq_idx        = fetch_entry_q[i].ftq_idx;
            assign decoded_uop[i].instruction    = fetch_entry_q[i].instruction;
            assign decoded_uop[i].exception      = fetch_entry_q[i].fetch_addr_misaligned
                                                 || fetch_entry_q[i].fetch_access_fault;
            assign decoded_uop[i].rs1            = decode_out[i].rs1;
            assign decoded_uop[i].rs2            = decode_out[i].rs2;
            assign decoded_uop[i].rd             = decode_out[i].rd;
            assign decoded_uop[i].rs1_read_en    = decode_out[i].rs1_read_en;
            assign decoded_uop[i].rs2_read_en    = decode_out[i].rs2_read_en;
            assign decoded_uop[i].rd_write_en    = decode_out[i].rd_write_en;
            assign decoded_uop[i].use_imm        = decode_out[i].use_imm;
            assign decoded_uop[i].imm_type       = decode_out[i].imm_type;
            assign decoded_uop[i].imm_raw        = decode_out[i].imm_raw;
            assign decoded_uop[i].int_alu_op     = decode_out[i].int_alu_op;
            assign decoded_uop[i].branch_op      = decode_out[i].branch_op;
            assign decoded_uop[i].is_int_uop     = decode_out[i].is_int_uop;
            assign decoded_uop[i].is_branch_uop  = decode_out[i].is_branch_uop;
            assign decoded_uop[i].illegal_uop    = decode_out[i].illegal_uop;
            assign decoded_uop[i].src1_sel       = decode_out[i].src1_sel;
        end
    endgenerate

    generate
        for (i = 0; i < MACHINE_WIDTH; i++) begin : rename_req_assign
            logic dst_write_real;

            assign fetch_instruction_id_d[i] = make_instruction_id(fetch_group_seq_q, i);
            assign rename_rs1_addr[i]        = rename_uop_head[i].rs1;
            assign rename_rs2_addr[i]        = rename_uop_head[i].rs2;
            assign rename_rd_addr[i]         = rename_uop_head[i].rd;
            assign rename_rs1_read_en[i]     = rename_uop_head[i].rs1_read_en;
            assign rename_rs2_read_en[i]     = rename_uop_head[i].rs2_read_en;
            assign rename_rd_write_en[i]     = rename_uop_head[i].rd_write_en;
            assign dst_write_real            = rename_uop_head[i].valid
                                            && rename_uop_head[i].rd_write_en
                                            && (rename_uop_head[i].rd != REG_ADDR_WIDTH'(0));

            // 只有 rd!=x0 的真实目的写才会消耗新的物理寄存器资源。
            assign alloc_req[i] = dst_write_real;

            assign rob_req[i]       = rename_uop_head[i].valid;
            assign rob_exception[i] = rename_uop_head[i].exception || rename_uop_head[i].illegal_uop;
            assign rob_alloc_instruction_id[i] = rename_uop_head[i].instruction_id;
`ifdef ENABLE_RETIRE_INFO
            assign rob_alloc_pc[i]          = rename_uop_head[i].pc;
            assign rob_alloc_instruction[i] = rename_uop_head[i].instruction;
            assign rob_alloc_uop_type[i]    = rename_uop_head[i].is_int_uop
                                            ? RETIRE_UOP_INT
                                            : (rename_uop_head[i].is_branch_uop
                                                ? RETIRE_UOP_BRANCH
                                                : RETIRE_UOP_OTHER);
            assign rob_alloc_rd[i]          = dst_write_real ? rename_uop_head[i].rd : REG_ADDR_WIDTH'(0);
            assign rob_alloc_rd_write_en[i] = dst_write_real;
`endif

            assign issueq_enq_entry[i].valid        = rename_uop_head[i].valid && rename_uop_head[i].is_int_uop;
            assign issueq_enq_entry[i].instruction_id = rename_uop_head[i].instruction_id;
`ifdef O3_SIM
            assign issueq_enq_entry[i].kanata_id    = rename_uop_head[i].kanata_id;
`endif
            assign issueq_enq_entry[i].src1_preg    = src1_preg[i];
            assign issueq_enq_entry[i].src2_preg    = src2_preg[i];
            assign issueq_enq_entry[i].src1_valid   = rename_uop_head[i].rs1_read_en;
            assign issueq_enq_entry[i].src2_valid   = rename_uop_head[i].rs2_read_en;
            // x0 固定映射到 p0，而 p0 的 ready 恒为 1。
            // 因此源操作数的 ready 初值只取决于“是否真的读取”以及当前 preg_ready 状态。
            assign issueq_enq_entry[i].src1_ready   = !rename_uop_head[i].rs1_read_en
                                                   || (preg_ready_q[src1_preg[i]]
                                                    && !src_depends_on_older_lane(i, rename_uop_head[i].rs1, rename_uop_head[i].rs1_read_en));
            assign issueq_enq_entry[i].src2_ready   = (!rename_uop_head[i].rs2_read_en)
                                                   || rename_uop_head[i].use_imm
                                                   || (preg_ready_q[src2_preg[i]]
                                                    && !src_depends_on_older_lane(i, rename_uop_head[i].rs2, rename_uop_head[i].rs2_read_en));
            assign issueq_enq_entry[i].rob_idx      = rob_idx[i];
            assign issueq_enq_entry[i].dst_preg     = dst_write_real ? dst_new_preg[i] : BACKEND_PREG_IDX_WIDTH'(0);
            assign issueq_enq_entry[i].dst_write_en = dst_write_real;
            assign issueq_enq_entry[i].imm_raw      = rename_uop_head[i].imm_raw;
            assign issueq_enq_entry[i].imm_valid    = rename_uop_head[i].use_imm;
            assign issueq_enq_entry[i].imm_type     = rename_uop_head[i].imm_type;
            assign issueq_enq_entry[i].int_alu_op   = rename_uop_head[i].int_alu_op;
            assign issueq_enq_entry[i].pc            = rename_uop_head[i].pc;
            assign issueq_enq_entry[i].src1_sel      = rename_uop_head[i].src1_sel;

            assign branch_issueq_enq_entry[i].valid = rename_uop_head[i].valid
                                                    && rename_uop_head[i].is_branch_uop;
            assign branch_issueq_enq_entry[i].instruction_id = rename_uop_head[i].instruction_id;
`ifdef O3_SIM
            assign branch_issueq_enq_entry[i].kanata_id = rename_uop_head[i].kanata_id;
`endif
            assign branch_issueq_enq_entry[i].pc         = rename_uop_head[i].pc;
            assign branch_issueq_enq_entry[i].ftq_idx    = rename_uop_head[i].ftq_idx;
            assign branch_issueq_enq_entry[i].src1_preg  = src1_preg[i];
            assign branch_issueq_enq_entry[i].src2_preg  = src2_preg[i];
            assign branch_issueq_enq_entry[i].src1_ready = preg_ready_q[src1_preg[i]]
                                                        && !src_depends_on_older_lane(i, rename_uop_head[i].rs1, rename_uop_head[i].rs1_read_en);
            assign branch_issueq_enq_entry[i].src2_ready = preg_ready_q[src2_preg[i]]
                                                        && !src_depends_on_older_lane(i, rename_uop_head[i].rs2, rename_uop_head[i].rs2_read_en);
            assign branch_issueq_enq_entry[i].rob_idx    = rob_idx[i];
            assign branch_issueq_enq_entry[i].imm_raw    = rename_uop_head[i].imm_raw;
            assign branch_issueq_enq_entry[i].imm_type   = rename_uop_head[i].imm_type;
            assign branch_issueq_enq_entry[i].branch_op  = rename_uop_head[i].branch_op;
            assign branch_issueq_enq_entry[i].dst_preg     = dst_write_real ? dst_new_preg[i] : BACKEND_PREG_IDX_WIDTH'(0);
            assign branch_issueq_enq_entry[i].dst_write_en = dst_write_real;
            assign rename_branch_req[i]                  = rename_uop_head[i].valid
                                                        && rename_uop_head[i].is_branch_uop;
        end
    endgenerate

    always_comb begin
        rename_branch_count = '0;
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            if (rename_branch_req[lane]) begin
                rename_branch_count = rename_branch_count + $clog2(MACHINE_WIDTH+1)'(1);
            end
        end
    end

    assign decode_ready    = uopq_enq_ready && !branch_squash_valid;
    assign decode_fire     = decode_valid && decode_ready;
    assign fetch_ready_o   = (((!fetch_entry_valid_q) || decode_ready) && !branch_squash_valid);
    assign fetch_fire      = fetch_valid_i && fetch_ready_o;
    assign rename_valid    = uopq_deq_valid;
    assign rename_checkpoint_hazard = (rename_branch_count > $clog2(MACHINE_WIDTH+1)'(1))
                                   || ((rename_branch_count != '0) && !checkpoint_alloc_found);
    assign issueq_enq_valid = rename_valid && alloc_valid && rob_valid && branch_issueq_enq_ready && !rename_checkpoint_hazard && !branch_squash_valid;
    assign branch_issueq_enq_valid = rename_valid && alloc_valid && rob_valid && issueq_enq_ready && !rename_checkpoint_hazard && !branch_squash_valid;
    assign rename_ready    = alloc_valid && rob_valid && issueq_enq_ready && branch_issueq_enq_ready && !rename_checkpoint_hazard && !branch_squash_valid;
    assign rename_fire     = rename_valid && rename_ready;
    assign alloc_ready     = rename_valid && rob_valid && issueq_enq_ready && branch_issueq_enq_ready && !rename_checkpoint_hazard && !branch_squash_valid;
    assign rob_ready       = rename_valid && alloc_valid && issueq_enq_ready && branch_issueq_enq_ready && !rename_checkpoint_hazard && !branch_squash_valid;
    assign done            = 1'b0;
    assign issueq_issue_ready = '1;
    assign branch_issueq_issue_ready = 1'b1;
    assign retired_inst_count_o = retired_inst_count_q;

`ifdef O3_SIM_SINGLE_INST_TRACE
    assign single_inst_retired_o = single_trace_done_q;
`endif

    generate
        for (i = 0; i < NUM_INT_ALUS; i++) begin : prf_read_addr_assign
            assign prf_rd_addr[(2*i)+0] = alu_issue_q[i].src1_preg;
            assign prf_rd_addr[(2*i)+1] = alu_issue_q[i].src2_preg;
        end
    endgenerate

    assign prf_rd_addr[BRANCH_PRF_RD_BASE + 0] = branch_issue_q.src1_preg;
    assign prf_rd_addr[BRANCH_PRF_RD_BASE + 1] = branch_issue_q.src2_preg;

    generate
        for (i = 0; i < NUM_INT_ALUS; i++) begin : prf_writeback_assign
            logic wb_survives;
            assign wb_survives = !branch_squash_valid
                              || rob_is_older_or_same(alu_result_q[i].rob_idx, branch_squash_rob_idx, rob_head);
            // `alu_result_q` 是 execute 后、writeback 前的过渡寄存器。
            // 只有真正带目的寄存器的新版本才会写回 PRF；rd=x0 的指令虽然会 complete，但不会写回。
            assign prf_wr_en[i]   = alu_result_q[i].valid && alu_result_q[i].dst_write_en && wb_survives;
            assign prf_wr_addr[i] = alu_result_q[i].dst_preg;
            assign prf_wr_data[i] = alu_result_q[i].result;

            // ROB complete 跟“是否真正写回 PRF”不是一回事。
            // 即使 rd=x0，没有目的寄存器写回，这条整数指令执行完成后也应标记 complete。
            assign rob_complete_valid[i] = alu_result_q[i].valid && wb_survives;
            assign rob_complete_idx[i]   = alu_result_q[i].rob_idx;
`ifdef ENABLE_RETIRE_INFO
            assign rob_complete_rd_wdata[i] = alu_result_q[i].result;
            assign rob_complete_branch_taken[i] = 1'b0;
            assign rob_complete_branch_mispredict[i] = 1'b0;
            assign rob_complete_branch_target_pc[i] = '0;
            assign rob_complete_branch_fallthrough_pc[i] = '0;
`endif
        end
    endgenerate

    logic branch_wb_survives;
    assign branch_wb_survives = !branch_squash_valid
                             || rob_is_older_or_same(branch_result_q.rob_idx, branch_squash_rob_idx, rob_head);

    assign rob_complete_valid[BRANCH_COMPLETE_PORT] = branch_result_q.valid && branch_wb_survives;
    assign rob_complete_idx[BRANCH_COMPLETE_PORT]   = branch_result_q.rob_idx;
`ifdef ENABLE_RETIRE_INFO
    assign rob_complete_rd_wdata[BRANCH_COMPLETE_PORT] = branch_result_q.rd_wdata;
    assign rob_complete_branch_taken[BRANCH_COMPLETE_PORT] = branch_result_q.taken;
    assign rob_complete_branch_mispredict[BRANCH_COMPLETE_PORT] = branch_result_q.mispredict;
    assign rob_complete_branch_target_pc[BRANCH_COMPLETE_PORT] = branch_result_q.target_pc;
    assign rob_complete_branch_fallthrough_pc[BRANCH_COMPLETE_PORT] = branch_result_q.fallthrough_pc;
`endif

    assign prf_wr_en[BRANCH_PRF_WR_PORT]   = branch_result_q.valid && branch_result_q.dst_write_en && branch_wb_survives;
    assign prf_wr_addr[BRANCH_PRF_WR_PORT] = branch_result_q.dst_preg;
    assign prf_wr_data[BRANCH_PRF_WR_PORT] = branch_result_q.rd_wdata;

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
                retire_count_this_cycle = retire_count_this_cycle + 2'd1;
            end
        end

        retired_inst_count_next = retired_inst_count_q + 64'(retire_count_this_cycle);
    end

    always_comb begin
        checkpoint_alloc_found = 1'b0;
        checkpoint_alloc_id = '0;
        for (int ckpt = 0; ckpt < CHECKPOINT_COUNT; ckpt++) begin
            if (!checkpoint_valid_q[ckpt] && !checkpoint_alloc_found) begin
                checkpoint_alloc_found = 1'b1;
                checkpoint_alloc_id = CHECKPOINT_ID_WIDTH'(ckpt);
            end
        end
    end

    assign checkpoint_alloc_en = rename_fire && (rename_branch_count == $clog2(MACHINE_WIDTH+1)'(1));

    assign branch_squash_valid = branch_result_q.valid && branch_result_q.mispredict;
    assign branch_squash_rob_idx = branch_result_q.rob_idx;
    assign branch_squash_ftq_idx = branch_result_q.ftq_idx;
    assign branch_squash_pc = branch_result_q.pc;
    assign branch_squash_target_pc = branch_result_q.target_pc;
    assign branch_squash_fallthrough_pc = branch_result_q.fallthrough_pc;
    assign mispredict_has_checkpoint = rob_has_checkpoint_q[branch_squash_rob_idx];
    assign mispredict_checkpoint_id = rob_checkpoint_id_q[branch_squash_rob_idx];

    always_comb begin
        for (int port = 0; port < RETIRE_WIDTH; port++) begin
            filtered_retire_valid[port] = rob_retire_valid[port]
                                       && (rob_retire_old_dst_preg[port] != '0)
                                       && (!branch_squash_valid
                                        || rob_is_older_or_same(rob_retire_idx[port], branch_squash_rob_idx, rob_head));
            filtered_retire_preg[port]  = rob_retire_old_dst_preg[port];
        end
    end

    assign decode_queue_flush = branch_squash_valid;
    assign int_issue_queue_flush = 1'b0;
    assign branch_issue_queue_flush = 1'b0;
    assign rename_recover_valid = branch_squash_valid && mispredict_has_checkpoint;
    assign free_list_recover_valid = branch_squash_valid && mispredict_has_checkpoint;

    always_comb begin
        for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
            rename_recover_map[arch] = '0;
            if (mispredict_has_checkpoint) begin
                rename_recover_map[arch] = checkpoint_rename_map_q[mispredict_checkpoint_id][arch];
            end
        end

        free_list_recover_head = '0;
        free_list_recover_tail = '0;
        free_list_recover_count = '0;
        if (mispredict_has_checkpoint) begin
            free_list_recover_head = checkpoint_free_head_q[mispredict_checkpoint_id];
            free_list_recover_tail = checkpoint_free_tail_q[mispredict_checkpoint_id];
            free_list_recover_count = checkpoint_free_count_q[mispredict_checkpoint_id];
        end
    end

    always_comb begin
        branch_redirect_o = '0;
        branch_redirect_o.valid = branch_squash_valid;
        branch_redirect_o.ftq_idx = branch_squash_ftq_idx;
        branch_redirect_o.branch_pc = branch_squash_pc;
        branch_redirect_o.redirect_pc = branch_squash_target_pc;
        branch_redirect_o.actual_taken = branch_result_q.taken;
        branch_redirect_o.fallthrough_pc = branch_squash_fallthrough_pc;
    end

    uop_queue #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .DEPTH(DECODE_QUEUE_DEPTH)
    ) u_decode_queue (
        .clk(clk),
        .rst(rst),
        .flush_i(decode_queue_flush),
        .enq_uop_i(decoded_uop),
        .enq_valid_i(decode_valid),
        .enq_ready_o(uopq_enq_ready),
        .deq_uop_o(rename_uop_head),
        .deq_valid_o(uopq_deq_valid),
        .deq_ready_i(rename_ready)
    );

    free_list #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .NUM_ARCH_REGS(NUM_ARCH_REGS),
        .RELEASE_WIDTH(RETIRE_WIDTH)
    ) u_free_list (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(alloc_req),
        .alloc_ready_i(alloc_ready),
        .alloc_valid_o(alloc_valid),
        .alloc_preg_o(dst_new_preg),
        .release_valid_i(filtered_retire_valid),
        .release_preg_i(filtered_retire_preg),
        .recover_valid_i(free_list_recover_valid),
        .recover_head_i(free_list_recover_head),
        .recover_tail_i(free_list_recover_tail),
        .recover_count_i(free_list_recover_count),
        .head_o(free_list_head),
        .tail_o(free_list_tail),
        .count_o(free_list_count)
    );

    rob #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES),
        .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .COMPLETE_WIDTH(COMPLETE_WIDTH),
        .RETIRE_WIDTH(RETIRE_WIDTH)
    ) u_rob (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(rob_req),
        .alloc_exception_i(rob_exception),
        .alloc_old_dst_preg_i(dst_old_preg),
        .alloc_instruction_id_i(rob_alloc_instruction_id),
`ifdef ENABLE_RETIRE_INFO
        .alloc_pc_i(rob_alloc_pc),
        .alloc_instruction_i(rob_alloc_instruction),
        .alloc_uop_type_i(rob_alloc_uop_type),
        .alloc_rd_i(rob_alloc_rd),
        .alloc_rd_write_en_i(rob_alloc_rd_write_en),
`endif
        .alloc_ready_i(rob_ready),
        .squash_valid_i(branch_squash_valid),
        .squash_branch_idx_i(branch_squash_rob_idx),
        .complete_valid_i(rob_complete_valid),
        .complete_idx_i(rob_complete_idx),
`ifdef ENABLE_RETIRE_INFO
        .complete_rd_wdata_i(rob_complete_rd_wdata),
        .complete_branch_taken_i(rob_complete_branch_taken),
        .complete_branch_mispredict_i(rob_complete_branch_mispredict),
        .complete_branch_target_pc_i(rob_complete_branch_target_pc),
        .complete_branch_fallthrough_pc_i(rob_complete_branch_fallthrough_pc),
`endif
        .alloc_valid_o(rob_valid),
        .alloc_idx_o(rob_idx),
        .retire_valid_o(rob_retire_valid),
        .retire_idx_o(rob_retire_idx),
        .retire_old_dst_preg_o(rob_retire_old_dst_preg),
        .retire_instruction_id_o(rob_retire_instruction_id),
        .head_o(rob_head)
`ifdef ENABLE_RETIRE_INFO
        ,.retire_info_o(retire_info_o)
`endif
    );

    rename_map_table #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_ARCH_REGS(NUM_ARCH_REGS),
        .NUM_PHYS_REGS(NUM_PHYS_REGS)
    ) u_rename_map_table (
        .clk(clk),
        .rst(rst),
        .rename_fire_i(rename_fire),
        .rs1_addr_i(rename_rs1_addr),
        .rs2_addr_i(rename_rs2_addr),
        .rd_addr_i(rename_rd_addr),
        .lane_valid_i(rob_req),
        .rs1_read_en_i(rename_rs1_read_en),
        .rs2_read_en_i(rename_rs2_read_en),
        .rd_write_en_i(rename_rd_write_en),
        .new_dst_preg_i(dst_new_preg),
        .recover_valid_i(rename_recover_valid),
        .recover_map_i(rename_recover_map),
        .src1_preg_o(src1_preg),
        .src2_preg_o(src2_preg),
        .old_dst_preg_o(dst_old_preg),
        .current_map_o(rename_map_current)
    );

    issue_queue #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .ISSUE_WIDTH(NUM_INT_ALUS),
        .DEPTH(INT_ISSUE_QUEUE_DEPTH),
        .NUM_PHYS_REGS(NUM_PHYS_REGS)
    ) u_int_issue_queue (
        .clk(clk),
        .rst(rst),
        .flush_i(int_issue_queue_flush),
        .squash_valid_i(branch_squash_valid),
        .squash_branch_idx_i(branch_squash_rob_idx),
        .rob_head_i(rob_head),
        .enq_entry_i(issueq_enq_entry),
        .enq_valid_i(issueq_enq_valid),
        .enq_ready_o(issueq_enq_ready),
        .preg_ready_i(preg_ready_q),
        .issue_entry_o(issueq_issue_entry),
        .issue_valid_o(issueq_issue_valid),
        .issue_ready_i(issueq_issue_ready),
        .wakeup_entry_o(issueq_wakeup_entry),
        .wakeup_valid_o(issueq_wakeup_valid)
    );

    branch_issue_queue #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .DEPTH(4),
        .NUM_PHYS_REGS(NUM_PHYS_REGS)
    ) u_branch_issue_queue (
        .clk(clk),
        .rst(rst),
        .flush_i(branch_issue_queue_flush),
        .squash_valid_i(branch_squash_valid),
        .squash_branch_idx_i(branch_squash_rob_idx),
        .rob_head_i(rob_head),
        .enq_entry_i(branch_issueq_enq_entry),
        .enq_valid_i(branch_issueq_enq_valid),
        .enq_ready_o(branch_issueq_enq_ready),
        .preg_ready_i(preg_ready_q),
        .issue_entry_o(branch_issueq_issue_entry),
        .issue_valid_o(branch_issueq_issue_valid),
        .issue_ready_i(branch_issueq_issue_ready)
    );

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
                .imm_value_i('0),
                .use_imm_i(1'b0),
                .is_word_op_i(1'b0),
                .valid_o(exec_valid[i]),
                .result_o(exec_result[i]),
                .cmp_true_o(exec_cmp_true[i])
            );
        end
    endgenerate

    branch_execute_unit u_branch_execute_unit (
        .valid_i(branch_regread_q.valid),
        .branch_op_i(branch_regread_q.branch_op),
        .pc_i(branch_regread_q.pc),
        .src1_value_i(branch_regread_q.src1_value),
        .src2_value_i(branch_regread_q.src2_value),
        .imm_value_i(branch_regread_q.imm_value),
        .dst_preg_i(branch_regread_q.dst_preg),
        .dst_write_en_i(branch_regread_q.dst_write_en),
        .valid_o(branch_exec_valid),
        .taken_o(branch_exec_taken),
        .mispredict_o(branch_exec_mispredict),
        .target_pc_o(branch_exec_target_pc),
        .fallthrough_pc_o(branch_exec_fallthrough_pc),
        .dst_preg_o(branch_exec_dst_preg),
        .dst_write_en_o(branch_exec_dst_write_en),
        .rd_wdata_o(branch_exec_rd_wdata)
    );

// ============================================================
// Intermediate rename map state before each lane's rename.
// Captures the map_table_next state after lanes 0..lane-1 apply
// their updates, used by checkpoint allocation when a branch
// is not at lane 0.  Without this, a checkpoint on lane 3 would
// capture pre-rename mappings (map_table_q = rename_map_current)
// and miss lanes 0-2's rename, corrupting recovery.
// ============================================================
logic [BACKEND_PREG_IDX_WIDTH-1:0] rename_map_before_lane [MACHINE_WIDTH][NUM_ARCH_REGS-1:0];
logic [FREE_COUNT_WIDTH-1:0] alloc_req_count_before_lane [MACHINE_WIDTH];

always_comb begin
    for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
        rename_map_before_lane[0][arch] = rename_map_current[arch];
    end
    alloc_req_count_before_lane[0] = '0;

    for (int lane = 1; lane < MACHINE_WIDTH; lane++) begin
        for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
            rename_map_before_lane[lane][arch] = rename_map_before_lane[lane-1][arch];
        end
        alloc_req_count_before_lane[lane] = alloc_req_count_before_lane[lane-1];

        if (alloc_req[lane-1]) begin
            rename_map_before_lane[lane][rename_uop_head[lane-1].rd] = dst_new_preg[lane-1];
            alloc_req_count_before_lane[lane] = alloc_req_count_before_lane[lane] + FREE_COUNT_WIDTH'(1);
        end
    end
end

    always_ff @(posedge clk) begin
        if (rst) begin
            fetch_entry_q          <= '0;
            fetch_entry_valid_q    <= 1'b0;
            fetch_instruction_id_q <= '{default: '0};
            fetch_group_seq_q      <= '0;
            alu_issue_q            <= '{default: '0};
            alu_regread_q          <= '{default: '0};
            alu_result_q           <= '{default: '0};
            branch_issue_q         <= '0;
            branch_regread_q       <= '0;
            branch_result_q        <= '0;
            retired_inst_count_q   <= 64'd0;
            for (int preg = 0; preg < NUM_PHYS_REGS; preg++) begin
                preg_ready_q[preg] <= (preg < NUM_ARCH_REGS);
            end
            for (int ckpt = 0; ckpt < CHECKPOINT_COUNT; ckpt++) begin
                checkpoint_valid_q[ckpt] <= 1'b0;
                checkpoint_branch_rob_idx_q[ckpt] <= '0;
                checkpoint_branch_pc_q[ckpt] <= '0;
                checkpoint_free_head_q[ckpt] <= '0;
                checkpoint_free_tail_q[ckpt] <= '0;
                checkpoint_free_count_q[ckpt] <= '0;
                for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
                    checkpoint_rename_map_q[ckpt][arch] <= BACKEND_PREG_IDX_WIDTH'(arch);
                end
            end
            for (int entry = 0; entry < NUM_ROB_ENTRIES; entry++) begin
                rob_has_checkpoint_q[entry] <= 1'b0;
                rob_checkpoint_id_q[entry] <= '0;
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
            if (rename_valid && (rename_branch_count > $clog2(MACHINE_WIDTH+1)'(1))) begin
                $error("backend only supports at most one branch checkpoint allocation per rename group");
            end

            if (branch_squash_valid && mispredict_has_checkpoint) begin
                checkpoint_valid_q[mispredict_checkpoint_id] <= 1'b0;
                rob_has_checkpoint_q[branch_squash_rob_idx] <= 1'b0;
            end

            for (int port = 0; port < RETIRE_WIDTH; port++) begin
                if (rob_retire_valid[port] && rob_has_checkpoint_q[rob_retire_idx[port]]) begin
                    checkpoint_valid_q[rob_checkpoint_id_q[rob_retire_idx[port]]] <= 1'b0;
                    rob_has_checkpoint_q[rob_retire_idx[port]] <= 1'b0;
                end
            end

            if (checkpoint_alloc_en) begin
                checkpoint_valid_q[checkpoint_alloc_id] <= 1'b1;
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (rename_branch_req[lane]) begin
                        checkpoint_branch_rob_idx_q[checkpoint_alloc_id] <= rob_idx[lane];
                        checkpoint_branch_pc_q[checkpoint_alloc_id] <= rename_uop_head[lane].pc;
                        // Save intermediate free list state reflecting alloc_req
                        // consumption from lanes before this branch lane.
                        checkpoint_free_head_q[checkpoint_alloc_id] <= FREE_PTR_WIDTH'((free_list_head + alloc_req_count_before_lane[lane]) % FREE_DEPTH);
                        checkpoint_free_tail_q[checkpoint_alloc_id] <= free_list_tail;
                        checkpoint_free_count_q[checkpoint_alloc_id] <= free_list_count - alloc_req_count_before_lane[lane];
                        // Save intermediate rename map state after older
                        // lanes have applied their updates but before this
                        // branch lane.
                        for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
                            checkpoint_rename_map_q[checkpoint_alloc_id][arch] <= rename_map_before_lane[lane][arch];
                        end
                        rob_has_checkpoint_q[rob_idx[lane]] <= 1'b1;
                        rob_checkpoint_id_q[rob_idx[lane]] <= checkpoint_alloc_id;
                    end
                end
            end

`ifdef O3_SIM
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
                    if (rename_uop_head[lane].valid) begin
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

            if (branch_result_q.valid && (kanata_fd != 0)) begin
                $fdisplay(kanata_fd, "S\t%0d\t%0d\tBR",
                          branch_result_q.kanata_id,
                          0);
                $fdisplay(kanata_fd, "L\t%0d\t1\ttaken=%0d mispredict=%0d target=0x%0h fallthrough=0x%0h dst:p%0d rd_wdata=0x%0h",
                          branch_result_q.kanata_id,
                          branch_result_q.taken,
                          branch_result_q.mispredict,
                          branch_result_q.target_pc,
                          branch_result_q.fallthrough_pc,
                          branch_result_q.dst_preg,
                          branch_result_q.rd_wdata);
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
                 && rename_uop_head[single_trace_lane_q].valid
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

            if (branch_issueq_issue_valid) begin
                $display("[O3_SIM][backend][cycle=%0d] BR_ISSUE id=0x%0h src1:p%0d src2:p%0d rob:%0d op=%s pc=0x%0h",
                         sim_cycle_q,
                         branch_issueq_issue_entry.instruction_id,
                         branch_issueq_issue_entry.src1_preg,
                         branch_issueq_issue_entry.src2_preg,
                         branch_issueq_issue_entry.rob_idx,
                         branch_op_name(branch_issueq_issue_entry.branch_op),
                         branch_issueq_issue_entry.pc);
            end else begin
                $display("[O3_SIM][backend][cycle=%0d] BR_ISSUE empty", sim_cycle_q);
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

            if (branch_issue_q.valid) begin
                $display("[O3_SIM][backend][cycle=%0d] BR_REGREAD id=0x%0h src1:p%0d->0x%0h src2:p%0d->0x%0h imm[%s]=0x%0h->0x%0h rob:%0d",
                         sim_cycle_q,
                         branch_issue_q.instruction_id,
                         branch_issue_q.src1_preg,
                         prf_rd_data[BRANCH_PRF_RD_BASE + 0],
                         branch_issue_q.src2_preg,
                         prf_rd_data[BRANCH_PRF_RD_BASE + 1],
                         imm_type_name(branch_issue_q.imm_type),
                         branch_issue_q.imm_raw,
                         expand_imm_value(branch_issue_q.imm_type, branch_issue_q.imm_raw),
                         branch_issue_q.rob_idx);
            end else begin
                $display("[O3_SIM][backend][cycle=%0d] BR_REGREAD empty", sim_cycle_q);
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

            if (branch_result_q.valid) begin
                $display("[O3_SIM][backend][cycle=%0d] BR_RESULT id=0x%0h taken=%0d mispredict=%0d target=0x%0h fallthrough=0x%0h dst:p%0d rd_wdata=0x%0h dst_write=%0d rob:%0d",
                         sim_cycle_q,
                         branch_result_q.instruction_id,
                         branch_result_q.taken,
                         branch_result_q.mispredict,
                         branch_result_q.target_pc,
                         branch_result_q.fallthrough_pc,
                         branch_result_q.dst_preg,
                         branch_result_q.rd_wdata,
                         branch_result_q.dst_write_en,
                         branch_result_q.rob_idx);
            end else begin
                $display("[O3_SIM][backend][cycle=%0d] BR_RESULT empty", sim_cycle_q);
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

            // rename 成功时，新分配的真实目的 preg 要先标记为 not-ready；
            // 写回阶段再把它置回 ready。这样 issue queue 才会等到真实结果返回再唤醒。
            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (rename_fire
                 && rename_uop_head[lane].valid
                 && rename_uop_head[lane].rd_write_en
                 && (rename_uop_head[lane].rd != REG_ADDR_WIDTH'(0))
                 && !branch_squash_valid) begin
                    preg_ready_q[dst_new_preg[lane]] <= 1'b0;
                end
            end

            // 当前整数写回统一从 alu_result_q 发起。
            // 本拍写回的 ready 变化只会在下一拍对 issue queue 可见，不做同拍旁路。
            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (alu_result_q[alu].valid
                 && alu_result_q[alu].dst_write_en
                 && (!branch_squash_valid
                  || rob_is_older_or_same(alu_result_q[alu].rob_idx, branch_squash_rob_idx, rob_head))) begin
                    preg_ready_q[alu_result_q[alu].dst_preg] <= 1'b1;
                end
            end

            // 分支写回（JAL/JALR 的 rd=PC+4）更新 preg_ready
            if (branch_result_q.valid
             && branch_result_q.dst_write_en
             && branch_wb_survives) begin
                preg_ready_q[branch_result_q.dst_preg] <= 1'b1;
            end

            // 退休计数器按本拍真正退休的 ROB 条数累加，用于后续性能观察和日志统计。
            retired_inst_count_q <= retired_inst_count_next;
`ifdef O3_SIM
            if (decode_fire) begin
                kanata_id_counter_q <= kanata_id_counter_q + 64'(MACHINE_WIDTH);
            end
            if (rename_fire) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (rename_uop_head[lane].valid) begin
                        rob_kanata_id_q[rob_idx[lane]] <= rename_uop_head[lane].kanata_id;
                    end
                end
            end
`endif

            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                logic alu_result_wb_survives;
                alu_result_wb_survives = !branch_squash_valid
                                      || rob_is_older_or_same(alu_regread_q[alu].rob_idx, branch_squash_rob_idx, rob_head);
                alu_result_q[alu].valid        <= exec_valid[alu] && alu_result_wb_survives;
                // Self-squash: clear alu_result_q entries that are already valid
                // but don't survive a newly-asserted squash (one cycle delayed from execute).
                // Only fires when no new instruction is flowing in (exec_valid=0)
                // to avoid overwriting a new instruction with the self-squash clear.
                if (!exec_valid[alu] && alu_result_q[alu].valid && branch_squash_valid
                 && !rob_is_older_or_same(alu_result_q[alu].rob_idx, branch_squash_rob_idx, rob_head)) begin
                    alu_result_q[alu].valid <= 1'b0;
                end
                alu_result_q[alu].instruction_id <= alu_regread_q[alu].instruction_id;
`ifdef O3_SIM
                alu_result_q[alu].kanata_id    <= alu_regread_q[alu].kanata_id;
`endif
                alu_result_q[alu].rob_idx      <= alu_regread_q[alu].rob_idx;
                alu_result_q[alu].dst_preg     <= alu_regread_q[alu].dst_preg;
                alu_result_q[alu].dst_write_en <= alu_regread_q[alu].dst_write_en;
                alu_result_q[alu].result       <= exec_result[alu];

                alu_regread_q[alu].valid        <= alu_issue_q[alu].valid
                                               && (!branch_squash_valid
                                                || rob_is_older_or_same(alu_issue_q[alu].rob_idx, branch_squash_rob_idx, rob_head));
                alu_regread_q[alu].instruction_id <= alu_issue_q[alu].instruction_id;
`ifdef O3_SIM
                alu_regread_q[alu].kanata_id   <= alu_issue_q[alu].kanata_id;
`endif
                alu_regread_q[alu].rob_idx      <= alu_issue_q[alu].rob_idx;
                alu_regread_q[alu].dst_preg     <= alu_issue_q[alu].dst_preg;
                alu_regread_q[alu].dst_write_en <= alu_issue_q[alu].dst_write_en;
                case (alu_issue_q[alu].src1_sel)
                    SRC1_ZERO: alu_regread_q[alu].src1_value <= '0;
                    SRC1_PC:   alu_regread_q[alu].src1_value <= XLEN'(alu_issue_q[alu].pc);
                    default:   alu_regread_q[alu].src1_value <= alu_issue_q[alu].src1_valid ? prf_rd_data[(2*alu)+0] : '0;
                endcase
                alu_regread_q[alu].imm_value    <= alu_issue_q[alu].imm_valid
                                                 ? expand_imm_value(alu_issue_q[alu].imm_type, alu_issue_q[alu].imm_raw)
                                                 : '0;
                alu_regread_q[alu].imm_valid    <= alu_issue_q[alu].imm_valid;
                alu_regread_q[alu].int_alu_op   <= alu_issue_q[alu].int_alu_op;
                alu_regread_q[alu].pc           <= alu_issue_q[alu].pc;
                alu_regread_q[alu].src1_sel     <= alu_issue_q[alu].src1_sel;
                if (alu_issue_q[alu].imm_valid) begin
                    alu_regread_q[alu].src2_value <= expand_imm_value(alu_issue_q[alu].imm_type, alu_issue_q[alu].imm_raw);
                end else if (alu_issue_q[alu].src2_valid) begin
                    alu_regread_q[alu].src2_value <= prf_rd_data[(2*alu)+1];
                end else begin
                    alu_regread_q[alu].src2_value <= '0;
                end

                alu_issue_q[alu].valid        <= issueq_issue_valid[alu]
                                             && (!branch_squash_valid
                                              || rob_is_older_or_same(issueq_issue_entry[alu].rob_idx, branch_squash_rob_idx, rob_head));
                alu_issue_q[alu].instruction_id <= issueq_issue_entry[alu].instruction_id;
`ifdef O3_SIM
                alu_issue_q[alu].kanata_id    <= issueq_issue_entry[alu].kanata_id;
`endif
                alu_issue_q[alu].src1_preg    <= issueq_issue_entry[alu].src1_preg;
                alu_issue_q[alu].src2_preg    <= issueq_issue_entry[alu].src2_preg;
                alu_issue_q[alu].src1_valid   <= issueq_issue_entry[alu].src1_valid;
                alu_issue_q[alu].src2_valid   <= issueq_issue_entry[alu].src2_valid;
                alu_issue_q[alu].rob_idx      <= issueq_issue_entry[alu].rob_idx;
                alu_issue_q[alu].dst_preg     <= issueq_issue_entry[alu].dst_preg;
                alu_issue_q[alu].dst_write_en <= issueq_issue_entry[alu].dst_write_en;
                alu_issue_q[alu].imm_raw      <= issueq_issue_entry[alu].imm_raw;
                alu_issue_q[alu].imm_valid    <= issueq_issue_entry[alu].imm_valid;
                alu_issue_q[alu].imm_type     <= issueq_issue_entry[alu].imm_type;
                alu_issue_q[alu].int_alu_op   <= issueq_issue_entry[alu].int_alu_op;
                alu_issue_q[alu].pc           <= issueq_issue_entry[alu].pc;
                alu_issue_q[alu].src1_sel     <= issueq_issue_entry[alu].src1_sel;
            end

            branch_regread_q.valid          <= branch_issue_q.valid
                                            && (!branch_squash_valid
                                             || rob_is_older_or_same(branch_issue_q.rob_idx, branch_squash_rob_idx, rob_head));
            branch_regread_q.instruction_id <= branch_issue_q.instruction_id;
`ifdef O3_SIM
            branch_regread_q.kanata_id      <= branch_issue_q.kanata_id;
`endif
            branch_regread_q.pc             <= branch_issue_q.pc;
            branch_regread_q.ftq_idx        <= branch_issue_q.ftq_idx;
            branch_regread_q.src1_value     <= prf_rd_data[BRANCH_PRF_RD_BASE + 0];
            branch_regread_q.src2_value     <= prf_rd_data[BRANCH_PRF_RD_BASE + 1];
            branch_regread_q.imm_value      <= expand_imm_value(branch_issue_q.imm_type, branch_issue_q.imm_raw);
            branch_regread_q.rob_idx        <= branch_issue_q.rob_idx;
            branch_regread_q.branch_op      <= branch_issue_q.branch_op;
            branch_regread_q.dst_preg       <= branch_issue_q.dst_preg;
            branch_regread_q.dst_write_en   <= branch_issue_q.dst_write_en;

            branch_issue_q.valid            <= branch_issueq_issue_valid
                                            && (!branch_squash_valid
                                             || rob_is_older_or_same(branch_issueq_issue_entry.rob_idx, branch_squash_rob_idx, rob_head));
            branch_issue_q.instruction_id   <= branch_issueq_issue_entry.instruction_id;
`ifdef O3_SIM
            branch_issue_q.kanata_id        <= branch_issueq_issue_entry.kanata_id;
`endif
            branch_issue_q.pc               <= branch_issueq_issue_entry.pc;
            branch_issue_q.ftq_idx          <= branch_issueq_issue_entry.ftq_idx;
            branch_issue_q.src1_preg        <= branch_issueq_issue_entry.src1_preg;
            branch_issue_q.src2_preg        <= branch_issueq_issue_entry.src2_preg;
            branch_issue_q.rob_idx          <= branch_issueq_issue_entry.rob_idx;
            branch_issue_q.imm_raw          <= branch_issueq_issue_entry.imm_raw;
            branch_issue_q.imm_type         <= branch_issueq_issue_entry.imm_type;
            branch_issue_q.branch_op        <= branch_issueq_issue_entry.branch_op;
            branch_issue_q.dst_preg         <= branch_issueq_issue_entry.dst_preg;
            branch_issue_q.dst_write_en     <= branch_issueq_issue_entry.dst_write_en;

            branch_result_q.valid          <= branch_exec_valid
                                           && (!branch_squash_valid
                                            || rob_is_older_or_same(branch_regread_q.rob_idx, branch_squash_rob_idx, rob_head));
            // Self-squash: clear branch_result_q if delayed squash catches it
            if (!branch_exec_valid && branch_result_q.valid && branch_squash_valid
             && !rob_is_older_or_same(branch_result_q.rob_idx, branch_squash_rob_idx, rob_head)) begin
                branch_result_q.valid <= 1'b0;
            end
            branch_result_q.instruction_id <= branch_regread_q.instruction_id;
`ifdef O3_SIM
            branch_result_q.kanata_id      <= branch_regread_q.kanata_id;
`endif
            branch_result_q.rob_idx        <= branch_regread_q.rob_idx;
            branch_result_q.pc             <= branch_regread_q.pc;
            branch_result_q.ftq_idx        <= branch_regread_q.ftq_idx;
            branch_result_q.target_pc      <= branch_exec_target_pc;
            branch_result_q.fallthrough_pc <= branch_exec_fallthrough_pc;
            branch_result_q.taken          <= branch_exec_taken;
            branch_result_q.mispredict     <= branch_exec_mispredict;
            branch_result_q.dst_preg       <= branch_regread_q.dst_preg;
            branch_result_q.dst_write_en   <= branch_regread_q.dst_write_en;
            branch_result_q.rd_wdata       <= branch_regread_q.pc + PC_WIDTH'(4);

            if (branch_squash_valid) begin
                fetch_entry_q       <= '0;
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
