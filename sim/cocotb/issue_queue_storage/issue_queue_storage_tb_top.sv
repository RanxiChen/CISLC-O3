/**
 * Domain-qualified backend issue queue (B14/B15/B33).
 * Every source has a domain and cached readiness; wake/ready checks compare only the
 * corresponding register domain. src3 participates in FMA dependencies. No same-cycle
 * wake-select bypass: a received writeback becomes selectable on the following cycle.
 * FP: depth CFG.dispatch.fp_iq_depth, oldest-ready dual issue; five RegRead capacities
 * prevent repeated FU selection, at most one INT-source FP candidate per cycle.
 * INT: independent selection width and FU-buffer capacity, fused-pair handling.
 * MEM: two oldest-ready candidates; LQ/SQ/cache capacities arbitrate after its buffers.
 * INT selection budgets per-FU issue-buffer capacity. Only a buffer enqueue handshake
 * deletes an INT candidate; read-port denial keeps it in the buffer, outside this IQ.
 * FP/MEM also leave IQ on registered issue-buffer acceptance; BR retains direct reads.
 * Correct resolution clears masks; misprediction removes dependent younger entries.
 * Notices and ready bits permit scheduling only. Buffer read grants recheck real data.
 * 当前实现状态：闭环简化（L9）；本次重构尚未功能验证。
 * N: select stored-ready candidates and form next queue. N edge: delete accepted candidates,
 * update source readiness, compact narrow slot indices and append dispatch lanes. N+1: new candidates.
 * 测试：sim/cocotb/backend_issue_queue/（MEM load 顺序、store bypass、replay 门控）。
 */
module issue_queue_storage_tb_top
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG=o3_cfg_pkg::O3_CFG.be,
    parameter  o3_types_pkg::iq_kind_e KIND=o3_types_pkg::IQ_INT,          // 实例选择，无默认值
    localparam int ENQ_WIDTH = CFG.dispatch.width,
    localparam int ISSUE_WIDTH = (KIND == o3_types_pkg::IQ_INT) ? CFG.exec.int_issue_width : (KIND == o3_types_pkg::IQ_FP ? 2 : (KIND==o3_types_pkg::IQ_MEM ? CFG.lsu.agu_pipes:1)),
    parameter int WAKEUP_WIDTH = CFG.exec.int_prf_write_ports+2*(CFG.exec.num_alu+2+5+CFG.lsu.agu_pipes)+1,
    parameter int FP_WAKEUP_WIDTH = CFG.exec.fp_prf_write_ports+2*(CFG.exec.num_alu+2+5+CFG.lsu.agu_pipes)+1,
    localparam int DEPTH = (KIND == o3_types_pkg::IQ_INT) ? CFG.dispatch.int_iq_depth
                         : (KIND == o3_types_pkg::IQ_MEM) ? CFG.dispatch.mem_iq_depth
                         : (KIND == o3_types_pkg::IQ_BR)  ? CFG.dispatch.br_iq_depth
                         : CFG.dispatch.fp_iq_depth,
    localparam int NUM_PHYS_REGS = CFG.rename.int_phys_regs,
    localparam bit OLDEST_ONLY = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  renamed_uop_t [ENQ_WIDTH-1:0] enq_uop_i,
    input  logic enq_fire_i,
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,

    input  logic preg_ready_i [NUM_PHYS_REGS-1:0],
    input logic fp_preg_ready_i [CFG.rename.fp_phys_regs-1:0],
    input logic fp_wakeup_valid_i [FP_WAKEUP_WIDTH-1:0],
    input logic [PREG_IDX_WIDTH-1:0] fp_wakeup_preg_i [FP_WAKEUP_WIDTH-1:0],
    // FU indices: FMA0, FMA1, DIVSQRT, MISC, CONV; capacity of RegRead slots.
    input logic [4:0] fp_regread_ready_i,
    output logic [2:0] issue_fp_fu_o [ISSUE_WIDTH-1:0],
    output logic [$clog2(CFG.exec.num_alu+2)-1:0] issue_int_fu_o[ISSUE_WIDTH-1:0],
    input  logic mul_ready_i, mul_pair_ready_i, div_ready_i,
    // INT: destination issue-buffer capacities. Default preserves standalone callers.
    input logic [CFG.exec.num_alu-1:0] alu_buffer_ready_i = '1,
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
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_branch_mask,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_lo_mask,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_fuse_valid,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_fu_class,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rs1_read_en,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rs2_read_en,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rs3_read_en,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_src1_preg,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_src2_preg,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_src3_preg,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rs1_dom,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rs2_dom,
    output logic [$bits(renamed_uop_t)-1:0] fmt_renamed_uop_t_rs3_dom,
    output logic [31:0] cfg_width_o,cfg_issue_o,cfg_depth_o,cfg_alu_o,cfg_tags_o
);
backend_issue_queue #(.CFG(CFG),.KIND(KIND),.WAKEUP_WIDTH(WAKEUP_WIDTH),.FP_WAKEUP_WIDTH(FP_WAKEUP_WIDTH)) dut(.*);
always_comb begin renamed_uop_t u;u='0;u.valid='1;fmt_renamed_uop_t_valid=u;end
always_comb begin renamed_uop_t u;u='0;u.branch_mask='1;fmt_renamed_uop_t_branch_mask=u;end
always_comb begin renamed_uop_t u;u='0;u.mdu_fuse.lo_tag.br_mask='1;fmt_renamed_uop_t_lo_mask=u;end
always_comb begin renamed_uop_t u;u='0;u.mdu_fuse.valid='1;fmt_renamed_uop_t_fuse_valid=u;end
always_comb begin renamed_uop_t u;u='0;u.ext.fu_class=o3_types_pkg::fu_class_e'('1);fmt_renamed_uop_t_fu_class=u;end
always_comb begin renamed_uop_t u;u='0;u.rs1_read_en='1;fmt_renamed_uop_t_rs1_read_en=u;end
always_comb begin renamed_uop_t u;u='0;u.rs2_read_en='1;fmt_renamed_uop_t_rs2_read_en=u;end
always_comb begin renamed_uop_t u;u='0;u.ext.rs3_read_en='1;fmt_renamed_uop_t_rs3_read_en=u;end
always_comb begin renamed_uop_t u;u='0;u.src1_preg='1;fmt_renamed_uop_t_src1_preg=u;end
always_comb begin renamed_uop_t u;u='0;u.src2_preg='1;fmt_renamed_uop_t_src2_preg=u;end
always_comb begin renamed_uop_t u;u='0;u.rext.src3_preg='1;fmt_renamed_uop_t_src3_preg=u;end
always_comb begin renamed_uop_t u;u='0;u.ext.rs1_dom=o3_types_pkg::reg_domain_e'('1);fmt_renamed_uop_t_rs1_dom=u;end
always_comb begin renamed_uop_t u;u='0;u.ext.rs2_dom=o3_types_pkg::reg_domain_e'('1);fmt_renamed_uop_t_rs2_dom=u;end
always_comb begin renamed_uop_t u;u='0;u.ext.rs3_dom=o3_types_pkg::reg_domain_e'('1);fmt_renamed_uop_t_rs3_dom=u;end
assign cfg_width_o=ENQ_WIDTH;assign cfg_issue_o=ISSUE_WIDTH;assign cfg_depth_o=DEPTH;assign cfg_alu_o=CFG.exec.num_alu;assign cfg_tags_o=CFG.rename.checkpoints;
endmodule
