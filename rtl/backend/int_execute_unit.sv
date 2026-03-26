/**
 * 整数执行单元
 *
 * 当前已经实现的功能：
 * - 提供 RV64I 整数算术、逻辑、移位、比较类运算的数据通路
 * - 支持寄存器-寄存器与寄存器-立即数两种输入选择
 * - 支持 64 位整数操作与 32 位 word 操作的结果截断/符号扩展
 * - 输出一个独立的 cmp_true_o，便于后续接分支比较或条件选择
 *
 * 当前没有实现的功能：
 * - 不负责指令解码，不直接识别 32 位 instruction
 * - 不负责调度、旁路、回写仲裁、异常、trap、分支重定向
 * - 不负责访存地址生成与 LSU 协同
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 未来扩展入口：
 * - 当前已经和 `o3_pkg::int_alu_op_t` 对齐；后续可继续把 branch/load-store 控制统一抽到公共 package
 * - 后续可在外部接入 issue/dispatch/forwarding，而不改变本模块单拍接口
 * - 后续可拆分 branch compare / address generation / integer ALU 子路径
 *
 * 输入输出语义：
 * - `valid_i`
 *   1) 表示当前这一拍送进来的操作数与操作类型是否真的有效
 *   2) 本模块当前不会用它去屏蔽内部组合计算，组合逻辑始终会按输入值算出 result_o/cmp_true_o
 *   3) 但对外约定只有 `valid_i=1` 时，这一拍的 `valid_o/result_o/cmp_true_o` 才应被下游当成有效执行结果
 * - `op_i`
 *   1) 指定本拍要执行哪一种整数操作
 *   2) 当前支持 `ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND`
 *   3) 若给到未定义操作码，则输出结果回落为 0，比较结果回落为 0
 * - `src1_value_i`
 *   1) 第一个源操作数
 *   2) 对所有操作都参与计算
 * - `src2_value_i`
 *   1) 第二个源操作数
 *   2) 仅在 `use_imm_i=0` 时作为真正的第二输入参与计算
 * - `imm_value_i`
 *   1) 立即数形式的第二操作数
 *   2) 仅在 `use_imm_i=1` 时替代 `src2_value_i` 参与计算
 * - `use_imm_i`
 *   1) 第二操作数选择信号
 *   2) 为 1 时，第二操作数取 `imm_value_i`
 *   3) 为 0 时，第二操作数取 `src2_value_i`
 * - `is_word_op_i`
 *   1) 表示当前是否按 RV64 的 32 位 word 语义执行
 *   2) 为 1 时，移位使用 5 位移位量，最终结果统一做低 32 位截断并符号扩展回 64 位
 *   3) 为 0 时，按完整 DATA_WIDTH 宽度执行
 * - `valid_o`
 *   1) 直接透传 `valid_i`
 *   2) 供后续调度/回写级判断这一拍整数单元输出是否可被消费
 * - `result_o`
 *   1) 算术、逻辑、移位类操作的执行结果
 *   2) 对比较类操作，当前也会输出一个 0/1 的整数结果，便于后续统一接数据通路
 * - `cmp_true_o`
 *   1) 比较条件是否成立
 *   2) 当前对 `SLT/SLTU` 会给出对应真假值
 *   3) 对非比较类操作保持为 0
 *
 * 计算规则：
 * - 第二操作数先由 `use_imm_i` 在 `src2_value_i` 与 `imm_value_i` 之间二选一。
 * - `ADD/SUB/XOR/OR/AND` 直接对两个操作数执行对应运算。
 * - `SLL/SRL/SRA` 在 64 位模式下分别使用 6 位移位量，在 word 模式下使用 5 位移位量。
 * - `SLT` 使用有符号比较，`SLTU` 使用无符号比较。
 * - 当 `is_word_op_i=1` 时，最终对 `result_raw[31:0]` 做符号扩展形成 `result_o`。
 *
 * 时序行为：
 * - 本模块完全是组合逻辑，没有内部状态
 * - 周期 N 组合阶段：
 *   1) 根据 valid_i、op_i、src1_value_i、src2_value_i、imm_value_i 选择输入操作数
 *   2) 组合地产生 result_o 与 cmp_true_o
 * - 周期 N 上升沿：
 *   1) 本模块不更新任何状态
 * - 周期 N+1：
 *   1) 输出继续由新的输入组合决定
 */

module int_execute_unit
    import o3_pkg::*;
#(
    parameter int DATA_WIDTH = XLEN
) (
    input  int_alu_op_t           op_i,          // 本拍整数操作类型；仅在 valid_i=1 时应被下游视为有效。
    input  logic                  valid_i,       // 本拍输入是否有效；valid_o 直接透传该信号。
    input  logic [DATA_WIDTH-1:0] src1_value_i,  // 第一个源操作数；所有操作都会读取该值。
    input  logic [DATA_WIDTH-1:0] src2_value_i,  // 第二个寄存器源操作数；仅在 use_imm_i=0 时被选中。
    input  logic [DATA_WIDTH-1:0] imm_value_i,   // 立即数第二操作数；仅在 use_imm_i=1 时被选中。
    input  logic                  use_imm_i,     // 第二操作数选择；1 选 imm_value_i，0 选 src2_value_i。
    input  logic                  is_word_op_i,  // 是否按 RV64 word 语义执行；1 表示结果最终做 32 位截断和符号扩展。

    output logic                  valid_o,       // 输出结果是否有效；当前等于 valid_i。
    output logic [DATA_WIDTH-1:0] result_o,      // 整数执行结果；比较类操作也输出 0/1 整数值。
    output logic                  cmp_true_o     // 比较条件是否成立；非比较类操作保持为 0。
);

    logic [DATA_WIDTH-1:0] src2_sel;
    logic [DATA_WIDTH-1:0] result_raw;
    logic signed [DATA_WIDTH-1:0] signed_src1;
    logic signed [DATA_WIDTH-1:0] signed_src2;

    assign src2_sel   = use_imm_i ? imm_value_i : src2_value_i;
    assign signed_src1 = signed'(src1_value_i);
    assign signed_src2 = signed'(src2_sel);
    assign valid_o     = valid_i;

    always_comb begin
        result_raw = '0;
        cmp_true_o = 1'b0;

        unique case (op_i)
            INT_ALU_OP_ADD: begin
                result_raw = src1_value_i + src2_sel;
            end

            INT_ALU_OP_SUB: begin
                result_raw = src1_value_i - src2_sel;
            end

            INT_ALU_OP_SLL: begin
                if (is_word_op_i) begin
                    result_raw = DATA_WIDTH'($signed(src1_value_i[31:0] << src2_sel[4:0]));
                end else begin
                    result_raw = src1_value_i << src2_sel[5:0];
                end
            end

            INT_ALU_OP_SLT: begin
                cmp_true_o = (signed_src1 < signed_src2);
                result_raw = {{(DATA_WIDTH-1){1'b0}}, cmp_true_o};
            end

            INT_ALU_OP_SLTU: begin
                cmp_true_o = (src1_value_i < src2_sel);
                result_raw = {{(DATA_WIDTH-1){1'b0}}, cmp_true_o};
            end

            INT_ALU_OP_XOR: begin
                result_raw = src1_value_i ^ src2_sel;
            end

            INT_ALU_OP_SRL: begin
                if (is_word_op_i) begin
                    result_raw = DATA_WIDTH'($signed({1'b0, (src1_value_i[31:0] >> src2_sel[4:0])}[31:0]));
                end else begin
                    result_raw = src1_value_i >> src2_sel[5:0];
                end
            end

            INT_ALU_OP_SRA: begin
                if (is_word_op_i) begin
                    result_raw = DATA_WIDTH'($signed($signed(src1_value_i[31:0]) >>> src2_sel[4:0]));
                end else begin
                    result_raw = DATA_WIDTH'(signed_src1 >>> src2_sel[5:0]);
                end
            end

            INT_ALU_OP_OR: begin
                result_raw = src1_value_i | src2_sel;
            end

            INT_ALU_OP_AND: begin
                result_raw = src1_value_i & src2_sel;
            end

            default: begin
                result_raw = '0;
                cmp_true_o = 1'b0;
            end
        endcase
    end

    always_comb begin
        result_o = result_raw;

        if (is_word_op_i) begin
            result_o = {{(DATA_WIDTH-32){result_raw[31]}}, result_raw[31:0]};
        end
    end

endmodule
