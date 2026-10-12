/** Independent MUL/DIV operand register and FU request handshake.
 * 当前实现状态：目标实现。Read-port grant captures operands and complete identity.
 * N: a buffered instruction competes for ports if this register has capacity.
 * N edge: capture granted reads; consume the previous request only on FU handshake.
 * N+1: captured operands drive the FU, held stable through backpressure.
 * MUL reserves completion credits at the FU handshake, not at IQ selection/read.
 * Adjacent fused MUL instructions have the same cancellation mask on entry.
 * Validation deferred until the authorized backend refactor is complete.
 */
module mdu_regread import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(
    input logic clk, rst, flush_i,
    input renamed_uop_t read_uop_i,
    input logic read_grant_i,
    input logic [XLEN-1:0] src1_data_i, src2_data_i,
    output logic read_ready_o,
    output logic req_valid_o,
    input logic req_ready_i,
    output o3_types_pkg::mdu_req_t req_o,
    input branch_resolution_t resolution_i
);
    logic valid_q, killed;
    o3_types_pkg::mdu_req_t req_q;
    assign killed = br_killed(req_q.tag.br_mask, resolution_i);
    assign read_ready_o = !rst && !flush_i && (!valid_q || req_ready_i || killed);
    assign req_valid_o = valid_q && !rst && !flush_i && !killed;
    always_comb begin
        req_o = req_q;
        req_o.tag.br_mask = br_resolved_mask(req_q.tag.br_mask, resolution_i);
        req_o.fuse.lo_tag.br_mask = br_resolved_mask(req_q.fuse.lo_tag.br_mask, resolution_i);
    end
    always_ff @(posedge clk) begin
        if (rst || flush_i) begin
            valid_q <= 1'b0;
            req_q <= '0;
        end else if (read_grant_i && read_ready_o) begin
            valid_q <= 1'b1;
            req_q.op <= read_uop_i.ext.mdu_op;
            req_q.src1 <= src1_data_i;
            req_q.src2 <= src2_data_i;
            req_q.tag <= '{rob_idx:read_uop_i.rob_idx,
                br_mask:br_resolved_mask(read_uop_i.branch_mask, resolution_i),
                dst_dom:read_uop_i.ext.rd_dom, dst_preg:read_uop_i.dst_preg,
                dst_write_en:read_uop_i.rd_write_en};
            req_q.fuse <= read_uop_i.mdu_fuse;
            req_q.fuse.lo_tag.br_mask <= br_resolved_mask(read_uop_i.mdu_fuse.lo_tag.br_mask, resolution_i);
        end else begin
            if (killed || (req_valid_o && req_ready_i)) valid_q <= 1'b0;
            if (resolution_i.valid) begin
                req_q.tag.br_mask <= br_resolved_mask(req_q.tag.br_mask, resolution_i);
                req_q.fuse.lo_tag.br_mask <= br_resolved_mask(req_q.fuse.lo_tag.br_mask, resolution_i);
            end
        end
    end
endmodule
