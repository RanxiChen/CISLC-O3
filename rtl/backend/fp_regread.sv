/** Independent elastic FP operand register, after the issue buffer/read arbiter.
 * 当前实现状态：目标实现；功能验证待后端重构后进行。
 * N grant captures all enabled operands atomically. N+1 drives the assigned FU.
 * Requests remain stable until native FU acceptance; recovery cancels before delivery.
 */
module fp_regread import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(
    input logic clk,rst,flush_i,
    input renamed_uop_t read_uop_i,input logic read_grant_i,
    input logic [XLEN-1:0] src1_data_i,src2_data_i,src3_data_i,
    output logic read_ready_o,req_valid_o,input logic req_ready_i,
    output o3_types_pkg::fpu_req_t req_o,
    input branch_resolution_t resolution_i
);
    logic valid_q,killed;o3_types_pkg::fpu_req_t req_q;
    assign killed=br_killed(req_q.tag.br_mask,resolution_i);
    assign read_ready_o=!rst && !flush_i && (!valid_q || req_ready_i || killed);
    assign req_valid_o=valid_q && !rst && !flush_i && !killed;
    always_comb begin
        req_o=req_q;req_o.tag.br_mask=br_resolved_mask(req_q.tag.br_mask,resolution_i);
    end
    always_ff @(posedge clk) begin
        if(rst || flush_i) begin valid_q<=0;req_q<='0;end
        else if(read_grant_i && read_ready_o) begin
            valid_q<=1;
            req_q.tag<='{rob_idx:read_uop_i.rob_idx,
                br_mask:br_resolved_mask(read_uop_i.branch_mask,resolution_i),
                dst_dom:read_uop_i.ext.rd_dom,dst_preg:read_uop_i.dst_preg,
                dst_write_en:read_uop_i.rd_write_en};
            req_q.op<=read_uop_i.ext.fp_op;req_q.src_fmt<=read_uop_i.ext.fp_src_fmt;
            req_q.dst_fmt<=read_uop_i.ext.fp_fmt;req_q.int_fmt<=read_uop_i.ext.fp_int_fmt;
            req_q.rm<=read_uop_i.ext.rm;req_q.op_mod<=read_uop_i.ext.fp_unsigned;
            req_q.src1<=read_uop_i.rs1_read_en ? src1_data_i:'0;
            req_q.src2<=read_uop_i.rs2_read_en ? src2_data_i:'0;
            req_q.src3<=read_uop_i.ext.rs3_read_en ? src3_data_i:'0;
        end else begin
            if(killed || (req_valid_o && req_ready_i)) valid_q<=0;
            if(resolution_i.valid) req_q.tag.br_mask<=br_resolved_mask(req_q.tag.br_mask,resolution_i);
        end
    end
endmodule
