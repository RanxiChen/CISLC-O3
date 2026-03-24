/**
 * 指令解码器 - 纯组合逻辑
 *
 * 当前已经实现的功能：
 * - 从 32 位指令中直接提取 rs1 / rs2 / rd 编码字段
 * - 为基础 RVI 指令给出 rename 阶段最小需要的语义位：
 *   1) rs1_read_en
 *   2) rs2_read_en
 *   3) rd_write_en
 *
 * 当前没有实现的功能：
 * - 不输出立即数
 * - 不输出功能单元类型
 * - 不输出 CSR / 异常 / trap / commit 相关信息
 * - 对 SYSTEM 指令先按保守方式处理，不把 CSR 写回纳入本版 rename
 *
 * 时序行为：
 * - 本模块完全是组合逻辑，没有内部状态
 * - 周期 N 内 decode_i.instruction 变化后，decode_o 在同一周期组合更新
 * - 下游若在周期 N 的上升沿使用 decode_o，就是消费该周期的组合解码结果
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

    localparam logic [6:0] OPCODE_LUI      = 7'b0110111;
    localparam logic [6:0] OPCODE_AUIPC    = 7'b0010111;
    localparam logic [6:0] OPCODE_JAL      = 7'b1101111;
    localparam logic [6:0] OPCODE_JALR     = 7'b1100111;
    localparam logic [6:0] OPCODE_BRANCH   = 7'b1100011;
    localparam logic [6:0] OPCODE_LOAD     = 7'b0000011;
    localparam logic [6:0] OPCODE_STORE    = 7'b0100011;
    localparam logic [6:0] OPCODE_OP_IMM   = 7'b0010011;
    localparam logic [6:0] OPCODE_OP       = 7'b0110011;
    localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;
    localparam logic [6:0] OPCODE_SYSTEM   = 7'b1110011;

    logic [6:0] opcode;

    assign decode_o.rd  = decode_i.instruction[11:7];
    assign decode_o.rs1 = decode_i.instruction[19:15];
    assign decode_o.rs2 = decode_i.instruction[24:20];
    assign opcode       = decode_i.instruction[6:0];

    always_comb begin
        // 默认值采用“最保守不分配”策略。
        // 对未知指令，先不申请新物理寄存器，后续等完整解码器扩展时再细化。
        decode_o.rs1_read_en = 1'b0;
        decode_o.rs2_read_en = 1'b0;
        decode_o.rd_write_en = 1'b0;

        unique case (opcode)
            OPCODE_LUI: begin
                decode_o.rd_write_en = 1'b1;
            end

            OPCODE_AUIPC: begin
                decode_o.rd_write_en = 1'b1;
            end

            OPCODE_JAL: begin
                decode_o.rd_write_en = 1'b1;
            end

            OPCODE_JALR: begin
                decode_o.rs1_read_en = 1'b1;
                decode_o.rd_write_en = 1'b1;
            end

            OPCODE_BRANCH: begin
                decode_o.rs1_read_en = 1'b1;
                decode_o.rs2_read_en = 1'b1;
            end

            OPCODE_LOAD: begin
                decode_o.rs1_read_en = 1'b1;
                decode_o.rd_write_en = 1'b1;
            end

            OPCODE_STORE: begin
                decode_o.rs1_read_en = 1'b1;
                decode_o.rs2_read_en = 1'b1;
            end

            OPCODE_OP_IMM: begin
                decode_o.rs1_read_en = 1'b1;
                decode_o.rd_write_en = 1'b1;
            end

            OPCODE_OP: begin
                decode_o.rs1_read_en = 1'b1;
                decode_o.rs2_read_en = 1'b1;
                decode_o.rd_write_en = 1'b1;
            end

            OPCODE_MISC_MEM: begin
                // FENCE / FENCE.I 目前不触发寄存器重命名更新。
            end

            OPCODE_SYSTEM: begin
                // 当前阶段先按保守方式处理 SYSTEM。
                // 这样可以避免 CSR 类指令在 rename 尚未配套完成时误分配物理寄存器。
            end

            default: begin
                // 保持默认全 0。
            end
        endcase
    end

endmodule
