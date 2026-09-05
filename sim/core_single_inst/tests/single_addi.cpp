#include "Vo3_core.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string_view>

namespace {

constexpr int kResetCycles = 5;
constexpr int kMaxCycles = 1000;
constexpr int kRefillLatencyCycles = 6;
constexpr int kLineBytes = 64;
constexpr int kInstBytes = 4;
constexpr int kInstsPerLine = kLineBytes / kInstBytes;
constexpr uint32_t kAddiX1X0One = 0x00100093u;
constexpr uint32_t kInvalidInst = 0xffffffffu;
constexpr int kRetirePorts = 3;

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
    if (pc == 0) {
        return kAddiX1X0One;
    }

    return kInvalidInst;
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

void require_retire_field(bool condition, std::string_view message) {
    if (!condition) {
        std::cerr << "[core_single_inst][assert] " << message << "\n";
        std::exit(1);
    }
}

std::string hex_u64(uint64_t value) {
    std::ostringstream oss;
    oss << "0x" << std::hex << value;
    return oss.str();
}

void check_retire_info(const Vo3_core& dut, int cycle, bool& saw_expected_retire) {
    for (int port = 0; port < kRetirePorts; ++port) {
        const RetireInfo info = read_retire_info(dut, port);
        if (!info.valid) {
            continue;
        }

        std::cout << "[core_single_inst][cycle=" << std::dec << cycle
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

        require_retire_field(!saw_expected_retire, "unexpected extra retired instruction before test exit");
        require_retire_field(port == 0, "single ADDI should retire on port 0");
        require_retire_field(info.rob_idx == 0, "single ADDI should retire from ROB entry 0");
        require_retire_field(info.instruction_id == 0, "single ADDI should have instruction_id 0");
        require_retire_field(info.pc == 0,
                             std::string("retire pc mismatch: got ") + hex_u64(info.pc));
        require_retire_field(info.instruction == kAddiX1X0One,
                             std::string("retire instruction mismatch: got ") + hex_u64(info.instruction));
        require_retire_field(info.rd == 1, "single ADDI should write architectural x1");
        require_retire_field(info.rd_write_en, "single ADDI should assert rd_write_en");
        require_retire_field(info.rd_wdata == 1,
                             std::string("single ADDI rd_wdata mismatch: got ") + hex_u64(info.rd_wdata));

        saw_expected_retire = true;
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
        std::cout << "[core_single_inst][cycle=" << std::dec << cycle
                  << "] refill req pc=0x" << std::hex << dut.refill_req_pc_o
                  << std::dec << "\n";
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vo3_core dut;
    std::deque<PendingRefill> pending_refills;
    bool saw_expected_retire = false;

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
            std::cout << "[core_single_inst][cycle=" << std::dec << cycle
                      << "] refill resp pc=0x" << std::hex << resp_pc
                      << std::dec << "\n";
        }

        eval_half_cycle(dut, 0);
        check_retire_info(dut, cycle, saw_expected_retire);

        step(dut);

        print_refill_req(dut, cycle);

        if (dut.refill_req_valid_o) {
            pending_refills.push_back(PendingRefill{
                .pc = dut.refill_req_pc_o,
                .remaining_cycles = kRefillLatencyCycles
            });
        }

        ++cycle;

        if (dut.single_inst_retired_o) {
            break;
        }
    }

    dut.final();

    if (dut.single_inst_retired_o) {
        require_retire_field(saw_expected_retire, "single_inst_retired_o set but no retire_info valid was observed");
        std::cout << "[core_single_inst] single instruction retired"
                  << " retired_inst_count=" << std::dec << dut.retired_inst_count_o
                  << " cycles=" << (cycle - 1)
                  << "\n";
    } else {
        std::cout << "[core_single_inst] timeout at cycle " << std::dec << cycle
                  << " retired_inst_count=" << dut.retired_inst_count_o
                  << "\n";
    }

    return 0;
}
