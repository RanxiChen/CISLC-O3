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

    // 解码器输出：寄存器索引与最小 uop 语义。
    // 当前阶段为后续的 decode queue / rename 两拍拆分补齐最小信息：
    // - 哪些源寄存器需要读取
    // - 该指令是否会写 rd
    // - 最小立即数字段
    // - 是否属于当前统一整数数据流
    // 还没有扩展异常、提交、执行完成、提交状态等更完整字段。
    typedef struct packed {
        logic [REG_ADDR_WIDTH-1:0] rs1;         // 源寄存器1
        logic [REG_ADDR_WIDTH-1:0] rs2;         // 源寄存器2
        logic [REG_ADDR_WIDTH-1:0] rd;          // 目的寄存器
        logic                      rs1_read_en; // 该指令是否真正读取 rs1
        logic                      rs2_read_en; // 该指令是否真正读取 rs2
        logic                      rd_write_en; // 该指令是否真正写回 rd
        logic [XLEN-1:0]           imm_value;   // 最小立即数字段，供后续执行级继续扩展
        logic                      is_int_uop;  // 当前是否纳入统一整数执行流
    } decode_out_t;

    // 解码完成但尚未重命名的 uop。
    // 当前作为 decode queue 的基本载荷，先稳住 frontend 信息和最小解码语义。
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
        logic [XLEN-1:0]           imm_value;
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
        logic [XLEN-1:0]           imm_value;
        logic                      is_int_uop;
        logic [PREG_IDX_WIDTH-1:0] src1_preg;
        logic [PREG_IDX_WIDTH-1:0] src2_preg;
        logic [PREG_IDX_WIDTH-1:0] dst_preg;
        logic [PREG_IDX_WIDTH-1:0] old_dst_preg;
        logic [ROB_IDX_WIDTH-1:0]  rob_idx;
    } renamed_uop_t;

endpackage
