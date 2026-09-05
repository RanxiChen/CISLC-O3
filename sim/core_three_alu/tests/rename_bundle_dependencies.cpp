#include "Vo3_core.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iomanip>
#include <iostream>
#include <string>

namespace {

constexpr int kResetCycles = 5;
constexpr int kMaxCycles = 1000;
constexpr int kRefillLatencyCycles = 6;
constexpr int kLineBytes = 64;
constexpr int kInstBytes = 4;
constexpr int kInstsPerLine = kLineBytes / kInstBytes;
constexpr int kRetirePorts = 3;

// All four instructions occupy one fetch/decode/rename bundle.  The last
// three exercise same-bundle RAW forwarding, and lane 3 also exercises WAW
// old-destination chaining for x1.
constexpr uint32_t kAddiX1X0Five = 0x00500093u;  // x1 = 5
constexpr uint32_t kAddX2X1X1 = 0x00108133u;     // x2 = 10, reads lane0 x1
constexpr uint32_t kSubX3X2X1 = 0x401101b3u;     // x3 = 5, reads lane1 x2 and lane0 x1
constexpr uint32_t kXorX1X3X2 = 0x0021c0b3u;     // x1 = 15, reads lane2/lane1 and overwrites lane0 x1
constexpr uint32_t kInvalidInst = 0xffffffffu;

struct PendingRefill {
    uint64_t pc;
    int remaining_cycles;
};

struct RetireInfo {
    bool valid;
    uint64_t rob_idx;
    uint64_t instruction_id;
    uint64_t pc;
    uint32_t instruction;
    uint32_t rd;
    bool rd_write_en;
    uint64_t rd_wdata;
};

struct ExpectedRetire {
    uint64_t pc;
    uint32_t instruction;
    uint32_t rd;
    uint64_t rd_wdata;
};

constexpr std::array<ExpectedRetire, 4> kExpected = {{
    {.pc = 0, .instruction = kAddiX1X0Five, .rd = 1, .rd_wdata = 5},
    {.pc = 4, .instruction = kAddX2X1X1, .rd = 2, .rd_wdata = 10},
    {.pc = 8, .instruction = kSubX3X2X1, .rd = 3, .rd_wdata = 5},
    {.pc = 12, .instruction = kXorX1X3X2, .rd = 1, .rd_wdata = 15},
}};

void require(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "[rename_bundle_dependencies][assert] " << message << "\n";
        std::exit(1);
    }
}

void step(Vo3_core& dut) {
    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();
}

void clear_refill_resp(Vo3_core& dut) {
    dut.refill_resp_valid_i = 0;
    dut.refill_resp_pc_i = 0;
    dut.refill_resp_error_i = 0;
    for (int word = 0; word < kInstsPerLine; ++word) {
        dut.refill_resp_data_i[word] = 0;
    }
}

uint32_t read_inst(uint64_t pc) {
    switch (pc) {
        case 0: return kAddiX1X0Five;
        case 4: return kAddX2X1X1;
        case 8: return kSubX3X2X1;
        case 12: return kXorX1X3X2;
        default: return kInvalidInst;
    }
}

void drive_refill_resp(Vo3_core& dut, uint64_t line_pc) {
    dut.refill_resp_valid_i = 1;
    dut.refill_resp_pc_i = line_pc;
    dut.refill_resp_error_i = 0;
    for (int word = 0; word < kInstsPerLine; ++word) {
        dut.refill_resp_data_i[word] = read_inst(line_pc + static_cast<uint64_t>(word * kInstBytes));
    }
}

template <typename WideSignal>
uint64_t read_wide_bits(const WideSignal& words, int lsb, int width) {
    uint64_t value = 0;
    for (int bit = 0; bit < width; ++bit) {
        const int src_bit = lsb + bit;
        const uint64_t bit_value = (words[src_bit / 32] >> (src_bit % 32)) & 1u;
        value |= bit_value << bit;
    }
    return value;
}

RetireInfo read_retire_info(const Vo3_core& dut, int port) {
    const auto& raw = dut.retire_info_o[port];
    return RetireInfo{
        .valid = read_wide_bits(raw, 211, 1) != 0,
        .rob_idx = read_wide_bits(raw, 205, 6),
        .instruction_id = read_wide_bits(raw, 141, 64),
        .pc = read_wide_bits(raw, 102, 39),
        .instruction = static_cast<uint32_t>(read_wide_bits(raw, 70, 32)),
        .rd = static_cast<uint32_t>(read_wide_bits(raw, 65, 5)),
        .rd_write_en = read_wide_bits(raw, 64, 1) != 0,
        .rd_wdata = read_wide_bits(raw, 0, 64),
    };
}

void check_retire(const RetireInfo& actual, std::size_t expected_index, int cycle, int port) {
    const ExpectedRetire& expected = kExpected.at(expected_index);
    require(actual.rob_idx == expected_index,
            "ROB order mismatch at retire " + std::to_string(expected_index));
    require(actual.instruction_id == expected_index,
            "instruction id mismatch at retire " + std::to_string(expected_index));
    require(actual.pc == expected.pc,
            "PC mismatch at retire " + std::to_string(expected_index));
    require(actual.instruction == expected.instruction,
            "instruction mismatch at retire " + std::to_string(expected_index));
    require(actual.rd == expected.rd && actual.rd_write_en,
            "destination mismatch at retire " + std::to_string(expected_index));
    require(actual.rd_wdata == expected.rd_wdata,
            "result mismatch at retire " + std::to_string(expected_index)
                + ": expected=" + std::to_string(expected.rd_wdata)
                + " actual=" + std::to_string(actual.rd_wdata));

    std::cout << "[rename_bundle_dependencies][cycle=" << cycle
              << "] retire port=" << port
              << " rob=" << actual.rob_idx
              << " pc=0x" << std::hex << actual.pc
              << " rd=x" << std::dec << actual.rd
              << " value=" << actual.rd_wdata << "\n";
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vo3_core dut;
    std::deque<PendingRefill> pending_refills;
    std::size_t retired = 0;

    dut.clk_i = 0;
    dut.rst_i = 1;
    dut.flush_i = 0;
    dut.reset_pc_i = 0;
    clear_refill_resp(dut);

    for (int cycle = 0; cycle < kResetCycles; ++cycle) {
        step(dut);
    }
    dut.rst_i = 0;

    for (int cycle = 0; cycle < kMaxCycles && retired < kExpected.size(); ++cycle) {
        clear_refill_resp(dut);

        if (dut.refill_req_valid_o) {
            bool already_pending = false;
            for (const PendingRefill& pending : pending_refills) {
                already_pending |= pending.pc == dut.refill_req_pc_o;
            }
            if (!already_pending) {
                pending_refills.push_back({dut.refill_req_pc_o, kRefillLatencyCycles});
            }
        }

        for (PendingRefill& pending : pending_refills) {
            --pending.remaining_cycles;
        }
        if (!pending_refills.empty() && pending_refills.front().remaining_cycles <= 0) {
            drive_refill_resp(dut, pending_refills.front().pc);
            pending_refills.pop_front();
        }

        for (int port = 0; port < kRetirePorts; ++port) {
            const RetireInfo info = read_retire_info(dut, port);
            if (info.valid) {
                require(retired < kExpected.size(), "unexpected extra retirement");
                check_retire(info, retired, cycle, port);
                ++retired;
            }
        }

        step(dut);
    }

    require(retired == kExpected.size(),
            "timeout before all four same-bundle dependency instructions retired");
    require(dut.retired_inst_count_o >= kExpected.size(),
            "retired instruction counter did not cover the checked instructions");

    std::cout << "[rename_bundle_dependencies] PASS retired=" << retired << "\n";
    dut.final();
    return 0;
}
