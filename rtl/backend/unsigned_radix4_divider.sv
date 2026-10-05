/** Hand translation of Breeze UnsignedRadix4Divider.scala (B21).
 * Reference Flow ee4a56ceefd49befc08741a59f714f6c37261010.
 * 当前实现状态：目标实现。One request, MSB alignment, two restoring steps/cycle.
 * N start edge initializes q/r/shift; each subsequent edge computes two bits;
 * when shift<=1 the edge releases busy and raises done for one cycle. Abort wins.
 * Tests: sim/cocotb/mdu/ (through DIV).
 */
module unsigned_radix4_divider (
    input logic clk, rst, start_i,
    output logic ready_o,
    input logic [63:0] dividend_i, divisor_i,
    input logic abort_i,
    output logic done_o,
    output logic [63:0] quotient_o, remainder_o
);
    logic busy_q;
    logic [63:0] divisor_q, q1, q2, r1, r2, d1, d2;
    logic [5:0] shift_q, shift2;
    function automatic logic [5:0] msb(input logic [63:0] x);
        msb=0;
        for(int i=0;i<64;i++) if(x[i]) msb=6'(i);
    endfunction
    assign ready_o = !busy_q;
    always_comb begin
        d1 = divisor_q << shift_q;
        r1 = remainder_o; q1 = quotient_o;
        if(remainder_o >= d1) begin r1 = remainder_o-d1; q1 = quotient_o | (64'd1 << shift_q); end
        shift2 = shift_q==0 ? 6'd0 : shift_q-6'd1;
        d2 = divisor_q << shift2;
        r2=r1; q2=q1;
        if(shift_q!=0 && r1>=d2) begin r2=r1-d2; q2=q1 | (64'd1 << shift2); end
    end
    always_ff @(posedge clk) begin
        if(rst || abort_i) begin
            busy_q<=0; done_o<=0; quotient_o<=0; remainder_o<=0; divisor_q<=0; shift_q<=0;
        end else begin
            done_o<=0;
            if(start_i && !busy_q) begin
                quotient_o<=0; divisor_q<=divisor_i; remainder_o<=dividend_i;
                if(divisor_i==0) begin quotient_o<='1; done_o<=1; end
                else if(dividend_i==0 || dividend_i<divisor_i) done_o<=1;
                else if(dividend_i==divisor_i) begin quotient_o<=1; remainder_o<=0; done_o<=1; end
                else begin shift_q<=msb(dividend_i)-msb(divisor_i); busy_q<=1; end
            end else if(busy_q) begin
                quotient_o<=q2; remainder_o<=r2;
                if(shift_q<=1) begin busy_q<=0; done_o<=1; end
                else shift_q<=shift_q-6'd2;
            end
        end
    end
endmodule
