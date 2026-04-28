// This module implements the LFSR used for random replacement in the cache.
module lfsr (
    input logic clk,
    input logic rst,
    input logic enable,
    output logic [15:0] lfsr_out
);

logic [15:0] lfsr_d, lfsr_q;
logic lfsr_last;
assign lfsr_last = lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10];
assign lfsr_d = {lfsr_q[14:0], lfsr_last};
assign lfsr_out = lfsr_q;
always_ff @( posedge clk ) begin : lfsr_ff
    if ( rst ) begin
        lfsr_q <= 16'hACE1; // Non-zero seed value
    end else if ( enable ) begin
        lfsr_q <= lfsr_d;
    end
    
end
    
endmodule
