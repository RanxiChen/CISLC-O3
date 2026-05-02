/**
 * O3 处理器核心类型定义包
 * 包含所有流水线阶段之间传递的数据结构
 */

package o3_pkg;
    // ========================================
    // 基础参数定义
    // ========================================
    parameter int XLEN = 64;           // 数据宽度
    parameter int ILEN = 32;           // 指令宽度
    parameter int PC_WIDTH = 39;       // PC宽度 (sv39)
    parameter int REG_ADDR_WIDTH = 5;  // 寄存器地址宽度
    parameter int INST_ID_WIDTH = 64;  // 调试用指令编号宽度
    parameter int DEFAULT_NUM_PHYS_REGS = 64;
    parameter int DEFAULT_NUM_ROB_ENTRIES = 64;
    parameter int PREG_IDX_WIDTH = $clog2(DEFAULT_NUM_PHYS_REGS);
    parameter int ROB_IDX_WIDTH = $clog2(DEFAULT_NUM_ROB_ENTRIES);
    parameter int IMM_RAW_WIDTH = 12;

    // ========================================
    // Frontend -> Backend 接口
    // ========================================

    // Frontend输出给Backend的数据包
    typedef struct packed {
        logic [PC_WIDTH-1:0] pc;          // 程序计数器
        logic [ILEN-1:0]     instruction; // 32位指令
        logic                exception;   // 异常标志
    } fetch_entry_t;

    // ========================================
    // 解码阶段数据结构
    // ========================================

    // 解码器输入：指令
    typedef struct packed {
        logic [ILEN-1:0] instruction;  // 32位指令
    } decode_in_t;

    typedef enum logic [1:0] {
        IMM_TYPE_NONE = 2'b00,
        IMM_TYPE_I    = 2'b01
    } imm_type_t;

    typedef enum logic [3:0] {
        INT_ALU_OP_ADD  = 4'd0,
        INT_ALU_OP_SUB  = 4'd1,
        INT_ALU_OP_SLL  = 4'd2,
        INT_ALU_OP_SLT  = 4'd3,
        INT_ALU_OP_SLTU = 4'd4,
        INT_ALU_OP_XOR  = 4'd5,
        INT_ALU_OP_SRL  = 4'd6,
        INT_ALU_OP_SRA  = 4'd7,
        INT_ALU_OP_OR   = 4'd8,
        INT_ALU_OP_AND  = 4'd9
    } int_alu_op_t;

    // 解码器输出：寄存器索引与整数 ALU 最小语义。
    // 当前阶段为 decode queue / rename 两拍拆分补齐这些信息：
    // - 哪些源寄存器需要读取
    // - 该指令是否会写 rd
    // - 第二操作数是否选择立即数
    // - I-type 12 位原始立即数字段以及对应类型
    // - 当前整数 ALU 操作类型
    // - 是否属于当前统一整数数据流
    // 还没有扩展异常、提交、执行完成、提交状态等更完整字段。
    typedef struct packed {
        logic [REG_ADDR_WIDTH-1:0] rs1;         // 源寄存器1
        logic [REG_ADDR_WIDTH-1:0] rs2;         // 源寄存器2
        logic [REG_ADDR_WIDTH-1:0] rd;          // 目的寄存器
        logic                      rs1_read_en; // 该指令是否真正读取 rs1
        logic                      rs2_read_en; // 该指令是否真正读取 rs2
        logic                      rd_write_en; // 该指令是否真正写回 rd
        logic                      use_imm;     // 第二操作数是否取立即数
        imm_type_t                 imm_type;    // 立即数原始编码类型；全 0 表示无效
        logic [IMM_RAW_WIDTH-1:0]  imm_raw;     // 原始立即数字段；当前只承载 I-type[31:20]
        int_alu_op_t               int_alu_op;  // 整数 ALU 操作类型
        logic                      is_int_uop;  // 当前是否纳入统一整数执行流
    } decode_out_t;

    // 解码完成但尚未重命名的 uop。
    // 当前作为 decode queue 的基本载荷，先稳住 frontend 信息和最小解码语义。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
`ifdef O3_SIM
        logic [63:0]               kanata_id;
`endif
        logic [PC_WIDTH-1:0]       pc;
        logic [ILEN-1:0]           instruction;
        logic                      exception;
        logic [REG_ADDR_WIDTH-1:0] rs1;
        logic [REG_ADDR_WIDTH-1:0] rs2;
        logic [REG_ADDR_WIDTH-1:0] rd;
        logic                      rs1_read_en;
        logic                      rs2_read_en;
        logic                      rd_write_en;
        logic                      use_imm;
        imm_type_t                 imm_type;
        logic [IMM_RAW_WIDTH-1:0]  imm_raw;
        int_alu_op_t               int_alu_op;
        logic                      is_int_uop;
    } decoded_uop_t;

    // 已完成重命名和 ROB 分配的 uop。
    // 当前先作为 rename 阶段输出骨架保留下来，后续再接 issue / execute / commit。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
        logic [PC_WIDTH-1:0]       pc;
        logic [ILEN-1:0]           instruction;
        logic                      exception;
        logic [REG_ADDR_WIDTH-1:0] rs1;
        logic [REG_ADDR_WIDTH-1:0] rs2;
        logic [REG_ADDR_WIDTH-1:0] rd;
        logic                      rs1_read_en;
        logic                      rs2_read_en;
        logic                      rd_write_en;
        logic                      use_imm;
        imm_type_t                 imm_type;
        logic [IMM_RAW_WIDTH-1:0]  imm_raw;
        int_alu_op_t               int_alu_op;
        logic                      is_int_uop;
        logic [PREG_IDX_WIDTH-1:0] src1_preg;
        logic [PREG_IDX_WIDTH-1:0] src2_preg;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic [PREG_IDX_WIDTH-1:0] old_dst_preg;
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
    } renamed_uop_t;

    // 已完成 rename、等待进入整数 issue queue 的表项。
    // 当前只保留“进入整数计算队列”所需的最小字段：
    // - 两个源操作数对应的物理寄存器编号
    // - 每个源是否真的需要、当前是否已经准备好
    // - 目的物理寄存器与是否真的写回
    // - ROB 索引、调试 instruction_id
    // - 原始立即数字段和是否真的使用立即数
    // - 整数 ALU 操作类型
    // 当前还没有加入唤醒标签、旁路结果、异常恢复等更完整字段。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
`ifdef O3_SIM
        logic [63:0]               kanata_id;
`endif
        logic [PREG_IDX_WIDTH-1:0] src1_preg;
        logic [PREG_IDX_WIDTH-1:0] src2_preg;
        logic                      src1_valid;
        logic                      src2_valid;
        logic                      src1_ready;
        logic                      src2_ready;
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic                      dst_write_en;
        logic [IMM_RAW_WIDTH-1:0]  imm_raw;
        logic                      imm_valid;
        imm_type_t                 imm_type;
        int_alu_op_t               int_alu_op;
    } issue_queue_entry_t;

    // issue queue 选中后、进入具体 ALU 发射寄存器的 uop。
    // 这一拍仍然只保存物理寄存器编号，不保存真正的寄存器值。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
`ifdef O3_SIM
        logic [63:0]               kanata_id;
`endif
        logic [PREG_IDX_WIDTH-1:0] src1_preg;
        logic [PREG_IDX_WIDTH-1:0] src2_preg;
        logic                      src1_valid;
        logic                      src2_valid;
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic                      dst_write_en;
        logic [IMM_RAW_WIDTH-1:0]  imm_raw;
        logic                      imm_valid;
        imm_type_t                 imm_type;
        int_alu_op_t               int_alu_op;
    } int_issue_pipe_uop_t;

    // 完成物理寄存器读取和立即数扩展后、进入执行单元前的 uop。
    // 当前阶段 src1/src2 都是最终送入 ALU 的真实 64 位操作数。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
`ifdef O3_SIM
        logic [63:0]               kanata_id;
`endif
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic                      dst_write_en;
        logic [XLEN-1:0]           src1_value;
        logic [XLEN-1:0]           src2_value;
        logic [XLEN-1:0]           imm_value;
        logic                      imm_valid;
        int_alu_op_t               int_alu_op;
    } int_regread_pipe_uop_t;

    // 整数执行单元输出后、等待后续接 wakeup / writeback / commit 的结果寄存器。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
`ifdef O3_SIM
        logic [63:0]               kanata_id;
`endif
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic                      dst_write_en;
        logic [XLEN-1:0]           result;
    } int_execute_result_t;

endpackage
