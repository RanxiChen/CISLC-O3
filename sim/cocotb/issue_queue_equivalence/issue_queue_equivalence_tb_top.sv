module issue_queue_equivalence_tb_top
    import o3_pkg::*;
#(parameter int KIND = 0,
  localparam int EW = o3_cfg_pkg::O3_CFG.be.dispatch.width,
  localparam int IW = KIND == 0 ? o3_cfg_pkg::O3_CFG.be.exec.num_alu :
                     KIND == 1 ? o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes : KIND == 3 ? 2 : 1,
  localparam int NP = o3_cfg_pkg::O3_CFG.be.rename.int_phys_regs,
  localparam int NFP = o3_cfg_pkg::O3_CFG.be.rename.fp_phys_regs,
  localparam int WP = o3_cfg_pkg::O3_CFG.be.exec.int_prf_write_ports,
  localparam int FWP = o3_cfg_pkg::O3_CFG.be.exec.fp_prf_write_ports,
  localparam int BITS = $bits(renamed_uop_t)) (
    input logic clk, rst,
    input logic [EW-1:0][BITS-1:0] enq_uop_i,
    input logic enq_fire_i,
    input logic [NP-1:0] preg_ready_i,
    input logic [NFP-1:0] fp_preg_ready_i,
    input logic [WP-1:0] wakeup_valid_i,
    input logic [WP-1:0][PREG_IDX_WIDTH-1:0] wakeup_preg_i,
    input logic [FWP-1:0] fp_wakeup_valid_i,
    input logic [FWP-1:0][PREG_IDX_WIDTH-1:0] fp_wakeup_preg_i,
    input logic [4:0] fp_regread_ready_i,
    input logic mul_ready_i, mul_pair_ready_i, div_ready_i,
    input logic [IW-1:0] issue_ready_i,
    input logic resolution_valid_i, resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,
    output logic [31:0] free_o,
    output logic [BITS-1:0] valid_mask_o,
    output logic match_o
);
    localparam int DEPTH = KIND == 0 ? o3_cfg_pkg::O3_CFG.be.dispatch.int_iq_depth :
                          KIND == 1 ? o3_cfg_pkg::O3_CFG.be.dispatch.mem_iq_depth :
                          KIND == 2 ? o3_cfg_pkg::O3_CFG.be.dispatch.br_iq_depth :
                                      o3_cfg_pkg::O3_CFG.be.dispatch.fp_iq_depth;
    logic ready [NP], fp_ready [NFP], wake_valid [WP], fp_wake_valid [FWP];
    logic [PREG_IDX_WIDTH-1:0] wake_preg [WP], fp_wake_preg [FWP];
    renamed_uop_t [IW-1:0] actual_uop, reference_uop;
    logic [IW-1:0] actual_valid, reference_valid;
    logic [2:0] actual_fu [IW], reference_fu [IW];
    logic [$clog2(DEPTH+1)-1:0] actual_free, reference_free;
    renamed_uop_t format;
    always_comb begin format = '0; format.valid = 1'b1; end
    assign valid_mask_o = format;
    assign free_o = actual_free;
    for (genvar i = 0; i < NP; i++) assign ready[i] = preg_ready_i[i];
    for (genvar i = 0; i < NFP; i++) assign fp_ready[i] = fp_preg_ready_i[i];
    for (genvar i = 0; i < WP; i++) begin
        assign wake_valid[i] = wakeup_valid_i[i];
        assign wake_preg[i] = wakeup_preg_i[i];
    end
    for (genvar i = 0; i < FWP; i++) begin
        assign fp_wake_valid[i] = fp_wakeup_valid_i[i];
        assign fp_wake_preg[i] = fp_wakeup_preg_i[i];
    end
    backend_issue_queue #(.CFG(o3_cfg_pkg::O3_CFG.be), .KIND(o3_types_pkg::iq_kind_e'(KIND))) dut (
        .clk, .rst, .enq_uop_i, .enq_fire_i, .free_count_o(actual_free),
        .preg_ready_i(ready), .fp_preg_ready_i(fp_ready),
        .wakeup_valid_i(wake_valid), .wakeup_preg_i(wake_preg),
        .fp_wakeup_valid_i(fp_wake_valid), .fp_wakeup_preg_i(fp_wake_preg),
        .fp_regread_ready_i, .issue_fp_fu_o(actual_fu),
        .mul_ready_i, .mul_pair_ready_i, .div_ready_i,
        .issue_uop_o(actual_uop), .issue_valid_o(actual_valid), .issue_ready_i,
        .resolution_valid_i, .resolution_mispredict_i, .resolution_tag_i
    );
    backend_issue_queue_reference #(.CFG(o3_cfg_pkg::O3_CFG.be), .KIND(o3_types_pkg::iq_kind_e'(KIND))) reference (
        .clk, .rst, .enq_uop_i, .enq_fire_i, .free_count_o(reference_free),
        .preg_ready_i(ready), .fp_preg_ready_i(fp_ready),
        .wakeup_valid_i(wake_valid), .wakeup_preg_i(wake_preg),
        .fp_wakeup_valid_i(fp_wake_valid), .fp_wakeup_preg_i(fp_wake_preg),
        .fp_regread_ready_i, .issue_fp_fu_o(reference_fu),
        .mul_ready_i, .mul_pair_ready_i, .div_ready_i,
        .issue_uop_o(reference_uop), .issue_valid_o(reference_valid), .issue_ready_i,
        .resolution_valid_i, .resolution_mispredict_i, .resolution_tag_i
    );
    always_comb begin
        match_o = actual_free == reference_free && actual_valid == reference_valid
                  && actual_uop == reference_uop;
        for (int i = 0; i < IW; i++) match_o &= actual_fu[i] == reference_fu[i];
    end
endmodule
