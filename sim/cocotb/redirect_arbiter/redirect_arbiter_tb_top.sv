module redirect_arbiter_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i,
    input logic [$bits(sys_redirect_t)-1:0] sys_bits_i,
    input logic [$bits(bru_resolve_t)-1:0] exec_bits_i,
    input logic [$bits(redirect_req_t)-1:0] pd_bits_i, slow_bits_i,
    input logic [$bits(ftq_id_t)-1:0] head_i, done_id_i,
    input logic history_done_i, ras_done_i,
    input logic [$bits(ras_ckpt_t)-1:0] ckpt_bits_i,
    output logic [$bits(redirect_req_t)-1:0] winner_bits_o, redirect_bits_o,
    output logic kill_valid_o, kill_all_o, kill_self_o,
    output logic [$bits(ftq_id_t)-1:0] kill_id_o, snap_id_o, recover_id_o,
    output logic [SLOT_W-1:0] kill_slot_o,
    output logic redirect_valid_o, snap_req_o, busy_o,
    output logic [VADDR_W-1:0] pc_o,
    output logic [$bits(ras_ckpt_t)-1:0] ckpt_bits_o,
    output logic [PERF_INC_W-1:0] slow_inc_o, pd_inc_o, exec_inc_o, sys_inc_o, recover_inc_o,
    output logic [31:0] ftq_depth_o, ras_ptr_w_o, ras_cnt_w_o
);
    fe_kill_t kill;
    fe_perf_t perf;
    redirect_arbiter #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i), .sys_i(sys_redirect_t'(sys_bits_i)),
        .exec_i(bru_resolve_t'(exec_bits_i)), .predecode_i(redirect_req_t'(pd_bits_i)),
        .slow_i(redirect_req_t'(slow_bits_i)), .ftq_head_i(ftq_id_t'(head_i)),
        .winner_o(winner_bits_o), .kill_o(kill),
        .bpu_redirect_valid_o(redirect_valid_o), .bpu_redirect_pc_o(pc_o),
        .snap_rd_req_o(snap_req_o), .snap_rd_ftq_id_o(snap_id_o),
        .history_done_i(history_done_i), .ras_done_i(ras_done_i), .recover_busy_o(busy_o),
        .ras_recover_ckpt_o(ckpt_bits_o), .ftq_ras_ckpt_i(ras_ckpt_t'(ckpt_bits_i)),
        .ras_recover_id_o(recover_id_o), .ras_done_id_i(ftq_id_t'(done_id_i)),
        .redirect_o(redirect_bits_o), .perf_o(perf)
    );
    assign kill_valid_o = kill.valid;
    assign kill_all_o = kill.all;
    assign kill_self_o = kill.kill_self;
    assign kill_id_o = kill.ftq_id;
    assign kill_slot_o = kill.slot;
    assign slow_inc_o = perf[PE_SLOW_OVERRIDE];
    assign pd_inc_o = perf[PE_PREDECODE_REDIRECT];
    assign exec_inc_o = perf[PE_REDIRECT_EXEC];
    assign sys_inc_o = perf[PE_REDIRECT_SYS];
    assign recover_inc_o = perf[PE_RECOVER_CYCLE];
    assign ftq_depth_o = FTQ_DEPTH;
    assign ras_ptr_w_o = RAS_PTR_W;
    assign ras_cnt_w_o = RAS_CNT_W;
endmodule
