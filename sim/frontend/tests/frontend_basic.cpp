#include "Vfrontend.h"
#include "verilated.h"

#include <array>
#include <cassert>
#include <cstdint>
#include <deque>
#include <iomanip>
#include <iostream>
#include <map>
#include <string>

namespace {

constexpr int kResetCycles = 5;
constexpr int kMaxCycles = 120;
constexpr int kRefillLatencyCycles = 6;
constexpr int kLineBytes = 64;
constexpr int kInstBytes = 4;
constexpr int kInstsPerLine = kLineBytes / kInstBytes;
constexpr uint32_t kDefaultInst = 0xffffffffu;

struct PendingRefill {
    uint64_t pc;
    int remaining_cycles;
};

struct FetchEntry {
    bool valid;
    uint64_t pc;
    uint32_t inst;
    bool fetch_addr_misaligned;
    bool fetch_access_fault;
    uint32_t ftq_idx;
};

uint64_t sim_time = 0;

void eval_half_cycle(Vfrontend& dut, uint8_t clk_value) {
    dut.clk_i = clk_value;
    dut.eval();
    ++sim_time;
}

void step(Vfrontend& dut) {
    eval_half_cycle(dut, 1);
    eval_half_cycle(dut, 0);
}

void clear_refill_resp(Vfrontend& dut) {
    dut.refill_resp_valid_i = 0;
    dut.refill_resp_pc_i = 0;
    dut.refill_resp_error_i = 0;
    for (int word = 0; word < 16; ++word) {
        dut.refill_resp_data_i[word] = 0;
    }
}

uint64_t get_bits(const WData* words, int lsb, int width) {
    uint64_t value = 0;
    for (int bit = 0; bit < width; ++bit) {
        const int src_bit = lsb + bit;
        const uint64_t bit_value = (words[src_bit / 32] >> (src_bit % 32)) & 1u;
        value |= bit_value << bit;
    }
    return value;
}

FetchEntry decode_fetch_entry(const WData* words) {
    FetchEntry entry{};
    entry.ftq_idx = static_cast<uint32_t>(get_bits(words, 0, 4));
    entry.fetch_access_fault = get_bits(words, 4, 1) != 0;
    entry.fetch_addr_misaligned = get_bits(words, 5, 1) != 0;
    entry.inst = static_cast<uint32_t>(get_bits(words, 6, 32));
    entry.pc = get_bits(words, 38, 39);
    entry.valid = get_bits(words, 77, 1) != 0;
    return entry;
}

uint32_t read_inst(const std::map<uint64_t, uint32_t>& inst_mem, uint64_t pc) {
    const auto it = inst_mem.find(pc);
    if (it == inst_mem.end()) {
        return kDefaultInst;
    }
    return it->second;
}

void drive_refill_resp(
    Vfrontend& dut,
    const std::map<uint64_t, uint32_t>& inst_mem,
    uint64_t line_pc
) {
    dut.refill_resp_valid_i = 1;
    dut.refill_resp_pc_i = line_pc;
    dut.refill_resp_error_i = 0;

    for (int i = 0; i < kInstsPerLine; ++i) {
        const uint64_t inst_pc = line_pc + static_cast<uint64_t>(i * kInstBytes);
        dut.refill_resp_data_i[i] = read_inst(inst_mem, inst_pc);
    }
}

void init_inst_mem(std::map<uint64_t, uint32_t>& inst_mem) {
    uint32_t inst_index = 1;
    for (uint64_t pc = 0; pc < 0x200; pc += 4) {
        inst_mem[pc] = inst_index;
        ++inst_index;
    }
}

struct CheckerState {
    uint64_t expected_pc = 0;
    uint32_t expected_inst = 1;
    int received_count = 0;
    bool failed = false;
};

void check_fetch_output(const Vfrontend& dut, int cycle, CheckerState& checker) {
    if (!dut.fetch_valid_o) {
        return;
    }

    std::cout << "[cycle " << std::dec << cycle << "] fetch valid mask=0x"
              << std::hex << static_cast<int>(dut.fetch_valid_mask_o) << "\n";

    for (int lane = 0; lane < 4; ++lane) {
        if (((dut.fetch_valid_mask_o >> lane) & 1u) == 0) {
            continue;
        }

        const FetchEntry entry = decode_fetch_entry(dut.fetch_entry_o[lane]);
        std::cout << "  lane " << std::dec << lane
                  << " pc=0x" << std::hex << entry.pc
                  << " inst=0x" << std::setw(8) << std::setfill('0') << entry.inst
                  << std::setfill(' ')
                  << " misalign=" << std::dec << entry.fetch_addr_misaligned
                  << " access_fault=" << entry.fetch_access_fault
                  << " ftq_idx=" << entry.ftq_idx
                  << "\n";

        if (!entry.valid || entry.pc != checker.expected_pc ||
            entry.inst != checker.expected_inst ||
            entry.fetch_addr_misaligned || entry.fetch_access_fault) {
            std::cerr << "MISMATCH cycle=" << std::dec << cycle
                      << " lane=" << lane
                      << " expected_pc=0x" << std::hex << checker.expected_pc
                      << " expected_inst=0x" << std::setw(8) << std::setfill('0')
                      << checker.expected_inst << std::setfill(' ')
                      << " actual_pc=0x" << entry.pc
                      << " actual_inst=0x" << std::setw(8) << std::setfill('0')
                      << entry.inst << std::setfill(' ')
                      << " valid=" << std::dec << entry.valid
                      << " misalign=" << entry.fetch_addr_misaligned
                      << " access_fault=" << entry.fetch_access_fault
                      << " ftq_idx=" << entry.ftq_idx
                      << "\n";
            checker.failed = true;
        }

        checker.expected_pc += 4;
        ++checker.expected_inst;
        ++checker.received_count;
    }
}

void print_refill_req(const Vfrontend& dut, int cycle) {
    if (dut.refill_req_valid_o) {
        std::cout << "[cycle " << std::dec << cycle
                  << "] refill req pc=0x" << std::hex << dut.refill_req_pc_o
                  << "\n";
    }
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vfrontend dut;
    std::map<uint64_t, uint32_t> inst_mem;
    std::deque<PendingRefill> pending_refills;
    CheckerState checker;

    init_inst_mem(inst_mem);

    dut.clk_i = 0;
    dut.rst_i = 1;
    dut.flush_i = 0;
    dut.fetch_ready_i = 1;
    dut.reset_pc_i = 0;
    clear_refill_resp(dut);

    for (int i = 0; i < kResetCycles; ++i) {
        step(dut);
    }

    dut.rst_i = 0;

    int ftq_ifu_fire_count = 0;
    int cycle = 0;

    while (ftq_ifu_fire_count < 4 && cycle < kMaxCycles && !Verilated::gotFinish()) {
        bool resp_this_cycle = false;

        clear_refill_resp(dut);

        for (auto& refill : pending_refills) {
            --refill.remaining_cycles;
        }

        if (!pending_refills.empty() && pending_refills.front().remaining_cycles < 0) {
            const uint64_t resp_pc = pending_refills.front().pc;
            pending_refills.pop_front();
            drive_refill_resp(dut, inst_mem, resp_pc);
            resp_this_cycle = true;
            std::cout << "[cycle " << std::dec << cycle
                      << "] refill resp pc=0x" << std::hex << resp_pc
                      << "\n";
        }

        step(dut);

        print_refill_req(dut, cycle);
        check_fetch_output(dut, cycle, checker);

        if (dut.dbg_ftq_ifu_fire_o) {
            ++ftq_ifu_fire_count;
            std::cout << "[cycle " << std::dec << cycle
                      << "] ftq ifu fire count=" << ftq_ifu_fire_count
                      << " alloc_tail=0x" << std::hex << static_cast<int>(dut.dbg_ftq_alloc_tail_o)
                      << " ifu_head=0x" << static_cast<int>(dut.dbg_ftq_ifu_head_o)
                      << " allocated_count=" << std::dec << static_cast<int>(dut.dbg_ftq_allocated_count_o)
                      << "\n";
        }

        if (dut.refill_req_valid_o) {
            pending_refills.push_back(PendingRefill{
                .pc = dut.refill_req_pc_o,
                .remaining_cycles = kRefillLatencyCycles
            });
        }

        if (resp_this_cycle) {
            clear_refill_resp(dut);
        }

        ++cycle;
    }

    dut.final();

    if (ftq_ifu_fire_count < 4) {
        std::cerr << "FAIL: ftq_ifu_fire_count=" << std::dec << ftq_ifu_fire_count
                  << " < 4 after " << cycle << " cycles\n";
        return 1;
    }

    if (checker.received_count == 0) {
        std::cerr << "FAIL: zero instructions accepted\n";
        return 1;
    }

    if (checker.failed) {
        return 1;
    }

    std::cout << "PASS: ftq_ifu_fire_count=" << std::dec << ftq_ifu_fire_count
              << " instructions_received=" << checker.received_count << "\n";
    return 0;
}
