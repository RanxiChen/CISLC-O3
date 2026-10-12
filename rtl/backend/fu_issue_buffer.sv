/** Per-FU two-slot issue buffer before registered PRF arbitration.
 * 当前实现状态：目标实现。INT/FP/BR FUs and MEM lanes own instances.
 * IQ deletion occurs only on enq_valid && enq_ready. An ungranted instruction
 * remains here, without occupying its FU or rereading operands.
 * N: expose the registered head; input capacity depends only on registered occupancy.
 * No deq-ready or arbitration-grant path propagates to IQ admission. A full buffer
 * cannot accept on its dequeue edge; the second slot absorbs normal one/cycle flow.
 * Payload remains in two stationary RAM slots. Branch masks/valid and the
 * head index are independent metadata; cancellation moves only that index.
 * N edge: accept arbitration ownership transfer, discard cancelled owners and append.
 * N+1: the next head independently enters the operand-request stage.
 * Validation deferred until the authorized backend refactor is complete.
 */
module fu_issue_buffer import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(
    input logic clk, rst, flush_i,
    input logic enq_valid_i,
    output logic enq_ready_o,
    input renamed_uop_t enq_uop_i,
    output logic deq_valid_o,
    input logic deq_ready_i,
    output renamed_uop_t deq_uop_o,
    input branch_resolution_t resolution_i
);
    localparam int UOP_W=$bits(renamed_uop_t);
    (* ram_style="distributed" *) logic [UOP_W-1:0] payload_mem[2];
    logic valid_q[2],valid_d[2],head_q,head_d;
    branch_mask_t mask_q[2],mask_d[2],lo_mask_q[2],lo_mask_d[2];
    logic write_slot;
    // Admission uses raw occupancy, preserving the original no-borrow rule.
    assign enq_ready_o=!rst && !flush_i && !(valid_q[0] && valid_q[1]);
    assign write_slot=valid_q[0];
    assign deq_valid_o=valid_q[head_q] && !rst && !flush_i &&
        !br_killed(mask_q[head_q],resolution_i);
    always_comb begin
        deq_uop_o='0;
        if(valid_q[head_q]) begin
            deq_uop_o=renamed_uop_t'(payload_mem[head_q]);
            deq_uop_o.branch_mask=br_resolved_mask(mask_q[head_q],resolution_i);
            deq_uop_o.mdu_fuse.lo_tag.br_mask=br_resolved_mask(lo_mask_q[head_q],resolution_i);
        end
        deq_uop_o.valid=deq_valid_o;
    end
    always_comb begin
        valid_d=valid_q;mask_d=mask_q;lo_mask_d=lo_mask_q;
        for(int s=0;s<2;s++) begin
            mask_d[s]=br_resolved_mask(mask_q[s],resolution_i);
            lo_mask_d[s]=br_resolved_mask(lo_mask_q[s],resolution_i);
            if(valid_q[s] && (br_killed(mask_q[s],resolution_i) ||
                (s==int'(head_q) && deq_valid_o && deq_ready_i))) valid_d[s]=0;
        end
        head_d=head_q;
        if(!valid_d[head_q] && valid_d[!head_q]) head_d=!head_q;
        if(enq_valid_i && enq_ready_o && !br_killed(enq_uop_i.branch_mask,resolution_i)) begin
            if(!(valid_d[0] || valid_d[1])) head_d=write_slot;
            valid_d[write_slot]=1;
            mask_d[write_slot]=br_resolved_mask(enq_uop_i.branch_mask,resolution_i);
            lo_mask_d[write_slot]=br_resolved_mask(enq_uop_i.mdu_fuse.lo_tag.br_mask,resolution_i);
        end
        if(!(valid_d[0] || valid_d[1])) head_d=0;
    end
    always_ff @(posedge clk) begin
        if(!rst && !flush_i && enq_valid_i && enq_ready_o &&
            !br_killed(enq_uop_i.branch_mask,resolution_i)) payload_mem[write_slot]<=UOP_W'(enq_uop_i);
        if(rst || flush_i) begin
            valid_q<='{default:0};mask_q<='{default:'0};lo_mask_q<='{default:'0};head_q<=0;
        end else begin
            valid_q<=valid_d;mask_q<=mask_d;lo_mask_q<=lo_mask_d;head_q<=head_d;
        end
    end
endmodule
