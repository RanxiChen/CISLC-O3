// Scalar/vector observation wrapper; never changes DUT state.
module rename_stage_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    localparam int WIDTH = BACKEND_MACHINE_WIDTH,          // 目标 R2 宽度 CFG.rename.width（B01）
    localparam int NUM_PHYS_REGS = CFG.rename.int_phys_regs,
    localparam int NUM_FP_PHYS_REGS = CFG.rename.fp_phys_regs, // 框架新增，未接入
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int LQ_DEPTH = CFG.lsu.lq_depth,
    localparam int SQ_DEPTH = CFG.lsu.sq_depth,
    localparam int RDQ_DEPTH = CFG.rename.rdq_depth
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

    input logic [PREG_IDX_WIDTH-1:0] src1_preg_i [WIDTH-1:0],
    input logic [PREG_IDX_WIDTH-1:0] src2_preg_i [WIDTH-1:0],
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
,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_valid,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_instruction_id,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_rd,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_rd_write_en,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_is_load,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_is_store,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_needs_checkpoint,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_ftq_id,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_ftq_last,
output logic [$bits(decoded_uop_t)-1:0] fmt_decoded_uop_t_ext_ftq_slot,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_valid,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_instruction_id,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rob_idx,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_branch_mask,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rs1_read_en,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rs2_read_en,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_use_imm,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_src1_preg,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_src2_preg,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_is_load,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_is_store,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rd,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rd_write_en,
output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_dst_preg,
output logic [31:0] cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o
);
rename_stage #(.CFG(CFG)) dut (
.decoded_i(decoded_i),
.visible_count_i(visible_count_i),
.recovery_block_i(recovery_block_i),
.preg_free_count_i(preg_free_count_i),
.rob_free_count_i(rob_free_count_i),
.lq_free_count_i(lq_free_count_i),
.sq_free_count_i(sq_free_count_i),
.rdq_free_count_i(rdq_free_count_i),
.active_branch_mask_i(active_branch_mask_i),
.checkpoint_grant_i(checkpoint_grant_i),
.checkpoint_tag_i(checkpoint_tag_i),
.src1_preg_i(src1_preg_i),
.src2_preg_i(src2_preg_i),
.old_dst_preg_i(old_dst_preg_i),
.new_dst_preg_i(new_dst_preg_i),
.rob_idx_i(rob_idx_i),
.lq_idx_i(lq_idx_i),
.sq_idx_i(sq_idx_i),
.src1_from_older_lane_i(src1_from_older_lane_i),
.src2_from_older_lane_i(src2_from_older_lane_i),
.lane_accept_o(lane_accept_o),
.dst_alloc_req_o(dst_alloc_req_o),
.rob_alloc_req_o(rob_alloc_req_o),
.lq_alloc_req_o(lq_alloc_req_o),
.sq_alloc_req_o(sq_alloc_req_o),
.checkpoint_create_o(checkpoint_create_o),
.lane_branch_mask_o(lane_branch_mask_o),
.accept_count_o(accept_count_o),
.renamed_uop_o(renamed_uop_o)
);
always_comb begin decoded_uop_t v; v='0; v.valid='1; fmt_decoded_uop_t_valid=v; end
always_comb begin decoded_uop_t v; v='0; v.instruction_id='1; fmt_decoded_uop_t_instruction_id=v; end
always_comb begin decoded_uop_t v; v='0; v.rd='1; fmt_decoded_uop_t_rd=v; end
always_comb begin decoded_uop_t v; v='0; v.rd_write_en='1; fmt_decoded_uop_t_rd_write_en=v; end
always_comb begin decoded_uop_t v; v='0; v.is_load='1; fmt_decoded_uop_t_is_load=v; end
always_comb begin decoded_uop_t v; v='0; v.is_store='1; fmt_decoded_uop_t_is_store=v; end
always_comb begin decoded_uop_t v; v='0; v.needs_checkpoint='1; fmt_decoded_uop_t_needs_checkpoint=v; end
always_comb begin decoded_uop_t v; v='0; v.ftq_id='1; fmt_decoded_uop_t_ftq_id=v; end
always_comb begin decoded_uop_t v; v='0; v.ftq_last='1; fmt_decoded_uop_t_ftq_last=v; end
always_comb begin decoded_uop_t v; v='0; v.ext.ftq_slot='1; fmt_decoded_uop_t_ext_ftq_slot=v; end
always_comb begin renamed_uop_t v; v='0; v.valid='1; fmt_renamed_uop_t_valid=v; end
always_comb begin renamed_uop_t v; v='0; v.instruction_id='1; fmt_renamed_uop_t_instruction_id=v; end
always_comb begin renamed_uop_t v; v='0; v.rob_idx='1; fmt_renamed_uop_t_rob_idx=v; end
always_comb begin renamed_uop_t v; v='0; v.branch_mask='1; fmt_renamed_uop_t_branch_mask=v; end
always_comb begin renamed_uop_t v; v='0; v.rs1_read_en='1; fmt_renamed_uop_t_rs1_read_en=v; end
always_comb begin renamed_uop_t v; v='0; v.rs2_read_en='1; fmt_renamed_uop_t_rs2_read_en=v; end
always_comb begin renamed_uop_t v; v='0; v.use_imm='1; fmt_renamed_uop_t_use_imm=v; end
always_comb begin renamed_uop_t v; v='0; v.src1_preg='1; fmt_renamed_uop_t_src1_preg=v; end
always_comb begin renamed_uop_t v; v='0; v.src2_preg='1; fmt_renamed_uop_t_src2_preg=v; end
always_comb begin renamed_uop_t v; v='0; v.is_load='1; fmt_renamed_uop_t_is_load=v; end
always_comb begin renamed_uop_t v; v='0; v.is_store='1; fmt_renamed_uop_t_is_store=v; end
always_comb begin renamed_uop_t v; v='0; v.rd='1; fmt_renamed_uop_t_rd=v; end
always_comb begin renamed_uop_t v; v='0; v.rd_write_en='1; fmt_renamed_uop_t_rd_write_en=v; end
always_comb begin renamed_uop_t v; v='0; v.dst_preg='1; fmt_renamed_uop_t_dst_preg=v; end
assign cfg_width_o=BACKEND_MACHINE_WIDTH;
assign cfg_depth_o=CFG.rename.rdq_depth;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
endmodule
