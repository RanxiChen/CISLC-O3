module Tile(
	input logic clk,
	input logic rst,
	output logic status
);

typedef enum logic [0:0] {
	NORMAL = 1'd0,
	ERROR = 1'd1
} tile_state_t;

tile_state_t state;
logic [3:0] count;
o3 core_inst(.clk(clk), .rst(rst), .led(count));
always_comb begin
	if(count == 4'd0) begin
		state = ERROR;
	end
	else begin
		state = NORMAL;
	end
end
assign status = state == NORMAL;
endmodule
