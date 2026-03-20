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

    // 解码器输出：寄存器索引
    typedef struct packed {
        logic [REG_ADDR_WIDTH-1:0] rs1;  // 源寄存器1
        logic [REG_ADDR_WIDTH-1:0] rs2;  // 源寄存器2
        logic [REG_ADDR_WIDTH-1:0] rd;   // 目的寄存器
    } decode_out_t;

endpackage
