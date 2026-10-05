// Scalar/vector observation wrapper; never changes DUT state.
module rename_map_table_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    parameter  o3_types_pkg::reg_domain_e DOMAIN = o3_types_pkg::RD_INT,     // RD_INT / RD_FP，无默认值
    localparam int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int NUM_ARCH_REGS = o3_isa_pkg::NUM_ARCH_REGS,
    localparam int NUM_PHYS_REGS = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.rename.fp_phys_regs
                                                                   : CFG.rename.int_phys_regs,
    localparam int NUM_CHECKPOINTS = CFG.rename.checkpoints,
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    // 整数域 x0 恒映射 p0；FP 域 f0 正常可写，不做恒零映射（B15）。
    localparam bit HAS_ZERO_REG = (DOMAIN == o3_types_pkg::RD_INT)
) (
    input  logic clk,
    input  logic rst,

    input  logic                             rename_fire_i,
    input  logic                             lane_valid_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rs1_addr_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rs2_addr_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rd_addr_i [MACHINE_WIDTH-1:0],
    input  logic                             rs1_read_en_i [MACHINE_WIDTH-1:0],
    input  logic                             rs2_read_en_i [MACHINE_WIDTH-1:0],
    input  logic                             rd_write_en_i [MACHINE_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0] new_dst_preg_i [MACHINE_WIDTH-1:0],

    input  logic                             checkpoint_create_i [MACHINE_WIDTH-1:0],
    input  branch_tag_t                      checkpoint_create_tag_i [MACHINE_WIDTH-1:0],
    input  logic                             resolution_valid_i,
    input  logic                             resolution_mispredict_i,
    input  branch_tag_t                      resolution_tag_i,

    input  logic                             commit_valid_i [COMMIT_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] commit_rd_i [COMMIT_WIDTH-1:0],
    input  logic                             commit_rd_write_en_i [COMMIT_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0] commit_new_preg_i [COMMIT_WIDTH-1:0],

    output logic [PREG_IDX_WIDTH-1:0] src1_preg_o [MACHINE_WIDTH-1:0],
    output logic [PREG_IDX_WIDTH-1:0] src2_preg_o [MACHINE_WIDTH-1:0],
    output logic [PREG_IDX_WIDTH-1:0] old_dst_preg_o [MACHINE_WIDTH-1:0],
    output logic                             src1_from_older_lane_o [MACHINE_WIDTH-1:0],
    output logic                             src2_from_older_lane_o [MACHINE_WIDTH-1:0]
,
output logic [31:0] cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o
);
rename_map_table #(.CFG(CFG), .DOMAIN(DOMAIN)) dut (
.clk(clk),
.rst(rst),
.rename_fire_i(rename_fire_i),
.lane_valid_i(lane_valid_i),
.rs1_addr_i(rs1_addr_i),
.rs2_addr_i(rs2_addr_i),
.rd_addr_i(rd_addr_i),
.rs1_read_en_i(rs1_read_en_i),
.rs2_read_en_i(rs2_read_en_i),
.rd_write_en_i(rd_write_en_i),
.new_dst_preg_i(new_dst_preg_i),
.checkpoint_create_i(checkpoint_create_i),
.checkpoint_create_tag_i(checkpoint_create_tag_i),
.resolution_valid_i(resolution_valid_i),
.resolution_mispredict_i(resolution_mispredict_i),
.resolution_tag_i(resolution_tag_i),
.commit_valid_i(commit_valid_i),
.commit_rd_i(commit_rd_i),
.commit_rd_write_en_i(commit_rd_write_en_i),
.commit_new_preg_i(commit_new_preg_i),
.src1_preg_o(src1_preg_o),
.src2_preg_o(src2_preg_o),
.old_dst_preg_o(old_dst_preg_o),
.src1_from_older_lane_o(src1_from_older_lane_o),
.src2_from_older_lane_o(src2_from_older_lane_o)
);
assign cfg_width_o=BACKEND_MACHINE_WIDTH;
assign cfg_depth_o=CFG.rename.rdq_depth;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
endmodule
