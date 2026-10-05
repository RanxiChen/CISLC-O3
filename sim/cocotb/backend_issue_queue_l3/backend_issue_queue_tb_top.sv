// Scalar/vector observation wrapper; never changes DUT state.
module backend_issue_queue_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    parameter  o3_types_pkg::iq_kind_e KIND = o3_types_pkg::IQ_INT,          // 实例选择，无默认值
    localparam int ENQ_WIDTH = CFG.dispatch.width,
    localparam int ISSUE_WIDTH = (KIND == o3_types_pkg::IQ_INT) ? CFG.exec.num_alu : 1,  // MEM/BR 现状单发射；FP 待定
    localparam int WAKEUP_WIDTH = CFG.exec.int_prf_write_ports,
    localparam int DEPTH = (KIND == o3_types_pkg::IQ_INT) ? CFG.dispatch.int_iq_depth
                         : (KIND == o3_types_pkg::IQ_MEM) ? CFG.dispatch.mem_iq_depth
                         : (KIND == o3_types_pkg::IQ_BR)  ? CFG.dispatch.br_iq_depth
                         : CFG.dispatch.fp_iq_depth,
    localparam int NUM_PHYS_REGS = (KIND == o3_types_pkg::IQ_FP) ? CFG.rename.fp_phys_regs : CFG.rename.int_phys_regs,
    localparam bit OLDEST_ONLY = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  renamed_uop_t [ENQ_WIDTH-1:0] enq_uop_i,
    input  logic enq_fire_i,
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,

    input  logic preg_ready_i [NUM_PHYS_REGS-1:0],
    input  logic allow_load_i,  // Memory replay 槽已占用/将占用时仍可选 store
    input  logic wakeup_valid_i [WAKEUP_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0] wakeup_preg_i [WAKEUP_WIDTH-1:0],
    output renamed_uop_t [ISSUE_WIDTH-1:0] issue_uop_o,
    output logic [ISSUE_WIDTH-1:0] issue_valid_o,
    input  logic [ISSUE_WIDTH-1:0] issue_ready_i,

    input  logic resolution_valid_i,
    input  logic resolution_mispredict_i,
    input  branch_tag_t resolution_tag_i
,
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
output logic [31:0] cfg_kind_o, cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o
);
backend_issue_queue #(.CFG(CFG), .KIND(KIND)) dut (
.clk(clk),
.rst(rst),
.enq_uop_i(enq_uop_i),
.enq_fire_i(enq_fire_i),
.free_count_o(free_count_o),
.preg_ready_i(preg_ready_i),
.allow_load_i(allow_load_i),
.wakeup_valid_i(wakeup_valid_i),
.wakeup_preg_i(wakeup_preg_i),
.issue_uop_o(issue_uop_o),
.issue_valid_o(issue_valid_o),
.issue_ready_i(issue_ready_i),
.resolution_valid_i(resolution_valid_i),
.resolution_mispredict_i(resolution_mispredict_i),
.resolution_tag_i(resolution_tag_i)
);
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
assign cfg_depth_o=DEPTH;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
assign cfg_kind_o=KIND;
endmodule
