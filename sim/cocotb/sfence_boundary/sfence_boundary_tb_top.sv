module sfence_boundary_tb_top import o3_types_pkg::*; (
input logic clk,rst,flush_i,request_valid_i,
input logic [$bits(sfence_req_t)-2:0] request_payload_i,
output logic command_valid_o,
output logic [$bits(sfence_req_t)-2:0] command_payload_o
);
sfence_req_t request,command;
assign request=sfence_req_t'({request_valid_i,request_payload_i});
assign command_valid_o=command.valid;
assign command_payload_o=($bits(sfence_req_t)-1)'(command);
sfence_boundary dut(.clk(clk),.rst(rst),.flush_i(flush_i),.request_i(request),.command_o(command));
endmodule
