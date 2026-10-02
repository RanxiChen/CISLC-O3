/** Cocotb adapter: keep the public RAS interface unchanged and expose packed fields. */
module ras_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
#(parameter int TEST_DEPTH = 16) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic op_valid_i,
    input  logic [1:0] op_action_i,
    input  logic [VADDR_W-1:0] op_push_addr_i,
    output logic [VADDR_W-1:0] top_o,
    output logic top_valid_o,
    output logic [RAS_PTR_W-1:0] ckpt_top_idx_o,
    output logic [RAS_CNT_W-1:0] ckpt_count_o,
    output logic [VADDR_W-1:0] ckpt_top_addr_o,
    input  logic recover_valid_i,
    input  logic [$bits(ftq_id_t)-1:0] recover_id_i,
    input  logic [RAS_PTR_W-1:0] recover_top_idx_i,
    input  logic [RAS_CNT_W-1:0] recover_count_i,
    input  logic [VADDR_W-1:0] recover_top_addr_i,
    input  logic [1:0] recover_fix_i,
    input  logic [VADDR_W-1:0] recover_push_addr_i,
    output logic recover_done_o,
    output logic [$bits(ftq_id_t)-1:0] recover_done_id_o,
    output logic [4:0] events_o,
    output logic [31:0] depth_o
);
    function automatic frontend_cfg_t test_cfg();
        frontend_cfg_t c;
        c = O3_CFG.fe;
        c.ras.depth = TEST_DEPTH;
        return c;
    endfunction
    localparam frontend_cfg_t CFG = test_cfg();
    ras_ckpt_t ckpt, recover_ckpt;
    fe_perf_t perf;

    always_comb begin
        recover_ckpt = '0;
        recover_ckpt.top_idx = recover_top_idx_i;
        recover_ckpt.count = recover_count_i;
        recover_ckpt.top_addr = recover_top_addr_i;
    end

    ras #(.CFG(CFG)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .op_valid_i(op_valid_i), .op_action_i(ras_action_e'(op_action_i)),
        .op_push_addr_i(op_push_addr_i), .top_o(top_o),
        .top_valid_o(top_valid_o), .ckpt_o(ckpt),
        .recover_valid_i(recover_valid_i), .recover_id_i(ftq_id_t'(recover_id_i)),
        .recover_ckpt_i(recover_ckpt), .recover_fix_i(ras_action_e'(recover_fix_i)),
        .recover_push_addr_i(recover_push_addr_i),
        .recover_done_o(recover_done_o), .recover_done_id_o(recover_done_id_o),
        .perf_o(perf)
    );
    assign ckpt_top_idx_o = ckpt.top_idx;
    assign ckpt_count_o = ckpt.count;
    assign ckpt_top_addr_o = ckpt.top_addr;
    assign events_o = {
        |perf[PE_RECOVER_CYCLE], |perf[PE_RAS_OVERFLOW],
        |perf[PE_RAS_UNDERFLOW], |perf[PE_RAS_POP], |perf[PE_RAS_PUSH]
    };
    assign depth_o = TEST_DEPTH;
endmodule
