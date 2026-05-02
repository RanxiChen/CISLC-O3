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
        parameter int MACHINE_WIDTH = 1,
        parameter int NUM_PHYS_REGS = 64,
        parameter int NUM_ARCH_REGS = 32,
        parameter int NUM_ROB_ENTRIES = 64,
        parameter int DECODE_QUEUE_DEPTH = 2,
        parameter int INT_ISSUE_QUEUE_DEPTH = 16,
        parameter int NUM_INT_ALUS = 3
    )
(
    input  logic clk,
    input  logic rst,
    input  fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry_i,
    input  logic                             fetch_valid_i,
    output logic                             fetch_ready_o,
    output logic                             done,
    output logic [63:0]                      retired_inst_count_o
);

    localparam int BACKEND_PREG_IDX_WIDTH = $clog2(NUM_PHYS_REGS);
    localparam int BACKEND_ROB_IDX_WIDTH  = $clog2(NUM_ROB_ENTRIES);
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

    logic [BACKEND_PREG_IDX_WIDTH-1:0] dst_new_preg [MACHINE_WIDTH-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_idx      [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] src1_preg    [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] src2_preg    [MACHINE_WIDTH-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] dst_old_preg [MACHINE_WIDTH-1:0];
    issue_queue_entry_t [MACHINE_WIDTH-1:0] issueq_enq_entry;

    issue_queue_entry_t [NUM_INT_ALUS-1:0] issueq_issue_entry;
    logic               [NUM_INT_ALUS-1:0] issueq_issue_valid;
    logic               [NUM_INT_ALUS-1:0] issueq_issue_ready;
    issue_queue_entry_t [INT_ISSUE_QUEUE_DEPTH-1:0] issueq_wakeup_entry;
    logic               [INT_ISSUE_QUEUE_DEPTH-1:0] issueq_wakeup_valid;

    int_issue_pipe_uop_t    alu_issue_q   [NUM_INT_ALUS-1:0];
    int_regread_pipe_uop_t  alu_regread_q [NUM_INT_ALUS-1:0];
    int_execute_result_t    alu_result_q  [NUM_INT_ALUS-1:0];

    logic [BACKEND_PREG_IDX_WIDTH-1:0] prf_rd_addr [PRF_READ_PORTS-1:0];
    logic [XLEN-1:0]                   prf_rd_data [PRF_READ_PORTS-1:0];
    logic                              prf_wr_en   [PRF_WRITE_PORTS-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] prf_wr_addr [PRF_WRITE_PORTS-1:0];
    logic [XLEN-1:0]                   prf_wr_data [PRF_WRITE_PORTS-1:0];

    logic                              exec_valid   [NUM_INT_ALUS-1:0];
    logic [XLEN-1:0]                   exec_result  [NUM_INT_ALUS-1:0];
    logic                              exec_cmp_true[NUM_INT_ALUS-1:0];
    logic                              preg_ready_q [NUM_PHYS_REGS-1:0];
    logic                              rob_complete_valid [NUM_INT_ALUS-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_complete_idx   [NUM_INT_ALUS-1:0];
    logic                              rob_retire_valid   [NUM_INT_ALUS-1:0];
    logic [BACKEND_ROB_IDX_WIDTH-1:0]  rob_retire_idx     [NUM_INT_ALUS-1:0];
    logic [BACKEND_PREG_IDX_WIDTH-1:0] rob_retire_old_dst_preg [NUM_INT_ALUS-1:0];
    logic [INST_ID_WIDTH-1:0]          rob_retire_instruction_id [NUM_INT_ALUS-1:0];
    logic                              rob_retire_any;

`ifdef O3_SIM
    logic [63:0] sim_cycle_q;
    logic [63:0] kanata_id_counter_q;
    logic [63:0] rob_kanata_id_q [NUM_ROB_ENTRIES-1:0];
    logic        kanata_header_printed_q;
    integer      kanata_fd;
    string       kanata_log_path;
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
                IMM_TYPE_I: imm_sext = XLEN'($signed({{(XLEN-IMM_RAW_WIDTH){imm_raw[IMM_RAW_WIDTH-1]}}, imm_raw}));
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
            assign decoded_uop[i].valid          = decode_valid;
            assign decoded_uop[i].instruction_id = fetch_instruction_id_q[i];
`ifdef O3_SIM
            assign decoded_uop[i].kanata_id      = kanata_id_counter_q + 64'(i);
`endif
            assign decoded_uop[i].pc             = fetch_entry_q[i].pc;
            assign decoded_uop[i].instruction    = fetch_entry_q[i].instruction;
            assign decoded_uop[i].exception      = fetch_entry_q[i].exception;
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
            assign decoded_uop[i].is_int_uop     = decode_out[i].is_int_uop;
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
            assign rob_exception[i] = rename_uop_head[i].exception;
            assign rob_alloc_instruction_id[i] = rename_uop_head[i].instruction_id;

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
                                                   || preg_ready_q[src1_preg[i]];
            assign issueq_enq_entry[i].src2_ready   = (!rename_uop_head[i].rs2_read_en)
                                                   || rename_uop_head[i].use_imm
                                                   || preg_ready_q[src2_preg[i]];
            assign issueq_enq_entry[i].rob_idx      = rob_idx[i];
            assign issueq_enq_entry[i].dst_preg     = dst_write_real ? dst_new_preg[i] : BACKEND_PREG_IDX_WIDTH'(0);
            assign issueq_enq_entry[i].dst_write_en = dst_write_real;
            assign issueq_enq_entry[i].imm_raw      = rename_uop_head[i].imm_raw;
            assign issueq_enq_entry[i].imm_valid    = rename_uop_head[i].use_imm;
            assign issueq_enq_entry[i].imm_type     = rename_uop_head[i].imm_type;
            assign issueq_enq_entry[i].int_alu_op   = rename_uop_head[i].int_alu_op;
        end
    endgenerate

    assign decode_ready    = uopq_enq_ready;
    assign decode_fire     = decode_valid && decode_ready;
    assign fetch_ready_o   = (!fetch_entry_valid_q) || decode_ready;
    assign fetch_fire      = fetch_valid_i && fetch_ready_o;
    assign rename_valid    = uopq_deq_valid;
    assign issueq_enq_valid = rename_valid && alloc_valid && rob_valid;
    assign rename_ready    = alloc_valid && rob_valid && issueq_enq_ready;
    assign rename_fire     = rename_valid && rename_ready;
    assign alloc_ready     = rename_valid && rob_valid && issueq_enq_ready;
    assign rob_ready       = rename_valid && alloc_valid && issueq_enq_ready;
    assign done            = 1'b0;
    assign issueq_issue_ready = '1;
    assign retired_inst_count_o = retired_inst_count_q;

    generate
        for (i = 0; i < NUM_INT_ALUS; i++) begin : prf_read_addr_assign
            assign prf_rd_addr[(2*i)+0] = alu_issue_q[i].src1_preg;
            assign prf_rd_addr[(2*i)+1] = alu_issue_q[i].src2_preg;
        end
    endgenerate

    generate
        for (i = 0; i < NUM_INT_ALUS; i++) begin : prf_writeback_assign
            // `alu_result_q` 是 execute 后、writeback 前的过渡寄存器。
            // 只有真正带目的寄存器的新版本才会写回 PRF；rd=x0 的指令虽然会 complete，但不会写回。
            assign prf_wr_en[i]   = alu_result_q[i].valid && alu_result_q[i].dst_write_en;
            assign prf_wr_addr[i] = alu_result_q[i].dst_preg;
            assign prf_wr_data[i] = alu_result_q[i].result;

            // ROB complete 跟“是否真正写回 PRF”不是一回事。
            // 即使 rd=x0，没有目的寄存器写回，这条整数指令执行完成后也应标记 complete。
            assign rob_complete_valid[i] = alu_result_q[i].valid;
            assign rob_complete_idx[i]   = alu_result_q[i].rob_idx;
        end
    endgenerate

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
                retire_count_this_cycle = retire_count_this_cycle + 2'd1;
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
        .RELEASE_WIDTH(NUM_INT_ALUS)
    ) u_free_list (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(alloc_req),
        .alloc_ready_i(alloc_ready),
        .alloc_valid_o(alloc_valid),
        .alloc_preg_o(dst_new_preg),
        .release_valid_i(rob_retire_valid),
        .release_preg_i(rob_retire_old_dst_preg)
    );

    rob #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES),
        .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .COMPLETE_WIDTH(NUM_INT_ALUS)
    ) u_rob (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(rob_req),
        .alloc_exception_i(rob_exception),
        .alloc_old_dst_preg_i(dst_old_preg),
        .alloc_instruction_id_i(rob_alloc_instruction_id),
        .alloc_ready_i(rob_ready),
        .complete_valid_i(rob_complete_valid),
        .complete_idx_i(rob_complete_idx),
        .alloc_valid_o(rob_valid),
        .alloc_idx_o(rob_idx),
        .retire_valid_o(rob_retire_valid),
        .retire_idx_o(rob_retire_idx),
        .retire_old_dst_preg_o(rob_retire_old_dst_preg),
        .retire_instruction_id_o(rob_retire_instruction_id)
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
        .rs1_read_en_i(rename_rs1_read_en),
        .rs2_read_en_i(rename_rs2_read_en),
        .rd_write_en_i(rename_rd_write_en),
        .new_dst_preg_i(dst_new_preg),
        .src1_preg_o(src1_preg),
        .src2_preg_o(src2_preg),
        .old_dst_preg_o(dst_old_preg)
    );

    issue_queue #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .ISSUE_WIDTH(NUM_INT_ALUS),
        .DEPTH(INT_ISSUE_QUEUE_DEPTH),
        .NUM_PHYS_REGS(NUM_PHYS_REGS)
    ) u_int_issue_queue (
        .clk(clk),
        .rst(rst),
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

    always_ff @(posedge clk) begin
        if (rst) begin
            fetch_entry_q          <= '0;
            fetch_entry_valid_q    <= 1'b0;
            fetch_instruction_id_q <= '{default: '0};
            fetch_group_seq_q      <= '0;
            alu_issue_q            <= '{default: '0};
            alu_regread_q          <= '{default: '0};
            alu_result_q           <= '{default: '0};
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
`endif
        end else begin
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
`else
            $display("[O3_SIM][backend][cycle=%0d] ----------------", sim_cycle_q);

            if (fetch_entry_valid_q) begin
                $display("[O3_SIM][backend][cycle=%0d] DECODE id=0x%0h pc=0x%0h inst=0x%08h",
                         sim_cycle_q,
                         fetch_instruction_id_q[0],
                         fetch_entry_q[0].pc,
                         fetch_entry_q[0].instruction);
            end else begin
                $display("[O3_SIM][backend][cycle=%0d] DECODE empty", sim_cycle_q);
            end

            if (rename_valid && rename_uop_head[0].valid) begin
                $display("[O3_SIM][backend][cycle=%0d] RENAME id=0x%0h asm=%s src1:x%0d->p%0d src2:x%0d->p%0d rd:x%0d old:p%0d new:p%0d rob:%0d",
                         sim_cycle_q,
                         rename_uop_head[0].instruction_id,
                         dpi_backend_disasm_rv64i(rename_uop_head[0].instruction),
                         rename_uop_head[0].rs1, src1_preg[0],
                         rename_uop_head[0].rs2, src2_preg[0],
                         rename_uop_head[0].rd, dst_old_preg[0], dst_new_preg[0],
                         rob_idx[0]);
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
                 && rename_uop_head[lane].valid
                 && rename_uop_head[lane].rd_write_en
                 && (rename_uop_head[lane].rd != REG_ADDR_WIDTH'(0))) begin
                    preg_ready_q[dst_new_preg[lane]] <= 1'b0;
                end
            end

            // 当前整数写回统一从 alu_result_q 发起。
            // 本拍写回的 ready 变化只会在下一拍对 issue queue 可见，不做同拍旁路。
            for (int alu = 0; alu < NUM_INT_ALUS; alu++) begin
                if (alu_result_q[alu].valid && alu_result_q[alu].dst_write_en) begin
                    preg_ready_q[alu_result_q[alu].dst_preg] <= 1'b1;
                end
            end

            // 退休计数器按本拍真正退休的 ROB 条数累加，用于后续性能观察和日志统计。
            retired_inst_count_q <= retired_inst_count_next;
`ifdef O3_SIM
            if (decode_fire) begin
                kanata_id_counter_q <= kanata_id_counter_q + MACHINE_WIDTH;
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
                alu_result_q[alu].valid        <= exec_valid[alu];
                alu_result_q[alu].instruction_id <= alu_regread_q[alu].instruction_id;
`ifdef O3_SIM
                alu_result_q[alu].kanata_id    <= alu_regread_q[alu].kanata_id;
`endif
                alu_result_q[alu].rob_idx      <= alu_regread_q[alu].rob_idx;
                alu_result_q[alu].dst_preg     <= alu_regread_q[alu].dst_preg;
                alu_result_q[alu].dst_write_en <= alu_regread_q[alu].dst_write_en;
                alu_result_q[alu].result       <= exec_result[alu];

                alu_regread_q[alu].valid        <= alu_issue_q[alu].valid;
                alu_regread_q[alu].instruction_id <= alu_issue_q[alu].instruction_id;
`ifdef O3_SIM
                alu_regread_q[alu].kanata_id   <= alu_issue_q[alu].kanata_id;
`endif
                alu_regread_q[alu].rob_idx      <= alu_issue_q[alu].rob_idx;
                alu_regread_q[alu].dst_preg     <= alu_issue_q[alu].dst_preg;
                alu_regread_q[alu].dst_write_en <= alu_issue_q[alu].dst_write_en;
                alu_regread_q[alu].src1_value   <= alu_issue_q[alu].src1_valid ? prf_rd_data[(2*alu)+0] : '0;
                alu_regread_q[alu].imm_value    <= alu_issue_q[alu].imm_valid
                                                 ? expand_imm_value(alu_issue_q[alu].imm_type, alu_issue_q[alu].imm_raw)
                                                 : '0;
                alu_regread_q[alu].imm_valid    <= alu_issue_q[alu].imm_valid;
                alu_regread_q[alu].int_alu_op   <= alu_issue_q[alu].int_alu_op;
                if (alu_issue_q[alu].imm_valid) begin
                    alu_regread_q[alu].src2_value <= expand_imm_value(alu_issue_q[alu].imm_type, alu_issue_q[alu].imm_raw);
                end else if (alu_issue_q[alu].src2_valid) begin
                    alu_regread_q[alu].src2_value <= prf_rd_data[(2*alu)+1];
                end else begin
                    alu_regread_q[alu].src2_value <= '0;
                end

                alu_issue_q[alu].valid        <= issueq_issue_valid[alu];
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
            end

            if (fetch_fire) begin
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
