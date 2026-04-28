#include "Vlfsr.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>

namespace {

constexpr uint16_t kSeed = 0xACE1;
constexpr int kDisableHoldCycles = 10;

std::string hex16(uint16_t value) {
    std::ostringstream stream;
    stream << "0x" << std::hex << std::uppercase << std::setw(4) << std::setfill('0')
           << value;
    return stream.str();
}

void fail(const std::string& phase, int cycle, uint16_t expected, uint16_t actual) {
    std::cerr << phase << " failed at cycle " << cycle << ": expected "
              << hex16(expected) << ", got " << hex16(actual) << '\n';
    std::exit(1);
}

void expect_eq(const std::string& phase, int cycle, uint16_t expected, uint16_t actual) {
    if (expected != actual) {
        fail(phase, cycle, expected, actual);
    }
}

void eval_clk(Vlfsr& dut, uint8_t clk_value) {
    dut.clk = clk_value;
    dut.eval();
}

void step_half_cycle(Vlfsr& dut) {
    eval_clk(dut, !dut.clk);
}

void step_cycle(Vlfsr& dut) {
    step_half_cycle(dut);
    step_half_cycle(dut);
}

uint16_t lfsr_next(uint16_t current) {
    const uint16_t feedback =
        ((current >> 15) ^ (current >> 13) ^ (current >> 12) ^ (current >> 10)) & 0x1;
    return static_cast<uint16_t>((current << 1) | feedback);
}

int parse_total_updates(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <total_updates>" << '\n';
        std::exit(1);
    }

    try {
        const int total_updates = std::stoi(argv[1]);
        if (total_updates <= 0) {
            std::cerr << "total_updates must be a positive integer" << '\n';
            std::exit(1);
        }
        return total_updates;
    } catch (const std::exception&) {
        std::cerr << "total_updates must be a positive integer" << '\n';
        std::exit(1);
    }
}

void print_distribution_metric(const int* counts, int total_updates) {
    std::cout << "Total updates: " << total_updates << '\n';
    double variance_like = 0.0;
    for (int value = 0; value < 4; ++value) {
        const double frequency =
            static_cast<double>(counts[value]) / static_cast<double>(total_updates);
        const double delta_from_uniform = frequency - 0.25;
        variance_like += delta_from_uniform * delta_from_uniform;
    }
    variance_like /= 4.0;
    std::cout << "variance_like=" << std::fixed << std::setprecision(8) << variance_like
              << '\n';
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const int total_updates = parse_total_updates(argc, argv);

    Vlfsr dut;
    dut.clk = 0;
    dut.rst = 1;
    dut.enable = 0;
    dut.eval();

    step_cycle(dut);
    expect_eq("reset", 0, kSeed, dut.lfsr_out);

    step_cycle(dut);
    expect_eq("reset", 1, kSeed, dut.lfsr_out);

    dut.rst = 0;
    for (int cycle = 0; cycle < kDisableHoldCycles; ++cycle) {
        dut.enable = 0;
        step_cycle(dut);
        expect_eq("hold-disable", cycle, kSeed, dut.lfsr_out);
    }

    uint16_t expected = kSeed;
    int low_bits_counts[4] = {0, 0, 0, 0};
    for (int cycle = 0; cycle < total_updates; ++cycle) {
        dut.enable = 1;
        expected = lfsr_next(expected);
        step_cycle(dut);
        expect_eq("advance-enable", cycle, expected, dut.lfsr_out);
        ++low_bits_counts[dut.lfsr_out & 0x3];
    }

    print_distribution_metric(low_bits_counts, total_updates);
    std::cout << "LFSR simulation passed" << '\n';
    return 0;
}
