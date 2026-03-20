/**
* 指令解码器 - 纯组合逻辑
* 从32位指令中提取寄存器索引
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

    // 纯组合逻辑提取寄存器字段
    assign decode_o.rd  = decode_i.instruction[11:7];
    assign decode_o.rs1 = decode_i.instruction[19:15];
    assign decode_o.rs2 = decode_i.instruction[24:20];

endmodule
