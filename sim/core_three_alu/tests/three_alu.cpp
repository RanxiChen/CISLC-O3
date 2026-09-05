#include "Vo3_core.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>

namespace {

constexpr int kResetCycles = 5;
constexpr int kMaxCycles = 1000;
constexpr int kRefillLatencyCycles = 6;
constexpr int kLineBytes = 64;
constexpr int kInstBytes = 4;
constexpr int kInstsPerLine = kLineBytes / kInstBytes;
constexpr uint32_t kAddiX1X0One = 0x00100093u;
constexpr uint32_t kOriX2X0Five = 0x00506113u;
constexpr uint32_t kXoriX3X0Seven = 0x00704193u;
constexpr uint32_t kInvalidInst = 0xffffffffu;
constexpr int kRetirePorts = 3;
constexpr int kExpectedRetires = 3;

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

constexpr std::array<ExpectedRetire, kExpectedRetires> kExpected = {{
    {.pc = 0, .instruction = kAddiX1X0One, .rd = 1, .rd_wdata = 1},
    {.pc = 4, .instruction = kOriX2X0Five, .rd = 2, .rd_wdata = 5},
    {.pc = 8, .instruction = kXoriX3X0Seven, .rd = 3, .rd_wdata = 7},
}};

void eval_half_cycle(Vo3_core& dut, uint8_t clk_value) {
    dut.clk_i = clk_value;
    dut.eval();
}

void step(Vo3_core& dut) {
    eval_half_cycle(dut, 1);
    eval_half_cycle(dut, 0);
}

void clear_refill_resp(Vo3_core& dut) {
    dut.refill_resp_valid_i = 0;
    dut.refill_resp_pc_i = 0;
    dut.refill_resp_error_i = 0;
    for (int word = 0; word < 16; ++word) {
        dut.refill_resp_data_i[word] = 0;
    }
}

uint32_t read_inst(uint64_t pc) {
    switch (pc) {
        case 0:
            return kAddiX1X0One;
        case 4:
            return kOriX2X0Five;
        case 8:
            return kXoriX3X0Seven;
        default:
            return kInvalidInst;
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

void require_field(bool condition, std::string_view message) {
    if (!condition) {
        std::cerr << "[core_three_alu][assert] " << message << "\n";
        std::exit(1);
    }
}

std::string hex_u64(uint64_t value) {
    std::ostringstream oss;
    oss << "0x" << std::hex << value;
    return oss.str();
}

void check_one_retire(const RetireInfo& info, int port) {
    const ExpectedRetire& expected = kExpected.at(port);

    require_field(info.rob_idx == static_cast<uint64_t>(port),
                  "retire ROB index mismatch on port " + std::to_string(port));
    require_field(info.instruction_id == static_cast<uint64_t>(port),
                  "instruction_id mismatch on port " + std::to_string(port));
    require_field(info.pc == expected.pc,
                  "retire pc mismatch on port " + std::to_string(port) + ": got " + hex_u64(info.pc));
    require_field(info.instruction == expected.instruction,
                  "instruction mismatch on port " + std::to_string(port) + ": got " + hex_u64(info.instruction));
    require_field(info.rd == expected.rd,
                  "rd mismatch on port " + std::to_string(port));
    require_field(info.rd_write_en,
                  "rd_write_en should be asserted on port " + std::to_string(port));
    require_field(info.rd_wdata == expected.rd_wdata,
                  "rd_wdata mismatch on port " + std::to_string(port) + ": got " + hex_u64(info.rd_wdata));
}

void check_retire_info(const Vo3_core& dut, int cycle, bool& saw_three_retire) {
    int valid_count = 0;

    for (int port = 0; port < kRetirePorts; ++port) {
        const RetireInfo info = read_retire_info(dut, port);
        if (!info.valid) {
            continue;
        }

        ++valid_count;
        std::cout << "[core_three_alu][cycle=" << std::dec << cycle
                  << "] retire_info port=" << port
                  << " pc=0x" << std::hex << info.pc
                  << " inst=0x" << std::setw(8) << std::setfill('0') << info.instruction
                  << std::setfill(' ')
                  << " rd=x" << std::dec << info.rd
                  << " rd_wen=" << info.rd_write_en
                  << " rd_wdata=0x" << std::hex << info.rd_wdata
                  << " rob=" << std::dec << info.rob_idx
                  << " id=0x" << std::hex << info.instruction_id
                  << std::dec << "\n";

        require_field(!saw_three_retire, "unexpected extra retire after three-ALU retire was observed");
        check_one_retire(info, port);
    }

    if (valid_count != 0) {
        require_field(valid_count == kExpectedRetires,
                      "expected all three ALU instructions to retire in the same cycle");
        saw_three_retire = true;
    }
}

void drive_refill_resp(Vo3_core& dut, uint64_t line_pc) {
    dut.refill_resp_valid_i = 1;
    dut.refill_resp_pc_i = line_pc;
    dut.refill_resp_error_i = 0;

    for (int i = 0; i < kInstsPerLine; ++i) {
        const uint64_t inst_pc = line_pc + static_cast<uint64_t>(i * kInstBytes);
        dut.refill_resp_data_i[i] = read_inst(inst_pc);
    }
}

void print_refill_req(const Vo3_core& dut, int cycle) {
    if (dut.refill_req_valid_o) {
        std::cout << "[core_three_alu][cycle=" << std::dec << cycle
                  << "] refill req pc=0x" << std::hex << dut.refill_req_pc_o
                  << std::dec << "\n";
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vo3_core dut;
    std::deque<PendingRefill> pending_refills;
    bool saw_three_retire = false;

    dut.clk_i = 0;
    dut.rst_i = 1;
    dut.flush_i = 0;
    dut.reset_pc_i = 0;
    clear_refill_resp(dut);

    for (int i = 0; i < kResetCycles; ++i) {
        step(dut);
    }

    dut.rst_i = 0;

    int cycle = 0;
    while (cycle < kMaxCycles) {
        clear_refill_resp(dut);

        for (auto& refill : pending_refills) {
            --refill.remaining_cycles;
        }

        if (!pending_refills.empty() && pending_refills.front().remaining_cycles < 0) {
            const uint64_t resp_pc = pending_refills.front().pc;
            pending_refills.pop_front();
            drive_refill_resp(dut, resp_pc);
            std::cout << "[core_three_alu][cycle=" << std::dec << cycle
                      << "] refill resp pc=0x" << std::hex << resp_pc
                      << std::dec << "\n";
        }

        eval_half_cycle(dut, 0);
        check_retire_info(dut, cycle, saw_three_retire);

        step(dut);

        print_refill_req(dut, cycle);

        if (dut.refill_req_valid_o) {
            pending_refills.push_back(PendingRefill{
                .pc = dut.refill_req_pc_o,
                .remaining_cycles = kRefillLatencyCycles
            });
        }

        ++cycle;

        if (saw_three_retire) {
            break;
        }
    }

    dut.final();

    if (saw_three_retire) {
        require_field(dut.retired_inst_count_o == kExpectedRetires,
                      "retired_inst_count should be 3 at test exit");
        std::cout << "[core_three_alu] three ALU instructions retired together"
                  << " retired_inst_count=" << std::dec << dut.retired_inst_count_o
                  << " cycles=" << (cycle - 1)
                  << "\n";
    } else {
        std::cout << "[core_three_alu] timeout at cycle " << std::dec << cycle
                  << " retired_inst_count=" << dut.retired_inst_count_o
                  << "\n";
        return 1;
    }

    return 0;
}
