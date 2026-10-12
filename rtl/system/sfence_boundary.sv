/** Precise SFENCE acceptance -> registered invalidation command, II=1.
 * commit_ctrl owns architectural serialization until downstream completion.
 * Freeze ASID/address/zero-register qualifiers before DTLB/PTW/epoch control.
 * Flush discards pending commands; no normal execution path or serial FSM here.
 * Tests: sim/cocotb/sfence_boundary/; integration validation is deferred.
 */
module sfence_boundary import o3_types_pkg::*; (
    input logic clk,rst,flush_i,
    input sfence_req_t request_i,
    output sfence_req_t command_o
);
    always_ff @(posedge clk) begin
        if(rst || flush_i) command_o <= '0;
        else command_o <= request_i;
    end
endmodule
