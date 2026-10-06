/**
 * cocotb-only adapter: expose public uBTB signals as VPI-friendly scalar/vector
 * ports. DUT ports, state, and O3_CFG are unchanged. Unused training context is 0.
 */
module ubtb_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    lookup_valid_i,
    input  logic [VADDR_W-1:0]      lookup_pc_i,
    input  logic                    stall_i,
    output logic                    hit_o,
    output logic [VADDR_W-1:0]      pred_region_base_o,
    output logic [SLOT_W-1:0]       pred_entry_slot_o,
    output logic [REGION_SLOTS-1:0] pred_br_mask_o,
    output logic [REGION_SLOTS-1:0] pred_jal_mask_o,
    output logic                    pred_cfi_valid_o,
    output logic [SLOT_W-1:0]       pred_cfi_slot_o,
    output logic [1:0]              pred_cfi_type_o,
    output logic [1:0]              pred_ras_action_o,
    output logic                    pred_raw_pred_taken_o,
    output logic                    pred_target_missing_o,
    output logic [VADDR_W-1:0]      pred_cfi_target_o,
    output logic [VADDR_W-1:0]      pred_next_pc_o,

    input  logic                    train_valid_i,
    output logic                    train_ready_o,
    input  logic [VADDR_W-1:0]      train_region_base_i,
    input  logic [REGION_SLOTS-1:0] train_br_commit_mask_i,
    input  logic [REGION_SLOTS-1:0] train_br_taken_mask_i,
    input  logic                    train_cfi_valid_i,
    input  logic [SLOT_W-1:0]       train_cfi_slot_i,
    input  logic [1:0]              train_cfi_type_i,
    input  logic [1:0]              train_ras_action_i,
    input  logic [VADDR_W-1:0]      train_cfi_target_i,

    output logic [PERF_INC_W-1:0]   perf_lookup_o,
    output logic [PERF_INC_W-1:0]   perf_hit_o,
    output logic reserved_rvc_o, reserved_edge_o,
    output logic [31:0]             cfg_region_bytes_o,
    output logic [31:0]             cfg_entries_o,
    output logic [31:0]             cfg_tag_bits_o
);
    bpu_train_t train;
    bpu_pred_t pred;
    fe_perf_t perf;

    always_comb begin
        train = '0;
        train.region_base = train_region_base_i;
        train.br_commit_mask = train_br_commit_mask_i;
        train.br_taken_mask = train_br_taken_mask_i;
        train.cfi_valid = train_cfi_valid_i;
        train.cfi_slot = train_cfi_slot_i;
        train.cfi_type = cfi_type_e'(train_cfi_type_i);
        train.ras_action = ras_action_e'(train_ras_action_i);
        train.cfi_target = train_cfi_target_i;
    end

    ubtb #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .lookup_valid_i(lookup_valid_i), .lookup_pc_i(lookup_pc_i),
        .stall_i(stall_i), .hit_o(hit_o), .pred_o(pred),
        .train_valid_i(train_valid_i), .train_ready_o(train_ready_o),
        .train_i(train), .perf_o(perf)
    );

    assign pred_region_base_o = pred.region_base;
    assign pred_entry_slot_o = pred.entry_slot;
    assign pred_br_mask_o = pred.br_mask;
    assign pred_jal_mask_o = pred.jal_mask;
    assign pred_cfi_valid_o = pred.cfi_valid;
    assign pred_cfi_slot_o = pred.cfi_slot;
    assign pred_cfi_type_o = pred.cfi_type;
    assign pred_ras_action_o = pred.ras_action;
    assign pred_raw_pred_taken_o = pred.raw_pred_taken;
    assign pred_target_missing_o = pred.target_missing;
    assign pred_cfi_target_o = pred.cfi_target;
    assign pred_next_pc_o = pred.next_pc;
    assign perf_lookup_o = perf[PE_UBTB_LOOKUP];
    assign perf_hit_o = perf[PE_UBTB_HIT];

    assign cfg_region_bytes_o = O3_CFG.fe.fetch.region_bytes;
    assign cfg_entries_o = O3_CFG.fe.ubtb.entries;
    assign cfg_tag_bits_o = O3_CFG.fe.ubtb.tag_bits;
    assign reserved_rvc_o = pred.cfi_is_rvc;
    assign reserved_edge_o = pred.\edge ;
endmodule
