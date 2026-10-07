module backend_issue_queue_tb_top
    import o3_pkg::*;
(
    input logic clk, rst,
    input logic enq_valid, enq_store, enq_load, enq_wait_src,
    input logic [ROB_IDX_WIDTH-1:0] enq_rob,
    input logic allow_load, issue_ready, wakeup,issue1_ready,
    output logic issue1_valid,issue1_load,issue1_store,
    output logic [ROB_IDX_WIDTH-1:0] issue1_rob,
    output logic issue_valid, issue_store, issue_load,
    output logic [ROB_IDX_WIDTH-1:0] issue_rob
);
    localparam int WIDTH = o3_cfg_pkg::O3_CFG.be.dispatch.width;
    localparam int PREGS = o3_cfg_pkg::O3_CFG.be.rename.int_phys_regs;
    localparam int WAKEUPS = o3_cfg_pkg::O3_CFG.be.exec.int_prf_write_ports;
    renamed_uop_t [WIDTH-1:0] enq_uop;
    renamed_uop_t [1:0] issue_uop;
    logic [1:0] issue_valid_arr, issue_ready_arr;
    logic preg_ready [PREGS-1:0];
    logic wakeup_valid [WAKEUPS-1:0];
    logic [PREG_IDX_WIDTH-1:0] wakeup_preg [WAKEUPS-1:0];
    always_comb begin
        enq_uop = '0;
        enq_uop[0].valid = enq_valid;
        enq_uop[0].is_store = enq_store;
        enq_uop[0].is_load = enq_load;
        enq_uop[0].rs1_read_en = enq_wait_src;
        enq_uop[0].ext.rs1_dom = o3_types_pkg::RD_INT;
        enq_uop[0].src1_preg = PREG_IDX_WIDTH'(1);
        enq_uop[0].rob_idx = enq_rob;
    end
    for (genvar preg = 0; preg < PREGS; preg++) begin : g_ready
        assign preg_ready[preg] = preg != 1;
    end
    for (genvar port = 0; port < WAKEUPS; port++) begin : g_wakeup
        assign wakeup_valid[port] = port == 0 && wakeup;
        assign wakeup_preg[port] = PREG_IDX_WIDTH'(1);
    end
    assign issue_ready_arr={issue1_ready,issue_ready};
    assign issue1_valid=issue_valid_arr[1];assign issue1_load=issue_uop[1].is_load;
    assign issue1_store=issue_uop[1].is_store;assign issue1_rob=issue_uop[1].rob_idx;
    assign issue_valid = issue_valid_arr[0];
    assign issue_store = issue_uop[0].is_store;
    assign issue_load = issue_uop[0].is_load;
    assign issue_rob = issue_uop[0].rob_idx;
    backend_issue_queue #(.CFG(o3_cfg_pkg::O3_CFG.be), .KIND(o3_types_pkg::IQ_MEM)) dut (
        .clk(clk), .rst(rst), .enq_uop_i(enq_uop), .enq_fire_i(enq_valid),
        .free_count_o(), .preg_ready_i(preg_ready), .mul_ready_i(1'b1),.mul_pair_ready_i(1'b1),.div_ready_i(1'b1),
        .fp_preg_ready_i('{default:0}),.fp_wakeup_valid_i('{default:0}),.fp_wakeup_preg_i('{default:'0}),
        .fp_regread_ready_i('0),.issue_fp_fu_o(),.wakeup_valid_i(wakeup_valid), .wakeup_preg_i(wakeup_preg),
        .issue_uop_o(issue_uop), .issue_valid_o(issue_valid_arr),
        .issue_ready_i(issue_ready_arr), .resolution_valid_i(1'b0),
        .resolution_mispredict_i(1'b0), .resolution_tag_i('0)
    );
endmodule
