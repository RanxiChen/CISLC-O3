#pragma once

#include "Vo3_core.h"

#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

// retire_info_t packed struct bit positions (LSB=0):
//   branch_fallthrough_pc[38:0]     0..38
//   branch_target_pc[38:0]         39..77
//   branch_mispredict              78
//   branch_taken                   79
//   rd_wdata[63:0]                 80..143
//   rd_write_en                   144
//   rd[4:0]                       145..149
//   uop_type[1:0]                 150..151
//   instruction[31:0]             152..183
//   pc[38:0]                      184..222
//   instruction_id[63:0]          223..286
//   rob_idx[5:0]                  287..292
//   valid                         293

struct IsaRetireInfo {
    bool     valid;
    uint64_t rob_idx;
    uint64_t instruction_id;
    uint64_t pc;
    uint32_t instruction;
    uint32_t rd;
    bool     rd_write_en;
    uint64_t rd_wdata;
};

struct IsaProgram {
    std::string name;
    uint64_t reset_pc;
    std::unordered_map<uint64_t, uint32_t> instructions;  // pc -> instruction encoding
};

struct IsaRegExpect {
    int rd;
    uint64_t value;
};

class IsaTestHarness {
public:
    IsaTestHarness(int argc, char** argv);
    ~IsaTestHarness();

    void load_json(const std::string& path);
    void expect_retired_count(uint64_t n);
    void expect_register(int rd, uint64_t value);
    void run();

private:
    static constexpr int kResetCycles = 5;
    static constexpr int kMaxCycles = 5000;
    static constexpr int kRefillLatencyCycles = 6;
    static constexpr int kLineBytes = 64;
    static constexpr int kInstBytes = 4;
    static constexpr int kInstsPerLine = kLineBytes / kInstBytes;
    static constexpr int kRetirePorts = 3;
    static constexpr int kDrainCycles = 10;

    struct PendingRefill {
        uint64_t pc;
        int remaining_cycles;
    };

    Vo3_core dut_;
    IsaProgram prog_;
    uint64_t expected_retired_count_ = 0;
    std::vector<IsaRegExpect> expected_regs_;

    // Internal scoreboard: last observed retired rd -> rd_wdata for each arch reg
    uint64_t retired_reg_values_[32] = {};
    bool retired_reg_seen_[32] = {};
    uint64_t retired_count_ = 0;

    // Helpers
    void eval_half_cycle(uint8_t clk_value);
    void step();
    void clear_refill_resp();
    uint32_t read_inst(uint64_t pc) const;
    void drive_refill_resp(uint64_t line_pc);
    IsaRetireInfo read_retire_info(int port) const;
    void sample_retire_info();

    static uint64_t read_wide_bits(const WData* words, int lsb, int width);
    static void require_field(bool condition, const std::string& message);
};
