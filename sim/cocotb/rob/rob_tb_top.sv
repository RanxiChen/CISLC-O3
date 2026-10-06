// Scalar/vector observation wrapper; never changes DUT state.
module rob_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    parameter  int COMPLETE_WIDTH = o3_cfg_pkg::O3_CFG.be.exec.num_alu + 3,                   // 完成报告源数量，由 backend 按写回源数给出
    localparam int MACHINE_WIDTH = o3_pkg::BACKEND_MACHINE_WIDTH,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int NUM_PHYS_REGS = o3_types_pkg::INT_PREGS > o3_types_pkg::FP_PREGS
                                 ? o3_types_pkg::INT_PREGS : o3_types_pkg::FP_PREGS,
    localparam int RETIRE_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width
) (
    input  logic clk,
    input  logic rst,
    input  logic                               alloc_req_i       [MACHINE_WIDTH-1:0],
    input  logic                               alloc_exception_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::PREG_IDX_WIDTH-1:0]   alloc_old_dst_preg_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::PREG_IDX_WIDTH-1:0]   alloc_new_dst_preg_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::REG_ADDR_WIDTH-1:0]  alloc_rd_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_rd_write_en_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_is_load_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_is_store_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::LQ_IDX_WIDTH-1:0]     alloc_lq_idx_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::SQ_IDX_WIDTH-1:0]     alloc_sq_idx_i [MACHINE_WIDTH-1:0],
    input  o3_pkg::branch_mask_t                alloc_branch_mask_i [MACHINE_WIDTH-1:0],
    input  o3_types_pkg::ftq_id_t                 alloc_ftq_idx_i [MACHINE_WIDTH-1:0],
    input  o3_types_pkg::fetch_slot_t            alloc_ftq_slot_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_ftq_last_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::INST_ID_WIDTH-1:0]   alloc_instruction_id_i [MACHINE_WIDTH-1:0],

    input  logic                               alloc_ready_i,
    input  logic                               complete_valid_i  [COMPLETE_WIDTH-1:0],
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] complete_idx_i    [COMPLETE_WIDTH-1:0],
    input  logic                               resolution_valid_i,
    input  logic                               resolution_mispredict_i,
    input  o3_pkg::branch_tag_t                resolution_tag_i,
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] resolution_rob_idx_i,
    input  logic                               resolution_completes_rob_i,
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] restore_tail_i,

    output logic                               alloc_valid_o,
    output logic [$clog2(NUM_ROB_ENTRIES+1)-1:0] free_count_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] head_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] tail_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_idx_o       [MACHINE_WIDTH-1:0],
    output logic                               retire_valid_o    [RETIRE_WIDTH-1:0],
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] retire_idx_o      [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::PREG_IDX_WIDTH-1:0]   retire_old_dst_preg_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::PREG_IDX_WIDTH-1:0]   retire_new_dst_preg_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::REG_ADDR_WIDTH-1:0]  retire_rd_o [RETIRE_WIDTH-1:0],
    output logic                               retire_rd_write_en_o [RETIRE_WIDTH-1:0],
    output logic                               retire_is_load_o [RETIRE_WIDTH-1:0],
    output logic                               retire_is_store_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::LQ_IDX_WIDTH-1:0]     retire_lq_idx_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::SQ_IDX_WIDTH-1:0]     retire_sq_idx_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::INST_ID_WIDTH-1:0]   retire_instruction_id_o [RETIRE_WIDTH-1:0]
    ,output o3_types_pkg::ftq_id_t               retire_ftq_idx_o [RETIRE_WIDTH-1:0]
    ,output o3_types_pkg::fetch_slot_t          retire_ftq_slot_o [RETIRE_WIDTH-1:0]
    ,output logic                              retire_ftq_last_o [RETIRE_WIDTH-1:0]

,

    // ---------------- 目标合同（框架新增，未接入逻辑） ----------------
    // 分配时保存：异常 cause/tval、FTQ 槽位、提交时需要的串行化类型、寄存器域
    input  o3_types_pkg::exc_info_t    t_alloc_exc_i      [MACHINE_WIDTH-1:0],
    input  o3_types_pkg::uop_ext_t     t_alloc_ext_i      [MACHINE_WIDTH-1:0],
    // 执行期异常报告到原项（访存/非法 CSR 等，B06）
    input  logic                       t_exc_valid_i,
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] t_exc_idx_i,
    input  o3_types_pkg::exc_info_t    t_exc_i,
    // FP 完成时写 fflags（B15）
    input  logic                       t_fflags_valid_i   [COMPLETE_WIDTH-1:0],
    input  logic [o3_isa_pkg::FFLAGS_W-1:0] t_fflags_i    [COMPLETE_WIDTH-1:0],
    // 队头信息：串行化指令（CSR/FENCE/FENCE.I/SFENCE/AMO/MMIO/xRET/ECALL）在队头执行
    output logic                       t_head_valid_o,
    output o3_types_pkg::rob_commit_t  t_head_o,
    input  logic                       t_head_serial_done_i,   // 队头串行操作已完成，可退休
    // 每条提交指令的完整信息，送 commit_ctrl
    output o3_types_pkg::rob_commit_t  t_commit_o         [RETIRE_WIDTH-1:0],
    // 提交端整体清空（异常/xRET/系统重定向）：使用 committed map 恢复（未设计）
    input  logic                       t_flush_all_i
,
output logic [$bits(o3_types_pkg::ftq_id_t)-1:0] fmt_ftq_id_t_idx,
output logic [$bits(o3_types_pkg::ftq_id_t)-1:0] fmt_ftq_id_t_gen,
output logic [31:0] cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o,
output branch_mask_t mask_obs_o [NUM_ROB_ENTRIES-1:0]
);
rob #(.CFG(CFG), .COMPLETE_WIDTH(COMPLETE_WIDTH)) dut (
.clk(clk),
.rst(rst),
.alloc_req_i(alloc_req_i),
.alloc_exception_i(alloc_exception_i),
.alloc_old_dst_preg_i(alloc_old_dst_preg_i),
.alloc_new_dst_preg_i(alloc_new_dst_preg_i),
.alloc_rd_i(alloc_rd_i),
.alloc_rd_write_en_i(alloc_rd_write_en_i),
.alloc_is_load_i(alloc_is_load_i),
.alloc_is_store_i(alloc_is_store_i),
.alloc_lq_idx_i(alloc_lq_idx_i),
.alloc_sq_idx_i(alloc_sq_idx_i),
.alloc_branch_mask_i(alloc_branch_mask_i),
.alloc_ftq_idx_i(alloc_ftq_idx_i),
.alloc_ftq_slot_i(alloc_ftq_slot_i),
.alloc_ftq_last_i(alloc_ftq_last_i),
.alloc_instruction_id_i(alloc_instruction_id_i),
.alloc_ready_i(alloc_ready_i),
.complete_valid_i(complete_valid_i),
.complete_idx_i(complete_idx_i),
.resolution_valid_i(resolution_valid_i),
.resolution_mispredict_i(resolution_mispredict_i),
.resolution_tag_i(resolution_tag_i),
.resolution_rob_idx_i(resolution_rob_idx_i),
.resolution_completes_rob_i(resolution_completes_rob_i),
.restore_tail_i(restore_tail_i),
.alloc_valid_o(alloc_valid_o),
.free_count_o(free_count_o),
.head_o(head_o),
.tail_o(tail_o),
.alloc_idx_o(alloc_idx_o),
.retire_valid_o(retire_valid_o),
.retire_idx_o(retire_idx_o),
.retire_old_dst_preg_o(retire_old_dst_preg_o),
.retire_new_dst_preg_o(retire_new_dst_preg_o),
.retire_rd_o(retire_rd_o),
.retire_rd_write_en_o(retire_rd_write_en_o),
.retire_is_load_o(retire_is_load_o),
.retire_is_store_o(retire_is_store_o),
.retire_lq_idx_o(retire_lq_idx_o),
.retire_sq_idx_o(retire_sq_idx_o),
.retire_instruction_id_o(retire_instruction_id_o),
.retire_ftq_idx_o(retire_ftq_idx_o),
.retire_ftq_slot_o(retire_ftq_slot_o),
.retire_ftq_last_o(retire_ftq_last_o),
.t_alloc_inst_len_i('{default:3'd4}),
.t_alloc_exc_i(t_alloc_exc_i),
.t_alloc_ext_i(t_alloc_ext_i),
.t_exc_valid_i(t_exc_valid_i),
.t_exc_idx_i(t_exc_idx_i),
.t_exc_i(t_exc_i),
.t_fflags_valid_i(t_fflags_valid_i),
.t_fflags_i(t_fflags_i),
.t_head_valid_o(t_head_valid_o),
.t_head_o(t_head_o),
.t_head_serial_done_i(t_head_serial_done_i),
.t_commit_o(t_commit_o),
.t_flush_all_i(t_flush_all_i)
);
always_comb begin o3_types_pkg::ftq_id_t v; v='0; v.idx='1; fmt_ftq_id_t_idx=v; end
always_comb begin o3_types_pkg::ftq_id_t v; v='0; v.gen='1; fmt_ftq_id_t_gen=v; end
assign cfg_width_o=BACKEND_MACHINE_WIDTH;
assign cfg_depth_o=CFG.rob.entries;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
for(genvar n=0;n<NUM_ROB_ENTRIES;n++) assign mask_obs_o[n]=dut.entry_branch_mask_q[n];
endmodule
