/**
  这里将是前端的顶层模块
  目前只会是在valid的时候输出指令地址和指令内容，后续会增加分支预测等功能
  当前的输出只是一堆预制的指令流
*/
module frontend(
    input logic clk_i,
    input logic rst_i,
    // 连接后端的接口, I will pack it later, now just for simplicity
    output logic [38:0] inst_addr_o, // may be sv39, just fun, I will change it later
    output logic [31:0] inst_o,
    output logic inst_valid_o,
    input logic inst_ready_i
);
o3_sram #(
    .DATA_WIDTH(32),
    .SRAM_ENTRIES(256),
    .INIT_FILE("inst.hex") // 预先准备好的指令文件
) inst_sram (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .we_i(1'b0), // 只读，不写
    .data_o(inst_o), // 从sram读取指令
    .data_i('0), // 不需要输入数据
    .addr_i(pc_q) // 使用pc_q作为地址输入
);
logic [7:0] pc_q; // program counter, just for simplicity, it can only access 256 instructions
logic inst_fire;
logic [38:0] inst_addr_q; // 当前指令地址
assign inst_fire = inst_valid_o && inst_ready_i;
//when output is ready,we can advance next pc
assign inst_valid_o = '1; // always valid
always_ff @( clk_i ) begin : dump_inst
    if (rst_i) begin
        pc_q <= '0;
    end else if (inst_fire) begin
        pc_q <= pc_q + 1; // advance to next instruction
        inst_addr_q <= {31'b0, pc_q};
    end  
end
assign inst_addr_o = inst_addr_q;
endmodule