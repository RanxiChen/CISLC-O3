// Scalar/vector observation wrapper; never changes DUT state.
module branch_checkpoint_file_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    localparam int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int NUM_CHECKPOINTS = CFG.rename.checkpoints,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int LQ_DEPTH = CFG.lsu.lq_depth,
    localparam int SQ_DEPTH = CFG.lsu.sq_depth
) (
    input  logic clk,
    input  logic rst,

    input  logic        alloc_req_i [MACHINE_WIDTH-1:0],
    output logic        alloc_grant_o [MACHINE_WIDTH-1:0],
    output branch_tag_t alloc_tag_o [MACHINE_WIDTH-1:0],

    input  logic        create_i [MACHINE_WIDTH-1:0],
    input  branch_mask_t create_parent_mask_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] create_rob_tail_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(LQ_DEPTH)-1:0] create_lq_tail_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(SQ_DEPTH)-1:0] create_sq_tail_i [MACHINE_WIDTH-1:0],

    input  logic        resolution_valid_i,
    input  logic        resolution_mispredict_i,
    input  branch_tag_t resolution_tag_i,

    output branch_mask_t active_mask_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] restore_rob_tail_o,
    output logic [$clog2(LQ_DEPTH)-1:0] restore_lq_tail_o,
    output logic [$clog2(SQ_DEPTH)-1:0] restore_sq_tail_o
,
output logic [31:0] cfg_lq_o, cfg_sq_o, cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o,
output branch_mask_t parent_obs_o [NUM_CHECKPOINTS-1:0]
);
branch_checkpoint_file #(.CFG(CFG)) dut (
.clk(clk),
.rst(rst),
.alloc_req_i(alloc_req_i),
.alloc_grant_o(alloc_grant_o),
.alloc_tag_o(alloc_tag_o),
.create_i(create_i),
.create_parent_mask_i(create_parent_mask_i),
.create_rob_tail_i(create_rob_tail_i),
.create_lq_tail_i(create_lq_tail_i),
.create_sq_tail_i(create_sq_tail_i),
.resolution_valid_i(resolution_valid_i),
.resolution_mispredict_i(resolution_mispredict_i),
.resolution_tag_i(resolution_tag_i),
.active_mask_o(active_mask_o),
.restore_rob_tail_o(restore_rob_tail_o),
.restore_lq_tail_o(restore_lq_tail_o),
.restore_sq_tail_o(restore_sq_tail_o)
);
assign cfg_lq_o=CFG.lsu.lq_depth;
assign cfg_sq_o=CFG.lsu.sq_depth;
assign cfg_width_o=BACKEND_MACHINE_WIDTH;
assign cfg_depth_o=CFG.rename.rdq_depth;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
for(genvar n=0;n<NUM_CHECKPOINTS;n++) assign parent_obs_o[n]=dut.parent_mask_q[n];
endmodule
