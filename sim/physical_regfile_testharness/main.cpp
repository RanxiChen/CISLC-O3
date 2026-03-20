#include <array>
#include <cstdint>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "Vphysical_regfile_testharness.h"
#include "verilated.h"

#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

namespace {
constexpr int kNumReadPorts = NUM_READ_PORTS;
constexpr int kNumWritePorts = NUM_WRITE_PORTS;
constexpr int kNumEntries = NUM_ENTRIES;
constexpr int kDataWidth = DATA_WIDTH;
constexpr uint64_t kDataMask = (kDataWidth >= 64) ? ~0ULL : ((1ULL << kDataWidth) - 1ULL);
constexpr int kRandomCycles = 200;
#if VM_TRACE
VerilatedVcdC* g_tfp = nullptr;
#endif

struct RefModel {
    std::vector<uint64_t> data = std::vector<uint64_t>(kNumEntries, 0);
    std::vector<bool> valid = std::vector<bool>(kNumEntries, false);
};

struct CycleStimulus {
    std::array<uint64_t, kNumReadPorts> rd_addr{};
    std::array<uint8_t, kNumWritePorts> wr_en{};
    std::array<uint64_t, kNumWritePorts> wr_addr{};
    std::array<uint64_t, kNumWritePorts> wr_data{};
};

void eval_tick(Vphysical_regfile_testharness* dut, vluint64_t& sim_time) {
    dut->clk_i = 0;
    dut->eval();
#if VM_TRACE
    if (g_tfp) g_tfp->dump(sim_time);
#endif
    sim_time++;

    dut->clk_i = 1;
    dut->eval();
#if VM_TRACE
    if (g_tfp) g_tfp->dump(sim_time);
#endif
    sim_time++;
}

void apply_inputs(Vphysical_regfile_testharness* dut, const CycleStimulus& s) {
    for (int rp = 0; rp < kNumReadPorts; rp++) {
        dut->rd_addr_i[rp] = s.rd_addr[rp];
    }
    for (int wp = 0; wp < kNumWritePorts; wp++) {
        dut->wr_en_i[wp] = s.wr_en[wp];
        dut->wr_addr_i[wp] = s.wr_addr[wp];
        dut->wr_data_i[wp] = s.wr_data[wp] & kDataMask;
    }
    dut->eval();
}

bool check_reads(Vphysical_regfile_testharness* dut, const CycleStimulus& s, const RefModel& ref, int cycle) {
    bool pass = true;
    for (int rp = 0; rp < kNumReadPorts; rp++) {
        const uint64_t addr = s.rd_addr[rp] % kNumEntries;
        bool has_expect = false;
        uint64_t expect = 0;

        for (int wp = kNumWritePorts - 1; wp >= 0; wp--) {
            if (s.wr_en[wp] && (s.wr_addr[wp] % kNumEntries) == addr) {
                has_expect = true;
                expect = s.wr_data[wp] & kDataMask;
                break;
            }
        }

        if (!has_expect && ref.valid[addr]) {
            has_expect = true;
            expect = ref.data[addr] & kDataMask;
        }

        if (!has_expect) {
            continue;
        }

        const uint64_t got = dut->rd_data_o[rp] & kDataMask;
        if (got != expect) {
            std::printf(
                "[FAIL] cycle=%d rp=%d addr=%llu expect=0x%016llx got=0x%016llx\n",
                cycle,
                rp,
                static_cast<unsigned long long>(addr),
                static_cast<unsigned long long>(expect),
                static_cast<unsigned long long>(got)
            );
            pass = false;
        }
    }
    return pass;
}

void commit_writes(const CycleStimulus& s, RefModel& ref) {
    for (int wp = 0; wp < kNumWritePorts; wp++) {
        if (!s.wr_en[wp]) {
            continue;
        }
        const uint64_t addr = s.wr_addr[wp] % kNumEntries;
        ref.valid[addr] = true;
        ref.data[addr] = s.wr_data[wp] & kDataMask;
    }
}

CycleStimulus make_idle() {
    CycleStimulus s{};
    for (int rp = 0; rp < kNumReadPorts; rp++) {
        s.rd_addr[rp] = 0;
    }
    for (int wp = 0; wp < kNumWritePorts; wp++) {
        s.wr_en[wp] = 0;
        s.wr_addr[wp] = 0;
        s.wr_data[wp] = 0;
    }
    return s;
}

bool run_directed(Vphysical_regfile_testharness* dut, RefModel& ref, int& cycle, vluint64_t& sim_time) {
    bool pass = true;

    {
        CycleStimulus s = make_idle();
        const uint64_t addr = 3 % kNumEntries;
        s.wr_en[0] = 1;
        s.wr_addr[0] = addr;
        s.wr_data[0] = 0x1122334455667788ULL;
        s.rd_addr[0] = addr;
        apply_inputs(dut, s);
        pass &= check_reads(dut, s, ref, cycle++);
        eval_tick(dut, sim_time);
        commit_writes(s, ref);
    }

    {
        CycleStimulus s = make_idle();
        const uint64_t addr = 3 % kNumEntries;
        for (int rp = 0; rp < kNumReadPorts; rp++) {
            s.rd_addr[rp] = addr;
        }
        apply_inputs(dut, s);
        pass &= check_reads(dut, s, ref, cycle++);
        eval_tick(dut, sim_time);
    }

    if (kNumWritePorts > 1) {
        CycleStimulus s = make_idle();
        const uint64_t addr = 7 % kNumEntries;
        s.wr_en[0] = 1;
        s.wr_addr[0] = addr;
        s.wr_data[0] = 0xAAAA000000000001ULL;
        s.wr_en[1] = 1;
        s.wr_addr[1] = addr;
        s.wr_data[1] = 0xBBBB000000000002ULL;
        s.rd_addr[0] = addr;
        apply_inputs(dut, s);
        pass &= check_reads(dut, s, ref, cycle++);
        eval_tick(dut, sim_time);
        commit_writes(s, ref);
    }

    return pass;
}

bool run_random(Vphysical_regfile_testharness* dut, RefModel& ref, int& cycle, vluint64_t& sim_time) {
    bool pass = true;
    std::mt19937_64 rng(0x20260319ULL);
    std::uniform_int_distribution<uint64_t> addr_dist(0, kNumEntries - 1);
    std::uniform_int_distribution<uint64_t> data_dist(0, kDataMask);
    std::bernoulli_distribution write_en_dist(0.45);

    for (int i = 0; i < kRandomCycles; i++) {
        CycleStimulus s = make_idle();
        for (int rp = 0; rp < kNumReadPorts; rp++) {
            s.rd_addr[rp] = addr_dist(rng);
        }
        for (int wp = 0; wp < kNumWritePorts; wp++) {
            s.wr_en[wp] = static_cast<uint8_t>(write_en_dist(rng));
            s.wr_addr[wp] = addr_dist(rng);
            s.wr_data[wp] = data_dist(rng);
        }

        apply_inputs(dut, s);
        pass &= check_reads(dut, s, ref, cycle++);
        eval_tick(dut, sim_time);
        commit_writes(s, ref);
    }

    return pass;
}
}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new Vphysical_regfile_testharness;

    vluint64_t sim_time = 0;

#if VM_TRACE
    Verilated::traceEverOn(true);
    g_tfp = new VerilatedVcdC;
    dut->trace(g_tfp, 99);
    std::string wave_name = "physical_regfile_";
    wave_name += std::to_string(kNumReadPorts) + "r" + std::to_string(kNumWritePorts) + "w.vcd";
    g_tfp->open(wave_name.c_str());
#endif

    dut->clk_i = 0;
    dut->rst_i = 1;
    CycleStimulus idle = make_idle();
    apply_inputs(dut, idle);
    for (int i = 0; i < 5; i++) {
        eval_tick(dut, sim_time);
    }

    dut->rst_i = 0;
    dut->eval();

    RefModel ref{};
    int cycle = 0;
    bool pass = true;
    pass &= run_directed(dut, ref, cycle, sim_time);
    pass &= run_random(dut, ref, cycle, sim_time);

    std::printf(
        "[SUMMARY] cfg=%dR%dW entries=%d data=%d checks=%d result=%s\n",
        kNumReadPorts, kNumWritePorts, kNumEntries, kDataWidth, cycle, pass ? "PASS" : "FAIL"
    );

#if VM_TRACE
    g_tfp->close();
    delete g_tfp;
    g_tfp = nullptr;
#endif

    delete dut;
    return pass ? 0 : 1;
}
