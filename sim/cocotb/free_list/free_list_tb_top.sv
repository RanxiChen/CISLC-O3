// Scalar/vector observation wrapper; never changes DUT state.
module free_list_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    parameter  o3_types_pkg::reg_domain_e DOMAIN = o3_types_pkg::RD_INT,     // RD_INT / RD_FP，无默认值
    localparam int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int NUM_PHYS_REGS = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.rename.fp_phys_regs
                                                                   : CFG.rename.int_phys_regs,
    localparam int NUM_ARCH_REGS = o3_isa_pkg::NUM_ARCH_REGS,
    localparam int RELEASE_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    localparam int NUM_CHECKPOINTS = CFG.rename.checkpoints,
    // 整数域 p0 永久恒零且保留；FP 域没有恒零寄存器，f0 正常可写（B15）。
    localparam bit HAS_ZERO_REG = (DOMAIN == o3_types_pkg::RD_INT)
) (
    input logic flush_all_i,
    input logic [PREG_IDX_WIDTH-1:0] commit_new_preg_i [RELEASE_WIDTH-1:0],
    input logic commit_write_i [RELEASE_WIDTH-1:0],
    input  logic clk,
    input  logic rst,

    input  logic                              alloc_req_i [MACHINE_WIDTH-1:0],
    input  logic                              alloc_fire_i,
    output logic                              alloc_available_o,
    output logic [PREG_IDX_WIDTH-1:0]  alloc_preg_o [MACHINE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS+1)-1:0] free_count_o,

    input  logic                              release_valid_i [RELEASE_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0]  release_preg_i [RELEASE_WIDTH-1:0],

    input  logic                              checkpoint_create_i [MACHINE_WIDTH-1:0],
    input  branch_tag_t                       checkpoint_create_tag_i [MACHINE_WIDTH-1:0],
    input  branch_mask_t                      alloc_branch_mask_i [MACHINE_WIDTH-1:0],

    input  logic                              resolution_valid_i,
    input  logic                              resolution_mispredict_i,
    input  branch_tag_t                       resolution_tag_i
,
output logic [31:0] cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o
);
free_list #(.CFG(CFG), .DOMAIN(DOMAIN)) dut (
.clk(clk),
.flush_all_i(flush_all_i),
.commit_new_preg_i(commit_new_preg_i),.commit_write_i(commit_write_i),
.rst(rst),
.alloc_req_i(alloc_req_i),
.alloc_fire_i(alloc_fire_i),
.alloc_available_o(alloc_available_o),
.alloc_preg_o(alloc_preg_o),
.free_count_o(free_count_o),
.release_valid_i(release_valid_i),
.release_preg_i(release_preg_i),
.checkpoint_create_i(checkpoint_create_i),
.checkpoint_create_tag_i(checkpoint_create_tag_i),
.alloc_branch_mask_i(alloc_branch_mask_i),
.resolution_valid_i(resolution_valid_i),
.resolution_mispredict_i(resolution_mispredict_i),
.resolution_tag_i(resolution_tag_i)
);
assign cfg_width_o=BACKEND_MACHINE_WIDTH;
assign cfg_depth_o=CFG.rename.rdq_depth;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
endmodule
