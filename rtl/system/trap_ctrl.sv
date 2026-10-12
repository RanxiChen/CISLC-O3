/** Precise trap transport with two registered logical stages, no FSM.
 * N: commit accepts a precise boundary, freezing EPC/cause/tval. Recovery
 * application cancels younger owners in N+1, alongside the CSR update.
 * Edge N captures that request. N+1: the registered request updates architectural
 * CSR/privilege state and computes its target. Edge N+1 captures the target.
 * N+2: target reaches the registered recovery packet dispatcher; N+3 it is
 * delivered to the frontend. busy_o holds this transport through both stages,
 * then recovery_pending holds the dispatched packet's cycle;
 * commit cannot accept another event or retire while it owns this boundary.
 * CSR hardware update always acknowledges in its request cycle. Exceptions,
 * IRQ and legal xRET share transport; legal xRET itself retires at acceptance.
 * Ordinary retirement/issue throughput is unchanged. Functional tests pending.
 */
module trap_ctrl import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(
    input logic clk,rst,
    input trap_req_t req_i,
    output logic csr_update_valid_o,
    output trap_req_t csr_update_o,
    input vaddr_t csr_target_pc_i,
    input logic csr_update_done_i,
    output logic redirect_valid_o,
    output vaddr_t redirect_pc_o,
    output logic busy_o
);
    trap_req_t request_q;
    assign csr_update_valid_o=request_q.valid;
    assign csr_update_o=request_q;
    assign busy_o=request_q.valid || redirect_valid_o;
    always_ff @(posedge clk) begin
        if(rst) begin
            request_q<='0;redirect_valid_o<=0;redirect_pc_o<='0;
        end else begin
            request_q<=req_i;
            redirect_valid_o<=request_q.valid && csr_update_done_i;
            if(request_q.valid && csr_update_done_i) redirect_pc_o<=csr_target_pc_i;
            if(request_q.valid) assert(csr_update_done_i);
        end
    end
endmodule
