#include <iostream>
#include <iomanip>
#include <cstdint>
#include "svdpi.h"

// ============================================================================
// RISC-V 执行模型 - 简化版（仅支持分支指令）
// ============================================================================

// 全局执行状态
static uint64_t g_pc = 0x80000000;              // 当前 PC
static uint64_t g_regs[32] = {0};               // 32 个通用寄存器
static uint64_t g_branch_count = 0;             // 分支指令计数
static uint64_t g_branch_taken_count = 0;      // 分支跳转次数
static uint64_t g_branch_history = 0;          // 简单的分支历史（用于预测）

// RISC-V 指令类型
enum InstType {
    INST_UNKNOWN = 0,
    INST_BRANCH,    // BEQ, BNE, BLT, BGE, BLTU, BGEU
    INST_JAL,       // JAL
    INST_JALR,      // JALR
    INST_OTHER      // 其他指令（本模型不关心）
};

// 分支指令操作码
enum BranchOp {
    BR_BEQ  = 0b000,
    BR_BNE  = 0b001,
    BR_BLT  = 0b100,
    BR_BGE  = 0b101,
    BR_BLTU = 0b110,
    BR_BGEU = 0b111
};

// 解码结果结构体
struct DecodeResult {
    InstType type;
    uint32_t opcode;
    uint32_t funct3;
    uint32_t rs1;
    uint32_t rs2;
    uint32_t rd;
    int64_t  imm;
    bool     is_branch;
    bool     is_jump;
};

// ============================================================================
// 辅助函数：提取指令字段
// ============================================================================

static inline uint32_t get_opcode(uint32_t inst) {
    return inst & 0x7F;
}

static inline uint32_t get_rd(uint32_t inst) {
    return (inst >> 7) & 0x1F;
}

static inline uint32_t get_funct3(uint32_t inst) {
    return (inst >> 12) & 0x7;
}

static inline uint32_t get_rs1(uint32_t inst) {
    return (inst >> 15) & 0x1F;
}

static inline uint32_t get_rs2(uint32_t inst) {
    return (inst >> 20) & 0x1F;
}

// B-type 立即数解码
static inline int64_t get_b_imm(uint32_t inst) {
    int64_t imm = 0;
    imm |= ((inst >> 31) & 0x1) << 12;   // imm[12]
    imm |= ((inst >> 7) & 0x1) << 11;    // imm[11]
    imm |= ((inst >> 25) & 0x3F) << 5;   // imm[10:5]
    imm |= ((inst >> 8) & 0xF) << 1;     // imm[4:1]
    // 符号扩展
    if (imm & (1 << 12)) {
        imm |= 0xFFFFFFFFFFFFE000ULL;
    }
    return imm;
}

// J-type 立即数解码
static inline int64_t get_j_imm(uint32_t inst) {
    int64_t imm = 0;
    imm |= ((inst >> 31) & 0x1) << 20;   // imm[20]
    imm |= ((inst >> 12) & 0xFF) << 12;  // imm[19:12]
    imm |= ((inst >> 20) & 0x1) << 11;   // imm[11]
    imm |= ((inst >> 21) & 0x3FF) << 1;  // imm[10:1]
    // 符号扩展
    if (imm & (1 << 20)) {
        imm |= 0xFFFFFFFFFFE00000ULL;
    }
    return imm;
}

// I-type 立即数解码
static inline int64_t get_i_imm(uint32_t inst) {
    int64_t imm = (inst >> 20) & 0xFFF;
    // 符号扩展
    if (imm & (1 << 11)) {
        imm |= 0xFFFFFFFFFFFFF000ULL;
    }
    return imm;
}

// ============================================================================
// DPI-C 函数实现
// ============================================================================

extern "C" {

// 解码指令
void dpi_decode_instruction(
    uint32_t inst,
    uint8_t* out_is_branch,
    uint8_t* out_is_jump,
    uint8_t* out_funct3,
    uint64_t* out_imm
) {
    DecodeResult dec = {0};
    uint32_t opcode = get_opcode(inst);

    dec.opcode = opcode;
    dec.funct3 = get_funct3(inst);
    dec.rs1 = get_rs1(inst);
    dec.rs2 = get_rs2(inst);
    dec.rd = get_rd(inst);

    // 判断指令类型
    switch (opcode) {
        case 0x63: // B-type: BEQ, BNE, BLT, BGE, BLTU, BGEU
            dec.type = INST_BRANCH;
            dec.is_branch = true;
            dec.is_jump = false;
            dec.imm = get_b_imm(inst);
            break;

        case 0x6F: // J-type: JAL
            dec.type = INST_JAL;
            dec.is_branch = false;
            dec.is_jump = true;
            dec.imm = get_j_imm(inst);
            break;

        case 0x67: // I-type: JALR
            dec.type = INST_JALR;
            dec.is_branch = false;
            dec.is_jump = true;
            dec.imm = get_i_imm(inst);
            break;

        default:
            dec.type = INST_OTHER;
            dec.is_branch = false;
            dec.is_jump = false;
            dec.imm = 0;
            break;
    }

    // 输出结果
    *out_is_branch = dec.is_branch ? 1 : 0;
    *out_is_jump = dec.is_jump ? 1 : 0;
    *out_funct3 = dec.funct3;
    *out_imm = dec.imm;

    if (dec.is_branch || dec.is_jump) {
        std::cout << "[DECODE] PC=0x" << std::hex << g_pc
                  << " Inst=0x" << inst
                  << " Type=" << (dec.is_branch ? "BRANCH" : "JUMP")
                  << " Funct3=" << std::dec << (int)dec.funct3
                  << " Imm=" << dec.imm
                  << std::endl;
    }
}

// 执行分支指令，返回是否跳转
uint8_t dpi_execute_branch(
    uint64_t pc,
    uint32_t inst,
    uint64_t rs1_val,
    uint64_t rs2_val
) {
    uint32_t opcode = get_opcode(inst);

    if (opcode != 0x63) {
        return 0; // 不是分支指令
    }

    g_branch_count++;

    uint32_t funct3 = get_funct3(inst);
    int64_t imm = get_b_imm(inst);
    bool taken = false;

    // 根据 funct3 判断分支类型并执行
    switch (funct3) {
        case BR_BEQ:  // BEQ
            taken = (rs1_val == rs2_val);
            break;
        case BR_BNE:  // BNE
            taken = (rs1_val != rs2_val);
            break;
        case BR_BLT:  // BLT (有符号)
            taken = ((int64_t)rs1_val < (int64_t)rs2_val);
            break;
        case BR_BGE:  // BGE (有符号)
            taken = ((int64_t)rs1_val >= (int64_t)rs2_val);
            break;
        case BR_BLTU: // BLTU (无符号)
            taken = (rs1_val < rs2_val);
            break;
        case BR_BGEU: // BGEU (无符号)
            taken = (rs1_val >= rs2_val);
            break;
        default:
            taken = false;
            break;
    }

    if (taken) {
        g_branch_taken_count++;
        g_pc = pc + imm;
    } else {
        g_pc = pc + 4;
    }

    // 更新分支历史（简单的移位寄存器）
    g_branch_history = (g_branch_history << 1) | (taken ? 1 : 0);

    std::cout << "[EXEC] PC=0x" << std::hex << pc
              << " Funct3=" << std::dec << funct3
              << " RS1=0x" << std::hex << rs1_val
              << " RS2=0x" << rs2_val
              << " Imm=" << std::dec << imm
              << " Taken=" << (taken ? "YES" : "NO")
              << " NextPC=0x" << std::hex << g_pc
              << std::endl;

    return taken ? 1 : 0;
}

// 简单的分支预测（基于历史）
uint8_t dpi_predict_branch(uint64_t pc, uint32_t inst) {
    // 使用最简单的 1-bit 预测器
    // 如果最近一次分支跳转了，就预测跳转
    bool predict_taken = (g_branch_history & 0x1) != 0;

    std::cout << "[PREDICT] PC=0x" << std::hex << pc
              << " Prediction=" << (predict_taken ? "TAKEN" : "NOT_TAKEN")
              << " History=0x" << g_branch_history
              << std::endl;

    return predict_taken ? 1 : 0;
}

// 执行 JAL 指令
uint64_t dpi_execute_jal(uint64_t pc, uint32_t inst) {
    int64_t imm = get_j_imm(inst);
    uint32_t rd = get_rd(inst);

    // 保存返回地址到 rd
    if (rd != 0) {
        g_regs[rd] = pc + 4;
    }

    uint64_t target = pc + imm;
    g_pc = target;

    std::cout << "[EXEC] JAL PC=0x" << std::hex << pc
              << " Target=0x" << target
              << " RD=" << std::dec << rd
              << std::endl;

    return target;
}

// 执行 JALR 指令
uint64_t dpi_execute_jalr(uint64_t pc, uint32_t inst, uint64_t rs1_val) {
    int64_t imm = get_i_imm(inst);
    uint32_t rd = get_rd(inst);

    // 保存返回地址到 rd
    if (rd != 0) {
        g_regs[rd] = pc + 4;
    }

    uint64_t target = (rs1_val + imm) & ~1ULL; // 清除最低位
    g_pc = target;

    std::cout << "[EXEC] JALR PC=0x" << std::hex << pc
              << " RS1=0x" << rs1_val
              << " Imm=" << std::dec << imm
              << " Target=0x" << std::hex << target
              << " RD=" << std::dec << rd
              << std::endl;

    return target;
}

// 打印分支统计信息
void dpi_print_branch_stats() {
    std::cout << "========================================" << std::endl;
    std::cout << "[STATS] Branch Statistics:" << std::endl;
    std::cout << "  Total Branches: " << g_branch_count << std::endl;
    std::cout << "  Branches Taken: " << g_branch_taken_count << std::endl;
    if (g_branch_count > 0) {
        double taken_rate = (double)g_branch_taken_count / g_branch_count * 100.0;
        std::cout << "  Taken Rate: " << std::fixed << std::setprecision(2)
                  << taken_rate << "%" << std::endl;
    }
    std::cout << "  Current PC: 0x" << std::hex << g_pc << std::endl;
    std::cout << "========================================" << std::endl;
}

// 重置执行状态
void dpi_reset_exec_state() {
    g_pc = 0x80000000;
    for (int i = 0; i < 32; i++) {
        g_regs[i] = 0;
    }
    g_branch_count = 0;
    g_branch_taken_count = 0;
    g_branch_history = 0;

    std::cout << "[RESET] Execution state reset" << std::endl;
}

// 设置寄存器值（用于测试）
void dpi_set_register(uint32_t reg_num, uint64_t value) {
    if (reg_num > 0 && reg_num < 32) {
        g_regs[reg_num] = value;
        std::cout << "[REG] x" << reg_num << " = 0x"
                  << std::hex << value << std::endl;
    }
}

// 获取寄存器值
uint64_t dpi_get_register(uint32_t reg_num) {
    if (reg_num < 32) {
        return g_regs[reg_num];
    }
    return 0;
}

} // extern "C"
