// Scalar/vector observation wrapper; never changes DUT state.
module rename_dispatch_queue_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    localparam int ENQ_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int DEQ_WIDTH = CFG.dispatch.width,
    localparam int DEPTH = CFG.rename.rdq_depth
) (
    input logic clk,
    input logic rst,
    input renamed_uop_t [ENQ_WIDTH-1:0] enq_uop_i,
    input logic [$clog2(ENQ_WIDTH+1)-1:0] enq_count_i,
    input logic enq_fire_i,
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,
    output renamed_uop_t [DEQ_WIDTH-1:0] deq_uop_o,
    output logic [$clog2(DEQ_WIDTH+1)-1:0] deq_count_o,
    input logic [$clog2(DEQ_WIDTH+1)-1:0] deq_accept_count_i,
    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i
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
output logic [31:0] cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o
);
rename_dispatch_queue #(.CFG(CFG)) dut (
.clk(clk),
.rst(rst),
.enq_uop_i(enq_uop_i),
.enq_count_i(enq_count_i),
.enq_fire_i(enq_fire_i),
.free_count_o(free_count_o),
.deq_uop_o(deq_uop_o),
.deq_count_o(deq_count_o),
.deq_accept_count_i(deq_accept_count_i),
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
assign cfg_depth_o=CFG.rename.rdq_depth;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
endmodule
