#include "Vo3_tandem_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int kResetCycles = 5;
constexpr int kRefillLatency = 2;
constexpr int kLineBytes = 64;
constexpr int kInstBytes = 4;
constexpr int kInstsPerLine = kLineBytes / kInstBytes;
constexpr int kRetireWidth = 4;
constexpr uint32_t kInvalidInstruction = 0xffffffffu;

struct Options {
    std::string image_path = "tests/smoke.hex";
    std::string trace_path = "tandem.jsonl";
    uint64_t max_cycles = 1000;
    uint64_t max_retires = 4;
    uint64_t reset_pc = 0;
};

struct PendingRefill {
    uint64_t line_pc;
    uint64_t ready_cycle;
};

uint64_t parse_u64(const std::string& text) {
    std::size_t consumed = 0;
    const uint64_t value = std::stoull(text, &consumed, 0);
    if (consumed != text.size()) {
        throw std::runtime_error("invalid integer: " + text);
    }
    return value;
}

Options parse_options(int argc, char** argv) {
    Options options;
    for (int arg = 1; arg < argc; ++arg) {
        const std::string current = argv[arg];
        auto take_value = [&](const char* name) -> std::string {
            if (arg + 1 >= argc) {
                throw std::runtime_error(std::string("missing value for ") + name);
            }
            return argv[++arg];
        };

        if (current == "--image") {
            options.image_path = take_value("--image");
        } else if (current == "--trace") {
            options.trace_path = take_value("--trace");
        } else if (current == "--max-cycles") {
            options.max_cycles = parse_u64(take_value("--max-cycles"));
        } else if (current == "--max-retires") {
            options.max_retires = parse_u64(take_value("--max-retires"));
        } else if (current == "--reset-pc") {
            options.reset_pc = parse_u64(take_value("--reset-pc"));
        } else if (current == "--help") {
            std::cout
                << "Usage: Vo3_tandem_top [options]\n"
                << "  --image PATH         word-per-line instruction hex image\n"
                << "  --trace PATH         Tandem JSONL output\n"
                << "  --max-cycles N       simulation timeout\n"
                << "  --max-retires N      stop after N retired instructions\n"
                << "  --reset-pc ADDRESS   reset PC and image base\n";
            std::exit(0);
        } else {
            throw std::runtime_error("unknown argument: " + current);
        }
    }
    return options;
}

std::vector<uint32_t> load_instruction_image(const std::string& path) {
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("cannot open instruction image: " + path);
    }

    std::vector<uint32_t> words;
    std::string line;
    while (std::getline(input, line)) {
        const std::size_t comment = line.find('#');
        if (comment != std::string::npos) {
            line.erase(comment);
        }
        std::istringstream parser(line);
        std::string token;
        if (!(parser >> token)) {
            continue;
        }
        std::size_t consumed = 0;
        const unsigned long value = std::stoul(token, &consumed, 16);
        if (consumed != token.size() || value > UINT32_MAX) {
            throw std::runtime_error("invalid instruction word in " + path + ": " + token);
        }
        words.push_back(static_cast<uint32_t>(value));
    }
    return words;
}

void clear_refill_response(Vo3_tandem_top& dut) {
    dut.refill_resp_valid_i = 0;
    dut.refill_resp_pc_i = 0;
    dut.refill_resp_error_i = 0;
    for (int word = 0; word < kInstsPerLine; ++word) {
        dut.refill_resp_data_i[word] = 0;
    }
}

uint32_t read_instruction(const std::vector<uint32_t>& image,
                          uint64_t image_base,
                          uint64_t pc) {
    if (pc < image_base || ((pc - image_base) % kInstBytes) != 0) {
        return kInvalidInstruction;
    }
    const uint64_t index = (pc - image_base) / kInstBytes;
    return index < image.size() ? image[index] : kInvalidInstruction;
}

void drive_refill_response(Vo3_tandem_top& dut,
                           const std::vector<uint32_t>& image,
                           uint64_t image_base,
                           uint64_t line_pc) {
    dut.refill_resp_valid_i = 1;
    dut.refill_resp_pc_i = line_pc;
    dut.refill_resp_error_i = 0;
    for (int word = 0; word < kInstsPerLine; ++word) {
        const uint64_t pc = line_pc + static_cast<uint64_t>(word * kInstBytes);
        dut.refill_resp_data_i[word] = read_instruction(image, image_base, pc);
    }
}

void eval_low(Vo3_tandem_top& dut) {
    dut.clk_i = 0;
    dut.eval();
}

void rising_edge(Vo3_tandem_top& dut) {
    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();
}

void write_hex_string(std::ostream& out, uint64_t value, int digits) {
    const auto old_flags = out.flags();
    const char old_fill = out.fill();
    out << "\"0x" << std::hex << std::setw(digits) << std::setfill('0') << value << "\"";
    out.flags(old_flags);
    out.fill(old_fill);
}

void emit_tandem_records(const Vo3_tandem_top& dut,
                         std::ofstream& trace,
                         uint64_t cycle,
                         uint64_t& next_order) {
    // 同拍退休是一个完整的连续前缀。即使本拍越过用户给出的停止数量，
    // 也必须把这一拍所有已退休指令写完，不能生成被截断的体系结构轨迹。
    for (int slot = 0; slot < kRetireWidth; ++slot) {
        if (((dut.tandem_valid_o >> slot) & 1u) == 0) {
            continue;
        }

        trace << "{\"type\":\"retire\",\"cycle\":" << cycle
              << ",\"order\":" << next_order
              << ",\"slot\":" << slot
              << ",\"instruction_id\":" << dut.tandem_instruction_id_o[slot]
              << ",\"rob_idx\":" << static_cast<unsigned>(dut.tandem_rob_idx_o[slot])
              << ",\"pc\":";
        write_hex_string(trace, dut.tandem_pc_o[slot], 10);
        trace << ",\"instruction\":";
        write_hex_string(trace, dut.tandem_instruction_o[slot], 8);
        trace << ",\"rd\":" << static_cast<unsigned>(dut.tandem_rd_o[slot])
              << ",\"rd_write\":"
              << ((((dut.tandem_rd_write_o >> slot) & 1u) != 0) ? "true" : "false")
              << ",\"rd_wdata\":";
        write_hex_string(trace, dut.tandem_rd_wdata_o[slot], 16);
        trace << "}\n";

        ++next_order;
    }
}

}  // namespace

int main(int argc, char** argv) {
    try {
        Verilated::commandArgs(argc, argv);
        const Options options = parse_options(argc, argv);
        const std::vector<uint32_t> image = load_instruction_image(options.image_path);

        std::ofstream trace(options.trace_path, std::ios::trunc);
        if (!trace) {
            throw std::runtime_error("cannot open Tandem trace: " + options.trace_path);
        }
        trace << "{\"type\":\"header\",\"format\":\"cislc-o3-tandem\","
              << "\"version\":1,\"xlen\":64,\"retire_width\":" << kRetireWidth << "}\n";

        Vo3_tandem_top dut;
        std::deque<PendingRefill> pending_refills;
        uint64_t cycle = 0;
        uint64_t next_order = 0;

        dut.clk_i = 0;
        dut.rst_i = 1;
        dut.flush_i = 0;
        dut.reset_pc_i = options.reset_pc;
        clear_refill_response(dut);
        for (int reset_cycle = 0; reset_cycle < kResetCycles; ++reset_cycle) {
            rising_edge(dut);
        }
        dut.rst_i = 0;

        while (cycle < options.max_cycles && next_order < options.max_retires) {
            clear_refill_response(dut);
            if (!pending_refills.empty() && pending_refills.front().ready_cycle <= cycle) {
                const uint64_t line_pc = pending_refills.front().line_pc;
                pending_refills.pop_front();
                drive_refill_response(dut, image, options.reset_pc, line_pc);
            }

            eval_low(dut);
            emit_tandem_records(dut, trace, cycle, next_order);

            if (dut.refill_req_valid_o) {
                pending_refills.push_back(PendingRefill{
                    .line_pc = dut.refill_req_pc_o,
                    .ready_cycle = cycle + kRefillLatency,
                });
            }

            rising_edge(dut);
            ++cycle;
        }

        dut.final();
        trace.flush();

        if (next_order < options.max_retires) {
            std::cerr << "[o3-tandem] timeout: cycles=" << cycle
                      << " retired=" << next_order
                      << " expected=" << options.max_retires << "\n";
            return 1;
        }

        std::cout << "[o3-tandem] PASS cycles=" << cycle
                  << " retired=" << next_order
                  << " trace=" << options.trace_path << "\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "[o3-tandem] error: " << error.what() << "\n";
        return 1;
    }
}
