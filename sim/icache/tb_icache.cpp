#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <sstream>

#include "VICache.h"
#include "verilated.h"

namespace {

constexpr int kNumSets = 64;
constexpr int kNumBanks = 4;
constexpr int kClkHalfPeriod = 5;

vluint64_t sim_time = 0;

void step_half_cycle(VICache& dut) {
    dut.clk = !dut.clk;
    dut.eval();
    sim_time += kClkHalfPeriod;
}

void step_full_cycle(VICache& dut) {
    step_half_cycle(dut);
    step_half_cycle(dut);
}

void drive_negedge(VICache& dut, uint64_t pc, bool valid) {
    if (dut.clk != 0) {
        step_half_cycle(dut);
    }
    dut.s0_pc = pc;
    dut.s0_valid = valid ? 1 : 0;
    dut.eval();
}

std::string hex_u64(uint64_t value) {
    std::ostringstream oss;
    oss << "0x" << std::hex << std::setw(16) << std::setfill('0') << value;
    return oss.str();
}

std::string hex_u32(uint32_t value) {
    std::ostringstream oss;
    oss << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return oss.str();
}

bool check_out_data(const VICache& dut, uint8_t expected_byte) {
    const uint32_t expected_word = uint32_t(expected_byte) * 0x01010101u;
    for (int word = 0; word < 4; ++word) {
        if (dut.out_data[word] != expected_word) {
            return false;
        }
    }
    return true;
}

std::string format_out_data(const VICache& dut) {
    std::ostringstream oss;
    oss << "0x";
    for (int word = 3; word >= 0; --word) {
        oss << std::hex << std::setw(8) << std::setfill('0') << dut.out_data[word];
    }
    return oss.str();
}

std::string format_expected_data(uint8_t expected_byte) {
    std::ostringstream oss;
    const uint32_t expected_word = uint32_t(expected_byte) * 0x01010101u;
    oss << "0x";
    for (int word = 0; word < 4; ++word) {
        oss << std::hex << std::setw(8) << std::setfill('0') << expected_word;
    }
    return oss.str();
}

}  // namespace

double sc_time_stamp() {
    return static_cast<double>(sim_time);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    VICache dut;
    dut.clk = 0;
    dut.rst = 1;
    dut.flush = 0;
    dut.s0_valid = 0;
    dut.s0_pc = 0;
    dut.eval();

    int pass_count = 0;
    int fail_count = 0;

    std::cout << "=== ICache All-Hit Test (Verilator/C++) ===\n";

    for (int i = 0; i < 3; ++i) {
        step_full_cycle(dut);
    }
    dut.rst = 0;
    dut.eval();
    step_full_cycle(dut);

    for (int set = 0; set < kNumSets; ++set) {
        for (int bank = 0; bank < kNumBanks; ++bank) {
            const uint64_t pc = (static_cast<uint64_t>(set) << 6) |
                                (static_cast<uint64_t>(bank) << 4);
            const uint8_t expected_byte = static_cast<uint8_t>(((set << 2) | bank) & 0xff);

            drive_negedge(dut, pc, true);
            step_half_cycle(dut);
            step_half_cycle(dut);
            drive_negedge(dut, pc, false);

            bool pass = true;
            std::ostringstream reason;

            if (!dut.out_valid) {
                pass = false;
                reason << "out_valid=0";
            } else if (!dut.out_hit) {
                pass = false;
                reason << "out_hit=0";
            } else if (dut.out_pc != pc) {
                pass = false;
                reason << "out_pc mismatch got=" << hex_u64(dut.out_pc)
                       << " exp=" << hex_u64(pc);
            } else if (!check_out_data(dut, expected_byte)) {
                pass = false;
                reason << "out_data mismatch got=" << format_out_data(dut)
                       << " exp=" << format_expected_data(expected_byte);
            }

            if (!pass) {
                std::cerr << "FAIL: set=" << set
                          << " bank=" << bank
                          << " pc=" << hex_u64(pc)
                          << " " << reason.str() << "\n";
                ++fail_count;
            } else {
                std::cout << "PASS: set=" << set
                          << " bank=" << bank
                          << " pc=" << hex_u64(pc)
                          << " data=" << format_out_data(dut)
                          << " hit=" << static_cast<int>(dut.out_hit) << "\n";
                std::cout << "      dbg: s1_set=" << static_cast<int>(dut.dbg_s1_set_idx)
                          << " s1_bank=" << static_cast<int>(dut.dbg_s1_bank_idx)
                          << " s1_tag=0x" << std::hex << dut.dbg_s1_tag << std::dec
                          << " way_hit=" << hex_u32(dut.dbg_s1_way_hit) << "\n";
                ++pass_count;
            }

            step_full_cycle(dut);
        }
    }

    std::cout << "\n=== Summary: " << pass_count << " passed, " << fail_count << " failed ===\n";
    if (fail_count == 0) {
        std::cout << "ALL TESTS PASSED\n";
    } else {
        std::cout << "SOME TESTS FAILED\n";
    }

    dut.final();
    return (fail_count == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
