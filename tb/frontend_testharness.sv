/**
 * 这个模块我打算实例化本项目的前端，
   然后将spike使用DPI-C接入进来，作为一个测试平台。
 */

// 包含所有 DPI-C 函数声明
`include "dpi_functions.svh"

module frontend_testharness(
    input logic clk_i,
    input logic rst_i,
    output logic done_o
);

// Frontend 接口信号
logic [38:0] inst_addr;
logic [31:0] inst;
logic inst_valid;
logic inst_ready;

// 实例化前端模块
frontend u_frontend (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .inst_addr_o(inst_addr),
    .inst_o(inst),
    .inst_valid_o(inst_valid),
    .inst_ready_i(inst_ready)
);

// 暂时让 ready 信号总是为 1
assign inst_ready = 1'b1;

// 计数器：用于定期打印全局调用计数
logic [31:0] cycle_counter;

// 解码结果
logic is_branch;
logic is_jump;
logic [7:0] funct3;
logic [63:0] imm;

// 示例：分支执行结果
logic branch_taken;
logic branch_predicted;

always @(posedge clk_i) begin
    if (rst_i) begin
        cycle_counter <= 0;
        dpi_reset_exec_state();  // 复位时重置执行状态
    end else begin
        cycle_counter <= cycle_counter + 1;
    end
end

// 每个时钟周期记录 ready-valid handshake 数据
always @(posedge clk_i) begin
    if (!rst_i) begin
        // 调用 DPI-C 函数记录 transaction（只在 fire 时打印）
        dpi_log_frontend_transaction(
            {25'b0, inst_addr},  // 扩展到 64-bit
            inst,
            inst_valid,
            inst_ready
        );

        // 当有有效指令时，进行解码和执行
        if (inst_valid && inst_ready) begin
            // 解码指令
            dpi_decode_instruction(
                inst,
                is_branch,
                is_jump,
                funct3,
                imm
            );

            // 如果是分支指令，进行预测和执行
            if (is_branch) begin
                // 分支预测
                branch_predicted = dpi_predict_branch({25'b0, inst_addr}, inst);

                // 执行分支（这里使用示例寄存器值）
                // 实际使用时应该从真实的寄存器文件读取
                branch_taken = dpi_execute_branch(
                    {25'b0, inst_addr},
                    inst,
                    64'h0,  // rs1_val - 示例值
                    64'h0   // rs2_val - 示例值
                );
            end
        end

        // 如果需要看每个周期的所有信号，可以取消注释下面这行
        // dpi_log_frontend_signals({25'b0, inst_addr}, inst, inst_valid, inst_ready);

        // 每 100 个周期打印一次全局计数器和分支统计
        if (cycle_counter % 100 == 0) begin
            dpi_print_call_counter();
            dpi_print_branch_stats();
        end
    end
end

assign done_o = inst_addr == 'd256; // 当访问到第 256 条指令时，认为测试完成

endmodule