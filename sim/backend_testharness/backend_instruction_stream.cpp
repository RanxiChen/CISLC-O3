#include <array>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <vector>
#include "svdpi.h"

namespace {

constexpr uint32_t kMachineWidth = 6;
constexpr uint32_t kGroupStrideBytes = kMachineWidth * 4;

using InstGroup = std::array<uint32_t, kMachineWidth>;

// 这些 helper 只用于构造固定的 RV64I 整形运算指令流。
constexpr uint32_t encode_i_type(int32_t imm12, uint32_t rs1, uint32_t funct3, uint32_t rd, uint32_t opcode) {
    return ((static_cast<uint32_t>(imm12) & 0xFFFu) << 20)
        | ((rs1 & 0x1Fu) << 15)
        | ((funct3 & 0x7u) << 12)
        | ((rd & 0x1Fu) << 7)
        | (opcode & 0x7Fu);
}

constexpr uint32_t encode_shift_imm(uint32_t shamt, uint32_t funct6, uint32_t rs1, uint32_t funct3, uint32_t rd) {
    return ((funct6 & 0x3Fu) << 26)
        | ((shamt & 0x3Fu) << 20)
        | ((rs1 & 0x1Fu) << 15)
        | ((funct3 & 0x7u) << 12)
        | ((rd & 0x1Fu) << 7)
        | 0x13u;
}

constexpr uint32_t encode_r_type(uint32_t funct7, uint32_t rs2, uint32_t rs1, uint32_t funct3, uint32_t rd) {
    return ((funct7 & 0x7Fu) << 25)
        | ((rs2 & 0x1Fu) << 20)
        | ((rs1 & 0x1Fu) << 15)
        | ((funct3 & 0x7u) << 12)
        | ((rd & 0x1Fu) << 7)
        | 0x33u;
}

std::vector<InstGroup> build_stream() {
    std::vector<InstGroup> groups;

    // 当前所有指令都故意选成“只读 x0 或彼此无关”的整形运算，
    // 目的是在还没有真实写回网络时，仍然能稳定驱动 decode/rename/issue/regread/execute 主链路。
    groups.push_back({
        encode_i_type(1,  0, 0b000,  1, 0x13),  // addi  x1,  x0, 1
        encode_i_type(18, 0, 0b110,  2, 0x13),  // ori   x2,  x0, 18
        encode_i_type(85, 0, 0b100,  3, 0x13),  // xori  x3,  x0, 85
        encode_i_type(127,0, 0b111,  4, 0x13),  // andi  x4,  x0, 127
        encode_i_type(-1, 0, 0b000,  5, 0x13),  // addi  x5,  x0, -1
        encode_i_type(1,  0, 0b010,  6, 0x13)   // slti  x6,  x0, 1
    });

    groups.push_back({
        encode_shift_imm(1, 0b000000, 0, 0b001,  7), // slli  x7,  x0, 1
        encode_shift_imm(2, 0b000000, 0, 0b101,  8), // srli  x8,  x0, 2
        encode_shift_imm(3, 0b010000, 0, 0b101,  9), // srai  x9,  x0, 3
        encode_i_type(1,   0, 0b011, 10, 0x13),      // sltiu x10, x0, 1
        encode_i_type(0,   0, 0b100, 11, 0x13),      // xori  x11, x0, 0
        encode_i_type(42,  0, 0b110, 12, 0x13)       // ori   x12, x0, 42
    });

    groups.push_back({
        encode_i_type(31, 0, 0b111, 13, 0x13),        // andi  x13, x0, 31
        encode_r_type(0b0000000, 0, 0, 0b000, 14),    // add   x14, x0, x0
        encode_r_type(0b0100000, 0, 0, 0b000, 15),    // sub   x15, x0, x0
        encode_r_type(0b0000000, 0, 0, 0b100, 16),    // xor   x16, x0, x0
        encode_r_type(0b0000000, 0, 0, 0b110, 17),    // or    x17, x0, x0
        encode_r_type(0b0000000, 0, 0, 0b111, 18)     // and   x18, x0, x0
    });

    groups.push_back({
        encode_r_type(0b0000000, 0, 0, 0b001, 19),    // sll   x19, x0, x0
        encode_r_type(0b0000000, 0, 0, 0b101, 20),    // srl   x20, x0, x0
        encode_r_type(0b0100000, 0, 0, 0b101, 21),    // sra   x21, x0, x0
        encode_r_type(0b0000000, 0, 0, 0b010, 22),    // slt   x22, x0, x0
        encode_r_type(0b0000000, 0, 0, 0b011, 23),    // sltu  x23, x0, x0
        encode_i_type(7,  0, 0b000, 24, 0x13)         // addi  x24, x0, 7
    });

    groups.push_back({
        encode_i_type(9,  0, 0b000, 25, 0x13),        // addi  x25, x0, 9
        encode_i_type(3,  0, 0b110, 26, 0x13),        // ori   x26, x0, 3
        encode_i_type(12, 0, 0b100, 27, 0x13),        // xori  x27, x0, 12
        encode_i_type(63, 0, 0b111, 28, 0x13),        // andi  x28, x0, 63
        encode_shift_imm(4, 0b000000, 0, 0b001, 29),  // slli  x29, x0, 4
        encode_shift_imm(1, 0b000000, 0, 0b101, 30)   // srli  x30, x0, 1
    });

    groups.push_back({
        encode_shift_imm(5, 0b010000, 0, 0b101, 31),  // srai  x31, x0, 5
        encode_r_type(0b0000000, 0, 0, 0b000, 1),     // add   x1,  x0, x0
        encode_r_type(0b0100000, 0, 0, 0b000, 2),     // sub   x2,  x0, x0
        encode_r_type(0b0000000, 0, 0, 0b001, 3),     // sll   x3,  x0, x0
        encode_r_type(0b0000000, 0, 0, 0b101, 4),     // srl   x4,  x0, x0
        encode_i_type(0,  0, 0b000, 5, 0x13)          // addi  x5,  x0, 0
    });

    return groups;
}

const std::vector<InstGroup> g_inst_groups = build_stream();
uint64_t g_fetch_count = 0;

}  // namespace

extern "C" {

void dpi_backend_stream_reset() {
    g_fetch_count = 0;
    std::cout << "[BACKEND_DPI] Reset backend instruction stream, groups="
              << g_inst_groups.size() << std::endl;
}

uint32_t dpi_backend_get_total_groups() {
    return static_cast<uint32_t>(g_inst_groups.size());
}

uint8_t dpi_backend_has_group(uint32_t group_idx) {
    return (group_idx < g_inst_groups.size()) ? 1 : 0;
}

void dpi_backend_get_fetch_entry(
    uint32_t group_idx,
    uint32_t lane_idx,
    uint64_t* pc,
    uint32_t* inst,
    uint8_t* exception,
    uint8_t* valid
) {
    if ((group_idx >= g_inst_groups.size()) || (lane_idx >= kMachineWidth)) {
        *pc = 0;
        *inst = 0;
        *exception = 0;
        *valid = 0;
        return;
    }

    *pc = static_cast<uint64_t>(group_idx) * kGroupStrideBytes + static_cast<uint64_t>(lane_idx) * 4ull;
    *inst = g_inst_groups[group_idx][lane_idx];
    *exception = 0;
    *valid = 1;
}

void dpi_backend_log_fetch_lane(
    uint64_t cycle,
    uint32_t group_idx,
    uint32_t lane_idx,
    uint8_t fire,
    uint64_t pc,
    uint32_t inst
) {
    if (!fire) {
        return;
    }

    if (lane_idx == 0) {
        g_fetch_count++;
        std::cout << "[BACKEND_DPI] Cycle " << std::dec << cycle
                  << " accepted group " << group_idx
                  << " (fetch #" << g_fetch_count << ")"
                  << std::endl;
    }

    std::cout << "  lane" << std::dec << lane_idx
              << " pc=0x" << std::hex << pc
              << " inst=0x" << inst
              << std::endl;
}

}  // extern "C"
