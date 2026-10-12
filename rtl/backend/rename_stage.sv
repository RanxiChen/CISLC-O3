/**
 * Four-lane atomic prefix rename planner (B02/B15/B42).
 * Budgets INT and FP physical registers separately, plus ROB/RDQ/LQ/SQ/checkpoints.
 * Every accepted lane receives all required resources; the first unavailable resource
 * blocks that lane and younger ones. FP f0 needs a register; INT x0 does not.
 * Third-source mapping and resolved FP control are carried through renamed_uop.rext/ext.
 * Integer MUL fusion still requires complete pair resources before accepting HEAD.
 * 当前实现状态：目标实现。R2 原子资源前缀；输入来自 R1 暂存，旁路使用已寄存依赖。
 * No internal state: N computes resource prefix then assembles mapped uops; N edge
 * downstream tables allocate that prefix, N+1 RDQ holds complete renamed identities.
 * 本次 lint/测试未运行。
 */
module rename_stage
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int WIDTH = BACKEND_MACHINE_WIDTH,          // 目标 R2 宽度 CFG.rename.width（B01）
    localparam int NUM_PHYS_REGS = CFG.rename.int_phys_regs,
    localparam int NUM_FP_PHYS_REGS = CFG.rename.fp_phys_regs,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int LQ_DEPTH = CFG.lsu.lq_depth,
    localparam int SQ_DEPTH = CFG.lsu.sq_depth,
    localparam int RDQ_DEPTH = CFG.rename.rdq_depth
) (
    input decoded_uop_t [WIDTH-1:0] decoded_i,
    input logic [$clog2(WIDTH+1)-1:0] visible_count_i,
    input logic recovery_block_i,

    input logic [$clog2(NUM_PHYS_REGS+1)-1:0] preg_free_count_i,
    input logic [$clog2(NUM_FP_PHYS_REGS+1)-1:0] fp_preg_free_count_i,
    input logic [$clog2(NUM_ROB_ENTRIES+1)-1:0] rob_free_count_i,
    input logic [$clog2(LQ_DEPTH+1)-1:0] lq_free_count_i,
    input logic [$clog2(SQ_DEPTH+1)-1:0] sq_free_count_i,
    input logic [$clog2(RDQ_DEPTH+1)-1:0] rdq_free_count_i,
    input branch_mask_t active_branch_mask_i,
    input logic checkpoint_grant_i [WIDTH-1:0],
    input branch_tag_t checkpoint_tag_i [WIDTH-1:0],

    input logic [PREG_IDX_WIDTH-1:0] src1_preg_i [WIDTH-1:0],
    input logic [PREG_IDX_WIDTH-1:0] src2_preg_i [WIDTH-1:0],
    input logic [PREG_IDX_WIDTH-1:0] src3_preg_i [WIDTH-1:0],
    input logic [PREG_IDX_WIDTH-1:0] old_dst_preg_i [WIDTH-1:0],
    input logic [PREG_IDX_WIDTH-1:0] new_dst_preg_i [WIDTH-1:0],
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
    // Decode-only demand prefixes are independent of free-resource counts.
    // All capacity comparisons run in parallel, followed by a prefix AND.
    // No lane subtracts an accepted predecessor from a resource budget.
    logic [WIDTH-1:0] demand_preg,demand_fp,demand_lq,demand_sq,visible_live;
    logic [WIDTH-1:0] lane_ok;
    always_comb begin
        demand_preg='0; demand_fp='0; demand_lq='0; demand_sq='0; visible_live='0;
        for(int lane=0;lane<WIDTH;lane++) begin
            visible_live[lane]=lane<int'(visible_count_i) && decoded_i[lane].valid;
            demand_preg[lane]=visible_live[lane] && decoded_i[lane].rd_write_en &&
                (decoded_i[lane].ext.rd_dom==o3_types_pkg::RD_FP || decoded_i[lane].rd!='0);
            demand_fp[lane]=demand_preg[lane] && decoded_i[lane].ext.rd_dom==o3_types_pkg::RD_FP;
            demand_lq[lane]=visible_live[lane] && decoded_i[lane].is_load;
            demand_sq[lane]=visible_live[lane] && decoded_i[lane].is_store;
        end
    end
    always_comb begin
        lane_ok='1;
        for(int lane=0;lane<WIDTH;lane++) begin
            logic [LANE_COUNT_WIDTH-1:0] int_need,fp_need,rob_need,lq_need,sq_need;
            int_need='0; fp_need='0; rob_need='0; lq_need='0; sq_need='0;
            for(int older=0;older<=lane;older++) begin
                int_need+=LANE_COUNT_WIDTH'(demand_preg[older] && !demand_fp[older]);
                fp_need+=LANE_COUNT_WIDTH'(demand_fp[older]);
                rob_need+=LANE_COUNT_WIDTH'(visible_live[older]);
                lq_need+=LANE_COUNT_WIDTH'(demand_lq[older]);
                sq_need+=LANE_COUNT_WIDTH'(demand_sq[older]);
            end
            if(visible_live[lane]) begin
                lane_ok[lane]=int'(preg_free_count_i)>=int'(int_need) &&
                    int'(fp_preg_free_count_i)>=int'(fp_need) &&
                    int'(rob_free_count_i)>=int'(rob_need) && int'(rdq_free_count_i)>=int'(rob_need) &&
                    int'(lq_free_count_i)>=int'(lq_need) && int'(sq_free_count_i)>=int'(sq_need) &&
                    (!decoded_i[lane].needs_checkpoint || checkpoint_grant_i[lane]);
                // Preserve legacy integer-pair HEAD lookahead, including the
                // original generic-field rules for malformed fusion inputs.
                if(decoded_i[lane].ext.fuse_role==o3_types_pkg::FUSE_HEAD) begin
                    if(lane+1>=WIDTH) lane_ok[lane]=0;
                    else lane_ok[lane]&=lane+1<int'(visible_count_i) && decoded_i[lane+1].valid &&
                        decoded_i[lane+1].ext.fuse_role==o3_types_pkg::FUSE_MEMBER &&
                        int'(rob_free_count_i)>=int'(rob_need)+1 && int'(rdq_free_count_i)>=int'(rob_need)+1 &&
                        int'(preg_free_count_i)>=int'(int_need)+int'(demand_fp[lane])+
                            int'(decoded_i[lane+1].rd_write_en && decoded_i[lane+1].rd!=0);
                end
            end
        end
    end
    always_comb begin
        lane_accept_o='{default:0}; dst_alloc_req_o='{default:0}; rob_alloc_req_o='{default:0};
        lq_alloc_req_o='{default:0}; sq_alloc_req_o='{default:0}; checkpoint_create_o='{default:0};
        lane_branch_mask_o='{default:'0}; accept_count_o='0;
        for(int lane=0;lane<WIDTH;lane++) begin
            logic prefix_ok;
            prefix_ok=!recovery_block_i;
            for(int older=0;older<=lane;older++) prefix_ok &= lane_ok[older];
            lane_accept_o[lane]=visible_live[lane] && prefix_ok;
            dst_alloc_req_o[lane]=lane_accept_o[lane] && demand_preg[lane];
            rob_alloc_req_o[lane]=lane_accept_o[lane];
            lq_alloc_req_o[lane]=lane_accept_o[lane] && demand_lq[lane];
            sq_alloc_req_o[lane]=lane_accept_o[lane] && demand_sq[lane];
            checkpoint_create_o[lane]=lane_accept_o[lane] && decoded_i[lane].needs_checkpoint;
            accept_count_o+=LANE_COUNT_WIDTH'(lane_accept_o[lane]);
        end
        for(int lane=0;lane<WIDTH;lane++) begin
            lane_branch_mask_o[lane]=active_branch_mask_i;
            for(int older=0;older<lane;older++)
                if(checkpoint_create_o[older]) lane_branch_mask_o[lane][checkpoint_tag_i[older]]=1;
        end
    end

    // 资源前缀已经独立确定后，再把映射表和各队列给出的候选编号装入uop。
    // 分开两个组合块避免候选编号反向参与accept决策形成伪组合环。
    always_comb begin
        renamed_uop_o = '{default: '0};
        for (int lane = 0; lane < WIDTH; lane++) begin
            logic need_preg, need_lq, need_sq, need_cp;
            need_preg = decoded_i[lane].valid && decoded_i[lane].rd_write_en && (decoded_i[lane].ext.rd_dom == o3_types_pkg::RD_FP || decoded_i[lane].rd != '0);
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
            renamed_uop_o[lane].ftq_id = decoded_i[lane].ftq_id;
            renamed_uop_o[lane].ext = decoded_i[lane].ext;          // 框架新增字段原样传递
            renamed_uop_o[lane].ftq_last = decoded_i[lane].ftq_last;
            renamed_uop_o[lane].predicted_next_pc = decoded_i[lane].predicted_next_pc;
            renamed_uop_o[lane].rs1 = decoded_i[lane].rs1;
            renamed_uop_o[lane].rs2 = decoded_i[lane].rs2;
            renamed_uop_o[lane].rd = decoded_i[lane].rd;
            renamed_uop_o[lane].rs1_read_en = decoded_i[lane].rs1_read_en;
            renamed_uop_o[lane].rs2_read_en = decoded_i[lane].rs2_read_en;
            renamed_uop_o[lane].rd_write_en = decoded_i[lane].rd_write_en;
            renamed_uop_o[lane].src1_is_pc = decoded_i[lane].src1_is_pc;
            renamed_uop_o[lane].use_imm = decoded_i[lane].use_imm;
            renamed_uop_o[lane].imm_type = decoded_i[lane].imm_type;
            renamed_uop_o[lane].imm_raw = decoded_i[lane].imm_raw;
            renamed_uop_o[lane].int_alu_op = decoded_i[lane].int_alu_op;
            renamed_uop_o[lane].is_word_op = decoded_i[lane].is_word_op;
            renamed_uop_o[lane].is_int_uop = decoded_i[lane].is_int_uop;
            renamed_uop_o[lane].is_load = decoded_i[lane].is_load;
            renamed_uop_o[lane].is_store = decoded_i[lane].is_store;
            renamed_uop_o[lane].mem_size = decoded_i[lane].mem_size;
            renamed_uop_o[lane].mem_unsigned = decoded_i[lane].mem_unsigned;
            renamed_uop_o[lane].is_branch = decoded_i[lane].is_branch;
            renamed_uop_o[lane].is_jal = decoded_i[lane].is_jal;
            renamed_uop_o[lane].is_jalr = decoded_i[lane].is_jalr;
            renamed_uop_o[lane].branch_cond = decoded_i[lane].branch_cond;
            renamed_uop_o[lane].needs_checkpoint = decoded_i[lane].needs_checkpoint;
            renamed_uop_o[lane].src1_preg = src1_preg_i[lane];
            renamed_uop_o[lane].src2_preg = src2_preg_i[lane];
            renamed_uop_o[lane].rext.src3_preg = src3_preg_i[lane];
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
