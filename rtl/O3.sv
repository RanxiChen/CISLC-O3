module o3(
	input logic clk,
	input logic rst,
	output logic[3:0] led
);

flow_led inst0(.clk(clk), .rst(rst), .led(led));

endmodule;
