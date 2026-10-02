/** cocotb-only flattened adapter; the public TAGE RTL interface is unchanged. */
module tage_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input logic clk_i,
    input logic rst_i,
    input logic s0_valid_i,
    input logic [VADDR_W-1:0] s0_region_base_i,
    input logic [HIST_FOLD_W-1:0] s0_folds_i,
    input logic stall_i,
    input logic kill_i,
    output logic resp_valid_o,
    output logic [REGION_SLOTS-1:0] resp_taken_mask_o,
    output logic [REGION_SLOTS-1:0] resp_provider_hit_mask_o,
    output logic [TAGE_META_W-1:0] resp_meta_o,

    input logic train_valid_i,
    output logic train_ready_o,
    input logic [VADDR_W-1:0] train_region_base_i,
    input logic [HIST_FOLD_W-1:0] train_folds_i,
    input logic [TAGE_META_W-1:0] train_meta_i,
    input logic [REGION_SLOTS-1:0] train_br_commit_mask_i,
    input logic [REGION_SLOTS-1:0] train_br_taken_mask_i,

    output logic [31:0] cfg_region_bytes_o,
    output logic [31:0] cfg_tables_o,
    output logic [31:0] cfg_base_entries_o,
    output logic [31:0] cfg_ctr_bits_o,
    output logic [31:0] cfg_useful_bits_o,
    output logic [TAGE_TABLES*32-1:0] cfg_index_bits_o,
    output logic [TAGE_TABLES*32-1:0] cfg_tag_bits_o
);
    bpu_train_t train;
    tage_resp_t resp;

    always_comb begin
        train = '0;
        train.region_base = train_region_base_i;
        train.ctx.folds = train_folds_i;
        train.tage_meta = train_meta_i;
        train.br_commit_mask = train_br_commit_mask_i;
        train.br_taken_mask = train_br_taken_mask_i;
    end

    tage #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .s0_valid_i(s0_valid_i), .s0_region_base_i(s0_region_base_i),
        .s0_folds_i(s0_folds_i), .stall_i(stall_i), .kill_i(kill_i),
        .resp_valid_o(resp_valid_o), .resp_o(resp),
        .train_valid_i(train_valid_i), .train_ready_o(train_ready_o),
        .train_i(train), .perf_o()
    );

    assign resp_taken_mask_o = resp.taken_mask;
    assign resp_provider_hit_mask_o = resp.provider_hit_mask;
    assign resp_meta_o = resp.meta;
    assign cfg_region_bytes_o = O3_CFG.fe.fetch.region_bytes;
    assign cfg_tables_o = TAGE_TABLES;
    assign cfg_base_entries_o = O3_CFG.fe.tage.base_entries;
    assign cfg_ctr_bits_o = O3_CFG.fe.tage.ctr_bits;
    assign cfg_useful_bits_o = O3_CFG.fe.tage.useful_bits;
    for (genvar table_idx = 0; table_idx < TAGE_TABLES; table_idx++) begin : cfg_export
        assign cfg_index_bits_o[table_idx*32 +: 32] = O3_CFG.fe.tage.index_bits[table_idx];
        assign cfg_tag_bits_o[table_idx*32 +: 32] = O3_CFG.fe.tage.tag_bits[table_idx];
    end
endmodule
