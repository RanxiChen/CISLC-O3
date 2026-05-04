#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>

namespace {

uint64_t g_call_counter = 0;
thread_local std::string g_disasm_buffer;

uint32_t get_opcode(uint32_t inst) {
    return inst & 0x7fu;
}

uint32_t get_rd(uint32_t inst) {
    return (inst >> 7) & 0x1fu;
}

uint32_t get_funct3(uint32_t inst) {
    return (inst >> 12) & 0x7u;
}

uint32_t get_rs1(uint32_t inst) {
    return (inst >> 15) & 0x1fu;
}

int32_t imm_i(uint32_t inst) {
    const uint32_t imm = inst >> 20;
    return static_cast<int32_t>((imm ^ 0x800u) - 0x800u);
}

std::string hex_inst(uint32_t inst) {
    std::ostringstream oss;
    oss << "0x" << std::hex << std::setw(8) << std::setfill('0') << inst;
    return oss.str();
}

std::string disasm_rv64i(uint32_t inst) {
    if (get_opcode(inst) != 0x13u) {
        return "unknown(" + hex_inst(inst) + ")";
    }

    const char* mnemonic = nullptr;
    switch (get_funct3(inst)) {
        case 0x0u:
            mnemonic = "addi";
            break;
        case 0x4u:
            mnemonic = "xori";
            break;
        case 0x6u:
            mnemonic = "ori";
            break;
        default:
            break;
    }

    if (mnemonic == nullptr) {
        return "unknown(" + hex_inst(inst) + ")";
    }

    return std::string(mnemonic) + " x" + std::to_string(get_rd(inst))
         + ",x" + std::to_string(get_rs1(inst))
         + "," + std::to_string(imm_i(inst));
}

}  // namespace

extern "C" {

void dpi_log_frontend_transaction(uint64_t, uint32_t, uint8_t, uint8_t) {
    ++g_call_counter;
}

void dpi_log_frontend_signals(uint64_t, uint32_t, uint8_t, uint8_t) {
}

void dpi_print_call_counter() {
}

void dpi_reset_call_counter() {
    g_call_counter = 0;
}

uint64_t dpi_get_call_counter() {
    return g_call_counter;
}

void dpi_backend_stream_reset() {
}

uint32_t dpi_backend_get_total_groups() {
    return 0;
}

uint8_t dpi_backend_has_group(uint32_t) {
    return 0;
}

void dpi_backend_get_fetch_entry(uint32_t, uint32_t, uint64_t* pc, uint32_t* inst, uint8_t* exception, uint8_t* valid) {
    *pc = 0;
    *inst = 0xffffffffu;
    *exception = 0;
    *valid = 0;
}

void dpi_backend_log_fetch_lane(uint64_t, uint32_t, uint32_t, uint8_t, uint64_t, uint32_t) {
}

const char* dpi_backend_disasm_rv64i(uint32_t inst) {
    g_disasm_buffer = disasm_rv64i(inst);
    return g_disasm_buffer.c_str();
}

void dpi_decode_instruction(uint32_t, uint8_t* out_is_branch, uint8_t* out_is_jump, uint8_t* out_funct3, uint64_t* out_imm) {
    *out_is_branch = 0;
    *out_is_jump = 0;
    *out_funct3 = 0;
    *out_imm = 0;
}

uint8_t dpi_execute_branch(uint64_t, uint32_t, uint64_t, uint64_t) {
    return 0;
}

uint8_t dpi_predict_branch(uint64_t, uint32_t) {
    return 0;
}

uint64_t dpi_execute_jal(uint64_t pc, uint32_t) {
    return pc + 4;
}

uint64_t dpi_execute_jalr(uint64_t pc, uint32_t, uint64_t) {
    return pc + 4;
}

void dpi_print_branch_stats() {
}

void dpi_reset_exec_state() {
}

void dpi_set_register(uint32_t, uint64_t) {
}

uint64_t dpi_get_register(uint32_t) {
    return 0;
}

}  // extern "C"
