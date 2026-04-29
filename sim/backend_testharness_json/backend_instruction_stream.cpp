#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include "svdpi.h"
#include "third_party/nlohmann/json.hpp"

namespace {

#ifndef MACHINE_WIDTH
#define MACHINE_WIDTH 4
#endif

constexpr uint32_t kMachineWidth = MACHINE_WIDTH;
constexpr uint32_t kGroupStrideBytes = kMachineWidth * 4;
constexpr uint32_t kNopInst = 0x00000013u;  // addi x0, x0, 0

using InstGroup = std::array<uint32_t, kMachineWidth>;
using nlohmann::json;

std::vector<InstGroup> g_inst_groups;
uint64_t g_fetch_count = 0;

bool parse_inst_value(const json& value, uint32_t* inst, std::string* error) {
    if (value.is_number_unsigned()) {
        const uint64_t raw = value.get<uint64_t>();
        if (raw > 0xFFFF'FFFFu) {
            *error = "Instruction value exceeds 32-bit range.";
            return false;
        }
        *inst = static_cast<uint32_t>(raw);
        return true;
    }

    if (value.is_number_integer()) {
        const int64_t raw = value.get<int64_t>();
        if (raw < 0 || raw > 0xFFFF'FFFFu) {
            *error = "Instruction value exceeds 32-bit range.";
            return false;
        }
        *inst = static_cast<uint32_t>(raw);
        return true;
    }

    if (value.is_string()) {
        const std::string text = value.get<std::string>();
        size_t parsed = 0;
        uint64_t raw = 0;
        try {
            raw = std::stoull(text, &parsed, 0);
        } catch (const std::exception& ex) {
            *error = std::string("Invalid instruction string: ") + ex.what();
            return false;
        }
        if (parsed != text.size()) {
            *error = "Instruction string contains trailing characters.";
            return false;
        }
        if (raw > 0xFFFF'FFFFu) {
            *error = "Instruction value exceeds 32-bit range.";
            return false;
        }
        *inst = static_cast<uint32_t>(raw);
        return true;
    }

    *error = "Instruction must be a number or string.";
    return false;
}

}  // namespace

bool backend_stream_load_json(const char* path, std::string* error) {
    std::ifstream file(path);
    if (!file) {
        *error = std::string("Cannot open file: ") + path;
        return false;
    }

    json root;
    try {
        file >> root;
    } catch (const std::exception& ex) {
        *error = std::string("Failed to parse JSON: ") + ex.what();
        return false;
    }

    if (!root.is_object()) {
        *error = "Root JSON must be an object with 'meta' and 'instruction'.";
        return false;
    }

    if (!root.contains("instruction") || !root["instruction"].is_array()) {
        *error = "Missing 'instruction' array.";
        return false;
    }

    std::vector<InstGroup> groups;
    const auto& instructions = root["instruction"];
    for (size_t group_idx = 0; group_idx < instructions.size(); group_idx++) {
        const auto& group = instructions[group_idx];
        if (!group.is_array()) {
            *error = "Each instruction group must be a list.";
            return false;
        }
        if (group.empty()) {
            *error = "Instruction group cannot be empty.";
            return false;
        }
        if (group.size() > kMachineWidth) {
            *error = "Instruction group exceeds max width (4).";
            return false;
        }

        InstGroup inst_group;
        inst_group.fill(kNopInst);
        for (size_t lane = 0; lane < group.size(); lane++) {
            uint32_t inst = 0;
            std::string parse_error;
            if (!parse_inst_value(group[lane], &inst, &parse_error)) {
                *error = "Group " + std::to_string(group_idx) + " lane " + std::to_string(lane) + ": " + parse_error;
                return false;
            }
            inst_group[lane] = inst;
        }
        groups.push_back(inst_group);
    }

    if (groups.empty()) {
        *error = "Instruction list is empty.";
        return false;
    }

    g_inst_groups = std::move(groups);
    g_fetch_count = 0;

    std::cout << "[BACKEND_DPI] Loaded JSON stream: groups=" << g_inst_groups.size() << std::endl;
    return true;
}

extern "C" {

void dpi_backend_stream_reset() {
    g_fetch_count = 0;
    std::cout << "[BACKEND_DPI] Reset backend instruction stream, groups="
              << g_inst_groups.size() << std::endl;
}

uint32_t dpi_backend_get_total_groups() {
    return static_cast<uint32_t>(g_inst_groups.size());
}

uint8_t dpi_backend_has_group(uint32_t group_idx) {
    return (group_idx < g_inst_groups.size()) ? 1 : 0;
}

void dpi_backend_get_fetch_entry(
    uint32_t group_idx,
    uint32_t lane_idx,
    uint64_t* pc,
    uint32_t* inst,
    uint8_t* exception,
    uint8_t* valid
) {
    if ((group_idx >= g_inst_groups.size()) || (lane_idx >= kMachineWidth)) {
        *pc = 0;
        *inst = 0;
        *exception = 0;
        *valid = 0;
        return;
    }

    *pc = static_cast<uint64_t>(group_idx) * kGroupStrideBytes + static_cast<uint64_t>(lane_idx) * 4ull;
    *inst = g_inst_groups[group_idx][lane_idx];
    *exception = 0;
    *valid = 1;
}

void dpi_backend_log_fetch_lane(
    uint64_t cycle,
    uint32_t group_idx,
    uint32_t lane_idx,
    uint8_t fire,
    uint64_t pc,
    uint32_t inst
) {
    if (!fire) {
        return;
    }

    if (lane_idx == 0) {
        g_fetch_count++;
        std::cout << "[BACKEND_DPI] Cycle " << std::dec << cycle
                  << " accepted group " << group_idx
                  << " (fetch #" << g_fetch_count << ")"
                  << std::endl;
    }

    std::cout << "  lane" << std::dec << lane_idx
              << " pc=0x" << std::hex << pc
              << " inst=0x" << inst
              << std::endl;
}

}  // extern "C"
