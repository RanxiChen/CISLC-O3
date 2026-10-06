module bpu_slow_check_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i, rst_i, fast_valid_i, kill_valid_i,
    input logic [$bits(ftq_id_t)-1:0] fast_id_i,
    input logic [$bits(bpu_pred_t)-1:0] fast_bits_i,
    input logic [$bits(btb_resp_t)-1:0] btb_bits_i,
    input logic [$bits(tage_resp_t)-1:0] tage_bits_i,
    input logic [$bits(ras_ckpt_t)-1:0] ras_bits_i,
    output logic valid_o, disagree_o,
    output logic [$bits(ftq_id_t)-1:0] id_o,
    output logic [$bits(bpu_pred_t)-1:0] pred_bits_o,
    output logic [TAGE_META_W-1:0] meta_o,
    output logic [$bits(redirect_req_t)-1:0] req_bits_o,
    output logic [PERF_INC_W-1:0] hit_inc_o, missing_inc_o, disagree_inc_o,
    output logic [31:0] addr_w_o, ras_ptr_w_o, ras_cnt_w_o
);
    bpu_slow_t slow;
    fe_perf_t perf;
    bpu_slow_check #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i), .fast_valid_i(fast_valid_i),
        .fast_ftq_id_i(ftq_id_t'(fast_id_i)), .fast_i(bpu_pred_t'(fast_bits_i)),
        .fast_ras_ckpt_i(ras_ckpt_t'(ras_bits_i)),
        .btb_valid_i(fast_valid_i), .btb_i(btb_resp_t'(btb_bits_i)),
        .tage_valid_i(fast_valid_i), .tage_i(tage_resp_t'(tage_bits_i)),
        .kill_i('{valid:kill_valid_i, all:1'b1, ftq_id:'0, slot:'0, kill_self:1'b1}),
        .slow_o(slow), .override_o(req_bits_o), .perf_o(perf)
    );
    assign valid_o = slow.valid;
    assign id_o = slow.ftq_id;
    assign pred_bits_o = slow.pred;
    assign meta_o = slow.tage_meta;
    assign disagree_o = slow.override;
    assign hit_inc_o = perf[PE_BTB_HIT];
    assign missing_inc_o = perf[PE_TARGET_MISSING];
    assign disagree_inc_o = perf[PE_FAST_SLOW_DISAGREE];
    assign addr_w_o = VADDR_W;
    assign ras_ptr_w_o = RAS_PTR_W;
    assign ras_cnt_w_o = RAS_CNT_W;
endmodule
