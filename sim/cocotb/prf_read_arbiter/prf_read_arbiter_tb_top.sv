// Scalar/vector observation wrapper; never changes DUT state.
module prf_read_arbiter_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    localparam int NUM_INT_ALUS    = CFG.exec.num_alu,
    localparam int PRF_READ_PORTS  = CFG.exec.int_prf_read_ports,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int PORT_W          = $clog2(PRF_READ_PORTS),
    localparam int ROB_W           = $clog2(NUM_ROB_ENTRIES)
) (
    input  logic                        issue_block_i,   // 现状：= branch_resolution.valid（B12 缺口 1）
    input  logic [ROB_W-1:0]            rob_head_i,

    input  renamed_uop_t [NUM_INT_ALUS-1:0] int_issue_uop_i,
    input  logic [NUM_INT_ALUS-1:0]     int_issue_valid_i,
    input  logic                        alu_regread_ready_i [NUM_INT_ALUS-1:0],
    input  renamed_uop_t                mem_issue_uop_i,
    input  logic                        mem_issue_valid_i,
    input  logic                        mem_accept_i,    // Memory 执行级可接收
    input  renamed_uop_t                br_issue_uop_i,
    input  logic                        br_issue_valid_i,
    input  logic                        branch_regread_ready_i,

    output logic [NUM_INT_ALUS-1:0]     int_read_grant_o,
    output logic                        mem_read_grant_o,
    output logic                        branch_read_grant_o,
    output logic [PORT_W-1:0]           int_src1_port_o [NUM_INT_ALUS-1:0],
    output logic [PORT_W-1:0]           int_src2_port_o [NUM_INT_ALUS-1:0],
    output logic [PORT_W-1:0]           mem_src1_port_o,
    output logic [PORT_W-1:0]           mem_src2_port_o,
    output logic [PORT_W-1:0]           branch_src1_port_o,
    output logic [PORT_W-1:0]           branch_src2_port_o,
    output logic [PREG_IDX_WIDTH-1:0]   prf_rd_addr_o [PRF_READ_PORTS-1:0]
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
prf_read_arbiter #(.CFG(CFG)) dut (
.issue_block_i(issue_block_i),
.rob_head_i(rob_head_i),
.int_issue_uop_i(int_issue_uop_i),
.int_issue_valid_i(int_issue_valid_i),
.alu_regread_ready_i(alu_regread_ready_i),
.mem_issue_uop_i(mem_issue_uop_i),
.mem_issue_valid_i(mem_issue_valid_i),
.mem_accept_i(mem_accept_i),
.br_issue_uop_i(br_issue_uop_i),
.br_issue_valid_i(br_issue_valid_i),
.branch_regread_ready_i(branch_regread_ready_i),
.int_read_grant_o(int_read_grant_o),
.mem_read_grant_o(mem_read_grant_o),
.branch_read_grant_o(branch_read_grant_o),
.int_src1_port_o(int_src1_port_o),
.int_src2_port_o(int_src2_port_o),
.mem_src1_port_o(mem_src1_port_o),
.mem_src2_port_o(mem_src2_port_o),
.branch_src1_port_o(branch_src1_port_o),
.branch_src2_port_o(branch_src2_port_o),
.prf_rd_addr_o(prf_rd_addr_o)
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
