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
    parameter int DEFAULT_NUM_PHYS_REGS = 96;
    parameter int DEFAULT_NUM_ROB_ENTRIES = 64;
    parameter int PREG_IDX_WIDTH = $clog2(DEFAULT_NUM_PHYS_REGS);
    parameter int ROB_IDX_WIDTH = $clog2(DEFAULT_NUM_ROB_ENTRIES);
    parameter int IMM_RAW_WIDTH = 21;
    parameter int FTQ_INDEX_WIDTH = 4;
    parameter int ICACHE_LINE_BYTES = 64;

    // RISC-V 同步异常 cause 编码。当前先定义前端可能产生的指令端异常，
    // 后续增加 Load/Store、CSR 和特权架构时继续沿用同一类型扩展。
    typedef logic [5:0] exception_cause_t;
    localparam exception_cause_t EXCEPTION_CAUSE_INST_ADDR_MISALIGNED = exception_cause_t'(0);
    localparam exception_cause_t EXCEPTION_CAUSE_INST_ACCESS_FAULT    = exception_cause_t'(1);
    localparam exception_cause_t EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION  = exception_cause_t'(2);
    localparam exception_cause_t EXCEPTION_CAUSE_INST_PAGE_FAULT      = exception_cause_t'(12);

    // ========================================
    // 当前 core/backend 固定配置
    // ========================================
    parameter int CORE_FETCH_WIDTH = 4;
    parameter int BACKEND_MACHINE_WIDTH = CORE_FETCH_WIDTH;
    parameter int BACKEND_NUM_PHYS_REGS = DEFAULT_NUM_PHYS_REGS;
    parameter int BACKEND_NUM_ARCH_REGS = 32;
    parameter int BACKEND_NUM_ROB_ENTRIES = 64;
    // Decode Queue 的深度按单条 decoded uop 计数，不按 bundle 计数。
    // 16 entries 在 4-wide Decode 下提供最多四拍满宽缓冲。
    parameter int BACKEND_DECODE_QUEUE_DEPTH = 16;
    parameter int BACKEND_DISPATCH_WIDTH = 4;
    parameter int BACKEND_INT_ISSUE_QUEUE_DEPTH = 16;
    parameter int BACKEND_MEM_ISSUE_QUEUE_DEPTH = 8;
    parameter int BACKEND_BRANCH_ISSUE_QUEUE_DEPTH = 4;
    parameter int BACKEND_NUM_INT_ALUS = 4;
    parameter int BACKEND_NUM_BRANCH_CHECKPOINTS = 4;
    parameter int BACKEND_LOAD_QUEUE_DEPTH = 8;
    parameter int BACKEND_STORE_QUEUE_DEPTH = 8;
    parameter int BACKEND_RENAME_DISPATCH_QUEUE_DEPTH = 16;

    parameter int BRANCH_TAG_WIDTH = $clog2(BACKEND_NUM_BRANCH_CHECKPOINTS);
    parameter int LQ_IDX_WIDTH = $clog2(BACKEND_LOAD_QUEUE_DEPTH);
    parameter int SQ_IDX_WIDTH = $clog2(BACKEND_STORE_QUEUE_DEPTH);
    typedef logic [BACKEND_NUM_BRANCH_CHECKPOINTS-1:0] branch_mask_t;
    typedef logic [BRANCH_TAG_WIDTH-1:0] branch_tag_t;

    // ========================================
    // Frontend -> Backend 接口
    // ========================================

    // Frontend 输出给 Backend 的单 lane 指令包。
    //
    // 该结构只表达前后端边界的架构合同：
    // - valid=1 表示该 lane 携带一条指令或一个与该 PC 绑定的取指异常。
    // - raw_instruction 保存前端实际取得的原始编码；RVC 使用低 16 位，高 16 位清零。
    // - instruction 始终是供 Backend Decoder 使用的规范 32 位指令；RVC 由前端解压。
    // - inst_len=2/4 分别表示 16/32 位指令；若取指在得到编码前失败，则允许为 0。
    // - 对非异常 entry，is_rvc 必须与 inst_len 一致：is_rvc <=> inst_len==2。
    // - exception_* 携带统一的精确异常元数据；取指地址异常的 tval 为故障地址，
    //   非法 RVC 可以在 tval 低位保留原始 16 位编码。
    //
    // instruction_id仍由Backend分配；FTQ身份与预测下一PC从Frontend随指令传播。
    typedef struct packed {
        logic                     valid;
        logic [PC_WIDTH-1:0]      pc;
        logic [ILEN-1:0]          raw_instruction;
        logic [ILEN-1:0]          instruction;
        logic [2:0]               inst_len;
        logic                     is_rvc;
        logic                     exception_valid;
        exception_cause_t         exception_cause;
        logic [XLEN-1:0]          exception_tval;
        logic [FTQ_INDEX_WIDTH-1:0] ftq_idx;
        logic                     ftq_last;
        logic [PC_WIDTH-1:0]      predicted_next_pc;
    } fetch_entry_t;

    // ========================================
    // 解码阶段数据结构
    // ========================================

    // 解码器输入：指令
    typedef struct packed {
        logic [ILEN-1:0] instruction;  // 32位指令
    } decode_in_t;

    typedef enum logic [2:0] {
        IMM_TYPE_NONE = 3'd0,
        IMM_TYPE_I    = 3'd1,
        IMM_TYPE_S    = 3'd2,
        IMM_TYPE_B    = 3'd3,
        IMM_TYPE_U    = 3'd4,
        IMM_TYPE_J    = 3'd5
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

    // 访存宽度按真实字节数编码。Load额外使用mem_unsigned决定零/符号扩展；
    // Store忽略mem_unsigned，只依据宽度生成byte mask。
    typedef enum logic [1:0] {
        MEM_SIZE_1B = 2'd0,
        MEM_SIZE_2B = 2'd1,
        MEM_SIZE_4B = 2'd2,
        MEM_SIZE_8B = 2'd3
    } mem_size_t;

    typedef enum logic [2:0] {
        BRANCH_COND_EQ  = 3'b000,
        BRANCH_COND_NE  = 3'b001,
        BRANCH_COND_LT  = 3'b100,
        BRANCH_COND_GE  = 3'b101,
        BRANCH_COND_LTU = 3'b110,
        BRANCH_COND_GEU = 3'b111
    } branch_cond_t;

    // 解码器输出：寄存器索引与整数 ALU 最小语义。
    // 当前阶段为 decode queue / rename 两拍拆分补齐这些信息：
    // - 哪些源寄存器需要读取
    // - 该指令是否会写 rd
    // - 第二操作数是否选择立即数
    // - I-type 12 位原始立即数字段以及对应类型
    // - 当前整数 ALU 操作类型
    // - 是否属于当前统一整数数据流
    // - 当前编码是否无法由本阶段识别，应形成非法指令异常
    // 还没有扩展提交、执行完成、提交状态等更完整字段。
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
        logic                      is_load;
        logic                      is_store;
        mem_size_t                 mem_size;
        logic                      mem_unsigned;
        logic                      is_branch;
        logic                      is_jal;
        logic                      is_jalr;
        branch_cond_t              branch_cond;
        logic                      needs_checkpoint;
        logic                      illegal_instruction;
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
        logic [ILEN-1:0]           raw_instruction;
        logic [ILEN-1:0]           instruction;
        logic [2:0]                inst_len;
        logic                      is_rvc;
        logic                      exception_valid;
        exception_cause_t          exception_cause;
        logic [XLEN-1:0]           exception_tval;
        logic [FTQ_INDEX_WIDTH-1:0] ftq_idx;
        logic                      ftq_last;
        logic [PC_WIDTH-1:0]       predicted_next_pc;
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
        logic                      is_load;
        logic                      is_store;
        mem_size_t                 mem_size;
        logic                      mem_unsigned;
        logic                      is_branch;
        logic                      is_jal;
        logic                      is_jalr;
        branch_cond_t              branch_cond;
        logic                      needs_checkpoint;
    } decoded_uop_t;

    // 已完成重命名和 ROB 分配的 uop。
    // 当前先作为 rename 阶段输出骨架保留下来，后续再接 issue / execute / commit。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
`ifdef O3_SIM
        logic [63:0]               kanata_id;
`endif
        logic [PC_WIDTH-1:0]       pc;
        logic [ILEN-1:0]           raw_instruction;
        logic [ILEN-1:0]           instruction;
        logic [2:0]                inst_len;
        logic                      is_rvc;
        logic                      exception_valid;
        exception_cause_t          exception_cause;
        logic [XLEN-1:0]           exception_tval;
        logic [FTQ_INDEX_WIDTH-1:0] ftq_idx;
        logic                      ftq_last;
        logic [PC_WIDTH-1:0]       predicted_next_pc;
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
        logic                      is_load;
        logic                      is_store;
        mem_size_t                 mem_size;
        logic                      mem_unsigned;
        logic                      is_branch;
        logic                      is_jal;
        logic                      is_jalr;
        branch_cond_t              branch_cond;
        logic                      needs_checkpoint;
        logic [PREG_IDX_WIDTH-1:0] src1_preg;
        logic [PREG_IDX_WIDTH-1:0] src2_preg;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic [PREG_IDX_WIDTH-1:0] old_dst_preg;
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [LQ_IDX_WIDTH-1:0]   lq_idx;
        logic [SQ_IDX_WIDTH-1:0]   sq_idx;
        branch_mask_t              branch_mask;
        branch_tag_t               branch_tag;
    } renamed_uop_t;

    // BRU 最终驱动该合同。当前 Backend 先原生接收它，使 Rename/ROB/LSQ
    // 的恢复机制不依赖具体分支执行单元的放置方式。
    typedef struct packed {
        logic                      valid;
        logic                      mispredict;
        branch_tag_t               branch_tag;
        logic [ROB_IDX_WIDTH-1:0]  branch_rob_idx;
        logic [FTQ_INDEX_WIDTH-1:0] ftq_idx;
        logic [PC_WIDTH-1:0]       branch_pc;
        logic                      is_branch;
        logic                      is_jal;
        logic                      is_jalr;
        logic                      actual_taken;
        logic [PC_WIDTH-1:0]       actual_target;
        logic [PC_WIDTH-1:0]       redirect_pc;
        logic                      completes_rob;
    } branch_resolution_t;

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
        branch_mask_t              branch_mask;
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
        branch_mask_t              branch_mask;
    } int_issue_pipe_uop_t;

    // 完成物理寄存器读取和立即数扩展后、进入执行单元前的 uop。
    // src2_value保留寄存器读值，imm_value保留扩展立即数；ALU由imm_valid显式选择。
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
        branch_mask_t              branch_mask;
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
        branch_mask_t              branch_mask;
    } int_execute_result_t;

    // Memory IQ取得全部读口后进入LSU的载荷。第一版只有一个Memory issue端口，
    // 因而LSU内部每级都是单entry valid/ready流水寄存器。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
`ifdef O3_SIM
        logic [63:0]               kanata_id;
`endif
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [LQ_IDX_WIDTH-1:0]   lq_idx;
        logic [SQ_IDX_WIDTH-1:0]   sq_idx;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic                      dst_write_en;
        logic                      is_load;
        logic                      is_store;
        mem_size_t                 mem_size;
        logic                      mem_unsigned;
        logic [XLEN-1:0]           base_value;
        logic [XLEN-1:0]           store_value;
        logic [XLEN-1:0]           imm_value;
        branch_mask_t              branch_mask;
    } mem_execute_uop_t;

    // Load完成后等待共享PRF写口的结果。真正获得写口时才广播并complete ROB。
    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
`ifdef O3_SIM
        logic [63:0]               kanata_id;
`endif
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [LQ_IDX_WIDTH-1:0]   lq_idx;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic [XLEN-1:0]           result;
        branch_mask_t              branch_mask;
    } load_result_t;

    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [FTQ_INDEX_WIDTH-1:0] ftq_idx;
        branch_tag_t               branch_tag;
        branch_mask_t              branch_mask;
        logic [PC_WIDTH-1:0]       pc;
        logic [2:0]                inst_len;
        logic [PC_WIDTH-1:0]       predicted_next_pc;
        logic                      is_branch;
        logic                      is_jal;
        logic                      is_jalr;
        branch_cond_t              branch_cond;
        logic [XLEN-1:0]           src1_value;
        logic [XLEN-1:0]           src2_value;
        logic [XLEN-1:0]           imm_value;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic                      dst_write_en;
    } branch_execute_uop_t;

    typedef struct packed {
        logic                      valid;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [FTQ_INDEX_WIDTH-1:0] ftq_idx;
        branch_tag_t               branch_tag;
        branch_mask_t              branch_mask;
        logic                      actual_taken;
        logic [PC_WIDTH-1:0]       branch_pc;
        logic                      is_branch;
        logic                      is_jal;
        logic                      is_jalr;
        logic [PC_WIDTH-1:0]       actual_target;
        logic [PC_WIDTH-1:0]       actual_next_pc;
        logic                      mispredict;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic                      dst_write_en;
        logic [XLEN-1:0]           link_value;
    } branch_result_t;

`ifdef ENABLE_RETIRE_INFO
    // Retire-time architectural observation record.
    // Valid entries describe instructions that committed from the ROB head.
    typedef struct packed {
        logic                      valid;
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
        logic [INST_ID_WIDTH-1:0]  instruction_id;
        logic [PC_WIDTH-1:0]       pc;
        logic [ILEN-1:0]           instruction;
        logic [REG_ADDR_WIDTH-1:0] rd;
        logic                      rd_write_en;
        logic [XLEN-1:0]           rd_wdata;
    } retire_info_t;
`endif

endpackage
