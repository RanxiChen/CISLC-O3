/** One-cycle MEM operand register after the independent issue buffer.
 * 当前实现状态：目标实现；功能验证待后端重构后进行。
 * Read grant owns LSU/cache/completion reservation. Each registered request advances
 * to AGU on the next edge without holding; replays use saved VA outside this module.
 */
module mem_regread import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(
    input logic clk,rst,flush_i,
    input renamed_uop_t read_uop_i,input logic read_grant_i,
    input logic [XLEN-1:0] src1_data_i,src2_data_i,
    output mem_execute_uop_t execute_o,output logic atomic_o,
    input branch_resolution_t resolution_i
);
    mem_execute_uop_t uop_q;logic atomic_q;
    always_comb begin
        execute_o=uop_q;
        execute_o.valid=uop_q.valid && !rst && !flush_i && !br_killed(uop_q.branch_mask,resolution_i);
        execute_o.branch_mask=br_resolved_mask(uop_q.branch_mask,resolution_i);
        atomic_o=atomic_q;
    end
    always_ff @(posedge clk) begin
        if(rst || flush_i) begin uop_q<='0;atomic_q<=0;end
        else begin
            uop_q.valid<=read_grant_i;
            if(read_grant_i) begin
                uop_q.instruction_id<=read_uop_i.instruction_id;
`ifdef O3_SIM
                uop_q.kanata_id<=read_uop_i.kanata_id;
`endif
                uop_q.rob_idx<=read_uop_i.rob_idx;uop_q.lq_idx<=read_uop_i.lq_idx;
                uop_q.sq_idx<=read_uop_i.sq_idx;uop_q.dst_preg<=read_uop_i.dst_preg;
                uop_q.dst_write_en<=read_uop_i.rd_write_en;uop_q.dst_dom<=read_uop_i.ext.rd_dom;
                uop_q.is_load<=read_uop_i.is_load;uop_q.is_store<=read_uop_i.is_store;
                uop_q.mem_size<=read_uop_i.mem_size;uop_q.mem_unsigned<=read_uop_i.mem_unsigned;
                uop_q.base_value<=read_uop_i.rs1_read_en ? src1_data_i:'0;
                uop_q.store_value<=read_uop_i.rs2_read_en ? src2_data_i:'0;
                uop_q.imm_value<=expand_imm_value(read_uop_i.imm_type,read_uop_i.imm_raw);
                uop_q.branch_mask<=br_resolved_mask(read_uop_i.branch_mask,resolution_i);
                atomic_q<=read_uop_i.ext.fu_class==o3_types_pkg::FU_AMO;
            end
        end
    end
endmodule
