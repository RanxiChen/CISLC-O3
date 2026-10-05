module rename_entry_gate_tb_top import o3_pkg::*; (
 input logic clk,rst,retire_i,flush_i,isolate_i,wfi_i,
 input logic [3:0] serial_i, input logic [2:0] count_i, accepted_i,
 output logic [2:0] pass_o,output logic block_o,output logic [31:0] width_o);
 decoded_uop_t [3:0] uops;
 for(genvar i=0;i<4;i++) always_comb begin uops[i]='0;uops[i].ext.block_younger=serial_i[i];end
 assign width_o=4;
 rename_entry_gate #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.clk(clk),.rst(rst),.uop_i(uops),.count_i(count_i),
 .pair_head_i('0),.pass_count_o(pass_o),.accepted_count_i(accepted_i),.serial_retire_i(retire_i),
 .flush_i(flush_i),.isolate_i(isolate_i),.wfi_stall_i(wfi_i),.block_younger_cycle_o(block_o));
endmodule
