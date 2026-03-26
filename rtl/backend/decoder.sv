/**
 * 指令解码器 - 纯组合逻辑
 *
 * 当前已经实现的功能：
 * - 从 32 位指令中直接提取 rs1 / rs2 / rd 编码字段
 * - 为 RV64I 中直接走整数 ALU 的 R/I 算术指令给出 decode queue / rename 阶段最小需要的语义位：
 *   1) rs1_read_en
 *   2) rs2_read_en
 *   3) rd_write_en
 *   4) use_imm
 *   5) imm_type / imm_raw
 *   6) int_alu_op
 *   7) is_int_uop
 * - 目前输出形态固定为 `decode_out_t`，字段含义如下：
 *   1) `rs1/rs2/rd`：直接来自指令编码位段 `[19:15] / [24:20] / [11:7]`
 *   2) `rs1_read_en/rs2_read_en/rd_write_en`：当前 rename 是否真的要读源寄存器、分配目的寄存器
 *   3) `use_imm`：第二操作数是否选择立即数
 *   4) `imm_type/imm_raw`：立即数类型与原始编码；当前只有 `IMM_TYPE_I + instruction[31:20]`
 *   5) `int_alu_op`：整数 ALU 操作类型，和 `int_execute_unit` 共用同一套编码
 *   6) `is_int_uop`：当前是否先归入统一整数数据流
 * - 当前覆盖的指令如下：
 *   1) R-type：`ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND`
 *   2) I-type：`ADDI/SLLI/SLTI/SLTIU/XORI/SRLI/SRAI/ORI/ANDI`
 * - 对于已覆盖的 I-type 算术指令：
 *   1) `use_imm=1`
 *   2) `imm_type=IMM_TYPE_I`
 *   3) `imm_raw=instruction[31:20]`
 * - 对于已覆盖的 R-type 算术指令：
 *   1) `use_imm=0`
 *   2) `imm_type=IMM_TYPE_NONE`
 *   3) `imm_raw=0`
 * - 对未覆盖 opcode 或未识别的 `funct3/funct7` 组合：
 *   1) 先按保守方式不给寄存器重命名副作用
 *   2) `imm_type` 保持全 0，表示立即数无效
 *
 * 当前没有实现的功能：
 * - 不覆盖 branch / load / store / jump / system / fence
 * - 不覆盖 RV64I 的 word 指令，如 `ADDIW/ADDW/SLLIW/SLLW`
 * - 不区分 ALU / BRU / LSU / MUL / DIV 等更细执行类型
 * - 不输出 CSR / 异常 / trap / commit 相关信息
 *
 * 扩展入口：
 * - 后续若要接 issue / execute，可在 `decode_out_t` 中继续增加 branch/load/store/jump 等控制语义
 * - 后续若要支持异常、CSR、分支恢复，应在这里补齐更完整的控制语义
 * - 当前阶段故意不写测试代码和仿真代码，只先把功能骨架和注释说明补齐
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) `decode_i.instruction` 被直接拆分出 `rs1/rs2/rd/opcode`
 *   2) 根据 `opcode/funct3/funct7` 组合地产生 `read_en/write_en/use_imm/imm_type/imm_raw/int_alu_op/is_int_uop`
 *   3) `decode_o` 在同一周期对下游可见
 * - 周期 N 上升沿：
 *   1) 本模块没有内部状态，不更新任何寄存器
 *   2) 下游若在该拍锁存 `decode_o`，拿到的是本周期组合结果
 * - 周期 N+1：
 *   1) 输出继续完全由新的 `decode_i.instruction` 组合决定
 */

module decoder
    import o3_pkg::*;
#(
    parameter type decode_in_t  = o3_pkg::decode_in_t,
    parameter type decode_out_t = o3_pkg::decode_out_t
)(
    input  decode_in_t  decode_i,
    output decode_out_t decode_o
);

    localparam logic [6:0] OPCODE_OP_IMM   = 7'b0010011;
    localparam logic [6:0] OPCODE_OP       = 7'b0110011;

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    assign decode_o.rd  = decode_i.instruction[11:7];
    assign decode_o.rs1 = decode_i.instruction[19:15];
    assign decode_o.rs2 = decode_i.instruction[24:20];
    assign opcode       = decode_i.instruction[6:0];
    assign funct3       = decode_i.instruction[14:12];
    assign funct7       = decode_i.instruction[31:25];

    always_comb begin
        // 默认值采用“最保守不分配”策略。
        // 对当前未覆盖的指令，先不申请新物理寄存器，后续等完整解码器扩展时再细化。
        decode_o.rs1_read_en = 1'b0;
        decode_o.rs2_read_en = 1'b0;
        decode_o.rd_write_en = 1'b0;
        decode_o.use_imm     = 1'b0;
        decode_o.imm_type    = IMM_TYPE_NONE;
        decode_o.imm_raw     = '0;
        decode_o.int_alu_op  = INT_ALU_OP_ADD;
        decode_o.is_int_uop  = 1'b0;

        unique case (opcode)
            OPCODE_OP_IMM: begin
                unique case (funct3)
                    3'b000: decode_o.int_alu_op = INT_ALU_OP_ADD;
                    3'b001: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SLL;
                        end
                    end
                    3'b010: decode_o.int_alu_op = INT_ALU_OP_SLT;
                    3'b011: decode_o.int_alu_op = INT_ALU_OP_SLTU;
                    3'b100: decode_o.int_alu_op = INT_ALU_OP_XOR;
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRL;
                        end else if (funct7 == 7'b0100000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRA;
                        end
                    end
                    3'b110: decode_o.int_alu_op = INT_ALU_OP_OR;
                    3'b111: decode_o.int_alu_op = INT_ALU_OP_AND;
                    default: begin
                    end
                endcase

                if ((funct3 != 3'b001 && funct3 != 3'b101)
                 || (funct7 == 7'b0000000)
                 || (funct3 == 3'b101 && funct7 == 7'b0100000)) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rd_write_en = 1'b1;
                    decode_o.use_imm     = 1'b1;
                    decode_o.imm_type    = IMM_TYPE_I;
                    decode_o.imm_raw     = decode_i.instruction[31:20];
                    decode_o.is_int_uop  = 1'b1;
                end
            end

            OPCODE_OP: begin
                unique case (funct3)
                    3'b000: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_ADD;
                        end else if (funct7 == 7'b0100000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SUB;
                        end
                    end
                    3'b001: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SLL;
                        end
                    end
                    3'b010: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SLT;
                        end
                    end
                    3'b011: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SLTU;
                        end
                    end
                    3'b100: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_XOR;
                        end
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRL;
                        end else if (funct7 == 7'b0100000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRA;
                        end
                    end
                    3'b110: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_OR;
                        end
                    end
                    3'b111: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_AND;
                        end
                    end
                    default: begin
                    end
                endcase

                if ((funct3 == 3'b000 && (funct7 == 7'b0000000 || funct7 == 7'b0100000))
                 || ((funct3 == 3'b001 || funct3 == 3'b010 || funct3 == 3'b011
                   || funct3 == 3'b100 || funct3 == 3'b110 || funct3 == 3'b111)
                   && (funct7 == 7'b0000000))
                 || (funct3 == 3'b101 && (funct7 == 7'b0000000 || funct7 == 7'b0100000))) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rs2_read_en = 1'b1;
                    decode_o.rd_write_en = 1'b1;
                    decode_o.is_int_uop  = 1'b1;
                end
            end

            default: begin
                // 保持默认全 0。
            end
        endcase
    end

endmodule
