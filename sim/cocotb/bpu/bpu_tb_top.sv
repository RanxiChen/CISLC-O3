/** cocotb adapter: only public L1 BPU ports, with packed records flattened. */
module bpu_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i,
    input logic [VADDR_W-1:0] boot_pc_i,
    input logic alloc_ready_i,
    input logic [$bits(ftq_id_t)-1:0] alloc_ftq_id_i,
    input logic hold_i, recover_busy_i, kill_valid_i,
    input logic train_valid_i,
    output logic alloc_valid_o,
    output logic [VADDR_W-1:0] region_base_o, next_pc_o,
    output logic [SLOT_W-1:0] entry_slot_o,
    output logic cfi_valid_o,
    output logic [1:0] ras_action_o,
    output logic [$bits(hist_snapshot_t)-1:0] snapshot_o,
    output logic [$bits(ras_ckpt_t)-1:0] ras_ckpt_o,
    output logic slow_valid_o,
    output logic [$bits(ftq_id_t)-1:0] slow_ftq_id_o,
    output logic [VADDR_W-1:0] slow_region_base_o, slow_next_pc_o,
    output logic override_valid_o, train_ready_o,
    output logic [31:0] cfg_region_bytes_o
);
    bpu_pred_t pred;
    bpu_slow_t slow;
    redirect_req_t override_req;
    hist_snapshot_t snapshot;
    ras_ckpt_t ras_ckpt;
    fe_kill_t kill;
    always_comb begin
        kill = '0;
        kill.valid = kill_valid_i;
    end
    bpu #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .reset_pc_i('0), .flush_i(1'b0), .redirect_valid_i(1'b0),
        .redirect_pc_i('0), .ftq_valid_o(), .ftq_ready_i(1'b0), .ftq_entry_o(),
        .boot_pc_i(boot_pc_i),
        .alloc_valid_o(alloc_valid_o), .alloc_ready_i(alloc_ready_i),
        .alloc_ftq_id_i(ftq_id_t'(alloc_ftq_id_i)), .alloc_pred_o(pred),
        .alloc_snapshot_o(snapshot), .alloc_ras_ckpt_o(ras_ckpt),
        .slow_o(slow), .override_o(override_req),
        .arb_redirect_valid_i(1'b0), .arb_redirect_pc_i('0),
        .recover_busy_i(recover_busy_i), .kill_i(kill),
        .hist_restore_valid_i(1'b0), .hist_restore_snapshot_i('0),
        .hist_restore_inject_i(1'b0), .hist_restore_branch_pc_i('0),
        .hist_restore_target_pc_i('0), .hist_restore_done_o(),
        .ras_recover_valid_i(1'b0), .ras_recover_id_i('0),
        .ras_recover_ckpt_i('0), .ras_fix_i(RAS_NONE),
        .ras_fix_push_addr_i('0), .ras_recover_done_o(),
        .ras_recover_done_id_o(),
        .hold_i(hold_i), .train_valid_i(train_valid_i),
        .train_ready_o(train_ready_o), .train_i('0), .perf_o()
    );
    assign region_base_o = pred.region_base;
    assign next_pc_o = pred.next_pc;
    assign entry_slot_o = pred.entry_slot;
    assign cfi_valid_o = pred.cfi_valid;
    assign ras_action_o = pred.ras_action;
    assign snapshot_o = snapshot;
    assign ras_ckpt_o = ras_ckpt;
    assign slow_valid_o = slow.valid;
    assign slow_ftq_id_o = slow.ftq_id;
    assign slow_region_base_o = slow.pred.region_base;
    assign slow_next_pc_o = slow.pred.next_pc;
    assign override_valid_o = override_req.valid;
    assign cfg_region_bytes_o = O3_CFG.fe.fetch.region_bytes;
endmodule
