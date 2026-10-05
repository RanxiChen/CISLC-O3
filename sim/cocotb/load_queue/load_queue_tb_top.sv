// Scalar/vector observation wrapper; never changes DUT state.
module load_queue_tb_top import o3_pkg::*; #(

    parameter  o3_cfg_pkg::backend_cfg_t CFG = o3_cfg_pkg::O3_CFG.be,
    localparam int RENAME_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int DEPTH = CFG.lsu.lq_depth,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries
) (
    input logic clk,
    input logic rst,
    input logic alloc_req_i [RENAME_WIDTH-1:0],
    input logic alloc_fire_i,
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_rob_idx_i [RENAME_WIDTH-1:0],
    input branch_mask_t alloc_branch_mask_i [RENAME_WIDTH-1:0],
    output logic [$clog2(DEPTH)-1:0] alloc_idx_o [RENAME_WIDTH-1:0],
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,
    output logic [$clog2(DEPTH)-1:0] tail_o,

    input logic execute_valid_i,
    input logic [$clog2(DEPTH)-1:0] execute_idx_i,
    input logic [XLEN-1:0] execute_addr_i,
    output logic execute_generation_o,
    input logic request_fire_i,
    input logic [$clog2(DEPTH)-1:0] request_idx_i,
    input logic response_valid_i,
    input logic [$clog2(DEPTH):0] response_tag_i,
    output logic response_live_o,

    input logic [$clog2(RENAME_WIDTH+1)-1:0] release_count_i,
    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,
    input logic [$clog2(DEPTH)-1:0] restore_tail_i
,

    // ---------------- 目标合同（框架新增，未接入逻辑） ----------------
    // replay 等待记录（B04 6.2）：等待原因与唤醒；记录放 LQ 内还是独立队列未冻结
    input  logic                       t_wait_set_valid_i,
    input  logic [$clog2(DEPTH)-1:0]   t_wait_set_idx_i,
    input  o3_types_pkg::dc_status_e   t_wait_reason_i,
    input  o3_types_pkg::dc_wake_t     t_dc_wake_i,
    input  logic                       t_tlb_wake_i,
    output logic                       t_replay_valid_o,
    output logic [$clog2(DEPTH)-1:0]   t_replay_idx_o,
    input  logic                       t_replay_ready_i,
    // 多事务身份：idx + 多位代际（现有 1 位不足，B04）
    output o3_types_pkg::lq_tag_t      t_exec_tag_o,
    // 访存违例检测（未知地址旧 store 的推测策略待定，B04）
    input  logic                       t_store_addr_valid_i,
    input  logic [XLEN-1:0]            t_store_addr_i,
    input  logic [ROB_IDX_WIDTH-1:0]   t_store_rob_idx_i,
    output logic                       t_violation_o
,
output logic [31:0] cfg_width_o, cfg_depth_o, cfg_rob_o, cfg_pregs_o, cfg_read_ports_o, cfg_tags_o,
output logic addr_valid_obs_o [DEPTH-1:0], outstanding_obs_o [DEPTH-1:0], live_obs_o [DEPTH-1:0],
output branch_mask_t mask_obs_o [DEPTH-1:0]
);
load_queue #(.CFG(CFG)) dut (
.clk(clk),
.rst(rst),
.alloc_req_i(alloc_req_i),
.alloc_fire_i(alloc_fire_i),
.alloc_rob_idx_i(alloc_rob_idx_i),
.alloc_branch_mask_i(alloc_branch_mask_i),
.alloc_idx_o(alloc_idx_o),
.free_count_o(free_count_o),
.tail_o(tail_o),
.execute_valid_i(execute_valid_i),
.execute_idx_i(execute_idx_i),
.execute_addr_i(execute_addr_i),
.execute_generation_o(execute_generation_o),
.request_fire_i(request_fire_i),
.request_idx_i(request_idx_i),
.response_valid_i(response_valid_i),
.response_tag_i(response_tag_i),
.response_live_o(response_live_o),
.release_count_i(release_count_i),
.resolution_valid_i(resolution_valid_i),
.resolution_mispredict_i(resolution_mispredict_i),
.resolution_tag_i(resolution_tag_i),
.restore_tail_i(restore_tail_i),
.t_wait_set_valid_i(t_wait_set_valid_i),
.t_wait_set_idx_i(t_wait_set_idx_i),
.t_wait_reason_i(t_wait_reason_i),
.t_dc_wake_i(t_dc_wake_i),
.t_tlb_wake_i(t_tlb_wake_i),
.t_replay_valid_o(t_replay_valid_o),
.t_replay_idx_o(t_replay_idx_o),
.t_replay_ready_i(t_replay_ready_i),
.t_exec_tag_o(t_exec_tag_o),
.t_store_addr_valid_i(t_store_addr_valid_i),
.t_store_addr_i(t_store_addr_i),
.t_store_rob_idx_i(t_store_rob_idx_i),
.t_violation_o(t_violation_o)
);
assign cfg_width_o=BACKEND_MACHINE_WIDTH;
assign cfg_depth_o=CFG.lsu.lq_depth;
assign cfg_rob_o=CFG.rob.entries;
assign cfg_pregs_o=CFG.rename.int_phys_regs;
assign cfg_read_ports_o=CFG.exec.int_prf_read_ports;
assign cfg_tags_o=CFG.rename.checkpoints;
for(genvar n=0;n<DEPTH;n++) begin assign addr_valid_obs_o[n]=dut.addr_valid_q[n]; assign outstanding_obs_o[n]=dut.outstanding_q[n]; assign live_obs_o[n]=dut.valid_q[n]; assign mask_obs_o[n]=dut.branch_mask_q[n]; end
endmodule
