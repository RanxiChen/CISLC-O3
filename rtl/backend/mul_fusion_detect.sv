/** B34 adjacent MULH*/
// 当前实现状态：目标实现。Combinational, no lookahead wait or forward search.
// Preserve two architectural instructions; resource planners accept each pair atomically.
// Tests: sim/cocotb/mul_fusion_detect/; whole-core L6 smoke.
module mul_fusion_detect import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,
    localparam int WIDTH=CFG.rename.width
)(
    input decoded_uop_t [WIDTH-1:0] uop_i,
    input logic [$clog2(WIDTH+1)-1:0] count_i,
    input logic no_fuse_i,
    output decoded_uop_t [WIDTH-1:0] uop_o,
    output logic [WIDTH-1:0] pair_head_o
);
    import o3_types_pkg::*;
    always_comb begin
        uop_o=uop_i;pair_head_o=0;
        for(int i=0;i<WIDTH;i++) uop_o[i].ext.fuse_role=FUSE_NONE;
        for(int i=0;i<WIDTH-1;i++) begin
            if(!no_fuse_i && i+1<int'(count_i) && uop_i[i].valid && uop_i[i+1].valid &&
               !uop_i[i].exception_valid && !uop_i[i+1].exception_valid &&
               uop_i[i].ext.fu_class==FU_MUL && uop_i[i+1].ext.fu_class==FU_MUL &&
               (uop_i[i].ext.mdu_op inside {MDU_MULH,MDU_MULHU,MDU_MULHSU}) &&
               uop_i[i+1].ext.mdu_op==MDU_MUL &&
               uop_i[i].rs1==uop_i[i+1].rs1 && uop_i[i].rs2==uop_i[i+1].rs2 &&
               (uop_i[i].rd==0 || (uop_i[i].rd!=uop_i[i].rs1 && uop_i[i].rd!=uop_i[i].rs2))) begin
                uop_o[i].ext.fuse_role=FUSE_HEAD;uop_o[i+1].ext.fuse_role=FUSE_MEMBER;pair_head_o[i]=1;
            end
        end
    end
endmodule
