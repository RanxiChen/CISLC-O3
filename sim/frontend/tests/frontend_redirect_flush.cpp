#include "Vfrontend.h"
#include "verilated.h"

#include <cstdint>
#include <deque>
#include <iomanip>
#include <iostream>
#include <map>

namespace {

constexpr int kResetCycles = 5;
constexpr int kMaxCycles = 160;
constexpr int kRefillLatencyCycles = 6;
constexpr int kLineBytes = 64;
constexpr int kInstBytes = 4;
constexpr int kInstsPerLine = kLineBytes / kInstBytes;
constexpr uint32_t kDefaultInst = 0xffffffffu;
constexpr uint64_t kRedirectPc = 0x100;

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

[[noreturn]] void fail(const std::string& msg) {
    std::cerr << "FAIL: " << msg << "\n";
    std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vfrontend dut;
    std::map<uint64_t, uint32_t> inst_mem;
    std::deque<PendingRefill> pending_refills;

    init_inst_mem(inst_mem);

    dut.clk_i = 0;
    dut.rst_i = 1;
    dut.flush_i = 0;
    dut.fetch_ready_i = 1;
    dut.reset_pc_i = 0;
    dut.redirect_valid_i = 0;
    dut.redirect_ftq_idx_i = 0;
    dut.redirect_branch_pc_i = 0;
    dut.redirect_redirect_pc_i = 0;
    dut.redirect_actual_taken_i = 0;
    clear_refill_resp(dut);

    for (int i = 0; i < kResetCycles; ++i) {
        step(dut);
    }

    dut.rst_i = 0;

    bool saw_initial_refill_req = false;
    bool issued_redirect = false;
    bool saw_redirect_refill_req = false;
    bool saw_wrong_path_output = false;
    bool saw_redirect_output = false;
    int redirect_output_count = 0;

    for (int cycle = 0; cycle < kMaxCycles && !Verilated::gotFinish(); ++cycle) {
        clear_refill_resp(dut);

        for (auto& refill : pending_refills) {
            --refill.remaining_cycles;
        }

        if (!pending_refills.empty() && pending_refills.front().remaining_cycles < 0) {
            const uint64_t resp_pc = pending_refills.front().pc;
            pending_refills.pop_front();
            drive_refill_resp(dut, inst_mem, resp_pc);
        }

        if (!issued_redirect && saw_initial_refill_req) {
            dut.redirect_valid_i = 1;
            dut.redirect_ftq_idx_i = 0;
            dut.redirect_branch_pc_i = 0x10;
            dut.redirect_redirect_pc_i = kRedirectPc;
            dut.redirect_actual_taken_i = 1;
            issued_redirect = true;
        } else {
            dut.redirect_valid_i = 0;
        }

        step(dut);

        if (dut.refill_req_valid_o) {
            pending_refills.push_back(PendingRefill{
                .pc = dut.refill_req_pc_o,
                .remaining_cycles = kRefillLatencyCycles,
            });

            if (dut.refill_req_pc_o == 0) {
                saw_initial_refill_req = true;
            }

            if (issued_redirect && dut.refill_req_pc_o == kRedirectPc) {
                saw_redirect_refill_req = true;
            }
        }

        if (dut.fetch_valid_o) {
            for (int lane = 0; lane < 4; ++lane) {
                if (((dut.fetch_valid_mask_o >> lane) & 1u) == 0) {
                    continue;
                }

                const FetchEntry entry = decode_fetch_entry(dut.fetch_entry_o[lane]);
                if (!entry.valid) {
                    continue;
                }

                if (issued_redirect && entry.pc < kRedirectPc) {
                    saw_wrong_path_output = true;
                    std::cerr << "[cycle " << std::dec << cycle
                              << "] wrong-path output pc=0x" << std::hex << entry.pc
                              << " inst=0x" << std::setw(8) << std::setfill('0') << entry.inst
                              << std::setfill(' ') << "\n";
                }

                if (entry.pc >= kRedirectPc) {
                    saw_redirect_output = true;
                    ++redirect_output_count;
                }
            }
        }

        if (saw_wrong_path_output) {
            fail("redirect should flush old IFU/fetch-buffer state before any pre-redirect entry reaches frontend output");
        }

        if (saw_redirect_refill_req && saw_redirect_output && redirect_output_count >= 4) {
            break;
        }
    }

    dut.final();

    if (!saw_initial_refill_req) {
        fail("frontend never issued the initial wrong-path refill request");
    }

    if (!issued_redirect) {
        fail("test never pulsed redirect");
    }

    if (!saw_redirect_refill_req) {
        fail("frontend never re-requested from redirect_pc after redirect");
    }

    if (!saw_redirect_output) {
        fail("frontend never produced redirected fetch output");
    }

    std::cout << "PASS: frontend redirect flush drops stale state and restarts from redirect_pc\n";
    return 0;
}
