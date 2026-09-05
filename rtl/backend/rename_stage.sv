/**
 * Four-wide prefix Rename planner and uop assembler
 *
 * 本模块无状态。从Decode Queue的最老lane开始累计检查ROB、preg、LQ、SQ、
 * branch checkpoint和Rename/Dispatch Queue资源，产生本拍可原子接受的最大前缀。
 * 一旦某条指令缺少任一资源，该条和所有更年轻lane都停止；更老可行前缀仍推进。
 */
module rename_stage
    import o3_pkg::*;
#(
    parameter int WIDTH = 4,
    parameter int NUM_PHYS_REGS = BACKEND_NUM_PHYS_REGS,
    parameter int NUM_ROB_ENTRIES = BACKEND_NUM_ROB_ENTRIES,
    parameter int LQ_DEPTH = BACKEND_LOAD_QUEUE_DEPTH,
    parameter int SQ_DEPTH = BACKEND_STORE_QUEUE_DEPTH,
    parameter int RDQ_DEPTH = BACKEND_RENAME_DISPATCH_QUEUE_DEPTH
) (
    input decoded_uop_t [WIDTH-1:0] decoded_i,
    input logic [$clog2(WIDTH+1)-1:0] visible_count_i,
    input logic recovery_block_i,

    input logic [$clog2(NUM_PHYS_REGS+1)-1:0] preg_free_count_i,
    input logic [$clog2(NUM_ROB_ENTRIES+1)-1:0] rob_free_count_i,
    input logic [$clog2(LQ_DEPTH+1)-1:0] lq_free_count_i,
    input logic [$clog2(SQ_DEPTH+1)-1:0] sq_free_count_i,
    input logic [$clog2(RDQ_DEPTH+1)-1:0] rdq_free_count_i,
    input branch_mask_t active_branch_mask_i,
    input logic checkpoint_grant_i [WIDTH-1:0],
    input branch_tag_t checkpoint_tag_i [WIDTH-1:0],

    input logic [$clog2(NUM_PHYS_REGS)-1:0] src1_preg_i [WIDTH-1:0],
    input logic [$clog2(NUM_PHYS_REGS)-1:0] src2_preg_i [WIDTH-1:0],
    input logic [$clog2(NUM_PHYS_REGS)-1:0] old_dst_preg_i [WIDTH-1:0],
    input logic [$clog2(NUM_PHYS_REGS)-1:0] new_dst_preg_i [WIDTH-1:0],
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_idx_i [WIDTH-1:0],
    input logic [$clog2(LQ_DEPTH)-1:0] lq_idx_i [WIDTH-1:0],
    input logic [$clog2(SQ_DEPTH)-1:0] sq_idx_i [WIDTH-1:0],
    input logic src1_from_older_lane_i [WIDTH-1:0],
    input logic src2_from_older_lane_i [WIDTH-1:0],

    output logic lane_accept_o [WIDTH-1:0],
    output logic dst_alloc_req_o [WIDTH-1:0],
    output logic rob_alloc_req_o [WIDTH-1:0],
    output logic lq_alloc_req_o [WIDTH-1:0],
    output logic sq_alloc_req_o [WIDTH-1:0],
    output logic checkpoint_create_o [WIDTH-1:0],
    output branch_mask_t lane_branch_mask_o [WIDTH-1:0],
    output logic [$clog2(WIDTH+1)-1:0] accept_count_o,
    output renamed_uop_t [WIDTH-1:0] renamed_uop_o
);
    localparam int LANE_COUNT_WIDTH = $clog2(WIDTH + 1);
    always_comb begin
        int unsigned preg_left, rob_left, lq_left, sq_left, rdq_left;
        logic blocked;
        branch_mask_t running_mask;

        preg_left = int'(preg_free_count_i);
        rob_left = int'(rob_free_count_i);
        lq_left = int'(lq_free_count_i);
        sq_left = int'(sq_free_count_i);
        rdq_left = int'(rdq_free_count_i);
        blocked = recovery_block_i;
        running_mask = active_branch_mask_i;
        accept_count_o = '0;
        lane_accept_o = '{default: 1'b0};
        dst_alloc_req_o = '{default: 1'b0};
        rob_alloc_req_o = '{default: 1'b0};
        lq_alloc_req_o = '{default: 1'b0};
        sq_alloc_req_o = '{default: 1'b0};
        checkpoint_create_o = '{default: 1'b0};
        lane_branch_mask_o = '{default: '0};

        for (int lane = 0; lane < WIDTH; lane++) begin
            logic need_preg, need_lq, need_sq, need_cp, can_accept;
            need_preg = decoded_i[lane].valid && decoded_i[lane].rd_write_en && (decoded_i[lane].rd != '0);
            need_lq = decoded_i[lane].valid && decoded_i[lane].is_load;
            need_sq = decoded_i[lane].valid && decoded_i[lane].is_store;
            need_cp = decoded_i[lane].valid && decoded_i[lane].needs_checkpoint;

            can_accept = !blocked && (lane < int'(visible_count_i)) && decoded_i[lane].valid
                       && (rob_left > 0) && (rdq_left > 0)
                       && (!need_preg || (preg_left > 0))
                       && (!need_lq || (lq_left > 0))
                       && (!need_sq || (sq_left > 0))
                       && (!need_cp || checkpoint_grant_i[lane]);

            lane_branch_mask_o[lane] = running_mask;
            if (can_accept) begin
                lane_accept_o[lane] = 1'b1;
                rob_alloc_req_o[lane] = 1'b1;
                dst_alloc_req_o[lane] = need_preg;
                lq_alloc_req_o[lane] = need_lq;
                sq_alloc_req_o[lane] = need_sq;
                checkpoint_create_o[lane] = need_cp;
                accept_count_o = accept_count_o + LANE_COUNT_WIDTH'(1);
                rob_left--;
                rdq_left--;
                if (need_preg) preg_left--;
                if (need_lq) lq_left--;
                if (need_sq) sq_left--;
                if (need_cp) running_mask[checkpoint_tag_i[lane]] = 1'b1;
            end else if ((lane < int'(visible_count_i)) && decoded_i[lane].valid) begin
                blocked = 1'b1;
            end

        end
    end

    // 资源前缀已经独立确定后，再把映射表和各队列给出的候选编号装入uop。
    // 分开两个组合块避免候选编号反向参与accept决策形成伪组合环。
    always_comb begin
        renamed_uop_o = '{default: '0};
        for (int lane = 0; lane < WIDTH; lane++) begin
            logic need_preg, need_lq, need_sq, need_cp;
            need_preg = decoded_i[lane].valid && decoded_i[lane].rd_write_en && (decoded_i[lane].rd != '0);
            need_lq = decoded_i[lane].valid && decoded_i[lane].is_load;
            need_sq = decoded_i[lane].valid && decoded_i[lane].is_store;
            need_cp = decoded_i[lane].valid && decoded_i[lane].needs_checkpoint;

            renamed_uop_o[lane].valid = lane_accept_o[lane];
            renamed_uop_o[lane].instruction_id = decoded_i[lane].instruction_id;
`ifdef O3_SIM
            renamed_uop_o[lane].kanata_id = decoded_i[lane].kanata_id;
`endif
            renamed_uop_o[lane].pc = decoded_i[lane].pc;
            renamed_uop_o[lane].raw_instruction = decoded_i[lane].raw_instruction;
            renamed_uop_o[lane].instruction = decoded_i[lane].instruction;
            renamed_uop_o[lane].inst_len = decoded_i[lane].inst_len;
            renamed_uop_o[lane].is_rvc = decoded_i[lane].is_rvc;
            renamed_uop_o[lane].exception_valid = decoded_i[lane].exception_valid;
            renamed_uop_o[lane].exception_cause = decoded_i[lane].exception_cause;
            renamed_uop_o[lane].exception_tval = decoded_i[lane].exception_tval;
            renamed_uop_o[lane].rs1 = decoded_i[lane].rs1;
            renamed_uop_o[lane].rs2 = decoded_i[lane].rs2;
            renamed_uop_o[lane].rd = decoded_i[lane].rd;
            renamed_uop_o[lane].rs1_read_en = decoded_i[lane].rs1_read_en;
            renamed_uop_o[lane].rs2_read_en = decoded_i[lane].rs2_read_en;
            renamed_uop_o[lane].rd_write_en = decoded_i[lane].rd_write_en;
            renamed_uop_o[lane].use_imm = decoded_i[lane].use_imm;
            renamed_uop_o[lane].imm_type = decoded_i[lane].imm_type;
            renamed_uop_o[lane].imm_raw = decoded_i[lane].imm_raw;
            renamed_uop_o[lane].int_alu_op = decoded_i[lane].int_alu_op;
            renamed_uop_o[lane].is_int_uop = decoded_i[lane].is_int_uop;
            renamed_uop_o[lane].is_load = decoded_i[lane].is_load;
            renamed_uop_o[lane].is_store = decoded_i[lane].is_store;
            renamed_uop_o[lane].mem_size = decoded_i[lane].mem_size;
            renamed_uop_o[lane].mem_unsigned = decoded_i[lane].mem_unsigned;
            renamed_uop_o[lane].is_branch = decoded_i[lane].is_branch;
            renamed_uop_o[lane].is_jal = decoded_i[lane].is_jal;
            renamed_uop_o[lane].is_jalr = decoded_i[lane].is_jalr;
            renamed_uop_o[lane].needs_checkpoint = decoded_i[lane].needs_checkpoint;
            renamed_uop_o[lane].src1_preg = src1_preg_i[lane];
            renamed_uop_o[lane].src2_preg = src2_preg_i[lane];
            renamed_uop_o[lane].dst_preg = need_preg ? new_dst_preg_i[lane] : '0;
            renamed_uop_o[lane].old_dst_preg = need_preg ? old_dst_preg_i[lane] : '0;
            renamed_uop_o[lane].rob_idx = rob_idx_i[lane];
            renamed_uop_o[lane].lq_idx = need_lq ? lq_idx_i[lane] : '0;
            renamed_uop_o[lane].sq_idx = need_sq ? sq_idx_i[lane] : '0;
            renamed_uop_o[lane].branch_mask = lane_branch_mask_o[lane];
            renamed_uop_o[lane].branch_tag = need_cp ? checkpoint_tag_i[lane] : '0;
        end
    end
endmodule
