#include <array>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "VICache.h"
#include "verilated.h"

namespace {

constexpr int kCyclePeriod = 10;
constexpr int kResetCycles = 3;
constexpr int kRefillLatencyCycles = 6;
constexpr int kLineWords = 16;
constexpr int kFetchWords = 4;
constexpr uint64_t kFetchBytes = 16;
constexpr uint64_t kLineAlignMask = 0x3fULL;
constexpr int kTargetInputFires = 16;
constexpr int kDrainCycles = 32;

vluint64_t sim_time = 0;

std::string hex_u64(uint64_t value) {
    std::ostringstream oss;
    oss << "0x" << std::hex << std::setw(16) << std::setfill('0') << value;
    return oss.str();
}

std::string format_fetch_data(const std::array<uint32_t, kFetchWords>& data) {
    std::ostringstream oss;
    oss << "0x";
    for (int word = kFetchWords - 1; word >= 0; --word) {
        oss << std::hex << std::setw(8) << std::setfill('0') << data[word];
    }
    return oss.str();
}

uint32_t refill_word_for_pc(uint64_t line_pc, int word) {
    return 0xc0000000u |
           (static_cast<uint32_t>((line_pc >> 4) & 0x0000ffffu) << 8) |
           static_cast<uint32_t>(word & 0xff);
}

uint32_t expected_word_for_pc(uint64_t pc, int fetch_word) {
    const uint64_t line_pc = pc & ~kLineAlignMask;
    const int line_word = static_cast<int>(((pc & kLineAlignMask) >> 2) + fetch_word);
    return refill_word_for_pc(line_pc, line_word);
}

void fail_now(const std::string& message) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(EXIT_FAILURE);
}

void expect(bool condition, const std::string& message) {
    if (!condition) {
        fail_now(message);
    }
}

struct RefillRequestRecord {
    int cycle;
    uint64_t pc;
};

struct OutputRecord {
    int cycle;
    uint64_t pc;
    bool hit;
    bool error;
    std::array<uint32_t, kFetchWords> data;
};

struct PendingRefill {
    bool valid = false;
    int request_cycle = 0;
    uint64_t pc = 0;
};

class ICacheCycleTb {
public:
    ICacheCycleTb() {
        dut_.clk = 0;
        dut_.rst = 1;
        dut_.flush = 0;
        dut_.s0_valid = 0;
        dut_.s0_pc = 0;
        clear_refill_resp();
        dut_.eval();
    }

    void reset() {
        dut_.rst = 1;
        dut_.flush = 0;
        dut_.s0_valid = 0;
        dut_.s0_pc = 0;
        clear_refill_resp();
        for (int i = 0; i < kResetCycles; ++i) {
            step();
        }
        dut_.rst = 0;
        dut_.eval();
        step();
    }

    void start_stream(uint64_t first_pc) {
        next_pc_ = first_pc;
        drive_next_request();
    }

    void run_cycle() {
        drive_scheduled_refill_resp();

        const bool input_fire = dut_.s0_valid && dut_.s0_ready;
        const uint64_t fired_pc = dut_.s0_pc;

        step();

        if (input_fire) {
            ++input_fire_count_;
            input_fire_pcs_.push_back(fired_pc);
            next_pc_ = fired_pc + kFetchBytes;
            if (input_fire_count_ < kTargetInputFires) {
                drive_next_request();
            } else {
                clear_request();
            }
        }

        monitor_refill_req();
        monitor_output();

        ++cycle_;
    }

    void run_cycles(int cycles) {
        for (int i = 0; i < cycles; ++i) {
            run_cycle();
        }
    }

    void run_until_input_fires(int target_fires) {
        while (input_fire_count_ < target_fires) {
            run_cycle();
        }
    }

    int input_fire_count() const {
        return input_fire_count_;
    }

    const std::vector<uint64_t>& input_fire_pcs() const {
        return input_fire_pcs_;
    }

    const std::vector<RefillRequestRecord>& refill_requests() const {
        return refill_requests_;
    }

    const std::vector<OutputRecord>& outputs() const {
        return outputs_;
    }

    void final() {
        dut_.final();
    }

private:
    void step() {
        dut_.clk = 1;
        dut_.eval();
        dut_.clk = 0;
        dut_.eval();
        sim_time += kCyclePeriod;
    }

    void drive_next_request() {
        dut_.s0_pc = next_pc_;
        dut_.s0_valid = 1;
        dut_.eval();
    }

    void clear_request() {
        dut_.s0_pc = 0;
        dut_.s0_valid = 0;
        dut_.eval();
    }

    void clear_refill_resp() {
        dut_.refill_resp_valid = 0;
        dut_.refill_resp_pc = 0;
        dut_.refill_resp_error = 0;
        for (int i = 0; i < kLineWords; ++i) {
            dut_.refill_resp_data[i] = 0;
        }
        dut_.eval();
    }

    void drive_refill_resp(uint64_t line_pc) {
        dut_.refill_resp_valid = 1;
        dut_.refill_resp_pc = line_pc;
        dut_.refill_resp_error = 0;
        for (int i = 0; i < kLineWords; ++i) {
            dut_.refill_resp_data[i] = refill_word_for_pc(line_pc, i);
        }
        dut_.eval();
    }

    void drive_scheduled_refill_resp() {
        clear_refill_resp();
        if (!pending_refill_.valid) {
            return;
        }

        if ((cycle_ - pending_refill_.request_cycle) == kRefillLatencyCycles) {
            drive_refill_resp(pending_refill_.pc);
            pending_refill_.valid = false;
        }
    }

    void monitor_refill_req() {
        if (!dut_.refill_req_valid) {
            return;
        }

        expect(!pending_refill_.valid,
               "observed a second refill request while one is pending");
        const uint64_t refill_pc = dut_.refill_req_pc;
        expect((refill_pc & kLineAlignMask) == 0,
               "refill request PC is not line aligned: " + hex_u64(refill_pc));

        pending_refill_.valid = true;
        pending_refill_.request_cycle = cycle_;
        pending_refill_.pc = refill_pc;
        refill_requests_.push_back(RefillRequestRecord{cycle_, refill_pc});
    }

    void monitor_output() {
        if (!dut_.out_valid) {
            return;
        }

        OutputRecord record{};
        record.cycle = cycle_;
        record.pc = dut_.out_pc;
        record.hit = dut_.out_hit;
        record.error = dut_.out_error;
        for (int i = 0; i < kFetchWords; ++i) {
            record.data[i] = dut_.out_data[i];
        }
        outputs_.push_back(record);
    }

    VICache dut_;
    int cycle_ = 0;
    int input_fire_count_ = 0;
    uint64_t next_pc_ = 0;
    PendingRefill pending_refill_{};
    std::vector<uint64_t> input_fire_pcs_;
    std::vector<RefillRequestRecord> refill_requests_;
    std::vector<OutputRecord> outputs_;
};

void check_input_stream(const ICacheCycleTb& tb) {
    expect(tb.input_fire_count() == kTargetInputFires,
           "input fire count mismatch: got=" + std::to_string(tb.input_fire_count()) +
           " exp=" + std::to_string(kTargetInputFires));

    const auto& pcs = tb.input_fire_pcs();
    expect(!pcs.empty(), "no input fire PCs were recorded");
    expect(pcs.front() == 0,
           "first input fire PC mismatch got=" + hex_u64(pcs.front()) +
           " exp=" + hex_u64(0));

    for (std::size_t i = 1; i < pcs.size(); ++i) {
        expect(pcs[i] == pcs[i - 1] + kFetchBytes,
               "input fire PC sequence mismatch at index " + std::to_string(i) +
               " got=" + hex_u64(pcs[i]) +
               " exp=" + hex_u64(pcs[i - 1] + kFetchBytes));
    }
}

void check_refill_responses(const ICacheCycleTb& tb) {
    const auto& requests = tb.refill_requests();
    const auto& outputs = tb.outputs();
    expect(!requests.empty(), "no refill requests were recorded");
    expect(!outputs.empty(), "no outputs were recorded");

    for (const auto& req : requests) {
        const int expected_done_cycle = req.cycle + kRefillLatencyCycles;
        bool saw_matching_output = false;

        for (const auto& out : outputs) {
            if (out.cycle != expected_done_cycle || out.pc != req.pc) {
                continue;
            }

            expect(!out.hit, "refill DONE output unexpectedly reported hit for pc=" +
                             hex_u64(out.pc));
            expect(!out.error, "refill DONE output reported error for pc=" +
                               hex_u64(out.pc));
            for (int word = 0; word < kFetchWords; ++word) {
                const uint32_t expected = expected_word_for_pc(out.pc, word);
                expect(out.data[word] == expected,
                       "refill DONE data mismatch pc=" + hex_u64(out.pc) +
                       " word=" + std::to_string(word) +
                       " got=" + hex_u64(out.data[word]) +
                       " exp=" + hex_u64(expected));
            }

            saw_matching_output = true;
            break;
        }

        expect(saw_matching_output,
               "missing refill DONE output for req_pc=" + hex_u64(req.pc) +
               " at cycle=" + std::to_string(expected_done_cycle));
    }
}

void print_summary(const ICacheCycleTb& tb) {
    std::cout << "input_fire_count=" << tb.input_fire_count() << "\n";

    std::cout << "\n=== Refill requests: " << tb.refill_requests().size() << " ===\n";
    for (const auto& req : tb.refill_requests()) {
        std::cout << "req cycle=" << req.cycle
                  << " pc=" << hex_u64(req.pc) << "\n";
    }

    std::cout << "\n=== Outputs: " << tb.outputs().size() << " ===\n";
    for (const auto& out : tb.outputs()) {
        std::cout << "out cycle=" << out.cycle
                  << " pc=" << hex_u64(out.pc)
                  << " hit=" << static_cast<int>(out.hit)
                  << " error=" << static_cast<int>(out.error)
                  << " data=" << format_fetch_data(out.data) << "\n";
    }
}

}  // namespace

double sc_time_stamp() {
    return static_cast<double>(sim_time);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    ICacheCycleTb tb;
    std::cout << "=== ICache Cycle-Step Streaming Refill Test ===\n";

    tb.reset();
    tb.start_stream(0x0);
    tb.run_until_input_fires(kTargetInputFires);
    tb.run_cycles(kDrainCycles);

    check_input_stream(tb);
    check_refill_responses(tb);
    print_summary(tb);

    std::cout << "ALL TESTS PASSED\n";
    tb.final();
    return EXIT_SUCCESS;
}
