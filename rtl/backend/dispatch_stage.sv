/**
 * Ordered prefix dispatch to INT/MEM/BR/FP IQs (B02/B14/B15).
 * Four lanes consume only their target queue's space. FP arithmetic/conversion routes
 * to FP IQ; floating loads/stores route to MEM. Exceptions and serialized head operations
 * consume RDQ without entering IQ. Fused integer pairs remain atomic and only HEAD enters IQ.
 * Correct resolution can proceed; recovery blocks dispatch.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行。
 * N: compute the oldest supported resource-feasible prefix and per-IQ lane enables.
 * N edge: RDQ deletes the prefix and target IQs enqueue. N+1: visible queue state advances.
 */
module dispatch_stage
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int DISPATCH_WIDTH = CFG.dispatch.width,
    localparam int INT_IQ_DEPTH = CFG.dispatch.int_iq_depth,
    localparam int MEM_IQ_DEPTH = CFG.dispatch.mem_iq_depth,
    localparam int BR_IQ_DEPTH = CFG.dispatch.br_iq_depth,
    localparam int FP_IQ_DEPTH = CFG.dispatch.fp_iq_depth
) (
    input  renamed_uop_t [DISPATCH_WIDTH-1:0] uop_i,
    input  logic [$clog2(DISPATCH_WIDTH+1)-1:0] visible_count_i,
    input  logic recovery_block_i,
    input  logic [$clog2(INT_IQ_DEPTH+1)-1:0] int_free_count_i,
    input  logic [$clog2(MEM_IQ_DEPTH+1)-1:0] mem_free_count_i,
    input  logic [$clog2(BR_IQ_DEPTH+1)-1:0] br_free_count_i,
    input logic [$clog2(FP_IQ_DEPTH+1)-1:0] fp_free_count_i,

    output logic fp_lane_o [DISPATCH_WIDTH-1:0],
    output logic int_lane_o [DISPATCH_WIDTH-1:0],
    output logic mem_lane_o [DISPATCH_WIDTH-1:0],
    output logic br_lane_o [DISPATCH_WIDTH-1:0],
    output logic [$clog2(DISPATCH_WIDTH+1)-1:0] accept_count_o
);
    localparam int COUNT_WIDTH = $clog2(DISPATCH_WIDTH + 1);

    always_comb begin
        int unsigned int_left, mem_left, br_left, fp_left;
        logic blocked;

        int_left = int'(int_free_count_i);
        mem_left = int'(mem_free_count_i);
        br_left = int'(br_free_count_i);
        fp_left = int'(fp_free_count_i);
        blocked = recovery_block_i;
        int_lane_o = '{default: 1'b0};
        mem_lane_o = '{default: 1'b0};
        br_lane_o = '{default: 1'b0};
        fp_lane_o = '{default: 1'b0};
        accept_count_o = '0;

        for (int lane = 0; lane < DISPATCH_WIDTH; lane++) begin
            logic is_int, is_mem, is_br, is_fp, supported, target_has_space;

            is_mem = uop_i[lane].valid && (uop_i[lane].is_load || uop_i[lane].is_store);
            is_br = uop_i[lane].valid
                 && (uop_i[lane].is_branch || uop_i[lane].is_jal || uop_i[lane].is_jalr);
            is_int = uop_i[lane].valid && uop_i[lane].is_int_uop && !is_mem && !is_br
                  && uop_i[lane].ext.fuse_role!=o3_types_pkg::FUSE_MEMBER;
            is_fp = uop_i[lane].valid && !uop_i[lane].exception_valid &&
                (uop_i[lane].ext.fu_class inside {o3_types_pkg::FU_FMA, o3_types_pkg::FU_FDIVSQRT, o3_types_pkg::FU_FMISC, o3_types_pkg::FU_FCONV});
            supported = uop_i[lane].ext.fuse_role==o3_types_pkg::FUSE_MEMBER || is_fp || is_int || is_mem || is_br || uop_i[lane].ext.serialize || uop_i[lane].exception_valid;
            target_has_space = uop_i[lane].ext.fuse_role==o3_types_pkg::FUSE_MEMBER || (is_int && (int_left > 0))
                            || (is_mem && (mem_left > 0))
                            || (is_fp && (fp_left > 0)) || (is_br && (br_left > 0)) || uop_i[lane].ext.serialize || uop_i[lane].exception_valid;

            if(uop_i[lane].ext.fuse_role==o3_types_pkg::FUSE_HEAD) begin
                if(lane+1>=DISPATCH_WIDTH) target_has_space=0;
                else target_has_space &= lane+1<int'(visible_count_i) && uop_i[lane+1].valid &&
                    uop_i[lane+1].ext.fuse_role==o3_types_pkg::FUSE_MEMBER;
            end
            if (!blocked && (lane < int'(visible_count_i))
             && uop_i[lane].valid && supported && target_has_space) begin
                int_lane_o[lane] = is_int;
                mem_lane_o[lane] = is_mem;
                br_lane_o[lane] = is_br;
                fp_lane_o[lane] = is_fp;
                accept_count_o = accept_count_o + COUNT_WIDTH'(1);
                if (is_int) int_left--;
                if (is_mem) mem_left--;
                if (is_br) br_left--;
                if (is_fp) fp_left--;
            end else if ((lane < int'(visible_count_i)) && uop_i[lane].valid) begin
                blocked = 1'b1;
            end
        end
    end

    initial begin
        if (DISPATCH_WIDTH <= 0) $error("dispatch_stage requires DISPATCH_WIDTH > 0");
        if ((INT_IQ_DEPTH <= 0) || (MEM_IQ_DEPTH <= 0) || (BR_IQ_DEPTH <= 0)) begin
            $error("dispatch_stage requires positive IQ depths");
        end
    end
endmodule
