/**
 * Ordered prefix dispatch to INT/MEM/BR/FP IQs (B02/B14/B15).
 * CFG.dispatch.width lanes consume only their target queue's space. FP arithmetic/conversion routes
 * to FP IQ; floating loads/stores route to MEM. Exceptions and serialized head operations
 * consume RDQ without entering IQ. Fused integer pairs remain atomic and only HEAD enters IQ.
 * Correct resolution can proceed; recovery blocks dispatch.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行。
 * Demand prefixes are independent of current queue capacities; lanes compare in parallel.
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
        logic is_int[DISPATCH_WIDTH],is_mem[DISPATCH_WIDTH],is_br[DISPATCH_WIDTH],is_fp[DISPATCH_WIDTH];
        logic feasible[DISPATCH_WIDTH];
        logic prefix_ok;
        int_lane_o='{default:0};mem_lane_o='{default:0};br_lane_o='{default:0};fp_lane_o='{default:0};
        accept_count_o='0;
        // Classify without dependence on queue capacities or earlier acceptance.
        for(int lane=0;lane<DISPATCH_WIDTH;lane++) begin
            is_mem[lane]=uop_i[lane].valid && (uop_i[lane].is_load || uop_i[lane].is_store);
            is_br[lane]=uop_i[lane].valid && (uop_i[lane].is_branch || uop_i[lane].is_jal || uop_i[lane].is_jalr);
            is_int[lane]=uop_i[lane].valid && uop_i[lane].is_int_uop && !is_mem[lane] && !is_br[lane]
                && uop_i[lane].ext.fuse_role!=o3_types_pkg::FUSE_MEMBER;
            is_fp[lane]=uop_i[lane].valid && !uop_i[lane].exception_valid &&
                (uop_i[lane].ext.fu_class inside {o3_types_pkg::FU_FMA,o3_types_pkg::FU_FDIVSQRT,o3_types_pkg::FU_FMISC,o3_types_pkg::FU_FCONV});
        end
        for(int lane=0;lane<DISPATCH_WIDTH;lane++) begin
            logic [$clog2(INT_IQ_DEPTH+1)-1:0] int_prior,int_left;
            logic [$clog2(MEM_IQ_DEPTH+1)-1:0] mem_prior,mem_left;
            logic [$clog2(BR_IQ_DEPTH+1)-1:0] br_prior,br_left;
            logic [$clog2(FP_IQ_DEPTH+1)-1:0] fp_prior,fp_left;
            logic supported,target_has_space;
            int_prior='0;mem_prior='0;br_prior='0;fp_prior='0;
            for(int older=0;older<lane;older++) if(older<int'(visible_count_i) && uop_i[older].valid) begin
                int_prior+=$clog2(INT_IQ_DEPTH+1)'(is_int[older]);
                mem_prior+=$clog2(MEM_IQ_DEPTH+1)'(is_mem[older]);
                br_prior+=$clog2(BR_IQ_DEPTH+1)'(is_br[older]);
                fp_prior+=$clog2(FP_IQ_DEPTH+1)'(is_fp[older]);
            end
            // Keep the original bounded subtraction even for exceptional or
            // overlapping classifications. Prefix rejection makes counts after
            // a blocked older lane unobservable; accepted prefixes are exact.
            int_left=int_free_count_i-int_prior;mem_left=mem_free_count_i-mem_prior;
            br_left=br_free_count_i-br_prior;fp_left=fp_free_count_i-fp_prior;
            supported=uop_i[lane].ext.fuse_role==o3_types_pkg::FUSE_MEMBER || is_fp[lane] || is_int[lane] || is_mem[lane] || is_br[lane] || uop_i[lane].ext.serialize || uop_i[lane].exception_valid;
            target_has_space=uop_i[lane].ext.fuse_role==o3_types_pkg::FUSE_MEMBER ||
                (is_int[lane] && int_left>0) || (is_mem[lane] && mem_left>0) ||
                (is_br[lane] && br_left>0) || (is_fp[lane] && fp_left>0) ||
                uop_i[lane].ext.serialize || uop_i[lane].exception_valid;
            if(uop_i[lane].ext.fuse_role==o3_types_pkg::FUSE_HEAD) begin
                if(lane+1>=DISPATCH_WIDTH) target_has_space=0;
                else target_has_space &= lane+1<int'(visible_count_i) && uop_i[lane+1].valid &&
                    uop_i[lane+1].ext.fuse_role==o3_types_pkg::FUSE_MEMBER;
            end
            feasible[lane]=!(lane<int'(visible_count_i) && uop_i[lane].valid) || (supported && target_has_space);
        end
        prefix_ok=!recovery_block_i;
        for(int lane=0;lane<DISPATCH_WIDTH;lane++) begin
            prefix_ok &= feasible[lane];
            if(prefix_ok && lane<int'(visible_count_i) && uop_i[lane].valid) begin
                int_lane_o[lane]=is_int[lane];mem_lane_o[lane]=is_mem[lane];
                br_lane_o[lane]=is_br[lane];fp_lane_o[lane]=is_fp[lane];
                accept_count_o+=COUNT_WIDTH'(1);
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
