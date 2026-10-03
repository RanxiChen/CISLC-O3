#include "Vo3_tandem_top.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int kResetCycles = 5;
constexpr int kRetireWidth = 4;
constexpr uint64_t kDtcmBase = 0x11000000ull;
constexpr uint64_t kDtcmBytes = 0x00040000ull;
constexpr uint64_t kAxiBase = 0x80000000ull;
constexpr uint64_t kAxiBytes = 0x00100000ull;

struct Options {
    std::string image_path = "tests/smoke.hex";
    std::string trace_path = "tandem.jsonl";
    uint64_t max_cycles = 1000;
    uint64_t max_retires = 4;
    uint64_t reset_pc = kAxiBase;
    bool reset_pc_explicit = false;
    bool require_icache_refill = false;
};

struct InitBeat {
    uint64_t addr = 0;
    uint64_t data = 0;
    uint8_t mask = 0;
};

class SparseMemory {
  public:
    void write8(uint64_t addr, uint8_t value) { bytes_[addr] = value; }

    uint8_t read8(uint64_t addr, uint8_t absent = 0) const {
        const auto found = bytes_.find(addr);
        return found == bytes_.end() ? absent : found->second;
    }

    void write64(uint64_t addr, uint64_t data, uint8_t mask) {
        for (int byte = 0; byte < 8; ++byte) {
            if ((mask >> byte) & 1u) {
                write8(addr + static_cast<uint64_t>(byte),
                       static_cast<uint8_t>(data >> (8 * byte)));
            }
        }
    }

    uint64_t read64(uint64_t addr) const {
        uint64_t result = 0;
        for (int byte = 0; byte < 8; ++byte) {
            result |= static_cast<uint64_t>(read8(addr + static_cast<uint64_t>(byte)))
                      << (8 * byte);
        }
        return result;
    }

    uint32_t read_instruction(uint64_t addr) const {
        uint32_t result = 0;
        for (int byte = 0; byte < 4; ++byte) {
            result |= static_cast<uint32_t>(read8(addr + static_cast<uint64_t>(byte), 0xff))
                      << (8 * byte);
        }
        return result;
    }

    std::vector<InitBeat> init_beats(uint64_t base, uint64_t size) const {
        std::map<uint64_t, InitBeat> grouped;
        const uint64_t end = base + size;
        for (auto it = bytes_.lower_bound(base); it != bytes_.end() && it->first < end; ++it) {
            const uint64_t beat_addr = it->first & ~uint64_t{7};
            const unsigned lane = static_cast<unsigned>(it->first & 7u);
            InitBeat& beat = grouped[beat_addr];
            beat.addr = beat_addr;
            beat.data |= static_cast<uint64_t>(it->second) << (8 * lane);
            beat.mask |= static_cast<uint8_t>(1u << lane);
        }

        std::vector<InitBeat> result;
        result.reserve(grouped.size());
        for (const auto& [addr, beat] : grouped) {
            static_cast<void>(addr);
            result.push_back(beat);
        }
        return result;
    }

  private:
    std::map<uint64_t, uint8_t> bytes_;
};

struct LoadedImage {
    SparseMemory memory;
    uint64_t entry = 0;
    bool has_entry = false;
};

uint64_t parse_u64(const std::string& text) {
    std::size_t consumed = 0;
    const uint64_t value = std::stoull(text, &consumed, 0);
    if (consumed != text.size()) {
        throw std::runtime_error("invalid integer: " + text);
    }
    return value;
}

uint64_t read_le(const std::vector<uint8_t>& data, std::size_t offset, int bytes) {
    if (offset + static_cast<std::size_t>(bytes) > data.size()) {
        throw std::runtime_error("truncated ELF field");
    }
    uint64_t value = 0;
    for (int byte = 0; byte < bytes; ++byte) {
        value |= static_cast<uint64_t>(data[offset + byte]) << (8 * byte);
    }
    return value;
}

LoadedImage load_elf64(const std::vector<uint8_t>& data) {
    if (data.size() < 64 || data[4] != 2 || data[5] != 1) {
        throw std::runtime_error("only little-endian ELF64 images are supported");
    }

    LoadedImage image;
    image.entry = read_le(data, 24, 8);
    image.has_entry = true;
    const uint64_t phoff = read_le(data, 32, 8);
    const uint16_t phentsize = static_cast<uint16_t>(read_le(data, 54, 2));
    const uint16_t phnum = static_cast<uint16_t>(read_le(data, 56, 2));
    const uint64_t program_header_bytes = static_cast<uint64_t>(phentsize) * phnum;
    if (phentsize < 56 || phoff > data.size()
     || program_header_bytes > data.size() - phoff) {
        throw std::runtime_error("invalid ELF64 program header table");
    }

    for (uint16_t index = 0; index < phnum; ++index) {
        const std::size_t header = static_cast<std::size_t>(phoff) + index * phentsize;
        if (read_le(data, header, 4) != 1) {
            continue;
        }
        const uint64_t file_offset = read_le(data, header + 8, 8);
        const uint64_t vaddr = read_le(data, header + 16, 8);
        const uint64_t paddr = read_le(data, header + 24, 8);
        const uint64_t file_size = read_le(data, header + 32, 8);
        const uint64_t mem_size = read_le(data, header + 40, 8);
        const uint64_t load_addr = paddr != 0 ? paddr : vaddr;
        if (file_size > mem_size || file_offset > data.size()
         || file_size > data.size() - file_offset) {
            throw std::runtime_error("invalid ELF64 PT_LOAD segment");
        }
        for (uint64_t byte = 0; byte < file_size; ++byte) {
            image.memory.write8(load_addr + byte, data[file_offset + byte]);
        }
        for (uint64_t byte = file_size; byte < mem_size; ++byte) {
            image.memory.write8(load_addr + byte, 0);
        }
    }
    return image;
}

LoadedImage load_hex(const std::string& text, const std::string& path, uint64_t base) {
    LoadedImage image;
    uint64_t cursor = base;
    std::istringstream input(text);
    std::string line;
    while (std::getline(input, line)) {
        const std::size_t comment = line.find('#');
        if (comment != std::string::npos) {
            line.erase(comment);
        }
        std::istringstream parser(line);
        std::string token;
        while (parser >> token) {
            if (token.front() == '@') {
                cursor = parse_u64(token.substr(1));
                continue;
            }
            std::size_t consumed = 0;
            const unsigned long value = std::stoul(token, &consumed, 16);
            if (consumed != token.size() || value > UINT32_MAX) {
                throw std::runtime_error("invalid word in " + path + ": " + token);
            }
            for (int byte = 0; byte < 4; ++byte) {
                image.memory.write8(cursor + static_cast<uint64_t>(byte),
                                    static_cast<uint8_t>(value >> (8 * byte)));
            }
            cursor += 4;
        }
    }
    return image;
}

LoadedImage load_image(const std::string& path, uint64_t hex_base) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("cannot open image: " + path);
    }
    const std::vector<uint8_t> data((std::istreambuf_iterator<char>(input)),
                                    std::istreambuf_iterator<char>());
    if (data.size() >= 4 && data[0] == 0x7f && data[1] == 'E'
     && data[2] == 'L' && data[3] == 'F') {
        return load_elf64(data);
    }
    return load_hex(std::string(data.begin(), data.end()), path, hex_base);
}

Options parse_options(int argc, char** argv) {
    Options options;
    for (int arg = 1; arg < argc; ++arg) {
        const std::string current = argv[arg];
        if (!current.empty() && current.front() == '+') {
            continue;  // Verilator plusargs, such as +L1_DEBUG.
        }
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
            options.reset_pc_explicit = true;
        } else if (current == "--require-icache-refill") {
            options.require_icache_refill = true;
        } else if (current == "--help") {
            std::cout
                << "Usage: Vo3_tandem_top [options]\n"
                << "  --image PATH         ELF64 or word-oriented hex image\n"
                << "  --trace PATH         Tandem JSONL output\n"
                << "  --max-cycles N       simulation timeout\n"
                << "  --max-retires N      stop after N retired instructions\n"
                << "  --reset-pc ADDRESS   reset PC and default hex load address\n"
                << "  --require-icache-refill  fail if no ICache line refill occurs\n"
                << "Hex files may use @ADDRESS to change the byte load address.\n";
            std::exit(0);
        } else {
            throw std::runtime_error("unknown argument: " + current);
        }
    }
    return options;
}

void clear_tcm_init(Vo3_tandem_top& dut) {
    dut.dtcm_init_valid_i = 0;
    dut.dtcm_init_addr_i = 0;
    dut.dtcm_init_wdata_i = 0;
    dut.dtcm_init_wmask_i = 0;
    dut.axi_init_valid_i = 0;
    dut.axi_init_addr_i = 0;
    dut.axi_init_wmask_i = 0;
    for (int word = 0; word < 4; ++word) dut.axi_init_data_i[word] = 0;
}

void drive_axi_init(Vo3_tandem_top& dut, const InitBeat& beat) {
    const unsigned byte_offset = static_cast<unsigned>(beat.addr & 0xfu);
    dut.axi_init_valid_i = 1;
    dut.axi_init_addr_i = beat.addr & ~uint64_t{0xf};
    dut.axi_init_wmask_i = static_cast<uint16_t>(beat.mask) << byte_offset;
    const unsigned word_offset = byte_offset / 4;
    dut.axi_init_data_i[word_offset] = static_cast<uint32_t>(beat.data);
    dut.axi_init_data_i[word_offset + 1] = static_cast<uint32_t>(beat.data >> 32);
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
        Options options = parse_options(argc, argv);
        LoadedImage image = load_image(options.image_path, options.reset_pc);
        if (!options.reset_pc_explicit && image.has_entry) {
            options.reset_pc = image.entry;
        }

        const std::vector<InitBeat> dtcm_init = image.memory.init_beats(kDtcmBase, kDtcmBytes);
        const std::vector<InitBeat> axi_init = image.memory.init_beats(kAxiBase, kAxiBytes);

        std::ofstream trace(options.trace_path, std::ios::trunc);
        if (!trace) {
            throw std::runtime_error("cannot open Tandem trace: " + options.trace_path);
        }
        trace << "{\"type\":\"header\",\"format\":\"cislc-o3-tandem\","
              << "\"version\":1,\"xlen\":64,\"retire_width\":" << kRetireWidth << "}\n";

        Vo3_tandem_top dut;
        uint64_t cycle = 0;
        uint64_t next_order = 0;

        dut.clk_i = 0;
        dut.rst_i = 1;
        dut.reset_pc_i = options.reset_pc;
        clear_tcm_init(dut);
        eval_low(dut);

        const std::size_t init_cycles = std::max(
            static_cast<std::size_t>(kResetCycles),
            std::max(dtcm_init.size(), axi_init.size()));
        for (std::size_t init_cycle = 0; init_cycle < init_cycles; ++init_cycle) {
            clear_tcm_init(dut);
            if (init_cycle < dtcm_init.size()) {
                const InitBeat& beat = dtcm_init[init_cycle];
                dut.dtcm_init_valid_i = 1;
                dut.dtcm_init_addr_i = beat.addr;
                dut.dtcm_init_wdata_i = beat.data;
                dut.dtcm_init_wmask_i = beat.mask;
            }
            if (init_cycle < axi_init.size()) {
                drive_axi_init(dut, axi_init[init_cycle]);
            }
            rising_edge(dut);
        }
        clear_tcm_init(dut);
        dut.rst_i = 0;

        while (cycle < options.max_cycles && next_order < options.max_retires) {
            eval_low(dut);
            emit_tandem_records(dut, trace, cycle, next_order);
            if (dut.fatal_o || dut.inclusion_err_o) {
                throw std::runtime_error("core fatal/inclusion error at cycle "
                                         + std::to_string(cycle));
            }
            rising_edge(dut);
            ++cycle;
        }

        dut.final();
        trace.flush();

        if (next_order < options.max_retires) {
            std::cerr << "[o3-tandem] timeout: cycles=" << cycle
                      << " retired=" << next_order
                      << " expected=" << options.max_retires;
            std::cerr << "\n";
            return 1;
        }

        if (options.require_icache_refill && dut.icache_refill_count_o == 0) {
            throw std::runtime_error("no ICache refill observed");
        }

        std::cout << "[o3-memory] dtcm_init_beats=" << dtcm_init.size()
                  << " axi_init_beats=" << axi_init.size()
                  << " icache_refills=" << dut.icache_refill_count_o << "\n";
        std::cout << "[o3-tandem] PASS cycles=" << cycle
                  << " retired=" << next_order
                  << " trace=" << options.trace_path << "\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "[o3-tandem] error: " << error.what() << "\n";
        return 1;
    }
}
