#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>

namespace {

uint64_t g_call_counter = 0;
uint64_t g_register_file[32] = {0};
thread_local std::string g_disasm_buffer;

uint32_t get_opcode(uint32_t inst) {
    return inst & 0x7Fu;
}

uint32_t get_rd(uint32_t inst) {
    return (inst >> 7) & 0x1Fu;
}

uint32_t get_funct3(uint32_t inst) {
    return (inst >> 12) & 0x7u;
}

uint32_t get_rs1(uint32_t inst) {
    return (inst >> 15) & 0x1Fu;
}

uint32_t get_rs2(uint32_t inst) {
    return (inst >> 20) & 0x1Fu;
}

uint32_t get_funct7(uint32_t inst) {
    return (inst >> 25) & 0x7Fu;
}

int32_t sign_extend(uint32_t value, int bits) {
    const uint32_t sign_bit = 1u << (bits - 1);
    const uint32_t mask = (bits == 32) ? 0xFFFF'FFFFu : ((1u << bits) - 1u);
    value &= mask;
    return static_cast<int32_t>((value ^ sign_bit) - sign_bit);
}

int32_t imm_i(uint32_t inst) {
    return sign_extend(inst >> 20, 12);
}

int32_t imm_s(uint32_t inst) {
    return sign_extend(((inst >> 25) << 5) | ((inst >> 7) & 0x1Fu), 12);
}

int32_t imm_b(uint32_t inst) {
    uint32_t imm = 0;
    imm |= ((inst >> 31) & 0x1u) << 12;
    imm |= ((inst >> 7) & 0x1u) << 11;
    imm |= ((inst >> 25) & 0x3Fu) << 5;
    imm |= ((inst >> 8) & 0xFu) << 1;
    return sign_extend(imm, 13);
}

int32_t imm_u(uint32_t inst) {
    return static_cast<int32_t>(inst & 0xFFFFF000u);
}

int32_t imm_j(uint32_t inst) {
    uint32_t imm = 0;
    imm |= ((inst >> 31) & 0x1u) << 20;
    imm |= ((inst >> 12) & 0xFFu) << 12;
    imm |= ((inst >> 20) & 0x1u) << 11;
    imm |= ((inst >> 21) & 0x3FFu) << 1;
    return sign_extend(imm, 21);
}

std::string reg_name(uint32_t reg_idx) {
    return "x" + std::to_string(reg_idx);
}

std::string format_hex32(uint32_t value) {
    std::ostringstream oss;
    oss << "0x" << std::hex << std::nouppercase << value;
    return oss.str();
}

std::string format_imm_operand(int32_t value) {
    return std::to_string(value);
}

std::string format_load_store_operand(int32_t imm, uint32_t rs1) {
    return std::to_string(imm) + "(" + reg_name(rs1) + ")";
}

std::string format_r_type(const char* mnemonic, uint32_t rd, uint32_t rs1, uint32_t rs2) {
    return std::string(mnemonic) + " " + reg_name(rd) + "," + reg_name(rs1) + "," + reg_name(rs2);
}

std::string format_i_type(const char* mnemonic, uint32_t rd, uint32_t rs1, int32_t imm) {
    return std::string(mnemonic) + " " + reg_name(rd) + "," + reg_name(rs1) + "," + format_imm_operand(imm);
}

std::string format_u_type(const char* mnemonic, uint32_t rd, int32_t imm) {
    return std::string(mnemonic) + " " + reg_name(rd) + "," + format_hex32(static_cast<uint32_t>(imm));
}

std::string format_branch(const char* mnemonic, uint32_t rs1, uint32_t rs2, int32_t imm) {
    return std::string(mnemonic) + " " + reg_name(rs1) + "," + reg_name(rs2) + "," + format_imm_operand(imm);
}

std::string format_load(const char* mnemonic, uint32_t rd, int32_t imm, uint32_t rs1) {
    return std::string(mnemonic) + " " + reg_name(rd) + "," + format_load_store_operand(imm, rs1);
}

std::string format_store(const char* mnemonic, uint32_t rs2, int32_t imm, uint32_t rs1) {
    return std::string(mnemonic) + " " + reg_name(rs2) + "," + format_load_store_operand(imm, rs1);
}

std::string disasm_rv64i(uint32_t inst) {
    const uint32_t opcode = get_opcode(inst);
    const uint32_t rd = get_rd(inst);
    const uint32_t funct3 = get_funct3(inst);
    const uint32_t rs1 = get_rs1(inst);
    const uint32_t rs2 = get_rs2(inst);
    const uint32_t funct7 = get_funct7(inst);

    switch (opcode) {
        case 0x37:
            return format_u_type("lui", rd, imm_u(inst));
        case 0x17:
            return format_u_type("auipc", rd, imm_u(inst));
        case 0x6F:
            return std::string("jal ") + reg_name(rd) + "," + format_imm_operand(imm_j(inst));
        case 0x67:
            if (funct3 == 0b000) {
                return std::string("jalr ") + reg_name(rd) + "," + format_load_store_operand(imm_i(inst), rs1);
            }
            break;
        case 0x63:
            switch (funct3) {
                case 0b000: return format_branch("beq", rs1, rs2, imm_b(inst));
                case 0b001: return format_branch("bne", rs1, rs2, imm_b(inst));
                case 0b100: return format_branch("blt", rs1, rs2, imm_b(inst));
                case 0b101: return format_branch("bge", rs1, rs2, imm_b(inst));
                case 0b110: return format_branch("bltu", rs1, rs2, imm_b(inst));
                case 0b111: return format_branch("bgeu", rs1, rs2, imm_b(inst));
                default: break;
            }
            break;
        case 0x03:
            switch (funct3) {
                case 0b000: return format_load("lb", rd, imm_i(inst), rs1);
                case 0b001: return format_load("lh", rd, imm_i(inst), rs1);
                case 0b010: return format_load("lw", rd, imm_i(inst), rs1);
                case 0b011: return format_load("ld", rd, imm_i(inst), rs1);
                case 0b100: return format_load("lbu", rd, imm_i(inst), rs1);
                case 0b101: return format_load("lhu", rd, imm_i(inst), rs1);
                case 0b110: return format_load("lwu", rd, imm_i(inst), rs1);
                default: break;
            }
            break;
        case 0x23:
            switch (funct3) {
                case 0b000: return format_store("sb", rs2, imm_s(inst), rs1);
                case 0b001: return format_store("sh", rs2, imm_s(inst), rs1);
                case 0b010: return format_store("sw", rs2, imm_s(inst), rs1);
                case 0b011: return format_store("sd", rs2, imm_s(inst), rs1);
                default: break;
            }
            break;
        case 0x13:
            switch (funct3) {
                case 0b000: return format_i_type("addi", rd, rs1, imm_i(inst));
                case 0b010: return format_i_type("slti", rd, rs1, imm_i(inst));
                case 0b011: return format_i_type("sltiu", rd, rs1, imm_i(inst));
                case 0b100: return format_i_type("xori", rd, rs1, imm_i(inst));
                case 0b110: return format_i_type("ori", rd, rs1, imm_i(inst));
                case 0b111: return format_i_type("andi", rd, rs1, imm_i(inst));
                case 0b001:
                    if ((inst >> 26) == 0b000000) {
                        return std::string("slli ") + reg_name(rd) + "," + reg_name(rs1) + "," + std::to_string((inst >> 20) & 0x3Fu);
                    }
                    break;
                case 0b101:
                    if ((inst >> 26) == 0b000000) {
                        return std::string("srli ") + reg_name(rd) + "," + reg_name(rs1) + "," + std::to_string((inst >> 20) & 0x3Fu);
                    }
                    if ((inst >> 26) == 0b010000) {
                        return std::string("srai ") + reg_name(rd) + "," + reg_name(rs1) + "," + std::to_string((inst >> 20) & 0x3Fu);
                    }
                    break;
                default: break;
            }
            break;
        case 0x1B:
            switch (funct3) {
                case 0b000: return format_i_type("addiw", rd, rs1, imm_i(inst));
                case 0b001:
                    if ((inst >> 25) == 0b0000000) {
                        return std::string("slliw ") + reg_name(rd) + "," + reg_name(rs1) + "," + std::to_string((inst >> 20) & 0x1Fu);
                    }
                    break;
                case 0b101:
                    if ((inst >> 25) == 0b0000000) {
                        return std::string("srliw ") + reg_name(rd) + "," + reg_name(rs1) + "," + std::to_string((inst >> 20) & 0x1Fu);
                    }
                    if ((inst >> 25) == 0b0100000) {
                        return std::string("sraiw ") + reg_name(rd) + "," + reg_name(rs1) + "," + std::to_string((inst >> 20) & 0x1Fu);
                    }
                    break;
                default: break;
            }
            break;
        case 0x33:
            switch (funct3) {
                case 0b000:
                    if (funct7 == 0b0000000) return format_r_type("add", rd, rs1, rs2);
                    if (funct7 == 0b0100000) return format_r_type("sub", rd, rs1, rs2);
                    break;
                case 0b001:
                    if (funct7 == 0b0000000) return format_r_type("sll", rd, rs1, rs2);
                    break;
                case 0b010:
                    if (funct7 == 0b0000000) return format_r_type("slt", rd, rs1, rs2);
                    break;
                case 0b011:
                    if (funct7 == 0b0000000) return format_r_type("sltu", rd, rs1, rs2);
                    break;
                case 0b100:
                    if (funct7 == 0b0000000) return format_r_type("xor", rd, rs1, rs2);
                    break;
                case 0b101:
                    if (funct7 == 0b0000000) return format_r_type("srl", rd, rs1, rs2);
                    if (funct7 == 0b0100000) return format_r_type("sra", rd, rs1, rs2);
                    break;
                case 0b110:
                    if (funct7 == 0b0000000) return format_r_type("or", rd, rs1, rs2);
                    break;
                case 0b111:
                    if (funct7 == 0b0000000) return format_r_type("and", rd, rs1, rs2);
                    break;
                default: break;
            }
            break;
        case 0x3B:
            switch (funct3) {
                case 0b000:
                    if (funct7 == 0b0000000) return format_r_type("addw", rd, rs1, rs2);
                    if (funct7 == 0b0100000) return format_r_type("subw", rd, rs1, rs2);
                    break;
                case 0b001:
                    if (funct7 == 0b0000000) return format_r_type("sllw", rd, rs1, rs2);
                    break;
                case 0b101:
                    if (funct7 == 0b0000000) return format_r_type("srlw", rd, rs1, rs2);
                    if (funct7 == 0b0100000) return format_r_type("sraw", rd, rs1, rs2);
                    break;
                default: break;
            }
            break;
        case 0x0F:
            if (funct3 == 0b000) {
                return "fence";
            }
            if (funct3 == 0b001) {
                return "fence.i";
            }
            break;
        case 0x73:
            if (inst == 0x00000073u) {
                return "ecall";
            }
            if (inst == 0x00100073u) {
                return "ebreak";
            }
            if (funct3 == 0b000) {
                return "system";
            }
            break;
        default:
            break;
    }

    return "unknown(0x" + format_hex32(inst).substr(2) + ")";
}

}  // namespace

extern "C" {

void dpi_log_frontend_transaction(uint64_t, uint32_t, uint8_t, uint8_t) {
    g_call_counter++;
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
    for (uint64_t& reg : g_register_file) {
        reg = 0;
    }
}

void dpi_set_register(uint32_t reg_num, uint64_t value) {
    if (reg_num < 32) {
        g_register_file[reg_num] = value;
    }
}

uint64_t dpi_get_register(uint32_t reg_num) {
    if (reg_num < 32) {
        return g_register_file[reg_num];
    }

    return 0;
}

}  // extern "C"
