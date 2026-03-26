/**
 * DPI-C 函数声明头文件
 * 使用方式: `include "dpi_functions.svh"
 */

`ifndef DPI_FUNCTIONS_SVH
`define DPI_FUNCTIONS_SVH

// ============================================================================
// 日志函数
// ============================================================================

import "DPI-C" function void dpi_log_frontend_transaction(
    input longint unsigned inst_addr,
    input int unsigned inst,
    input bit inst_valid,
    input bit inst_ready
);

import "DPI-C" function void dpi_log_frontend_signals(
    input longint unsigned inst_addr,
    input int unsigned inst,
    input bit inst_valid,
    input bit inst_ready
);

// ============================================================================
// 计数器函数
// ============================================================================

import "DPI-C" function void dpi_print_call_counter();
import "DPI-C" function void dpi_reset_call_counter();
import "DPI-C" function longint unsigned dpi_get_call_counter();

// ============================================================================
// Backend 虚拟前端仿真函数
// ============================================================================

import "DPI-C" function void dpi_backend_stream_reset();

import "DPI-C" function int unsigned dpi_backend_get_total_groups();

import "DPI-C" function bit dpi_backend_has_group(
    input int unsigned group_idx
);

import "DPI-C" function void dpi_backend_get_fetch_entry(
    input int unsigned group_idx,
    input int unsigned lane_idx,
    output longint unsigned pc,
    output int unsigned inst,
    output bit exception,
    output bit valid
);

import "DPI-C" function void dpi_backend_log_fetch_lane(
    input longint unsigned cycle,
    input int unsigned group_idx,
    input int unsigned lane_idx,
    input bit fire,
    input longint unsigned pc,
    input int unsigned inst
);

import "DPI-C" function string dpi_backend_disasm_rv64i(
    input int unsigned inst
);

// ============================================================================
// RISC-V 执行模型 - 指令解码
// ============================================================================

import "DPI-C" function void dpi_decode_instruction(
    input int unsigned inst,
    output bit out_is_branch,
    output bit out_is_jump,
    output byte unsigned out_funct3,
    output longint unsigned out_imm
);

// ============================================================================
// RISC-V 执行模型 - 分支执行
// ============================================================================

import "DPI-C" function bit dpi_execute_branch(
    input longint unsigned pc,
    input int unsigned inst,
    input longint unsigned rs1_val,
    input longint unsigned rs2_val
);

import "DPI-C" function bit dpi_predict_branch(
    input longint unsigned pc,
    input int unsigned inst
);

// ============================================================================
// RISC-V 执行模型 - 跳转执行
// ============================================================================

import "DPI-C" function longint unsigned dpi_execute_jal(
    input longint unsigned pc,
    input int unsigned inst
);

import "DPI-C" function longint unsigned dpi_execute_jalr(
    input longint unsigned pc,
    input int unsigned inst,
    input longint unsigned rs1_val
);

// ============================================================================
// RISC-V 执行模型 - 统计和状态管理
// ============================================================================

import "DPI-C" function void dpi_print_branch_stats();
import "DPI-C" function void dpi_reset_exec_state();

import "DPI-C" function void dpi_set_register(
    input int unsigned reg_num,
    input longint unsigned value
);

import "DPI-C" function longint unsigned dpi_get_register(
    input int unsigned reg_num
);

`endif // DPI_FUNCTIONS_SVH
