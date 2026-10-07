/**
 * INT writeback arbitration by ROB age (B13/B14/B15/B33).
 * ALU, integer load, branch link and extra MUL/DIV/FP->INT candidates compete for
 * INT PRF ports. FP->INT extra slots 2/3 preserve each result's fflags. x0 results
 * complete without a PRF port and still report flags. Unselected live results stay held.
 * Global flush and misprediction filter all writes and completion in the same cycle;
 * canceled results are consumed for discard without completing a reused ROB entry.
 * AMO remains outside L9; CSR keeps the serialized head path in backend.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行。
 * Pure combinational N grants; N edge updates PRF/ready/ROB with the same event;
 * N+1 ungranted producer heads still hold their numerical result and identity.
 */
module writeback_arbiter
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int P=CFG.lsu.agu_pipes,
    localparam int NUM_ALUS = CFG.exec.num_alu,
    localparam int PRF_WRITE_PORTS = CFG.exec.int_prf_write_ports,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    // 目标新增整数写回源（框架，未接入选择逻辑）：
    //   0 MUL、1 DIV、2 FP-MISC→INT（比较/分类）、3 FP-CONV→INT（F2I/FMV.X）、4 CSR、5 AMO/LR/SC
    localparam int NUM_EXTRA_SRC = 6
) (
    input logic flush_all_i,
    input int_execute_result_t alu_result_i [NUM_ALUS-1:0],
    input load_result_t load_result_i[P],
    input branch_result_t branch_result_i,
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_head_i,
    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,

    output logic alu_consume_o [NUM_ALUS-1:0],
    output logic load_consume_o[P],
    output logic branch_consume_o,
    output logic prf_wr_en_o [PRF_WRITE_PORTS-1:0],
    output logic [PREG_IDX_WIDTH-1:0] prf_wr_addr_o [PRF_WRITE_PORTS-1:0],
    output logic [XLEN-1:0] prf_wr_data_o [PRF_WRITE_PORTS-1:0],
    output logic complete_valid_o [NUM_ALUS+P:0],
    output logic [ROB_IDX_WIDTH-1:0] complete_idx_o [NUM_ALUS+P:0],
    output logic [XLEN-1:0] complete_data_o [NUM_ALUS+P:0],

    // ---------------- L6 extra 源：M 已接入；其余由 backend 显式 tie-off ----------------
    input  o3_types_pkg::wb_req_t extra_src_i [NUM_EXTRA_SRC],
    output logic                  extra_consume_o [NUM_EXTRA_SRC],
    output logic extra_complete_valid_o [NUM_EXTRA_SRC],
    output logic [ROB_IDX_WIDTH-1:0] extra_complete_idx_o [NUM_EXTRA_SRC],
    output logic [XLEN-1:0] extra_complete_data_o [NUM_EXTRA_SRC],
    output logic [o3_isa_pkg::FFLAGS_W-1:0] extra_complete_fflags_o [NUM_EXTRA_SRC]
);
    localparam int NUM_SOURCES = NUM_ALUS + P + 1 + NUM_EXTRA_SRC;
    logic candidate_valid [NUM_SOURCES-1:0];
    logic [ROB_IDX_WIDTH-1:0] candidate_rob [NUM_SOURCES-1:0];
    logic [PREG_IDX_WIDTH-1:0] candidate_dst [NUM_SOURCES-1:0];
    logic [XLEN-1:0] candidate_data [NUM_SOURCES-1:0];
    logic selected [NUM_SOURCES-1:0];

    function automatic int unsigned rob_distance(input logic [ROB_IDX_WIDTH-1:0] idx);
        rob_distance = (int'(idx) + NUM_ROB_ENTRIES - int'(rob_head_i)) % NUM_ROB_ENTRIES;
    endfunction

    function automatic logic killed(input branch_mask_t mask);
        killed = flush_all_i || (resolution_valid_i && resolution_mispredict_i && mask[resolution_tag_i]);
    endfunction

    always_comb begin
        candidate_valid = '{default: 1'b0};
        candidate_rob = '{default: '0};
        candidate_dst = '{default: '0};
        candidate_data = '{default: '0};
        selected = '{default: 1'b0};
        prf_wr_en_o = '{default: 1'b0};
        prf_wr_addr_o = '{default: '0};
        prf_wr_data_o = '{default: '0};
        complete_valid_o = '{default: 1'b0};
        complete_idx_o = '{default: '0};
        complete_data_o = '{default: '0};

        for (int alu = 0; alu < NUM_ALUS; alu++) begin
            candidate_valid[alu] = alu_result_i[alu].valid
                                && alu_result_i[alu].dst_write_en
                                && !killed(alu_result_i[alu].branch_mask);
            candidate_rob[alu] = alu_result_i[alu].rob_idx;
            candidate_dst[alu] = alu_result_i[alu].dst_preg;
            candidate_data[alu] = alu_result_i[alu].result;
        end
        for(int p=0;p<P;p++) begin
        candidate_valid[NUM_ALUS+p] = load_result_i[p].valid
                                  && !killed(load_result_i[p].branch_mask);
        candidate_rob[NUM_ALUS+p] = load_result_i[p].rob_idx;
        candidate_dst[NUM_ALUS+p] = load_result_i[p].dst_preg;
        candidate_data[NUM_ALUS+p] = load_result_i[p].result;
        end
        candidate_valid[NUM_ALUS+P] = branch_result_i.valid && !branch_result_i.exc.valid
                                    && branch_result_i.dst_write_en
                                    && !killed(branch_result_i.branch_mask);
        candidate_rob[NUM_ALUS+P] = branch_result_i.rob_idx;
        candidate_dst[NUM_ALUS+P] = branch_result_i.dst_preg;
        candidate_data[NUM_ALUS+P] = branch_result_i.link_value;

        for(int e=0;e<NUM_EXTRA_SRC;e++) begin
            candidate_valid[NUM_ALUS+P+1+e]=extra_src_i[e].valid && extra_src_i[e].tag.dst_write_en &&
                !killed(extra_src_i[e].tag.br_mask);
            candidate_rob[NUM_ALUS+P+1+e]=extra_src_i[e].tag.rob_idx;
            candidate_dst[NUM_ALUS+P+1+e]=extra_src_i[e].tag.dst_preg;
            candidate_data[NUM_ALUS+P+1+e]=extra_src_i[e].data;
        end
        for (int port = 0; port < PRF_WRITE_PORTS; port++) begin
            int chosen;
            int unsigned chosen_age;
            chosen = -1;
            chosen_age = NUM_ROB_ENTRIES;
            for (int src = 0; src < NUM_SOURCES; src++) begin
                if (candidate_valid[src] && !selected[src]
                 && ((chosen < 0) || (rob_distance(candidate_rob[src]) < chosen_age))) begin
                    chosen = src;
                    chosen_age = rob_distance(candidate_rob[src]);
                end
            end
            if (chosen >= 0) begin
                selected[chosen] = 1'b1;
                prf_wr_en_o[port] = 1'b1;
                prf_wr_addr_o[port] = candidate_dst[chosen];
                prf_wr_data_o[port] = candidate_data[chosen];
            end
        end

        for (int alu = 0; alu < NUM_ALUS; alu++) begin
            alu_consume_o[alu] = !alu_result_i[alu].valid
                              || killed(alu_result_i[alu].branch_mask)
                              || !alu_result_i[alu].dst_write_en
                              || selected[alu];
            complete_valid_o[alu] = alu_result_i[alu].valid
                                  && !killed(alu_result_i[alu].branch_mask)
                                  && (!alu_result_i[alu].dst_write_en || selected[alu]);
            complete_idx_o[alu] = alu_result_i[alu].rob_idx;
            complete_data_o[alu] = alu_result_i[alu].result;
        end
        for(int p=0;p<P;p++) begin
        load_consume_o[p] = !load_result_i[p].valid
                       || killed(load_result_i[p].branch_mask)
                       || selected[NUM_ALUS+p];
        complete_valid_o[NUM_ALUS+p] = load_result_i[p].valid
                                   && !killed(load_result_i[p].branch_mask)
                                   && selected[NUM_ALUS+p];
        complete_idx_o[NUM_ALUS+p] = load_result_i[p].rob_idx;
        complete_data_o[NUM_ALUS+p] = load_result_i[p].result;
        end
        for(int e=0;e<NUM_EXTRA_SRC;e++) begin
            extra_consume_o[e]=!extra_src_i[e].valid || killed(extra_src_i[e].tag.br_mask) ||
                !extra_src_i[e].tag.dst_write_en || selected[NUM_ALUS+P+1+e];
            extra_complete_valid_o[e]=extra_src_i[e].valid && !killed(extra_src_i[e].tag.br_mask) &&
                (!extra_src_i[e].tag.dst_write_en || selected[NUM_ALUS+P+1+e]);
            extra_complete_idx_o[e]=extra_src_i[e].tag.rob_idx;
            extra_complete_data_o[e]=extra_src_i[e].data;
            extra_complete_fflags_o[e]=extra_src_i[e].fflags;
        end
        branch_consume_o = !branch_result_i.valid || branch_result_i.exc.valid
                         || killed(branch_result_i.branch_mask)
                         || !branch_result_i.dst_write_en
                         || selected[NUM_ALUS+P];
        complete_valid_o[NUM_ALUS+P] = branch_result_i.valid && !branch_result_i.exc.valid
                                     && branch_result_i.dst_write_en
                                     && !killed(branch_result_i.branch_mask)
                                     && selected[NUM_ALUS+P];
        complete_idx_o[NUM_ALUS+P] = branch_result_i.rob_idx;
        complete_data_o[NUM_ALUS+P] = branch_result_i.link_value;
    end
endmodule
