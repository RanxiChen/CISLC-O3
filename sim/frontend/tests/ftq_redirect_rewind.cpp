#include "Vftq.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <iostream>

namespace {

constexpr int kResetCycles = 2;
constexpr int kMaxWordsPerEntry = 8;
constexpr uint32_t kFtqDepth = 16;

constexpr int kBitValid = 251;
constexpr int kBitStartPc = 212;
constexpr int kBitEndPc = 173;
constexpr int kBitHasBranch = 172;
constexpr int kBitBranchPc = 133;
constexpr int kBitBranchSlot = 130;
constexpr int kBitBranchType = 127;
constexpr int kBitPredTaken = 126;
constexpr int kBitTargetPc = 87;
constexpr int kBitFallthroughPc = 48;
constexpr int kBitNextPc = 9;
constexpr int kBitException = 8;
constexpr int kBitExceptionCause = 0;

using EntryWords = std::array<uint32_t, kMaxWordsPerEntry>;

void eval_half_cycle(Vftq& dut, uint8_t clk_value) {
    dut.clk_i = clk_value;
    dut.eval();
}

void step(Vftq& dut) {
    eval_half_cycle(dut, 1);
    eval_half_cycle(dut, 0);
}

void clear_bits(EntryWords& words) {
    words.fill(0);
}

void set_bits(EntryWords& words, int lsb, int width, uint64_t value) {
    for (int bit = 0; bit < width; ++bit) {
        const int dst_bit = lsb + bit;
        const int word_idx = dst_bit / 32;
        const int bit_idx = dst_bit % 32;
        const uint32_t mask = uint32_t(1u) << bit_idx;
        if ((value >> bit) & 1u) {
            words[word_idx] |= mask;
        } else {
            words[word_idx] &= ~mask;
        }
    }
}

void write_entry(Vftq& dut, const EntryWords& words) {
    for (int i = 0; i < kMaxWordsPerEntry; ++i) {
        dut.bpu_entry_i[i] = words[i];
    }
}

EntryWords make_entry(uint64_t start_pc) {
    EntryWords words{};
    clear_bits(words);
    set_bits(words, kBitValid, 1, 1);
    set_bits(words, kBitStartPc, 39, start_pc);
    set_bits(words, kBitEndPc, 39, start_pc + 32);
    set_bits(words, kBitHasBranch, 1, 0);
    set_bits(words, kBitBranchPc, 39, 0);
    set_bits(words, kBitBranchSlot, 3, 0);
    set_bits(words, kBitBranchType, 3, 0);
    set_bits(words, kBitPredTaken, 1, 0);
    set_bits(words, kBitTargetPc, 39, 0);
    set_bits(words, kBitFallthroughPc, 39, start_pc + 32);
    set_bits(words, kBitNextPc, 39, start_pc + 32);
    set_bits(words, kBitException, 1, 0);
    set_bits(words, kBitExceptionCause, 8, 0);
    return words;
}

uint64_t get_bits(const VlWide<kMaxWordsPerEntry>& words, int lsb, int width) {
    uint64_t value = 0;
    for (int bit = 0; bit < width; ++bit) {
        const int src_bit = lsb + bit;
        const uint64_t bit_value = (words[src_bit / 32] >> (src_bit % 32)) & 1u;
        value |= bit_value << bit;
    }
    return value;
}

[[noreturn]] void fail(const char* msg) {
    std::cerr << "FAIL: " << msg << "\n";
    std::exit(1);
}

void expect_eq(uint32_t actual, uint32_t expected, const char* msg) {
    if (actual != expected) {
        std::cerr << "FAIL: " << msg
                  << " expected=" << expected
                  << " actual=" << actual
                  << "\n";
        std::exit(1);
    }
}

void expect_true(bool cond, const char* msg) {
    if (!cond) {
        fail(msg);
    }
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vftq dut;

    dut.clk_i = 0;
    dut.rst_i = 1;
    dut.bpu_valid_i = 0;
    dut.ifu_ready_i = 0;
    dut.redirect_valid_i = 0;
    dut.redirect_ftq_idx_i = 0;
    dut.redirect_branch_pc_i = 0;
    dut.redirect_redirect_pc_i = 0;
    dut.redirect_actual_taken_i = 0;
    write_entry(dut, make_entry(0));

    for (int i = 0; i < kResetCycles; ++i) {
        step(dut);
    }

    dut.rst_i = 0;

    for (uint64_t start_pc = 0; start_pc < 128; start_pc += 32) {
        dut.bpu_valid_i = 1;
        dut.ifu_ready_i = 0;
        write_entry(dut, make_entry(start_pc));
        step(dut);
    }

    dut.bpu_valid_i = 0;
    expect_eq(dut.dbg_alloc_tail_o, 4, "alloc_tail should advance after four enqueues");
    expect_eq(dut.dbg_ifu_head_o, 0, "ifu_head should stay at zero before consume");
    expect_eq(dut.dbg_allocated_count_o, 4, "allocated_count should track four allocated entries");

    dut.ifu_ready_i = 1;
    eval_half_cycle(dut, 0);
    for (int i = 0; i < 3; ++i) {
        expect_true(dut.ifu_valid_o, "ifu should see valid entries before redirect");
        step(dut);
    }

    expect_eq(dut.dbg_ifu_head_o, 3, "ifu_head should point at the fourth entry before redirect");

    dut.ifu_ready_i = 0;
    dut.redirect_valid_i = 1;
    dut.redirect_ftq_idx_i = 1;
    dut.redirect_branch_pc_i = 0x24;
    dut.redirect_redirect_pc_i = 0x100;
    dut.redirect_actual_taken_i = 1;
    eval_half_cycle(dut, 0);
    step(dut);
    dut.redirect_valid_i = 0;
    eval_half_cycle(dut, 0);

    expect_eq(dut.dbg_alloc_tail_o, 2, "redirect should rewind alloc_tail to branch+1");
    expect_eq(dut.dbg_ifu_head_o, 2, "redirect should rewind ifu_head to branch+1");
    expect_eq(dut.dbg_allocated_count_o, 2, "redirect should shrink allocated_count to retained window");
    expect_true(!dut.ifu_valid_o, "redirect should leave the rewound slot empty until refill from BPU");

    dut.bpu_valid_i = 1;
    write_entry(dut, make_entry(0x100));
    eval_half_cycle(dut, 0);
    step(dut);
    dut.bpu_valid_i = 0;
    eval_half_cycle(dut, 0);

    expect_eq(dut.dbg_alloc_tail_o, 3, "new enqueue should advance alloc_tail from rewound slot");
    expect_eq(dut.dbg_ifu_head_o, 2, "new enqueue should not skip the rewound slot");
    expect_eq(dut.dbg_allocated_count_o, 3, "new enqueue should grow allocated_count from the retained window");
    expect_true(dut.ifu_valid_o, "rewound slot should become visible to IFU after re-enqueue");
    expect_eq(dut.ifu_ftq_idx_o, 2, "IFU should resume from the first slot after the branch");
    expect_eq(static_cast<uint32_t>(get_bits(dut.ifu_entry_o, kBitStartPc, 39)), 0x100, "rewound slot should carry the redirected block");

    dut.final();
    std::cout << "PASS: ftq redirect rewind behavior holds\n";
    return 0;
}
