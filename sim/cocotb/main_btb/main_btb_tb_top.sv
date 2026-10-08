/**
 * cocotb-only adapter: keep main_btb's typed RTL interface unchanged while
 * exposing only public, scalar/vector signals through Verilator VPI.
 * Unused prediction-history/TAGE training context is zero; main_btb does not
 * consume it. All sizes come from O3_CFG, never a test-only configuration.
 */
module main_btb_tb_top
    import o3_cfg_pkg::*;
    import o3_types_pkg::*;
(
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    s0_valid_i,
    input  logic [VADDR_W-1:0]      s0_region_base_i,
    input  logic                    stall_i,
    input  logic                    kill_i,

    output logic                    resp_valid_o,
    output logic                    resp_hit_o,
    output logic [REGION_SLOTS-1:0] resp_br_mask_o,
    output logic [REGION_SLOTS-1:0] resp_jal_mask_o,
    output logic [SLOT_W-1:0]      resp_cfi_slot_o,
    output logic [1:0]             resp_cfi_type_o,
    output logic [1:0]             resp_ras_action_o,
    output logic [VADDR_W-1:0]     resp_target_o,

    input  logic                    train_valid_i,
    output logic                    train_ready_o,
    input  logic [VADDR_W-1:0]      train_region_base_i,
    input  logic [REGION_SLOTS-1:0] train_br_commit_mask_i,
    input  logic [REGION_SLOTS-1:0] train_br_taken_mask_i,
    input  logic                    train_cfi_valid_i,
    input  logic [SLOT_W-1:0]      train_cfi_slot_i,
    input  logic [1:0]             train_cfi_type_i,
    input  logic [1:0]             train_ras_action_i,
    input  logic [VADDR_W-1:0]     train_cfi_target_i,

    output logic [O3_CFG.fe.btb.ways-1:0][1+O3_CFG.fe.btb.tag_bits+2*REGION_SLOTS+SLOT_W+4+VADDR_W+2-1:0] mon_rows_o,
    output logic reserved_rvc_o, reserved_is_edge_o,
    output logic [31:0]             cfg_region_bytes_o,
    output logic [31:0]             cfg_sets_o,
    output logic [31:0]             cfg_ways_o,
    output logic [31:0]             cfg_tag_bits_o
);
    bpu_train_t train;
    btb_resp_t resp;

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

    main_btb #(.CFG(O3_CFG.fe)) dut (
        .clk_i(clk_i), .rst_i(rst_i),
        .s0_valid_i(s0_valid_i), .s0_region_base_i(s0_region_base_i),
        .stall_i(stall_i), .kill_i(kill_i),
        .resp_valid_o(resp_valid_o), .resp_o(resp),
        .train_valid_i(train_valid_i), .train_ready_o(train_ready_o),
        .train_i(train), .perf_o()
    );

    for(genvar w=0;w<O3_CFG.fe.btb.ways;w++) begin
        assign mon_rows_o[w]={dut.valid_q[dut.set_of(train_region_base_i)][w],dut.g_way[w].u_train.mem[dut.set_of(train_region_base_i)]};
    end
    assign resp_hit_o = resp.hit;
    assign resp_br_mask_o = resp.br_mask;
    assign resp_jal_mask_o = resp.jal_mask;
    assign resp_cfi_slot_o = resp.cfi_slot;
    assign resp_cfi_type_o = resp.cfi_type;
    assign resp_ras_action_o = resp.ras_action;
    assign resp_target_o = resp.target;

    assign cfg_region_bytes_o = O3_CFG.fe.fetch.region_bytes;
    assign cfg_sets_o = O3_CFG.fe.btb.sets;
    assign cfg_ways_o = O3_CFG.fe.btb.ways;
    assign cfg_tag_bits_o = O3_CFG.fe.btb.tag_bits;
    assign reserved_rvc_o = resp.cfi_is_rvc;
    assign reserved_is_edge_o = resp.is_edge;
endmodule
