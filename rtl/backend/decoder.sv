/**
 * RV64 integer and scalar F/D decode (L9 spec section 3).
 * Produces source/destination register domains, three-source FMA, conversion control
 * and uses_arch_rm. Static reserved rm/unsupported format encodings are illegal.
 * FP memory ignores fmt bits (they belong to immediate); f0 is ordinary writable state.
 * INT destinations x0 retain their routing domain with rd_write_en=0, so FP flags
 * still complete through the INT domain. Illegal instructions carry no execution semantics.
 * Dynamic rm and FS checks occur at rename entry after serialized CSR state changes.
 * 当前实现状态：闭环简化（L10 T08a）；SRET/SFENCE 编码与源身份已接入，合法性在提交端。
 * Pure combinational decode in N; downstream queue captures only on accepted transfer.
 * Existing CSR/system serialization and M-extension decode are retained.
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
    localparam logic [6:0] OPCODE_OP_IMM_32 = 7'b0011011;
    localparam logic [6:0] OPCODE_OP_32     = 7'b0111011;
    localparam logic [6:0] OPCODE_LUI       = 7'b0110111;
    localparam logic [6:0] OPCODE_AUIPC     = 7'b0010111;
    localparam logic [6:0] OPCODE_LOAD     = 7'b0000011;
    localparam logic [6:0] OPCODE_STORE    = 7'b0100011;
    localparam logic [6:0] OPCODE_BRANCH   = 7'b1100011;
    localparam logic [6:0] OPCODE_JAL      = 7'b1101111;
    localparam logic [6:0] OPCODE_JALR     = 7'b1100111;
    localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [5:0] funct6;
    logic [6:0] funct7;

    assign decode_o.rd  = decode_i.instruction[11:7];
    assign decode_o.rs1 = decode_i.instruction[19:15];
    assign decode_o.rs2 = decode_i.instruction[24:20];
    assign opcode       = decode_i.instruction[6:0];
    assign funct3       = decode_i.instruction[14:12];
    assign funct6       = decode_i.instruction[31:26];
    assign funct7       = decode_i.instruction[31:25];

    always_comb begin
        // 默认值采用“最保守不分配”策略。
        // 对当前未覆盖的指令，先不申请新物理寄存器，后续等完整解码器扩展时再细化。
        decode_o.ext = '0;
        decode_o.rs1_read_en = 1'b0;
        decode_o.rs2_read_en = 1'b0;
        decode_o.rd_write_en = 1'b0;
        decode_o.src1_is_pc  = 1'b0;
        decode_o.use_imm     = 1'b0;
        decode_o.imm_type    = IMM_TYPE_NONE;
        decode_o.imm_raw     = '0;
        decode_o.int_alu_op  = INT_ALU_OP_ADD;
        decode_o.is_word_op  = 1'b0;
        decode_o.is_int_uop  = 1'b0;
        decode_o.is_load     = 1'b0;
        decode_o.is_store    = 1'b0;
        decode_o.mem_size    = MEM_SIZE_1B;
        decode_o.mem_unsigned = 1'b0;
        decode_o.is_branch   = 1'b0;
        decode_o.is_jal      = 1'b0;
        decode_o.is_jalr     = 1'b0;
        decode_o.branch_cond = BRANCH_COND_EQ;
        decode_o.needs_checkpoint = 1'b0;
        decode_o.illegal_instruction = 1'b1;

        unique case (opcode)
            OPCODE_LUI,
            OPCODE_AUIPC: begin
                // 两条U-type都走整数ADD：LUI使用0+imm，AUIPC使用pc+imm。
                decode_o.rd_write_en = 1'b1;
                decode_o.src1_is_pc = (opcode == OPCODE_AUIPC);
                decode_o.use_imm = 1'b1;
                decode_o.imm_type = IMM_TYPE_U;
                // 立即数容器保留真实低零位，统一扩展函数再补剩余11个零。
                decode_o.imm_raw[20:0] = {decode_i.instruction[31:12], 1'b0};
                decode_o.int_alu_op = INT_ALU_OP_ADD;
                decode_o.is_int_uop = 1'b1;
                decode_o.illegal_instruction = 1'b0;
            end

            OPCODE_OP_IMM: begin
                unique case (funct3)
                    3'b000: decode_o.int_alu_op = INT_ALU_OP_ADD;
                    3'b001: begin
                        // RV64移位立即数使用6位shamt，bit25属于shamt而不是funct字段。
                        if (funct6 == 6'b000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SLL;
                        end
                    end
                    3'b010: decode_o.int_alu_op = INT_ALU_OP_SLT;
                    3'b011: decode_o.int_alu_op = INT_ALU_OP_SLTU;
                    3'b100: decode_o.int_alu_op = INT_ALU_OP_XOR;
                    3'b101: begin
                        if (funct6 == 6'b000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRL;
                        end else if (funct6 == 6'b010000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRA;
                        end
                    end
                    3'b110: decode_o.int_alu_op = INT_ALU_OP_OR;
                    3'b111: decode_o.int_alu_op = INT_ALU_OP_AND;
                    default: begin
                    end
                endcase

                if ((funct3 != 3'b001 && funct3 != 3'b101)
                 || (funct3 == 3'b001 && funct6 == 6'b000000)
                 || (funct3 == 3'b101
                     && (funct6 == 6'b000000 || funct6 == 6'b010000))) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rd_write_en = 1'b1;
                    decode_o.use_imm     = 1'b1;
                    decode_o.imm_type    = IMM_TYPE_I;
                    decode_o.imm_raw[11:0] = decode_i.instruction[31:20];
                    decode_o.is_int_uop  = 1'b1;
                    decode_o.illegal_instruction = 1'b0;
                end
            end

            OPCODE_OP_IMM_32: begin
                unique case (funct3)
                    3'b000: begin // ADDIW
                        decode_o.int_alu_op = INT_ALU_OP_ADD;
                        decode_o.illegal_instruction = 1'b0;
                    end
                    3'b001: begin // SLLIW；RV64 word立即数移位只允许5位shamt。
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SLL;
                            decode_o.illegal_instruction = 1'b0;
                        end
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRL;
                            decode_o.illegal_instruction = 1'b0;
                        end else if (funct7 == 7'b0100000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRA;
                            decode_o.illegal_instruction = 1'b0;
                        end
                    end
                    default: begin
                    end
                endcase

                if (!decode_o.illegal_instruction) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rd_write_en = 1'b1;
                    decode_o.use_imm = 1'b1;
                    decode_o.imm_type = IMM_TYPE_I;
                    decode_o.imm_raw[11:0] = decode_i.instruction[31:20];
                    decode_o.is_int_uop = 1'b1;
                    decode_o.is_word_op = 1'b1;
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
                    decode_o.illegal_instruction = 1'b0;
                end
            end

            OPCODE_OP_32: begin
                unique case (funct3)
                    3'b000: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_ADD;
                            decode_o.illegal_instruction = 1'b0;
                        end else if (funct7 == 7'b0100000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SUB;
                            decode_o.illegal_instruction = 1'b0;
                        end
                    end
                    3'b001: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SLL;
                            decode_o.illegal_instruction = 1'b0;
                        end
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRL;
                            decode_o.illegal_instruction = 1'b0;
                        end else if (funct7 == 7'b0100000) begin
                            decode_o.int_alu_op = INT_ALU_OP_SRA;
                            decode_o.illegal_instruction = 1'b0;
                        end
                    end
                    default: begin
                    end
                endcase

                if (!decode_o.illegal_instruction) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rs2_read_en = 1'b1;
                    decode_o.rd_write_en = 1'b1;
                    decode_o.is_int_uop = 1'b1;
                    decode_o.is_word_op = 1'b1;
                end
            end

            // 当前只生成 Rename/LSQ 所需的分类和寄存器副作用。
            // 地址生成、尺寸/符号扩展和真正访存语义留在 LSU 阶段。
            OPCODE_LOAD: begin
                if (funct3 != 3'b111) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rd_write_en = 1'b1;
                    decode_o.use_imm     = 1'b1;
                    decode_o.imm_type    = IMM_TYPE_I;
                    decode_o.imm_raw[11:0] = decode_i.instruction[31:20];
                    decode_o.is_load     = 1'b1;
                    unique case (funct3)
                        3'b000, 3'b100: decode_o.mem_size = MEM_SIZE_1B;
                        3'b001, 3'b101: decode_o.mem_size = MEM_SIZE_2B;
                        3'b010, 3'b110: decode_o.mem_size = MEM_SIZE_4B;
                        3'b011:         decode_o.mem_size = MEM_SIZE_8B;
                        default:        decode_o.mem_size = MEM_SIZE_1B;
                    endcase
                    decode_o.mem_unsigned = funct3[2];
                    decode_o.illegal_instruction = 1'b0;
                end
            end

            OPCODE_STORE: begin
                if (funct3 inside {3'b000, 3'b001, 3'b010, 3'b011}) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rs2_read_en = 1'b1;
                    decode_o.use_imm     = 1'b1;
                    decode_o.imm_type    = IMM_TYPE_S;
                    decode_o.imm_raw[11:0] = {decode_i.instruction[31:25], decode_i.instruction[11:7]};
                    decode_o.is_store    = 1'b1;
                    decode_o.mem_size    = mem_size_t'(funct3[1:0]);
                    decode_o.illegal_instruction = 1'b0;
                end
            end

            OPCODE_BRANCH: begin
                if (funct3 inside {3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111}) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rs2_read_en = 1'b1;
                    decode_o.use_imm     = 1'b1;
                    decode_o.imm_type    = IMM_TYPE_B;
                    decode_o.imm_raw[12:0] = {decode_i.instruction[31], decode_i.instruction[7],
                                              decode_i.instruction[30:25], decode_i.instruction[11:8], 1'b0};
                    decode_o.is_branch   = 1'b1;
                    decode_o.branch_cond = branch_cond_t'(funct3);
                    decode_o.needs_checkpoint = 1'b1;
                    decode_o.illegal_instruction = 1'b0;
                end
            end

            OPCODE_JAL: begin
                decode_o.rd_write_en = 1'b1;
                decode_o.use_imm     = 1'b1;
                decode_o.imm_type    = IMM_TYPE_J;
                decode_o.imm_raw[20:0] = {decode_i.instruction[31], decode_i.instruction[19:12],
                                           decode_i.instruction[20], decode_i.instruction[30:21], 1'b0};
                decode_o.is_jal      = 1'b1;
                decode_o.needs_checkpoint = 1'b1;
                decode_o.illegal_instruction = 1'b0;
            end

            OPCODE_JALR: begin
                if (funct3 == 3'b000) begin
                    decode_o.rs1_read_en = 1'b1;
                    decode_o.rd_write_en = 1'b1;
                    decode_o.use_imm     = 1'b1;
                    decode_o.imm_type    = IMM_TYPE_I;
                    decode_o.imm_raw[11:0] = decode_i.instruction[31:20];
                    decode_o.is_jalr     = 1'b1;
                    decode_o.needs_checkpoint = 1'b1;
                    decode_o.illegal_instruction = 1'b0;
                end
            end

            7'h07, 7'h27: begin // FLW/FLD/FSW/FSD; fmt bits belong to immediate here.
                if (funct3 inside {3'b010,3'b011}) begin
                    decode_o.illegal_instruction=0;
                    decode_o.rs1_read_en=1;
                    decode_o.ext.rs1_dom=o3_types_pkg::RD_INT;
                    decode_o.ext.fu_class=o3_types_pkg::FU_LDST;
                    decode_o.mem_size=funct3==3 ? MEM_SIZE_8B : MEM_SIZE_4B;
                    decode_o.use_imm=1;
                    if (opcode==7'h07) begin
                        decode_o.is_load=1; decode_o.rd_write_en=1;
                        decode_o.ext.rd_dom=o3_types_pkg::RD_FP;
                        decode_o.imm_type=IMM_TYPE_I;
                        decode_o.imm_raw[11:0]=decode_i.instruction[31:20];
                    end else begin
                        decode_o.is_store=1; decode_o.rs2_read_en=1;
                        decode_o.ext.rs2_dom=o3_types_pkg::RD_FP;
                        decode_o.imm_type=IMM_TYPE_S;
                        decode_o.imm_raw[11:0]={decode_i.instruction[31:25],decode_i.instruction[11:7]};
                    end
                end
            end
            7'h43,7'h47,7'h4b,7'h4f,7'h53: begin
                decode_o.ext.fp_fmt=o3_types_pkg::fp_fmt_e'(decode_i.instruction[25]);
                decode_o.ext.fp_src_fmt=decode_o.ext.fp_fmt;
                decode_o.ext.rm=funct3;
                decode_o.ext.rd_dom=o3_types_pkg::RD_FP;
                decode_o.ext.rs1_dom=o3_types_pkg::RD_FP;
                decode_o.ext.rs2_dom=o3_types_pkg::RD_FP;
                decode_o.rs1_read_en=1; decode_o.rs2_read_en=1; decode_o.rd_write_en=1;
                decode_o.ext.uses_arch_rm=1;
                if (decode_i.instruction[26:25] inside {2'b00,2'b01}) begin
                    if (opcode!=7'h53) begin
                        decode_o.illegal_instruction=0;
                        decode_o.ext.fu_class=o3_types_pkg::FU_FMA;
                        decode_o.ext.rs3=decode_i.instruction[31:27];
                        decode_o.ext.rs3_dom=o3_types_pkg::RD_FP;
                        decode_o.ext.rs3_read_en=1;
                        case (opcode)
                            7'h43: decode_o.ext.fp_op=o3_types_pkg::FOP_MADD;
                            7'h47: decode_o.ext.fp_op=o3_types_pkg::FOP_MSUB;
                            7'h4b: decode_o.ext.fp_op=o3_types_pkg::FOP_NMSUB;
                            7'h4f: decode_o.ext.fp_op=o3_types_pkg::FOP_NMADD;
                            default: ;
                        endcase
                    end else begin
                        case (decode_i.instruction[31:27])
                            5'b00000,5'b00001,5'b00010: begin
                                decode_o.illegal_instruction=0;
                                decode_o.ext.fu_class=o3_types_pkg::FU_FMA;
                                case (decode_i.instruction[31:27])
                                    0: decode_o.ext.fp_op=o3_types_pkg::FOP_ADD;
                                    1: decode_o.ext.fp_op=o3_types_pkg::FOP_SUB;
                                    2: decode_o.ext.fp_op=o3_types_pkg::FOP_MUL;
                                    default: ;
                                endcase
                            end
                            5'b00011: begin
                                decode_o.illegal_instruction=0;
                                decode_o.ext.fu_class=o3_types_pkg::FU_FDIVSQRT;
                                decode_o.ext.fp_op=o3_types_pkg::FOP_DIV;
                            end
                            5'b01011: if (decode_o.rs2==0) begin
                                decode_o.illegal_instruction=0; decode_o.rs2_read_en=0;
                                decode_o.ext.fu_class=o3_types_pkg::FU_FDIVSQRT;
                                decode_o.ext.fp_op=o3_types_pkg::FOP_SQRT;
                            end
                            5'b00100: if (funct3<=2) begin
                                decode_o.illegal_instruction=0; decode_o.ext.uses_arch_rm=0;
                                decode_o.ext.fu_class=o3_types_pkg::FU_FMISC;
                                case (funct3)
                                    0: decode_o.ext.fp_op=o3_types_pkg::FOP_SGNJ;
                                    1: decode_o.ext.fp_op=o3_types_pkg::FOP_SGNJN;
                                    2: decode_o.ext.fp_op=o3_types_pkg::FOP_SGNJX;
                                    default: ;
                                endcase
                            end
                            5'b00101: if (funct3<=1) begin
                                decode_o.illegal_instruction=0; decode_o.ext.uses_arch_rm=0;
                                decode_o.ext.fu_class=o3_types_pkg::FU_FMISC;
                                decode_o.ext.fp_op=funct3==0 ? o3_types_pkg::FOP_MIN:o3_types_pkg::FOP_MAX;
                            end
                            5'b10100: if (funct3<=2) begin
                                decode_o.illegal_instruction=0; decode_o.ext.uses_arch_rm=0;
                                decode_o.ext.rd_dom=o3_types_pkg::RD_INT;
                                decode_o.ext.fu_class=o3_types_pkg::FU_FMISC;
                                case (funct3)
                                    0: decode_o.ext.fp_op=o3_types_pkg::FOP_LE;
                                    1: decode_o.ext.fp_op=o3_types_pkg::FOP_LT;
                                    2: decode_o.ext.fp_op=o3_types_pkg::FOP_EQ;
                                    default: ;
                                endcase
                            end
                            5'b01000: if (decode_o.rs2<=1 && decode_o.rs2[0]!=decode_i.instruction[25]) begin
                                decode_o.illegal_instruction=0; decode_o.rs2_read_en=0;
                                decode_o.ext.fp_src_fmt=o3_types_pkg::fp_fmt_e'(decode_o.rs2[0]);
                                decode_o.ext.fu_class=o3_types_pkg::FU_FCONV;
                                decode_o.ext.fp_op=o3_types_pkg::FOP_CVT_F2F;
                            end
                            5'b11000,5'b11010: if (decode_o.rs2<=3) begin
                                decode_o.illegal_instruction=0; decode_o.rs2_read_en=0;
                                decode_o.ext.fu_class=o3_types_pkg::FU_FCONV;
                                decode_o.ext.fp_int_fmt=o3_types_pkg::fp_int_fmt_e'(decode_o.rs2[1]);
                                decode_o.ext.fp_unsigned=decode_o.rs2[0];
                                if (decode_i.instruction[28]) begin
                                    decode_o.ext.fp_op=o3_types_pkg::FOP_CVT_I2F;
                                    decode_o.ext.rs1_dom=o3_types_pkg::RD_INT;
                                end else begin
                                    decode_o.ext.fp_op=o3_types_pkg::FOP_CVT_F2I;
                                    decode_o.ext.rd_dom=o3_types_pkg::RD_INT;
                                end
                            end
                            5'b11100: if (decode_o.rs2==0 && funct3<=1) begin
                                decode_o.illegal_instruction=0; decode_o.rs2_read_en=0;
                                decode_o.ext.uses_arch_rm=0; decode_o.ext.rd_dom=o3_types_pkg::RD_INT;
                                decode_o.ext.fu_class=funct3==1 ? o3_types_pkg::FU_FMISC:o3_types_pkg::FU_FCONV;
                                decode_o.ext.fp_op=funct3==1 ? o3_types_pkg::FOP_CLASS:o3_types_pkg::FOP_MV_F2X;
                            end
                            5'b11110: if (decode_o.rs2==0 && funct3==0) begin
                                decode_o.illegal_instruction=0; decode_o.rs2_read_en=0;
                                decode_o.ext.uses_arch_rm=0; decode_o.ext.rs1_dom=o3_types_pkg::RD_INT;
                                decode_o.ext.fu_class=o3_types_pkg::FU_FCONV;
                                decode_o.ext.fp_op=o3_types_pkg::FOP_MV_X2F;
                            end
                            default: ;
                        endcase
                    end
                end
                if (decode_o.ext.uses_arch_rm && (funct3 inside {3'd5,3'd6}))
                    decode_o.illegal_instruction=1;
            end

            OPCODE_MISC_MEM: begin
                if (funct3==0 || funct3==1) begin
                    decode_o.ext.sys_op = funct3==0 ? o3_types_pkg::SYSOP_FENCE : o3_types_pkg::SYSOP_FENCE_I;
                    decode_o.ext.fence_pred = decode_i.instruction[27:24];
                    decode_o.ext.fence_succ = decode_i.instruction[23:20];
                    decode_o.ext.serialize = 1'b1;
                    decode_o.ext.block_younger = 1'b1;
                    decode_o.illegal_instruction = 1'b0;
                end
            end
            7'h73: begin
                if (funct3!=0 && funct3!=4) begin
                    decode_o.ext.csr_op = o3_types_pkg::csr_op_e'(funct3[1:0]);
                    decode_o.ext.csr_use_imm = funct3[2];
                    decode_o.ext.csr_addr = decode_i.instruction[31:20];
                    decode_o.ext.fu_class = o3_types_pkg::FU_CSR;
                    decode_o.rs1_read_en = !funct3[2];
                    decode_o.rd_write_en = 1'b1;
                    decode_o.illegal_instruction = 1'b0;
                end else if (funct3==0) begin
                    case (decode_i.instruction)
                        32'h00000073: begin decode_o.ext.sys_op=o3_types_pkg::SYSOP_ECALL; decode_o.illegal_instruction=0; end
                        32'h00100073: begin decode_o.ext.sys_op=o3_types_pkg::SYSOP_EBREAK; decode_o.illegal_instruction=0; end
                        32'h10200073: begin decode_o.ext.sys_op=o3_types_pkg::SYSOP_SRET; decode_o.illegal_instruction=0; end
                        32'h30200073: begin decode_o.ext.sys_op=o3_types_pkg::SYSOP_MRET; decode_o.illegal_instruction=0; end
                        32'h10500073: begin decode_o.ext.sys_op=o3_types_pkg::SYSOP_WFI; decode_o.illegal_instruction=0; end
                        default: ;
                    endcase
                    if (funct7==7'b0001001 && decode_i.instruction[11:7]==0) begin
                        decode_o.ext.sys_op=o3_types_pkg::SYSOP_SFENCE_VMA;
                        decode_o.ext.sfence_rs1_x0=decode_i.instruction[19:15]==0;
                        decode_o.ext.sfence_rs2_x0=decode_i.instruction[24:20]==0;
                        decode_o.rs1_read_en=1;decode_o.rs2_read_en=1;
                        decode_o.illegal_instruction=0;
                    end
                end
                if (!decode_o.illegal_instruction) begin
                    decode_o.ext.serialize=1; decode_o.ext.block_younger=1;
                end
            end

            default: begin
                // 保持默认全 0。
            end
        endcase
        // L6 M overrides only funct7=1; reserved OP-32 high-multiply encodings stay illegal.
        if ((opcode==OPCODE_OP || opcode==OPCODE_OP_32) && funct7==7'b0000001 &&
            (opcode==OPCODE_OP || funct3==0 || funct3>=4)) begin
            decode_o.illegal_instruction=0;decode_o.rs1_read_en=1;decode_o.rs2_read_en=1;
            decode_o.rd_write_en=1;decode_o.is_int_uop=1;decode_o.is_word_op=opcode==OPCODE_OP_32;
            decode_o.ext.fu_class=funct3<4 ? o3_types_pkg::FU_MUL:o3_types_pkg::FU_DIV;
            if(opcode==OPCODE_OP_32) case(funct3)
                0: decode_o.ext.mdu_op=o3_types_pkg::MDU_MULW;
                4: decode_o.ext.mdu_op=o3_types_pkg::MDU_DIVW;
                5: decode_o.ext.mdu_op=o3_types_pkg::MDU_DIVUW;
                6: decode_o.ext.mdu_op=o3_types_pkg::MDU_REMW;
                7: decode_o.ext.mdu_op=o3_types_pkg::MDU_REMUW;
                default: ;
            endcase
            else case(funct3)
                0: decode_o.ext.mdu_op=o3_types_pkg::MDU_MUL;
                1: decode_o.ext.mdu_op=o3_types_pkg::MDU_MULH;
                2: decode_o.ext.mdu_op=o3_types_pkg::MDU_MULHSU;
                3: decode_o.ext.mdu_op=o3_types_pkg::MDU_MULHU;
                4: decode_o.ext.mdu_op=o3_types_pkg::MDU_DIV;
                5: decode_o.ext.mdu_op=o3_types_pkg::MDU_DIVU;
                6: decode_o.ext.mdu_op=o3_types_pkg::MDU_REM;
                7: decode_o.ext.mdu_op=o3_types_pkg::MDU_REMU;
                default: ;
            endcase
        end
        // Every source is domain qualified. INT destination x0 keeps its routing domain
        // for FP flags/completion, but never allocates a physical register.
        if (!decode_o.illegal_instruction) begin
            if (decode_o.rs1_read_en && decode_o.ext.rs1_dom==o3_types_pkg::RD_NONE)
                decode_o.ext.rs1_dom=o3_types_pkg::RD_INT;
            if (decode_o.rs2_read_en && decode_o.ext.rs2_dom==o3_types_pkg::RD_NONE)
                decode_o.ext.rs2_dom=o3_types_pkg::RD_INT;
            if (decode_o.rd_write_en && decode_o.ext.rd_dom==o3_types_pkg::RD_NONE)
                decode_o.ext.rd_dom=o3_types_pkg::RD_INT;
            if (!decode_o.rs1_read_en) decode_o.ext.rs1_dom=o3_types_pkg::RD_NONE;
            if (!decode_o.rs2_read_en) decode_o.ext.rs2_dom=o3_types_pkg::RD_NONE;
            if (decode_o.ext.rd_dom==o3_types_pkg::RD_INT && decode_o.rd==0)
                decode_o.rd_write_en=0;
        end else begin
            decode_o.rs1_read_en=0; decode_o.rs2_read_en=0; decode_o.rd_write_en=0;
            decode_o.is_int_uop=0; decode_o.is_load=0; decode_o.is_store=0;
            decode_o.is_branch=0; decode_o.is_jal=0; decode_o.is_jalr=0; decode_o.needs_checkpoint=0;
            decode_o.ext='0;
        end
    end

endmodule
