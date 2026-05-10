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
constexpr int kMaxCycles = 2000;
constexpr int kRefillLatencyCycles = 6;
constexpr int kLineBytes = 64;
constexpr int kInstBytes = 4;
constexpr int kInstsPerLine = kLineBytes / kInstBytes;
constexpr int kRetirePorts = 3;
constexpr int kExpectedRetires = 6;

// Architectural setup the test exercises:
//   x1 = 1, x2 = 1, x3 = x1 + x2 = 2
//   bne x3, x2, +16  -> taken (2 != 1) -> redirect from 0x0c to 0x1c
//   wrong path 0x10/0x14/0x18 must never retire
//   redirect path retires 0x1c (x7=11) and 0x20 (x8 = x7 + x1 = 12).
constexpr uint32_t kAddiX1X0One   = 0x00100093u;  // 0x00: addi x1, x0, 1
constexpr uint32_t kAddiX2X0One   = 0x00100113u;  // 0x04: addi x2, x0, 1
constexpr uint32_t kAddX3X1X2     = 0x002081B3u;  // 0x08: add  x3, x1, x2
constexpr uint32_t kBneX3X2Plus16 = 0x00219863u;  // 0x0c: bne  x3, x2, +16
constexpr uint32_t kOriX4X0Nine   = 0x00906213u;  // 0x10: ori  x4, x0, 9   (wrong path)
constexpr uint32_t kXoriX5X0Six   = 0x00604293u;  // 0x14: xori x5, x0, 6   (wrong path)
constexpr uint32_t kAddiX6X0Seven = 0x00700313u;  // 0x18: addi x6, x0, 7   (wrong path)
constexpr uint32_t kAddiX7X0Eleven= 0x00B00393u;  // 0x1c: addi x7, x0, 11
constexpr uint32_t kAddX8X7X1     = 0x00138433u;  // 0x20: add  x8, x7, x1
constexpr uint32_t kInvalidInst   = 0xffffffffu;

constexpr uint32_t kRetireUopInt    = 1;
constexpr uint32_t kRetireUopBranch = 2;

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
    uint32_t uop_type;
    uint32_t rd;
    bool rd_write_en;
    uint64_t rd_wdata;
    bool branch_taken;
    bool branch_mispredict;
    uint64_t branch_target_pc;
    uint64_t branch_fallthrough_pc;
};

struct ExpectedRetire {
    uint64_t pc;
    uint32_t instruction;
    uint32_t uop_type;
    uint32_t rd;
    bool rd_write_en;
    uint64_t rd_wdata;
    bool branch_taken;
    bool branch_mispredict;
    uint64_t branch_target_pc;
    uint64_t branch_fallthrough_pc;
};

constexpr std::array<ExpectedRetire, kExpectedRetires> kExpected = {{
    {
        .pc = 0x00,
        .instruction = kAddiX1X0One,
        .uop_type = kRetireUopInt,
        .rd = 1,
        .rd_write_en = true,
        .rd_wdata = 1,
        .branch_taken = false,
        .branch_mispredict = false,
        .branch_target_pc = 0,
        .branch_fallthrough_pc = 0,
    },
    {
        .pc = 0x04,
        .instruction = kAddiX2X0One,
        .uop_type = kRetireUopInt,
        .rd = 2,
        .rd_write_en = true,
        .rd_wdata = 1,
        .branch_taken = false,
        .branch_mispredict = false,
        .branch_target_pc = 0,
        .branch_fallthrough_pc = 0,
    },
    {
        .pc = 0x08,
        .instruction = kAddX3X1X2,
        .uop_type = kRetireUopInt,
        .rd = 3,
        .rd_write_en = true,
        .rd_wdata = 2,
        .branch_taken = false,
        .branch_mispredict = false,
        .branch_target_pc = 0,
        .branch_fallthrough_pc = 0,
    },
    {
        .pc = 0x0c,
        .instruction = kBneX3X2Plus16,
        .uop_type = kRetireUopBranch,
        .rd = 0,
        .rd_write_en = false,
        .rd_wdata = 0,
        .branch_taken = true,
        .branch_mispredict = true,
        .branch_target_pc = 0x1c,
        .branch_fallthrough_pc = 0x10,
    },
    {
        .pc = 0x1c,
        .instruction = kAddiX7X0Eleven,
        .uop_type = kRetireUopInt,
        .rd = 7,
        .rd_write_en = true,
        .rd_wdata = 11,
        .branch_taken = false,
        .branch_mispredict = false,
        .branch_target_pc = 0,
        .branch_fallthrough_pc = 0,
    },
    {
        .pc = 0x20,
        .instruction = kAddX8X7X1,
        .uop_type = kRetireUopInt,
        .rd = 8,
        .rd_write_en = true,
        .rd_wdata = 12,
        .branch_taken = false,
        .branch_mispredict = false,
        .branch_target_pc = 0,
        .branch_fallthrough_pc = 0,
    },
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
        case 0x00:
            return kAddiX1X0One;
        case 0x04:
            return kAddiX2X0One;
        case 0x08:
            return kAddX3X1X2;
        case 0x0c:
            return kBneX3X2Plus16;
        case 0x10:
            return kOriX4X0Nine;
        case 0x14:
            return kXoriX5X0Six;
        case 0x18:
            return kAddiX6X0Seven;
        case 0x1c:
            return kAddiX7X0Eleven;
        case 0x20:
            return kAddX8X7X1;
        default:
            return kInvalidInst;
    }
}

uint64_t read_wide_bits(const WData* words, int lsb, int width) {
    uint64_t value = 0;
    for (int bit = 0; bit < width; ++bit) {
        const int src_bit = lsb + bit;
        const uint64_t bit_value = (words[src_bit / 32] >> (src_bit % 32)) & 1u;
        value |= bit_value << bit;
    }
    return value;
}

RetireInfo read_retire_info(const Vo3_core& dut, int port) {
    const WData* raw = dut.retire_info_o[port];
    return RetireInfo{
        .valid = read_wide_bits(raw, 293, 1) != 0,
        .rob_idx = read_wide_bits(raw, 287, 6),
        .instruction_id = read_wide_bits(raw, 223, 64),
        .pc = read_wide_bits(raw, 184, 39),
        .instruction = static_cast<uint32_t>(read_wide_bits(raw, 152, 32)),
        .uop_type = static_cast<uint32_t>(read_wide_bits(raw, 150, 2)),
        .rd = static_cast<uint32_t>(read_wide_bits(raw, 145, 5)),
        .rd_write_en = read_wide_bits(raw, 144, 1) != 0,
        .rd_wdata = read_wide_bits(raw, 80, 64),
        .branch_taken = read_wide_bits(raw, 79, 1) != 0,
        .branch_mispredict = read_wide_bits(raw, 78, 1) != 0,
        .branch_target_pc = read_wide_bits(raw, 39, 39),
        .branch_fallthrough_pc = read_wide_bits(raw, 0, 39),
    };
}

void require_field(bool condition, std::string_view message) {
    if (!condition) {
        std::cerr << "[core_three_alu_redirect][assert] " << message << "\n";
        std::exit(1);
    }
}

std::string hex_u64(uint64_t value) {
    std::ostringstream oss;
    oss << "0x" << std::hex << value;
    return oss.str();
}

bool is_wrong_path_pc(uint64_t pc) {
    return pc == 0x10 || pc == 0x14 || pc == 0x18;
}

void check_one_retire(const RetireInfo& info, int retire_index) {
    const ExpectedRetire& expected = kExpected.at(retire_index);

    // After branch squash, ROB tail rewinds to branch_rob_idx+1 and the
    // redirect-target uops reuse contiguous ROB slots, so rob_idx tracks the
    // architectural retire order across the squash boundary.
    require_field(info.rob_idx == static_cast<uint64_t>(retire_index),
                  "ROB index mismatch for retire " + std::to_string(retire_index));
    require_field(info.pc == expected.pc,
                  "pc mismatch for retire " + std::to_string(retire_index) + ": got " + hex_u64(info.pc));
    require_field(info.instruction == expected.instruction,
                  "instruction mismatch for retire " + std::to_string(retire_index) + ": got " + hex_u64(info.instruction));
    require_field(info.uop_type == expected.uop_type,
                  "uop_type mismatch for retire " + std::to_string(retire_index));
    require_field(info.rd == expected.rd,
                  "rd mismatch for retire " + std::to_string(retire_index));
    require_field(info.rd_write_en == expected.rd_write_en,
                  "rd_write_en mismatch for retire " + std::to_string(retire_index));
    require_field(info.rd_wdata == expected.rd_wdata,
                  "rd_wdata mismatch for retire " + std::to_string(retire_index) + ": got " + hex_u64(info.rd_wdata));
    require_field(info.branch_taken == expected.branch_taken,
                  "branch_taken mismatch for retire " + std::to_string(retire_index));
    require_field(info.branch_mispredict == expected.branch_mispredict,
                  "branch_mispredict mismatch for retire " + std::to_string(retire_index));
    require_field(info.branch_target_pc == expected.branch_target_pc,
                  "branch_target_pc mismatch for retire " + std::to_string(retire_index) + ": got " + hex_u64(info.branch_target_pc));
    require_field(info.branch_fallthrough_pc == expected.branch_fallthrough_pc,
                  "branch_fallthrough_pc mismatch for retire " + std::to_string(retire_index) + ": got " + hex_u64(info.branch_fallthrough_pc));

    // The first 4 retires come from a single fetch group at reset_pc=0,
    // so their instruction_id equals the lane index. Retires 4 and 5 land in
    // post-redirect fetch groups whose absolute group sequence depends on
    // simulation timing; only require them to be strictly newer than the branch.
    if (retire_index < 4) {
        require_field(info.instruction_id == static_cast<uint64_t>(retire_index),
                      "instruction_id mismatch for retire " + std::to_string(retire_index));
    } else {
        require_field(info.instruction_id > kExpected.size(),
                      "post-redirect instruction_id should be allocated to a new fetch group, retire "
                          + std::to_string(retire_index) + ": got " + hex_u64(info.instruction_id));
    }
}

void check_retire_info(const Vo3_core& dut, int cycle, int& observed_retires) {
    for (int port = 0; port < kRetirePorts; ++port) {
        const RetireInfo info = read_retire_info(dut, port);
        if (!info.valid) {
            continue;
        }

        require_field(!is_wrong_path_pc(info.pc),
                      "wrong-path instruction retired: pc=" + hex_u64(info.pc));
        require_field(observed_retires < kExpectedRetires,
                      "unexpected extra retire after expected stream completed");

        std::cout << "[core_three_alu_redirect][cycle=" << std::dec << cycle
                  << "] retire_info port=" << port
                  << " pc=0x" << std::hex << info.pc
                  << " inst=0x" << std::setw(8) << std::setfill('0') << info.instruction
                  << std::setfill(' ')
                  << " type=" << std::dec << info.uop_type
                  << " rd=x" << info.rd
                  << " rd_wen=" << info.rd_write_en
                  << " rd_wdata=0x" << std::hex << info.rd_wdata
                  << " taken=" << info.branch_taken
                  << " mispredict=" << info.branch_mispredict
                  << " target=0x" << info.branch_target_pc
                  << " fallthrough=0x" << info.branch_fallthrough_pc
                  << " rob=" << std::dec << info.rob_idx
                  << " id=0x" << std::hex << info.instruction_id
                  << std::dec << "\n";

        check_one_retire(info, observed_retires);
        ++observed_retires;
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
        std::cout << "[core_three_alu_redirect][cycle=" << std::dec << cycle
                  << "] refill req pc=0x" << std::hex << dut.refill_req_pc_o
                  << std::dec << "\n";
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vo3_core dut;
    std::deque<PendingRefill> pending_refills;
    int observed_retires = 0;

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
            std::cout << "[core_three_alu_redirect][cycle=" << std::dec << cycle
                      << "] refill resp pc=0x" << std::hex << resp_pc
                      << std::dec << "\n";
        }

        eval_half_cycle(dut, 0);
        check_retire_info(dut, cycle, observed_retires);

        step(dut);

        print_refill_req(dut, cycle);

        if (dut.refill_req_valid_o) {
            pending_refills.push_back(PendingRefill{
                .pc = dut.refill_req_pc_o,
                .remaining_cycles = kRefillLatencyCycles
            });
        }

        ++cycle;

        if (observed_retires == kExpectedRetires) {
            break;
        }
    }

    dut.final();

    if (observed_retires == kExpectedRetires) {
        require_field(dut.retired_inst_count_o == kExpectedRetires,
                      "retired_inst_count should be 6 at test exit");
        std::cout << "[core_three_alu_redirect] redirect target retired"
                  << " retired_inst_count=" << std::dec << dut.retired_inst_count_o
                  << " cycles=" << (cycle - 1)
                  << "\n";
    } else {
        std::cout << "[core_three_alu_redirect] timeout at cycle " << std::dec << cycle
                  << " observed_retires=" << observed_retires
                  << " retired_inst_count=" << dut.retired_inst_count_o
                  << "\n";
        return 1;
    }

    return 0;
}
