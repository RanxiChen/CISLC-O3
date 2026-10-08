module decoder_tb_top import o3_pkg::*; import o3_types_pkg::*; (
 input logic [31:0] instruction_i,
 output logic illegal_o,serial_o,block_o,rs1_read_o,rs2_read_o,x0_1_o,x0_2_o,
 output logic [3:0] sysop_o,amo_op_o,
 output logic aq_o,rl_o,load_o,store_o,rd_write_o,
 output logic [1:0] size_o
);
 decode_in_t req;decode_out_t resp;
 always_comb begin req='0;req.instruction=instruction_i;end
 decoder dut(.decode_i(req),.decode_o(resp));
 assign illegal_o=resp.illegal_instruction;
 assign serial_o=resp.ext.serialize;assign block_o=resp.ext.block_younger;
 assign rs1_read_o=resp.rs1_read_en;assign rs2_read_o=resp.rs2_read_en;
 assign x0_1_o=resp.ext.sfence_rs1_x0;assign x0_2_o=resp.ext.sfence_rs2_x0;
 assign sysop_o=resp.ext.sys_op;
assign amo_op_o=resp.ext.amo_op;assign aq_o=resp.ext.aq;assign rl_o=resp.ext.rl;
 assign load_o=resp.is_load;assign store_o=resp.is_store;assign rd_write_o=resp.rd_write_en;assign size_o=resp.mem_size;
endmodule
