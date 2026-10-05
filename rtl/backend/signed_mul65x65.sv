/** B43: signed 65x65 multiply, four register boundaries, II=1.
 * 当前实现状态：目标实现。Vivado infers DSPs and may retime these registers.
 * N edge captures the product; N+1..N+3 advance it. No identity or kill here.
 * Tests: sim/cocotb/mdu/ (through the MUL wrapper).
 */
module signed_mul65x65 (
    input logic clk, en_i,
    input logic [64:0] a_i, b_i,
    output logic [129:0] p_o
);
    (* use_dsp = "yes" *) logic signed [129:0] product_q [0:3];
    always_ff @(posedge clk) if (en_i) begin
        product_q[0] <= $signed(a_i) * $signed(b_i);
        for (int i=1;i<4;i++) product_q[i] <= product_q[i-1];
    end
    assign p_o = product_q[3];
endmodule
