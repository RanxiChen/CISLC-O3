#include "isa_harness.h"

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string_view>

// ---------------------------------------------------------------------------
// Minimal JSON parser for our specific program format:
// {"name":"...","reset_pc":N,"instructions":{"PC":"0xHEX",...}}
// ---------------------------------------------------------------------------
namespace {

std::string_view trim_spaces(std::string_view s) {
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t' || s.front() == '\n' || s.front() == '\r')) {
        s.remove_prefix(1);
    }
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\n' || s.back() == '\r')) {
        s.remove_suffix(1);
    }
    return s;
}

bool consume_char(std::string_view& s, char c) {
    s = trim_spaces(s);
    if (s.empty() || s.front() != c) return false;
    s.remove_prefix(1);
    return true;
}

std::string_view consume_string(std::string_view& s) {
    s = trim_spaces(s);
    if (s.empty() || s.front() != '"') return {};
    s.remove_prefix(1);
    size_t end = 0;
    while (end < s.size() && s[end] != '"') {
        if (s[end] == '\\') ++end;
        ++end;
    }
    if (end >= s.size()) return {};
    std::string_view result(s.data(), end);
    s.remove_prefix(end + 1);
    return result;
}

uint64_t parse_hex64(std::string_view s) {
    s = trim_spaces(s);
    if (s.size() >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s.remove_prefix(2);
    }
    uint64_t v = 0;
    for (char c : s) {
        v <<= 4;
        if (c >= '0' && c <= '9')       v |= static_cast<uint64_t>(c - '0');
        else if (c >= 'a' && c <= 'f')  v |= static_cast<uint64_t>(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F')  v |= static_cast<uint64_t>(c - 'A' + 10);
        else break;
    }
    return v;
}

uint64_t parse_decimal64(std::string_view s) {
    s = trim_spaces(s);
    uint64_t v = 0;
    for (char c : s) {
        if (c < '0' || c > '9') break;
        v = v * 10 + static_cast<uint64_t>(c - '0');
    }
    return v;
}

std::string hex_u64(uint64_t value) {
    std::ostringstream oss;
    oss << "0x" << std::hex << value;
    return oss.str();
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// IsaTestHarness
// ---------------------------------------------------------------------------

IsaTestHarness::IsaTestHarness(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut_.clk_i = 0;
    dut_.rst_i = 1;
    dut_.flush_i = 0;
    dut_.reset_pc_i = 0;
    clear_refill_resp();
}

IsaTestHarness::~IsaTestHarness() {
    dut_.final();
}

void IsaTestHarness::load_json(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        require_field(false, "failed to open JSON program: " + path);
    }
    std::string content((std::istreambuf_iterator<char>(file)),
                         std::istreambuf_iterator<char>());
    file.close();

    std::string_view sv(content);
    sv = trim_spaces(sv);

    if (!consume_char(sv, '{')) {
        require_field(false, "JSON: expected '{'");
    }

    bool expect_comma = false;
    while (true) {
        sv = trim_spaces(sv);
        if (sv.empty()) {
            require_field(false, "JSON: unexpected EOF");
        }
        if (sv.front() == '}') {
            sv.remove_prefix(1);
            break;
        }
        if (expect_comma) {
            if (!consume_char(sv, ',')) {
                require_field(false, "JSON: expected ','");
            }
        }
        expect_comma = true;

        std::string_view key = consume_string(sv);
        if (key.empty()) {
            require_field(false, "JSON: expected string key");
        }
        if (!consume_char(sv, ':')) {
            require_field(false, "JSON: expected ':'");
        }

        if (key == "name") {
            std::string_view val = consume_string(sv);
            if (val.empty()) {
                require_field(false, "JSON: expected string value for 'name'");
            }
            prog_.name = std::string(val);
        } else if (key == "reset_pc") {
            sv = trim_spaces(sv);
            size_t end = 0;
            while (end < sv.size() && sv[end] >= '0' && sv[end] <= '9') ++end;
            if (end == 0) {
                require_field(false, "JSON: expected number for 'reset_pc'");
            }
            prog_.reset_pc = parse_decimal64(std::string_view(sv.data(), end));
            sv.remove_prefix(end);
        } else if (key == "instructions") {
            sv = trim_spaces(sv);
            if (sv.empty() || sv.front() != '{') {
                require_field(false, "JSON: expected '{' for 'instructions'");
            }
            sv.remove_prefix(1);

            bool first = true;
            while (true) {
                sv = trim_spaces(sv);
                if (sv.empty()) {
                    require_field(false, "JSON: unexpected EOF in 'instructions'");
                }
                if (sv.front() == '}') {
                    sv.remove_prefix(1);
                    break;
                }
                if (!first) {
                    if (!consume_char(sv, ',')) {
                        require_field(false, "JSON: expected ',' in instructions");
                    }
                }
                first = false;

                std::string_view pc_key = consume_string(sv);
                if (pc_key.empty()) {
                    require_field(false, "JSON: expected string PC key in instructions");
                }
                if (!consume_char(sv, ':')) {
                    require_field(false, "JSON: expected ':' in instructions");
                }
                std::string_view inst_hex = consume_string(sv);
                if (inst_hex.empty()) {
                    require_field(false, "JSON: expected hex instruction in instructions");
                }

                uint64_t pc = parse_decimal64(pc_key);
                uint32_t inst = static_cast<uint32_t>(parse_hex64(inst_hex));
                prog_.instructions[pc] = inst;
            }
        } else {
            // Unknown key, skip its value
            sv = trim_spaces(sv);
            if (sv.front() == '"') {
                consume_string(sv);
            } else if (sv.front() == '{') {
                int depth = 1;
                sv.remove_prefix(1);
                while (depth > 0 && !sv.empty()) {
                    if (sv.front() == '{') ++depth;
                    else if (sv.front() == '}') --depth;
                    sv.remove_prefix(1);
                }
            } else {
                while (!sv.empty() && sv.front() != ',' && sv.front() != '}') {
                    sv.remove_prefix(1);
                }
            }
        }
    }

    std::cout << "[isa_harness] loaded program \"" << prog_.name
              << "\" reset_pc=0x" << std::hex << prog_.reset_pc
              << std::dec << " (" << prog_.instructions.size() << " instructions)\n";
    dut_.reset_pc_i = prog_.reset_pc;
}

void IsaTestHarness::expect_retired_count(uint64_t n) {
    expected_retired_count_ = n;
}

void IsaTestHarness::expect_register(int rd, uint64_t value) {
    expected_regs_.push_back({rd, value});
}

void IsaTestHarness::eval_half_cycle(uint8_t clk_value) {
    dut_.clk_i = clk_value;
    dut_.eval();
}

void IsaTestHarness::step() {
    eval_half_cycle(1);
    eval_half_cycle(0);
}

void IsaTestHarness::clear_refill_resp() {
    dut_.refill_resp_valid_i = 0;
    dut_.refill_resp_pc_i = 0;
    dut_.refill_resp_error_i = 0;
    for (int word = 0; word < kInstsPerLine; ++word) {
        dut_.refill_resp_data_i[word] = 0;
    }
}

uint32_t IsaTestHarness::read_inst(uint64_t pc) const {
    auto it = prog_.instructions.find(pc);
    if (it != prog_.instructions.end()) {
        return it->second;
    }
    return 0xffffffffu;
}

void IsaTestHarness::drive_refill_resp(uint64_t line_pc) {
    dut_.refill_resp_valid_i = 1;
    dut_.refill_resp_pc_i = line_pc;
    dut_.refill_resp_error_i = 0;
    for (int i = 0; i < kInstsPerLine; ++i) {
        const uint64_t inst_pc = line_pc + static_cast<uint64_t>(i * kInstBytes);
        dut_.refill_resp_data_i[i] = read_inst(inst_pc);
    }
}

// static
uint64_t IsaTestHarness::read_wide_bits(const WData* words, int lsb, int width) {
    uint64_t value = 0;
    for (int bit = 0; bit < width; ++bit) {
        const int src_bit = lsb + bit;
        const uint64_t bit_value = (words[src_bit / 32] >> (src_bit % 32)) & 1u;
        value |= bit_value << bit;
    }
    return value;
}

IsaRetireInfo IsaTestHarness::read_retire_info(int port) const {
    const WData* raw = dut_.retire_info_o[port];
    return IsaRetireInfo{
        .valid         = read_wide_bits(raw, 293, 1) != 0,
        .rob_idx       = read_wide_bits(raw, 287, 6),
        .instruction_id = read_wide_bits(raw, 223, 64),
        .pc            = read_wide_bits(raw, 184, 39),
        .instruction   = static_cast<uint32_t>(read_wide_bits(raw, 152, 32)),
        .rd            = static_cast<uint32_t>(read_wide_bits(raw, 145, 5)),
        .rd_write_en   = read_wide_bits(raw, 144, 1) != 0,
        .rd_wdata      = read_wide_bits(raw, 80, 64),
    };
}

// static
void IsaTestHarness::require_field(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "[isa_harness][assert] " << message << "\n";
        std::exit(1);
    }
}

void IsaTestHarness::sample_retire_info() {
    for (int port = 0; port < kRetirePorts; ++port) {
        IsaRetireInfo info = read_retire_info(port);
        if (!info.valid) continue;

        ++retired_count_;

        std::cout << "[isa_harness][retire] port=" << port
                  << " pc=0x" << std::hex << info.pc
                  << " inst=0x" << std::setw(8) << std::setfill('0') << info.instruction
                  << std::setfill(' ')
                  << std::dec
                  << " rd=x" << info.rd
                  << " rd_wen=" << info.rd_write_en
                  << " rd_wdata=0x" << std::hex << info.rd_wdata
                  << std::dec
                  << " rob=" << info.rob_idx
                  << " id=0x" << std::hex << info.instruction_id
                  << std::dec << "\n";

        if (info.rd_write_en && info.rd < 32) {
            retired_reg_values_[info.rd] = info.rd_wdata;
            retired_reg_seen_[info.rd] = true;
        }
    }
}

void IsaTestHarness::run() {
    std::deque<PendingRefill> pending_refills;

    // ---- Reset phase ----
    for (int i = 0; i < kResetCycles; ++i) {
        step();
    }
    dut_.rst_i = 0;

    // ---- Main simulation loop ----
    int cycle = 0;
    int drain_counter = 0;

    while (cycle < kMaxCycles) {
        clear_refill_resp();

        for (auto& refill : pending_refills) {
            --refill.remaining_cycles;
        }

        if (!pending_refills.empty() && pending_refills.front().remaining_cycles < 0) {
            const uint64_t resp_pc = pending_refills.front().pc;
            pending_refills.pop_front();
            drive_refill_resp(resp_pc);
            std::cout << "[isa_harness][cycle=" << std::dec << cycle
                      << "] refill resp pc=0x" << std::hex << resp_pc
                      << std::dec << "\n";
        }

        eval_half_cycle(0);
        sample_retire_info();

        step();

        if (dut_.refill_req_valid_o) {
            std::cout << "[isa_harness][cycle=" << std::dec << cycle
                      << "] refill req pc=0x" << std::hex << dut_.refill_req_pc_o
                      << std::dec << "\n";
            pending_refills.push_back(PendingRefill{
                .pc = dut_.refill_req_pc_o,
                .remaining_cycles = kRefillLatencyCycles
            });
        }

        ++cycle;

        // Once we've retired enough, start drain countdown
        if (retired_count_ >= expected_retired_count_ && drain_counter == 0) {
            std::cout << "[isa_harness] expected retired count reached at cycle "
                      << (cycle - 1) << " (retired=" << retired_count_
                      << "), draining " << kDrainCycles << " cycles\n";
            drain_counter = 1;
        }

        if (drain_counter > 0) {
            ++drain_counter;
            if (drain_counter > kDrainCycles) {
                break;
            }
        }
    }

    uint64_t hw_retired = dut_.retired_inst_count_o;

    std::cout << "[isa_harness] simulation ended at cycle " << cycle
              << " retired_count=" << retired_count_
              << " hw_retired_inst_count=" << hw_retired
              << " expected=" << expected_retired_count_ << "\n";

    require_field(retired_count_ == expected_retired_count_,
                  "retired instruction count mismatch: got " + std::to_string(retired_count_)
                  + " expected " + std::to_string(expected_retired_count_));

    require_field(hw_retired == expected_retired_count_,
                  "hardware retired_inst_count mismatch: got " + std::to_string(hw_retired)
                  + " expected " + std::to_string(expected_retired_count_));

    for (const auto& exp : expected_regs_) {
        std::string reg_name = "x" + std::to_string(exp.rd);
        require_field(retired_reg_seen_[exp.rd],
                      "register " + reg_name + " was never written");
        require_field(retired_reg_values_[exp.rd] == exp.value,
                      "register " + reg_name + " value mismatch: got "
                      + hex_u64(retired_reg_values_[exp.rd])
                      + " expected " + hex_u64(exp.value));
    }

    std::cout << "[isa_harness] ALL CHECKS PASSED\n";
}
