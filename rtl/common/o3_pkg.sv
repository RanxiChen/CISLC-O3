/**
 * O3 后端旧流水类型包
 *
 * 定位（2026-10-02 框架阶段）：
 * - 保存后端现有流水载荷（decode_out_t、decoded_uop_t、renamed_uop_t、各执行级 uop 与结果）。
 * - 本包不再写任何可调数值：原 BACKEND_* 参数全部从 o3_cfg_pkg::O3_CFG 推导，名字保留，
 *   使现有后端 RTL 继续引用同一名字。
 * - ISA 常量（XLEN/ILEN/REG_ADDR_WIDTH/exception cause）来自 o3_isa_pkg，并由本包重新导出。
 * - 新机制所需字段通过 o3_types_pkg::uop_ext_t / rename_ext_t 以 `ext` 字段挂在旧结构上；
 *   这些字段当前没有生产者和消费者，标为“框架新增”。
 * - FTQ 身份改为 o3_types_pkg::ftq_id_t（idx + 代际），槽位在 ext.ftq_slot。
 *
 * 已删除：fetch_entry_t（迁入 o3_types_pkg）、FTQ_INDEX_WIDTH、ICACHE_LINE_BYTES、
 * 旧 ITCM_* 常量与 DEFAULT_NUM_*。
 */

package o3_pkg;
    import o3_cfg_pkg::*;
    // Explicit imports make wildcard re-export portable to Vivado 2022.2.
    import o3_isa_pkg::XLEN;
    import o3_isa_pkg::ILEN;
    import o3_isa_pkg::REG_ADDR_WIDTH;
    import o3_isa_pkg::NUM_ARCH_REGS;
    import o3_isa_pkg::FFLAGS_W;
    import o3_isa_pkg::FRM_W;
    import o3_isa_pkg::CSR_ADDR_W;
    import o3_isa_pkg::EXCEPTION_CAUSE_INST_ADDR_MISALIGNED;
    import o3_isa_pkg::EXCEPTION_CAUSE_INST_ACCESS_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION;
    import o3_isa_pkg::EXCEPTION_CAUSE_BREAKPOINT;
    import o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED;
    import o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ACCESS_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED;
    import o3_isa_pkg::EXCEPTION_CAUSE_STORE_ACCESS_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_ECALL_U;
    import o3_isa_pkg::EXCEPTION_CAUSE_ECALL_S;
    import o3_isa_pkg::EXCEPTION_CAUSE_ECALL_M;
    import o3_isa_pkg::EXCEPTION_CAUSE_INST_PAGE_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_LOAD_PAGE_FAULT;
    import o3_isa_pkg::EXCEPTION_CAUSE_STORE_PAGE_FAULT;
    import o3_isa_pkg::exception_cause_t;
    import o3_types_pkg::*;
    export o3_isa_pkg::*;

    // ========================================
    // 由 O3_CFG 推导的旧名字
    // ========================================
    // PC 宽度与前端 vaddr_t 一致；目标地址检查的完整方案见 B12 第 4 条（待定）。
    parameter int PC_WIDTH       = O3_CFG.core.vaddr_bits;
    parameter int INST_ID_WIDTH  = 64;   // 仿真调试编号宽度，不是微架构参数
    parameter int IMM_RAW_WIDTH  = 21;   // 由 RISC-V 立即数格式决定

    // 旧代码的统一 lane 数：现有 rename 前缀规划器、ROB 分配、LQ/SQ 分配按此宽度工作。
    // 现有路径直接取 O3_CFG.be.rename.width；B42 为 4，R1/R2 按综合时序触发。
    parameter int BACKEND_MACHINE_WIDTH            = O3_CFG.be.rename.width;
    parameter int BACKEND_DECODE_WIDTH             = O3_CFG.be.decode.width;
    parameter int BACKEND_COMMIT_WIDTH             = O3_CFG.core.commit_width;
    parameter int BACKEND_NUM_PHYS_REGS            = O3_CFG.be.rename.int_phys_regs;
    parameter int BACKEND_NUM_FP_PHYS_REGS         = O3_CFG.be.rename.fp_phys_regs;
    parameter int BACKEND_NUM_ARCH_REGS            = NUM_ARCH_REGS;
    parameter int BACKEND_NUM_ROB_ENTRIES          = O3_CFG.be.rob.entries;
    parameter int BACKEND_DECODE_QUEUE_DEPTH       = O3_CFG.be.decode.queue_depth;
    parameter int BACKEND_DISPATCH_WIDTH           = O3_CFG.be.dispatch.width;
    parameter int BACKEND_INT_ISSUE_QUEUE_DEPTH    = O3_CFG.be.dispatch.int_iq_depth;
    parameter int BACKEND_MEM_ISSUE_QUEUE_DEPTH    = O3_CFG.be.dispatch.mem_iq_depth;
    parameter int BACKEND_BRANCH_ISSUE_QUEUE_DEPTH = O3_CFG.be.dispatch.br_iq_depth;
    parameter int BACKEND_NUM_INT_ALUS             = O3_CFG.be.exec.num_alu;
    parameter int BACKEND_NUM_BRANCH_CHECKPOINTS   = O3_CFG.be.rename.checkpoints;
    parameter int BACKEND_LOAD_QUEUE_DEPTH         = O3_CFG.be.lsu.lq_depth;
    parameter int BACKEND_STORE_QUEUE_DEPTH        = O3_CFG.be.lsu.sq_depth;
    parameter int BACKEND_RENAME_DISPATCH_QUEUE_DEPTH = O3_CFG.be.rename.rdq_depth;

    parameter int PREG_IDX_WIDTH = PREG_W;      // 两域共用宽度（o3_types_pkg）
    parameter int ROB_IDX_WIDTH  = ROB_IDX_W;

    // DTCM：基线未设计，现状沿用（见 O3_CFG.be.lsu）。
    parameter logic [XLEN-1:0] DTCM_BASE_ADDR  = XLEN'(O3_CFG.be.lsu.dtcm_base);
    parameter int              DTCM_SIZE_BYTES = O3_CFG.be.lsu.dtcm_bytes;

    parameter int BRANCH_TAG_WIDTH = BR_TAG_W;
    parameter int LQ_IDX_WIDTH = LQ_IDX_W;
    parameter int SQ_IDX_WIDTH = SQ_IDX_W;
    typedef logic [BACKEND_NUM_BRANCH_CHECKPOINTS-1:0] branch_mask_t;
    typedef logic [BRANCH_TAG_WIDTH-1:0] branch_tag_t;

    // ========================================
    // Frontend -> Backend 接口
    // ========================================

    // fetch_entry_t 已于 2026-10-02 迁入 o3_types_pkg（前端框架阶段），并补充
    // 动态 FTQ 身份（idx+代际）与槽位，PC 改用 vaddr_t。后端尚未迁移，仍引用本包
    // 旧定义的位置（backend.sv、tb/*）在后端推进时改为 import o3_types_pkg，
    // 当前暂时不能编译，符合 agent.md 的顺序重构约定。

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
        logic                      src1_is_pc; // 第一操作数选择当前指令PC；AUIPC使用
        logic                      use_imm;     // 第二操作数是否取立即数
        imm_type_t                 imm_type;    // 立即数原始编码类型；全 0 表示无效
        logic [IMM_RAW_WIDTH-1:0]  imm_raw;     // 原始立即数字段；当前只承载 I-type[31:20]
        int_alu_op_t               int_alu_op;  // 整数 ALU 操作类型
        logic                      is_word_op; // RV64 *W结果截断为32位后符号扩展
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
        uop_ext_t                  ext;         // 框架新增：M/A/F/D/Zicsr/SYSTEM、寄存器域、第三源（未产生）
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
        ftq_id_t                   ftq_id;
        logic                      ftq_last;
        logic [PC_WIDTH-1:0]       predicted_next_pc;
        logic [REG_ADDR_WIDTH-1:0] rs1;
        logic [REG_ADDR_WIDTH-1:0] rs2;
        logic [REG_ADDR_WIDTH-1:0] rd;
        logic                      rs1_read_en;
        logic                      rs2_read_en;
        logic                      rd_write_en;
        logic                      src1_is_pc;
        logic                      use_imm;
        imm_type_t                 imm_type;
        logic [IMM_RAW_WIDTH-1:0]  imm_raw;
        int_alu_op_t               int_alu_op;
        logic                      is_word_op;
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
        uop_ext_t                  ext;         // 框架新增（未接入逻辑）
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
        ftq_id_t                   ftq_id;
        logic                      ftq_last;
        logic [PC_WIDTH-1:0]       predicted_next_pc;
        logic [REG_ADDR_WIDTH-1:0] rs1;
        logic [REG_ADDR_WIDTH-1:0] rs2;
        logic [REG_ADDR_WIDTH-1:0] rd;
        logic                      rs1_read_en;
        logic                      rs2_read_en;
        logic                      rd_write_en;
        logic                      src1_is_pc;
        logic                      use_imm;
        imm_type_t                 imm_type;
        logic [IMM_RAW_WIDTH-1:0]  imm_raw;
        int_alu_op_t               int_alu_op;
        logic                      is_word_op;
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
        uop_ext_t                  ext;         // 框架新增（未接入逻辑）
        rename_ext_t               rext;        // 框架新增：第三源 preg（未接入逻辑）
        mdu_fuse_t                 mdu_fuse; // B34 member identity after dispatch pair acceptance
    } renamed_uop_t;

    // 前端目标框架不再消费本结构：执行解析改为 o3_types_pkg::bru_resolve_t，
    // 提交端系统重定向为 sys_redirect_t，由前端 redirect_arbiter 按 D24 统一仲裁。
    // 后端迁移时替换本结构的生产端。
    // BRU 最终驱动该合同。当前 Backend 先原生接收它，使 Rename/ROB/LSQ
    // 的恢复机制不依赖具体分支执行单元的放置方式。
    typedef struct packed {
        logic                      valid;
        logic                      mispredict;
        branch_tag_t               branch_tag;
        logic [ROB_IDX_WIDTH-1:0]  branch_rob_idx;
        ftq_id_t                   ftq_id;
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
        logic                      is_word_op;
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
        ftq_id_t                   ftq_id;
        fetch_slot_t               ftq_slot;
        branch_tag_t               branch_tag;
        branch_mask_t              branch_mask;
        logic [PC_WIDTH-1:0]       pc;
        logic [2:0]                inst_len;
        logic [PC_WIDTH-1:0]       predicted_next_pc;
        cfi_type_e                 cfi_type;
        ras_action_e               ras_action;
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
        ftq_id_t                   ftq_id;
        fetch_slot_t               ftq_slot;
        branch_tag_t               branch_tag;
        branch_mask_t              branch_mask;
        logic                      actual_taken;
        logic [PC_WIDTH-1:0]       branch_pc;
        logic [2:0]                inst_len;
        cfi_type_e                 cfi_type;
        ras_action_e               ras_action;
        logic                      is_branch;
        logic                      is_jal;
        logic                      is_jalr;
        logic [PC_WIDTH-1:0]       actual_target;
        logic [PC_WIDTH-1:0]       actual_next_pc;
        logic                      mispredict;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic                      dst_write_en;
        logic [XLEN-1:0]           link_value;
        exc_info_t                 exc; // L6 IALIGN=32 target exception (L7 C relaxes to 16)
    } branch_result_t;

`ifdef ENABLE_RETIRE_INFO
    // O3-T02 observation only; never used by execution/control logic.
    // mem_kind: 0=none, 1=load, 2=store; size is log2(bytes).
    typedef struct packed {
        logic [1:0] kind;
        logic [XLEN-1:0] addr;
        logic [1:0] size;
        logic [XLEN-1:0] data;
    } retire_mem_t;
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
        retire_mem_t               mem;
        logic                      fp_valid, csr_valid, exc_valid;
        logic [4:0]                fp_rd;
        logic [63:0]               fp_wdata;
        logic [11:0]               csr_addr;
        logic [63:0]               csr_wdata, exc_cause, exc_tval;
    } retire_info_t;
`endif

    // ========================================
    // 共享辅助函数（2026-10-02 从 backend.sv 迁出，逻辑未改）
    // ========================================
    // 立即数按原始编码类型符号扩展。
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

    // 本拍误预测是否杀死依赖该分支的项。
    function automatic logic br_killed(input branch_mask_t mask, input branch_resolution_t res);
        br_killed = res.valid && res.mispredict && mask[res.branch_tag];
    endfunction

    // 本拍解析（正确或错误）后清除对应 branch bit。
    function automatic branch_mask_t br_resolved_mask(input branch_mask_t mask,
                                                      input branch_resolution_t res);
        branch_mask_t result;
        begin
            result = mask;
            if (res.valid) begin
                result[res.branch_tag] = 1'b0;
            end
            br_resolved_mask = result;
        end
    endfunction

endpackage
