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

constexpr int kClkHalfPeriod = 5;
constexpr int kRefillLatencyCycles = 6;
constexpr uint32_t kDeadbeef = 0xdeadbeefu;
constexpr uint64_t kRequestPc = 0x0;
constexpr uint64_t kExpectedLinePc = 0x0;
constexpr uint64_t kLineAlignMask = 0x3fULL;
constexpr int kLineWords = 16;

struct OutputSample {
    vluint64_t time;
    uint8_t state;
    uint64_t out_pc;
    bool out_hit;
    bool out_error;
    std::string out_data;
};

vluint64_t sim_time = 0;
std::vector<OutputSample> g_output_samples;

void maybe_capture_output(const VICache& dut);

void step_half_cycle(VICache& dut) {
    dut.clk = !dut.clk;
    dut.eval();
    maybe_capture_output(dut);
    sim_time += kClkHalfPeriod;
}

void step_full_cycle(VICache& dut) {
    step_half_cycle(dut);
    step_half_cycle(dut);
}

void drive_negedge_req(VICache& dut, uint64_t pc, bool valid) {
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

std::string format_out_data(const VICache& dut) {
    std::ostringstream oss;
    oss << "0x";
    for (int word = 3; word >= 0; --word) {
        oss << std::hex << std::setw(8) << std::setfill('0') << dut.out_data[word];
    }
    return oss.str();
}

std::string format_expected_deadbeef_128() {
    std::ostringstream oss;
    oss << "0x";
    for (int word = 0; word < 4; ++word) {
        oss << std::hex << std::setw(8) << std::setfill('0') << kDeadbeef;
    }
    return oss.str();
}

void maybe_capture_output(const VICache& dut) {
    if (dut.out_valid) {
        g_output_samples.push_back(OutputSample{
            sim_time,
            static_cast<uint8_t>(dut.dbg_state),
            static_cast<uint64_t>(dut.out_pc),
            static_cast<bool>(dut.out_hit),
            static_cast<bool>(dut.out_error),
            format_out_data(dut)
        });
    }
}

const char* state_name(uint8_t state) {
    switch (state) {
    case 0: return "WORK";
    case 1: return "REQ";
    case 2: return "WAIT";
    case 3: return "DONE";
    default: return "UNKNOWN";
    }
}

void print_icache_snapshot(const VICache& dut, const std::string& tag) {
    std::cout << "[tb] " << tag
              << " state=" << state_name(dut.dbg_state)
              << " out_valid=" << static_cast<int>(dut.out_valid)
              << " out_hit=" << static_cast<int>(dut.out_hit)
              << " out_pc=" << hex_u64(dut.out_pc)
              << " out_error=" << static_cast<int>(dut.out_error)
              << " out_data=" << format_out_data(dut)
              << " done_data=0x";
    for (int word = 3; word >= 0; --word) {
        std::cout << std::hex << std::setw(8) << std::setfill('0') << dut.dbg_done_data[word];
    }
    std::cout << std::dec
              << " miss_pc=" << hex_u64(dut.dbg_miss_pc)
              << " refill_pc=" << hex_u64(dut.dbg_miss_refill_pc)
              << " req_valid=" << static_cast<int>(dut.refill_req_valid)
              << " req_pc=" << hex_u64(dut.refill_req_pc)
              << "\n";
}

void print_output_summary() {
    std::cout << "\n=== Captured out_valid samples: " << g_output_samples.size() << " ===\n";
    for (std::size_t i = 0; i < g_output_samples.size(); ++i) {
        const auto& s = g_output_samples[i];
        std::cout << "sample[" << i << "]"
                  << " time=" << s.time
                  << " state=" << state_name(s.state)
                  << " out_pc=" << hex_u64(s.out_pc)
                  << " out_hit=" << static_cast<int>(s.out_hit)
                  << " out_error=" << static_cast<int>(s.out_error)
                  << " out_data=" << s.out_data << "\n";
    }
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

void clear_refill_resp(VICache& dut) {
    dut.refill_resp_valid = 0;
    dut.refill_resp_pc = 0;
    dut.refill_resp_error = 0;
    for (int i = 0; i < kLineWords; ++i) {
        dut.refill_resp_data[i] = 0;
    }
    dut.eval();
}

void drive_refill_resp_deadbeef(VICache& dut, uint64_t pc) {
    dut.refill_resp_valid = 1;
    dut.refill_resp_pc = pc;
    dut.refill_resp_error = 0;
    for (int i = 0; i < kLineWords; ++i) {
        dut.refill_resp_data[i] = kDeadbeef;
    }
    dut.eval();
}

bool check_out_data_deadbeef(const VICache& dut) {
    for (int word = 0; word < 4; ++word) {
        if (dut.out_data[word] != kDeadbeef) {
            return false;
        }
    }
    return true;
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
    clear_refill_resp(dut);

    std::cout << "=== ICache Basic Refill Test (cold cache, debug only) ===\n";

    for (int i = 0; i < 3; ++i) {
        step_full_cycle(dut);
    }
    dut.rst = 0;
    dut.eval();
    step_full_cycle(dut);

    drive_negedge_req(dut, kRequestPc, true);
    step_half_cycle(dut);
    step_half_cycle(dut);
    drive_negedge_req(dut, kRequestPc, false);

    bool saw_refill_req = false;
    bool checked_one_pulse = false;
    uint64_t captured_refill_pc = 0;

    for (int cycle = 0; cycle < 64; ++cycle) {
        if (dut.refill_req_valid) {
            expect(!saw_refill_req, "refill_req_valid asserted more than once before response");
            saw_refill_req = true;
            captured_refill_pc = dut.refill_req_pc;
            expect(captured_refill_pc == kExpectedLinePc,
                   "refill_req_pc mismatch got=" + hex_u64(captured_refill_pc) +
                   " exp=" + hex_u64(kExpectedLinePc));
            expect((captured_refill_pc & kLineAlignMask) == 0,
                   "refill_req_pc is not line aligned: " + hex_u64(captured_refill_pc));

            step_full_cycle(dut);
            expect(!dut.refill_req_valid, "refill_req_valid did not deassert after one cycle");
            checked_one_pulse = true;
            break;
        }
        step_full_cycle(dut);
    }

    expect(saw_refill_req, "did not observe refill_req_valid for request_pc=0x0");
    expect(checked_one_pulse, "did not finish refill request pulse width check");

    for (int i = 1; i < kRefillLatencyCycles; ++i) {
        step_full_cycle(dut);
    }

    drive_refill_resp_deadbeef(dut, captured_refill_pc);
    print_icache_snapshot(dut, "before refill resp clocks");
    step_half_cycle(dut);
    print_icache_snapshot(dut, "after refill resp first half");
    step_half_cycle(dut);
    print_icache_snapshot(dut, "after refill resp second half");
    clear_refill_resp(dut);
    print_icache_snapshot(dut, "after clear_refill_resp");

    expect(dut.out_valid, "DONE output missing after refill response");
    expect(dut.out_pc == kRequestPc,
           "DONE out_pc mismatch got=" + hex_u64(dut.out_pc) + " exp=" + hex_u64(kRequestPc));
    expect(!dut.out_error, "DONE out_error asserted unexpectedly");
    expect(check_out_data_deadbeef(dut),
           "DONE out_data mismatch got=" + format_out_data(dut) +
           " exp=" + format_expected_deadbeef_128());

    step_full_cycle(dut);
    print_icache_snapshot(dut, "after DONE full cycle");

    drive_negedge_req(dut, kRequestPc, true);
    step_half_cycle(dut);
    step_half_cycle(dut);
    drive_negedge_req(dut, kRequestPc, false);

    expect(dut.out_valid, "second access missing out_valid");
    expect(dut.out_hit, "second access did not hit");
    expect(dut.out_pc == kRequestPc,
           "second access out_pc mismatch got=" + hex_u64(dut.out_pc) + " exp=" + hex_u64(kRequestPc));
    expect(!dut.out_error, "second access out_error asserted unexpectedly");
    expect(check_out_data_deadbeef(dut),
           "second access out_data mismatch got=" + format_out_data(dut) +
           " exp=" + format_expected_deadbeef_128());
    expect(!dut.refill_req_valid, "second access unexpectedly triggered refill_req_valid immediately");

    step_full_cycle(dut);
    print_icache_snapshot(dut, "after second access settle");
    expect(!dut.refill_req_valid, "second access triggered a new refill request");

    std::cout << "PASS: basic refill flow request_pc=" << hex_u64(kRequestPc)
              << " refill_pc=" << hex_u64(captured_refill_pc)
              << " out_data=" << format_out_data(dut) << "\n";
    print_output_summary();
    std::cout << "ALL TESTS PASSED\n";

    dut.final();
    return EXIT_SUCCESS;
}
