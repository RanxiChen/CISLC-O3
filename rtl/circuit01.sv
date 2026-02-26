module flow_led(
	input clk,
	input rst,
	output logic [3:0] led
);

logic [3:0] data;
always_ff @(posedge clk or posedge rst) begin
	if(rst) begin
		// reset
		data <= 4'b0001;
	end
	else begin
		// shift
		data <= {data[2:0], data[3]};
	end
end

assign led[3:0] = data[3:0];

endmodule
