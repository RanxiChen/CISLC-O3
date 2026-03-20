/**
* 一个统一的后端，后面将会将代码进行拆分
*/

module backend
    import o3_pkg::*;
(
    input  logic clk,
    input  logic rst,

    // Frontend -> Backend 接口
    input  fetch_entry_t [DECODE_WIDTH-1:0] fetch_entry_i,
    input  logic                             fetch_valid_i,
    output logic                             fetch_ready_o,

    output logic done
);

    // 固定参数，将来会变成可配置的参数
    localparam int DECODE_WIDTH = 4;

    // 存放fetch_entry的寄存器
    fetch_entry_t [DECODE_WIDTH-1:0] fetch_entry_q;

    // 握手信号
    logic fetch_fire;
    assign fetch_fire = fetch_valid_i && fetch_ready_o;

    // 寄存器逻辑：握手成功时存储fetch_entry
    always_ff @(posedge clk) begin
        if (rst) begin
            fetch_entry_q <= '0;
        end else if (fetch_fire) begin
            fetch_entry_q <= fetch_entry_i;
        end
    end

    // Ready信号：目前先一直为false，后续实现
    assign fetch_ready_o = 1'b0;

    // 从寄存器输出连接到解码器
    decode_in_t  [DECODE_WIDTH-1:0] decode_in;
    decode_out_t [DECODE_WIDTH-1:0] decode_out;

    // 将fetch_entry_q的instruction字段提取给解码器
    genvar i;
    generate
        for (i = 0; i < DECODE_WIDTH; i++) begin : decode_input_assign
            assign decode_in[i].instruction = fetch_entry_q[i].instruction;
        end
    endgenerate

    // 实例化多个解码器
    generate
        for (i = 0; i < DECODE_WIDTH; i++) begin : decoder_array
            decoder u_decoder (
                .decode_i(decode_in[i]),
                .decode_o(decode_out[i])
            );
        end
    endgenerate

endmodule
