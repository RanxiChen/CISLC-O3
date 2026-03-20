#include <stdio.h>
#include <stdint.h>
#include "svdpi.h"

// 全局状态变量 - 记录函数调用次数
static uint64_t g_call_counter = 0;

// DPI-C 函数：打印 frontend ready-valid handshake 的数据
void dpi_log_frontend_transaction(
    uint64_t inst_addr,    // 39-bit 地址，用 64-bit 存储
    uint32_t inst,         // 32-bit 指令
    uint8_t  inst_valid,   // 1-bit valid 信号
    uint8_t  inst_ready    // 1-bit ready 信号
) {
    // 每次调用时递增计数器
    g_call_counter++;

    // 只在 handshake 成功时打印（valid && ready）
    if (inst_valid && inst_ready) {
        printf("[DPI] Transaction fired - Addr: 0x%09lx, Inst: 0x%08x (Call #%lu)\n",
               inst_addr & 0x7FFFFFFFFF,  // 只取低39位
               inst,
               g_call_counter);
    }
}

// DPI-C 函数：每个周期都打印所有信号状态
void dpi_log_frontend_signals(
    uint64_t inst_addr,
    uint32_t inst,
    uint8_t  inst_valid,
    uint8_t  inst_ready
) {
    printf("[DPI] Addr: 0x%09lx, Inst: 0x%08x, Valid: %d, Ready: %d, Fire: %d\n",
           inst_addr & 0x7FFFFFFFFF,
           inst,
           inst_valid,
           inst_ready,
           inst_valid && inst_ready);
}

// DPI-C 函数：打印当前的全局计数器值
void dpi_print_call_counter() {
    printf("[DPI] Global call counter = %lu\n", g_call_counter);
}

// DPI-C 函数：重置全局计数器
void dpi_reset_call_counter() {
    printf("[DPI] Resetting call counter (was %lu)\n", g_call_counter);
    g_call_counter = 0;
}

// DPI-C 函数：获取全局计数器值（返回值）
uint64_t dpi_get_call_counter() {
    return g_call_counter;
}
