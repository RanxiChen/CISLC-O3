module mul_fusion_detect_tb_top import o3_pkg::*; (
    input logic [31:0] instr_i [3:0],
    input logic [2:0] count_i,
    input logic no_fuse_i,exc_i,
    input logic [7:0] resources_i,
    output logic [1:0] role_o [3:0],
    output logic [3:0] pair_o,illegal_o,
    output logic [2:0] accepted_o
);
    localparam o3_cfg_pkg::backend_cfg_t C=o3_cfg_pkg::O3_CFG.be;
    decode_in_t di [3:0];decode_out_t dout [3:0];decoded_uop_t [3:0] u,v;
    logic cpgrant [3:0];branch_tag_t tag [3:0];logic [PREG_IDX_WIDTH-1:0] pg [3:0];
    logic [ROB_IDX_WIDTH-1:0] ri [3:0];logic [LQ_IDX_WIDTH-1:0] li [3:0];logic [SQ_IDX_WIDTH-1:0] si [3:0];logic z [3:0];
    for(genvar i=0;i<4;i++) begin
        assign di[i].instruction=instr_i[i];decoder d(.decode_i(di[i]),.decode_o(dout[i]));
        always_comb begin
            u[i]='0;u[i].valid=i<int'(count_i);u[i].rs1=dout[i].rs1;u[i].rs2=dout[i].rs2;
            u[i].rd=dout[i].rd;u[i].rd_write_en=dout[i].rd_write_en;u[i].ext=dout[i].ext;
            u[i].exception_valid=exc_i || dout[i].illegal_instruction;
        end
        assign cpgrant[i]=1;assign tag[i]=0;assign pg[i]=0;assign ri[i]=0;assign li[i]=0;assign si[i]=0;assign z[i]=0;
        assign role_o[i]=v[i].ext.fuse_role;assign illegal_o[i]=dout[i].illegal_instruction;
    end
    mul_fusion_detect #(.CFG(C)) dut(.uop_i(u),.count_i(count_i),.no_fuse_i(no_fuse_i),.uop_o(v),.pair_head_o(pair_o));
    rename_stage #(.CFG(C)) rename_dut(.decoded_i(v),.visible_count_i(count_i),.recovery_block_i(1'b0),
        .preg_free_count_i(resources_i),.rob_free_count_i(resources_i),.lq_free_count_i(7'd32),.sq_free_count_i(7'd32),
        .rdq_free_count_i(resources_i),.active_branch_mask_i('0),.checkpoint_grant_i(cpgrant),.checkpoint_tag_i(tag),
        .src1_preg_i(pg),.src2_preg_i(pg),.old_dst_preg_i(pg),.new_dst_preg_i(pg),.rob_idx_i(ri),.lq_idx_i(li),.sq_idx_i(si),
        .src1_from_older_lane_i(z),.src2_from_older_lane_i(z),.lane_accept_o(),.dst_alloc_req_o(),.rob_alloc_req_o(),
        .lq_alloc_req_o(),.sq_alloc_req_o(),.checkpoint_create_o(),.lane_branch_mask_o(),.accept_count_o(accepted_o),.renamed_uop_o());
endmodule
