/**
 * 除法执行单元
 *
 * 当前已经实现的功能：
 * - 提供 RV64M 除法与取余类指令的独立执行单元
 * - 采用“请求进入时直接计算商/余数 + 固定拍数后返回”的简化多拍骨架
 * - 支持 DIV / DIVU / REM / REMU / DIVW / DIVUW / REMW / REMUW
 * - 直接在模块内部处理 RISC-V 规定的除零与有符号溢出语义
 *
 * 当前没有实现的功能：
 * - 不做工业级迭代除法器、SRT、restoring 或 non-restoring 结构
 * - 不做商余融合，不做多请求并发，不做取消、flush、replay
 * - 不提供早停、变长时延或流水化接收能力
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 未来扩展入口：
 * - 后续可以在不改变外部握手的前提下，把内部 "/" "%" 替换为更真实的多拍除法器
 * - 后续可在请求侧追加 DIV/REM 融合所需的配对提示
 * - 后续可改成更复杂的可取消或可流水结构，但应保持默认节拍契约兼容
 *
 * 输入输出语义：
 * - `req_valid_i`
 *   1) 表示当前这一拍请求端是否真的送来了一条除法/取余请求
 *   2) 只有当 `req_valid_i=1 && req_ready_o=1` 时，这条请求才会在本拍上升沿被接受
 * - `req_ready_o`
 *   1) 表示当前单元是否可以接受新的请求
 *   2) 当前实现下，只有 `busy_q=0` 时为 1
 *   3) 因而当前只支持一条除法/取余请求在飞
 * - `op_i`
 *   1) 指定本次请求究竟是求商还是求余，以及是有符号、无符号还是 word 变体
 *   2) 当前支持 `DIV/DIVU/REM/REMU/DIVW/DIVUW/REMW/REMUW`
 *   3) 若给到未定义编码，则锁存结果为 0
 * - `src1_value_i/src2_value_i`
 *   1) 两个输入操作数，分别对应被除数和除数
 *   2) 仅在请求握手成功的那一拍被采样
 *   3) 握手之后输入继续变化，不会影响当前在飞请求
 * - `is_word_op_i`
 *   1) 表示最终结果是否还要按 word 语义统一收敛
 *   2) 对 `DIVW/DIVUW/REMW/REMUW` 来说，这个信号通常应为 1
 *   3) 当前模块会在 case 里先生成对应操作结果，再在 `is_word_op_i=1` 时统一做低 32 位截断并符号扩展
 * - `busy_o`
 *   1) 表示当前单元内部已有一条尚未完成的除法/取余请求
 *   2) `busy_o=1` 期间，`req_ready_o=0`
 * - `resp_valid_o`
 *   1) 表示本拍 `result_o` 是一条刚刚完成的请求结果
 *   2) 当前只保持 1 拍
 *   3) 只有 `resp_valid_o=1` 时，下游才应消费 `result_o`
 * - `result_o`
 *   1) 已完成请求的商或余数结果
 *   2) 当 `resp_valid_o=0` 时，`result_o` 只是上一次锁存值，不代表新的完成结果
 *
 * 计算规则：
 * - 请求握手成功时，本模块立即按 `op_i` 和输入操作数计算 `next_result`，并锁存到 `result_q`。
 * - 对 64 位 `DIV/REM`：
 *   1) 除数为 0 时，商返回全 1，余数返回被除数
 *   2) 有符号溢出（最小负数除以 -1）时，商返回被除数本身，余数返回 0
 *   3) 其他情况直接使用 `/` 与 `%` 计算
 * - 对 32 位 `DIVW/REMW`：
 *   1) 先只看输入低 32 位
 *   2) 再按 RISC-V 规则生成 32 位商/余数
 *   3) 最终把 bit[31] 符号扩展回 DATA_WIDTH
 * - 握手完成后，单元不再重新计算，只等待固定 `DIV_LATENCY` 拍后把锁存结果送出
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 当 busy_q=0 时，req_ready_o=1，可接受新的除法请求
 *   2) 输出 busy_o 反映当前单元是否仍有未完成请求
 * - 周期 N 上升沿：
 *   1) 若 req_valid_i && req_ready_o，则锁存 op/src1/src2/is_word_op 与预计算结果
 *   2) 同时装载剩余拍数计数器，进入 busy 状态
 *   3) 若单元处于 busy，则每拍递减剩余拍数
 *   4) 当剩余拍数走到完成条件时，拉起 resp_valid_q 并清 busy_q
 * - 周期 N+1：
 *   1) 对外看到更新后的 busy_o、resp_valid_o、result_o
 *   2) resp_valid_o 只保持 1 拍，随后单元重新回到可接收状态
 */

module div_execute_unit
    import o3_pkg::*;
#(
    parameter int DATA_WIDTH  = XLEN,
    parameter int OP_WIDTH    = 3,
    parameter int DIV_LATENCY = 16
) (
    input  logic                  clk,           // 时钟；请求接收、busy 计数与结果完成都在上升沿更新。
    input  logic                  rst,           // 复位；清空 busy、响应有效和锁存结果。
    input  logic                  req_valid_i,   // 请求端本拍是否送来一条有效除法/取余操作。
    output logic                  req_ready_o,   // 单元本拍是否可接收请求；当前仅在 busy_o=0 时为 1。
    input  logic [OP_WIDTH-1:0]   op_i,          // 除法/取余操作类型；仅在 req_valid_i && req_ready_o 时被锁存。
    input  logic [DATA_WIDTH-1:0] src1_value_i,  // 被除数；仅在请求握手成功时采样。
    input  logic [DATA_WIDTH-1:0] src2_value_i,  // 除数；仅在请求握手成功时采样。
    input  logic                  is_word_op_i,  // 是否按 word 语义收敛结果；仅在请求握手成功时采样。
    output logic                  resp_valid_o,  // 完成端有效；为 1 的这一拍表示 result_o 可被消费。
    output logic [DATA_WIDTH-1:0] result_o,      // 已完成请求的商或余数；仅在 resp_valid_o=1 时代表新的完成值。
    output logic                  busy_o         // 单元是否有请求在飞；为 1 时不接受新请求。
);

    localparam logic [OP_WIDTH-1:0] DIV_OP_DIV  = 3'd0;
    localparam logic [OP_WIDTH-1:0] DIV_OP_DIVU = 3'd1;
    localparam logic [OP_WIDTH-1:0] DIV_OP_REM  = 3'd2;
    localparam logic [OP_WIDTH-1:0] DIV_OP_REMU = 3'd3;
    localparam logic [OP_WIDTH-1:0] DIV_OP_DIVW = 3'd4;
    localparam logic [OP_WIDTH-1:0] DIV_OP_DIVUW = 3'd5;
    localparam logic [OP_WIDTH-1:0] DIV_OP_REMW = 3'd6;
    localparam logic [OP_WIDTH-1:0] DIV_OP_REMUW = 3'd7;

    // op 编码约定：
    // - DIV_OP_DIV / DIVU : 输出商
    // - DIV_OP_REM / REMU : 输出余数
    // - DIV_OP_DIVW / DIVUW / REMW / REMUW : 先按 32 位语义计算，再符号扩展到 DATA_WIDTH

    localparam int COUNT_WIDTH = (DIV_LATENCY > 1) ? $clog2(DIV_LATENCY + 1) : 1;

    logic [COUNT_WIDTH-1:0] remaining_cycles_q;
    logic                   busy_q;
    logic                   resp_valid_q;
    logic [DATA_WIDTH-1:0]  result_q;

    logic req_fire;
    logic [DATA_WIDTH-1:0] next_result;
    logic signed [DATA_WIDTH-1:0] signed_src1;
    logic signed [DATA_WIDTH-1:0] signed_src2;
    logic signed [31:0] signed_src1_w;
    logic signed [31:0] signed_src2_w;
    logic [31:0] unsigned_src1_w;
    logic [31:0] unsigned_src2_w;

    assign signed_src1   = signed'(src1_value_i);
    assign signed_src2   = signed'(src2_value_i);
    assign signed_src1_w = signed'(src1_value_i[31:0]);
    assign signed_src2_w = signed'(src2_value_i[31:0]);
    assign unsigned_src1_w = src1_value_i[31:0];
    assign unsigned_src2_w = src2_value_i[31:0];

    assign req_ready_o  = !busy_q;
    assign busy_o       = busy_q;
    assign resp_valid_o = resp_valid_q;
    assign result_o     = result_q;
    assign req_fire     = req_valid_i && req_ready_o;

    always_comb begin
        logic signed [DATA_WIDTH-1:0] signed_div_q;
        logic signed [DATA_WIDTH-1:0] signed_rem_q;
        logic [DATA_WIDTH-1:0]        unsigned_div_q;
        logic [DATA_WIDTH-1:0]        unsigned_rem_q;
        logic signed [31:0]           signed_div_w_q;
        logic signed [31:0]           signed_rem_w_q;
        logic [31:0]                  unsigned_div_w_q;
        logic [31:0]                  unsigned_rem_w_q;

        signed_div_q   = '0;
        signed_rem_q   = '0;
        unsigned_div_q = '0;
        unsigned_rem_q = '0;
        signed_div_w_q = '0;
        signed_rem_w_q = '0;
        unsigned_div_w_q = '0;
        unsigned_rem_w_q = '0;
        next_result    = '0;

        if (src2_value_i == DATA_WIDTH'(0)) begin
            signed_div_q   = '1;
            unsigned_div_q = '1;
            signed_rem_q   = signed_src1;
            unsigned_rem_q = src1_value_i;
        end else if ((signed_src1 == {1'b1, {(DATA_WIDTH-1){1'b0}}}) && (signed_src2 == DATA_WIDTH'(-1))) begin
            signed_div_q = signed_src1;
            signed_rem_q = '0;
        end else begin
            signed_div_q   = signed_src1 / signed_src2;
            signed_rem_q   = signed_src1 % signed_src2;
            unsigned_div_q = src1_value_i / src2_value_i;
            unsigned_rem_q = src1_value_i % src2_value_i;
        end

        if (unsigned_src2_w == 32'd0) begin
            signed_div_w_q   = -32'sd1;
            unsigned_div_w_q = 32'hFFFF_FFFF;
            signed_rem_w_q   = signed_src1_w;
            unsigned_rem_w_q = unsigned_src1_w;
        end else if ((signed_src1_w == 32'h8000_0000) && (signed_src2_w == -32'sd1)) begin
            signed_div_w_q = signed_src1_w;
            signed_rem_w_q = 32'sd0;
        end else begin
            signed_div_w_q   = signed_src1_w / signed_src2_w;
            signed_rem_w_q   = signed_src1_w % signed_src2_w;
            unsigned_div_w_q = unsigned_src1_w / unsigned_src2_w;
            unsigned_rem_w_q = unsigned_src1_w % unsigned_src2_w;
        end

        unique case (op_i)
            DIV_OP_DIV: begin
                next_result = DATA_WIDTH'(signed_div_q);
            end

            DIV_OP_DIVU: begin
                next_result = unsigned_div_q;
            end

            DIV_OP_REM: begin
                next_result = DATA_WIDTH'(signed_rem_q);
            end

            DIV_OP_REMU: begin
                next_result = unsigned_rem_q;
            end

            DIV_OP_DIVW: begin
                next_result = {{(DATA_WIDTH-32){signed_div_w_q[31]}}, signed_div_w_q};
            end

            DIV_OP_DIVUW: begin
                next_result = {{(DATA_WIDTH-32){unsigned_div_w_q[31]}}, unsigned_div_w_q};
            end

            DIV_OP_REMW: begin
                next_result = {{(DATA_WIDTH-32){signed_rem_w_q[31]}}, signed_rem_w_q};
            end

            DIV_OP_REMUW: begin
                next_result = {{(DATA_WIDTH-32){unsigned_rem_w_q[31]}}, unsigned_rem_w_q};
            end

            default: begin
                next_result = '0;
            end
        endcase

        if (is_word_op_i) begin
            next_result = {{(DATA_WIDTH-32){next_result[31]}}, next_result[31:0]};
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            remaining_cycles_q <= '0;
            busy_q             <= 1'b0;
            resp_valid_q       <= 1'b0;
            result_q           <= '0;
        end else begin
            resp_valid_q <= 1'b0;

            if (req_fire) begin
                busy_q             <= 1'b1;
                result_q           <= next_result;
                remaining_cycles_q <= COUNT_WIDTH'(DIV_LATENCY);
            end else if (busy_q) begin
                if (remaining_cycles_q > COUNT_WIDTH'(1)) begin
                    remaining_cycles_q <= remaining_cycles_q - COUNT_WIDTH'(1);
                end else begin
                    remaining_cycles_q <= '0;
                    busy_q             <= 1'b0;
                    resp_valid_q       <= 1'b1;
                end
            end
        end
    end

    initial begin
        if (DIV_LATENCY <= 0) begin
            $error("div_execute_unit requires DIV_LATENCY > 0");
        end
    end

endmodule
