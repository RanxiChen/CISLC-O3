// Real two-ALU producers plus held branch/load heads; no force of DUT state.
module wb_alu_kill_tb_top import o3_pkg::*; (
    input logic clk, rst,
    input logic [1:0] grant_i,
    input logic [ROB_IDX_WIDTH-1:0] rob0_i, rob1_i,
    input branch_mask_t mask0_i, mask1_i,
    input logic branch_send_i, resolution_i,
    input branch_tag_t tag_i,
    output logic old_consume_o, rr_valid_o, result_valid_o,
    output logic [ROB_IDX_WIDTH-1:0] result_rob_o,
    output logic complete_valid_o [o3_cfg_pkg::O3_CFG.be.exec.num_alu+o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes:0],
    output logic [ROB_IDX_WIDTH-1:0] complete_idx_o [o3_cfg_pkg::O3_CFG.be.exec.num_alu+o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes:0],
    output logic pressure_load_consume_o,
    output logic [31:0] cfg_tags_o
);
    localparam int ALUS=o3_cfg_pkg::O3_CFG.be.exec.num_alu;
    localparam int P=o3_cfg_pkg::O3_CFG.be.lsu.agu_pipes;
    load_result_t load_q [P];
    logic load_consume [P];
    renamed_uop_t issue [ALUS-1:0];
    int_execute_result_t results [ALUS-1:0];
    int_regread_pipe_uop_t rr [ALUS-1:0];
    logic consume [ALUS-1:0];
    branch_resolution_t resolution;
    branch_result_t branch_q;
    logic branch_consume;
    always_comb begin
        resolution='0;resolution.valid=resolution_i;
        resolution.mispredict=resolution_i;resolution.branch_tag=tag_i;
        for (int n=0;n<ALUS;n++) begin
            issue[n]='0;issue[n].valid=grant_i[n];
            issue[n].rob_idx=n==0?rob0_i:rob1_i;
            issue[n].branch_mask=n==0?mask0_i:mask1_i;
            issue[n].rd=5'(n+1);issue[n].rd_write_en=1;
            issue[n].dst_preg=PREG_IDX_WIDTH'(n+32);
            issue[n].use_imm=1;issue[n].imm_type=IMM_TYPE_I;issue[n].imm_raw=1;
        end
    end
    for(genvar n=0;n<ALUS;n++) begin : g_alu
        alu_pipe #(.CFG(o3_cfg_pkg::O3_CFG.be)) u_alu(
            .clk(clk),.rst(rst),.issue_uop_i(issue[n]),.read_grant_i(grant_i[n]),
            .src1_data_i('0),.src2_data_i('0),.resolution_i(resolution),
            .result_consume_i(consume[n]),.regread_ready_o(),.result_o(results[n]),
            .obs_regread_o(rr[n]),.obs_exec_result_o());
    end
    // One-shot JAL-link producer follows ready/valid holding rules.
    always_ff @(posedge clk) begin
        if(rst) branch_q<='0;
        else if(branch_send_i) begin
            branch_q<='0;branch_q.valid<=1;branch_q.rob_idx<=0;
            branch_q.dst_write_en<=1;branch_q.dst_preg<=34;branch_q.link_value<=64'h80000004;
        end else if(branch_consume) branch_q.valid<=0;
    end
    // L8a has three INT writes. Add an older held load head so branch ROB0,
    // ALU ROB1 and load ROB2 occupy all ports while ALU ROB3 must hold.
    // This public result model clears only on its real consume handshake.
    always_ff @(posedge clk) begin
        if(rst) begin
            for(int p=0;p<P;p++) load_q[p]<='0;
        end else if(branch_send_i) begin
            load_q[0]<='0;load_q[0].valid<=1;load_q[0].rob_idx<=2;
            load_q[0].dst_preg<=35;load_q[0].dst_dom<=o3_types_pkg::RD_INT;
            load_q[0].result<=64'h55;
        end else if(load_consume[0]) load_q[0].valid<=0;
    end
    assign pressure_load_consume_o=load_q[0].valid && load_consume[0];
    writeback_arbiter #(.CFG(o3_cfg_pkg::O3_CFG.be)) u_wb(
        .flush_all_i(1'b0),.alu_result_i(results),.load_result_i(load_q),.branch_result_i(branch_q),.rob_head_i('0),
        .resolution_valid_i(resolution_i),.resolution_mispredict_i(resolution_i),.resolution_tag_i(tag_i),
        .alu_consume_o(consume),.load_consume_o(load_consume),.branch_consume_o(branch_consume),
        .prf_wr_en_o(),.prf_wr_addr_o(),.prf_wr_data_o(),
        .complete_valid_o(complete_valid_o),.complete_idx_o(complete_idx_o),.complete_data_o(),
        .extra_src_i('{default:'0}),.extra_consume_o());
    assign old_consume_o=consume[0];assign rr_valid_o=rr[0].valid;
    assign result_valid_o=results[0].valid;assign result_rob_o=results[0].rob_idx;
    assign cfg_tags_o=BACKEND_NUM_BRANCH_CHECKPOINTS;
endmodule
