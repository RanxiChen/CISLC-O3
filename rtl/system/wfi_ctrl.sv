/** L10 B38: locally enabled pending interrupts wake independently of global
 * enable/delegation. N retirement without wake sets sleep at edge N; N+1
 * blocks entry. A wake level clears sleep at its edge; caches/SQ still run.
 * Current implementation: target implementation (Debug input unused until L11).
 * Tests: sim/cocotb/wfi_ctrl/ and commit_ctrl/.
 */
module wfi_ctrl import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(input logic clk,rst,wfi_retire_i,input irq_view_t irq_i,
  input logic debug_req_i,output logic sleeping_o,stall_o);
    logic wake;
    assign wake=|(irq_i.mip & irq_i.mie);
    assign stall_o=sleeping_o && !wake;
    always_ff @(posedge clk) begin
        if(rst) sleeping_o<=0;
        else if(wake) sleeping_o<=0;
        else if(wfi_retire_i) sleeping_o<=1;
    end
endmodule
