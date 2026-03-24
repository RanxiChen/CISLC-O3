/**
 * 乘法执行单元
 *
 * 当前已经实现的功能：
 * - 提供 RV64M 乘法类指令的独立执行单元
 * - 采用“请求进入时直接计算结果 + 固定拍数后返回”的简化多拍骨架
 * - 支持 MUL / MULH / MULHSU / MULHU / MULW
 * - 保持 req_valid/req_ready 与 resp_valid/busy 的基础时序契约
 *
 * 当前没有实现的功能：
 * - 不做工业级乘法器微结构，不做 Booth、华莱士树、深流水或资源复用优化
 * - 不做双指令融合，不做高低位共享结果缓存
 * - 不支持多请求并发在飞，不支持取消、flush、replay
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 未来扩展入口：
 * - 后续可以在不改变外部握手的前提下，将内部 "*" 替换成 DSP/原语/华莱士树实现
 * - 后续可以在请求侧增加相邻 M 指令配对信息，扩展成融合路径
 * - 后续可改成更深流水，但应保持默认拍数语义与外部接口兼容
 *
 * 输入输出语义：
 * - `req_valid_i`
 *   1) 表示当前这一拍请求端是否真的送来了一条乘法类操作
 *   2) 只有当 `req_valid_i=1 && req_ready_o=1` 时，这条请求才会在本拍上升沿被单元接受
 * - `req_ready_o`
 *   1) 表示当前单元是否能接受新的乘法请求
 *   2) 当前实现下，只有 `busy_q=0` 时才为 1
 *   3) 也就是说，当前单元同一时间只允许一条乘法请求在飞
 * - `op_i`
 *   1) 指定本次乘法请求的具体类型
 *   2) 当前支持 `MUL/MULH/MULHSU/MULHU/MULW`
 *   3) 若给到未定义编码，则锁存结果为 0
 * - `src1_value_i/src2_value_i`
 *   1) 两个乘法源操作数
 *   2) 仅在请求握手成功的那一拍被本模块采样
 *   3) 握手之后，即使输入继续变化，也不会影响已经在飞的这条乘法请求
 * - `is_word_op_i`
 *   1) 表示当前请求是否应按 32 位 word 语义收敛结果
 *   2) 当前 `MULW` 一定会走 word 语义
 *   3) 若上层把其它乘法操作也配合 `is_word_op_i=1` 送进来，本模块会在最终输出前统一做低 32 位截断并符号扩展
 * - `busy_o`
 *   1) 表示当前单元内部已有一条尚未完成的请求
 *   2) `busy_o=1` 期间，`req_ready_o=0`
 * - `resp_valid_o`
 *   1) 表示本拍 `result_o` 是一条刚刚完成的乘法结果
 *   2) 当前只保持 1 拍
 *   3) 只有 `resp_valid_o=1` 的这一拍，下游才应消费 `result_o`
 * - `result_o`
 *   1) 当前在飞请求完成后的乘法结果
 *   2) 当 `resp_valid_o=0` 时，`result_o` 只是上一次锁存值，不应被下游当作新的完成结果
 *
 * 计算规则：
 * - 请求握手成功时，本模块立即按 `op_i` 对 `src1_value_i/src2_value_i` 计算 `next_result`，并锁存到 `result_q`。
 * - `MUL` 取完整无符号乘积的低 64 位。
 * - `MULH` 取有符号乘积的高 64 位。
 * - `MULHSU` 取“有符号 src1 × 无符号 src2”乘积的高 64 位。
 * - `MULHU` 取无符号乘积的高 64 位。
 * - `MULW` 只取低 32 位，并把 bit[31] 符号扩展回 DATA_WIDTH。
 * - 握手完成后，单元并不会重新计算结果，而是只等待固定 `MUL_LATENCY` 拍后把锁存结果作为完成值送出。
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 当 busy_q=0 时，req_ready_o=1，可接受新的乘法请求
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

module mul_execute_unit
    import o3_pkg::*;
#(
    parameter int DATA_WIDTH  = XLEN,
    parameter int OP_WIDTH    = 3,
    parameter int MUL_LATENCY = 3
) (
    input  logic                  clk,           // 时钟；请求接收、busy 计数与结果完成都在上升沿更新。
    input  logic                  rst,           // 复位；清空 busy、响应有效和锁存结果。
    input  logic                  req_valid_i,   // 请求端本拍是否送来一条有效乘法操作。
    output logic                  req_ready_o,   // 单元本拍是否可接收请求；当前仅在 busy_o=0 时为 1。
    input  logic [OP_WIDTH-1:0]   op_i,          // 乘法操作类型；仅在 req_valid_i && req_ready_o 时被锁存。
    input  logic [DATA_WIDTH-1:0] src1_value_i,  // 第一个乘法源操作数；仅在请求握手成功时采样。
    input  logic [DATA_WIDTH-1:0] src2_value_i,  // 第二个乘法源操作数；仅在请求握手成功时采样。
    input  logic                  is_word_op_i,  // 是否按 word 语义收敛结果；仅在请求握手成功时采样。
    output logic                  resp_valid_o,  // 完成端有效；为 1 的这一拍表示 result_o 可被消费。
    output logic [DATA_WIDTH-1:0] result_o,      // 已完成乘法请求的结果；仅在 resp_valid_o=1 时代表新的完成值。
    output logic                  busy_o         // 单元是否有请求在飞；为 1 时不接受新请求。
);

    localparam logic [OP_WIDTH-1:0] MUL_OP_MUL    = 3'd0;
    localparam logic [OP_WIDTH-1:0] MUL_OP_MULH   = 3'd1;
    localparam logic [OP_WIDTH-1:0] MUL_OP_MULHSU = 3'd2;
    localparam logic [OP_WIDTH-1:0] MUL_OP_MULHU  = 3'd3;
    localparam logic [OP_WIDTH-1:0] MUL_OP_MULW   = 3'd4;

    // op 编码约定：
    // - MUL_OP_MUL   : 低位乘法结果
    // - MUL_OP_MULH  : 有符号高位乘法结果
    // - MUL_OP_MULHSU: 有符号×无符号高位乘法结果
    // - MUL_OP_MULHU : 无符号高位乘法结果
    // - MUL_OP_MULW  : 32 位乘法后符号扩展

    localparam int COUNT_WIDTH = (MUL_LATENCY > 1) ? $clog2(MUL_LATENCY + 1) : 1;

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
    /* verilator lint_off UNUSEDSIGNAL */
    logic [2*DATA_WIDTH-1:0] unsigned_product;
    logic signed [2*DATA_WIDTH-1:0] signed_product;
    logic signed [2*DATA_WIDTH-1:0] signed_unsigned_product;
    logic signed [63:0] mulw_product;
    /* verilator lint_on UNUSEDSIGNAL */

    assign signed_src1             = signed'(src1_value_i);
    assign signed_src2             = signed'(src2_value_i);
    assign signed_src1_w           = signed'(src1_value_i[31:0]);
    assign signed_src2_w           = signed'(src2_value_i[31:0]);
    assign unsigned_product        = src1_value_i * src2_value_i;
    assign signed_product          = signed_src1 * signed_src2;
    assign signed_unsigned_product = signed_src1 * $signed({1'b0, src2_value_i});

    assign req_ready_o   = !busy_q;
    assign busy_o        = busy_q;
    assign resp_valid_o  = resp_valid_q;
    assign result_o      = result_q;
    assign req_fire      = req_valid_i && req_ready_o;

    always_comb begin
        next_result  = '0;
        mulw_product = signed_src1_w * signed_src2_w;

        unique case (op_i)
            MUL_OP_MUL: begin
                next_result = unsigned_product[DATA_WIDTH-1:0];
            end

            MUL_OP_MULH: begin
                next_result = signed_product[2*DATA_WIDTH-1:DATA_WIDTH];
            end

            MUL_OP_MULHSU: begin
                next_result = signed_unsigned_product[2*DATA_WIDTH-1:DATA_WIDTH];
            end

            MUL_OP_MULHU: begin
                next_result = unsigned_product[2*DATA_WIDTH-1:DATA_WIDTH];
            end

            MUL_OP_MULW: begin
                next_result = {{(DATA_WIDTH-32){mulw_product[31]}}, mulw_product[31:0]};
            end

            default: begin
                next_result = '0;
            end
        endcase

        if (is_word_op_i && (op_i != MUL_OP_MULW)) begin
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
                remaining_cycles_q <= COUNT_WIDTH'(MUL_LATENCY);
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
        if (MUL_LATENCY <= 0) begin
            $error("mul_execute_unit requires MUL_LATENCY > 0");
        end
    end

endmodule
