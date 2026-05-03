#include "Vo3_core.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iomanip>
#include <iostream>
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

struct PendingRefill {
    uint64_t pc;
    int remaining_cycles;
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
