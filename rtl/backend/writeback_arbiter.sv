/**
 * Shared PRF writeback arbiter
 *
 * Integer、Load和JAL/JALR链接值结果保持寄存器竞争
 * PRF_WRITE_PORTS physical write ports. Candidates are selected oldest-first relative to
 * current ROB head. A producer is consumed only when killed, when it has no architectural
 * destination, or when it wins a write port. PRF write, wakeup and ROB complete therefore
 * share one atomic grant event.
 *
 * This block is combinational. Holding/backpressure state remains owned by each producer.
 */
module writeback_arbiter
    import o3_pkg::*;
#(
    parameter int NUM_ALUS = BACKEND_NUM_INT_ALUS,
    parameter int PRF_WRITE_PORTS = BACKEND_NUM_INT_ALUS,
    parameter int NUM_ROB_ENTRIES = BACKEND_NUM_ROB_ENTRIES
) (
    input int_execute_result_t alu_result_i [NUM_ALUS-1:0],
    input load_result_t load_result_i,
    input branch_result_t branch_result_i,
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_head_i,
    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,

    output logic alu_consume_o [NUM_ALUS-1:0],
    output logic load_consume_o,
    output logic branch_consume_o,
    output logic prf_wr_en_o [PRF_WRITE_PORTS-1:0],
    output logic [PREG_IDX_WIDTH-1:0] prf_wr_addr_o [PRF_WRITE_PORTS-1:0],
    output logic [XLEN-1:0] prf_wr_data_o [PRF_WRITE_PORTS-1:0],
    output logic complete_valid_o [NUM_ALUS+1:0],
    output logic [ROB_IDX_WIDTH-1:0] complete_idx_o [NUM_ALUS+1:0],
    output logic [XLEN-1:0] complete_data_o [NUM_ALUS+1:0]
);
    localparam int NUM_SOURCES = NUM_ALUS + 2;
    logic candidate_valid [NUM_SOURCES-1:0];
    logic [ROB_IDX_WIDTH-1:0] candidate_rob [NUM_SOURCES-1:0];
    logic [PREG_IDX_WIDTH-1:0] candidate_dst [NUM_SOURCES-1:0];
    logic [XLEN-1:0] candidate_data [NUM_SOURCES-1:0];
    logic selected [NUM_SOURCES-1:0];

    function automatic int unsigned rob_distance(input logic [ROB_IDX_WIDTH-1:0] idx);
        rob_distance = (int'(idx) + NUM_ROB_ENTRIES - int'(rob_head_i)) % NUM_ROB_ENTRIES;
    endfunction

    function automatic logic killed(input branch_mask_t mask);
        killed = resolution_valid_i && resolution_mispredict_i && mask[resolution_tag_i];
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
        candidate_valid[NUM_ALUS] = load_result_i.valid
                                  && !killed(load_result_i.branch_mask);
        candidate_rob[NUM_ALUS] = load_result_i.rob_idx;
        candidate_dst[NUM_ALUS] = load_result_i.dst_preg;
        candidate_data[NUM_ALUS] = load_result_i.result;
        candidate_valid[NUM_ALUS+1] = branch_result_i.valid
                                    && branch_result_i.dst_write_en
                                    && !killed(branch_result_i.branch_mask);
        candidate_rob[NUM_ALUS+1] = branch_result_i.rob_idx;
        candidate_dst[NUM_ALUS+1] = branch_result_i.dst_preg;
        candidate_data[NUM_ALUS+1] = branch_result_i.link_value;

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
        load_consume_o = !load_result_i.valid
                       || killed(load_result_i.branch_mask)
                       || selected[NUM_ALUS];
        complete_valid_o[NUM_ALUS] = load_result_i.valid
                                   && !killed(load_result_i.branch_mask)
                                   && selected[NUM_ALUS];
        complete_idx_o[NUM_ALUS] = load_result_i.rob_idx;
        complete_data_o[NUM_ALUS] = load_result_i.result;
        branch_consume_o = !branch_result_i.valid
                         || killed(branch_result_i.branch_mask)
                         || !branch_result_i.dst_write_en
                         || selected[NUM_ALUS+1];
        complete_valid_o[NUM_ALUS+1] = branch_result_i.valid
                                     && branch_result_i.dst_write_en
                                     && !killed(branch_result_i.branch_mask)
                                     && selected[NUM_ALUS+1];
        complete_idx_o[NUM_ALUS+1] = branch_result_i.rob_idx;
        complete_data_o[NUM_ALUS+1] = branch_result_i.link_value;
    end
endmodule
