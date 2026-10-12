/** Registered recovery application, no serial FSM.
 * C0: commit accepts the precise event and prevents architectural retirement
 * across that boundary. New irreversible head/translation admission is excluded
 * by the local request gate in backend; speculative younger work may progress.
 * Edge C0: capture global cancellation and non-trap refetch packet.
 * C1: cancel younger owners and restore committed rename state. Pending holds
 * commit/serial admission for this application cycle. Trap CSR update shares C1;
 * its C2 target is dispatched through the same packet register and reaches the
 * frontend in C3. No path bypasses this boundary with a combinational commit
 * packet: even its trap fields can otherwise depend on current head decisions.
 * Ordinary retirement and execution do not traverse this recovery pipeline.
 * Current target implementation: integration/function tests deferred.
 */
module recovery_boundary import o3_types_pkg::*; (
    input logic clk,rst,
    input logic cancel_request_i,
    input sys_redirect_t redirect_request_i,
    output logic cancel_o,pending_o,
    output sys_redirect_t redirect_o
);
    sys_redirect_t refetch_q;
    assign pending_o=cancel_o || refetch_q.valid;
    assign redirect_o=refetch_q;
    always_ff @(posedge clk) begin
        if(rst) begin cancel_o<=0;refetch_q<='0;end
        else begin
            cancel_o<=cancel_request_i;
            refetch_q<=redirect_request_i;
        end
    end
endmodule
