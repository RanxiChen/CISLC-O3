/**
 * L9 FP writeback: oldest-first two-port grant. Pure combinational arbitration.
 * N: filter cancellation, select sources and return consume; N edge: PRF/ready/ROB
 * accept the same grant. N+1: other candidates remain in producer holding slots.
 * Global flush forbids writes/completion in its own cycle; killed results are discarded.
 * B33 early wakeup for FP FUs is deferred to performance work; actual PRF writes wake IQs.
 * 当前实现状态：闭环简化（L9）；功能与 lint 未运行。
 */
module fp_writeback_arbiter import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,
    localparam int WRITE_PORTS=CFG.exec.fp_prf_write_ports,
    parameter int NUM_SRC=CFG.exec.num_fma+CFG.exec.num_fdivsqrt+CFG.exec.num_fmisc+CFG.exec.num_fconv+CFG.lsu.agu_pipes
) (
    input o3_types_pkg::wb_req_t src_i [NUM_SRC],
    output logic consume_o [NUM_SRC],
    input logic [ROB_IDX_WIDTH-1:0] rob_head_i,
    input branch_resolution_t resolution_i,
    input logic flush_all_i,
    output logic prf_wr_en_o [WRITE_PORTS],
    output logic [PREG_IDX_WIDTH-1:0] prf_wr_addr_o [WRITE_PORTS],
    output logic [XLEN-1:0] prf_wr_data_o [WRITE_PORTS],
    output logic complete_valid_o [WRITE_PORTS],
    output logic [ROB_IDX_WIDTH-1:0] complete_idx_o [WRITE_PORTS],
    output logic [XLEN-1:0] complete_data_o [WRITE_PORTS],
    output logic [o3_isa_pkg::FFLAGS_W-1:0] complete_fflags_o [WRITE_PORTS]
);
    function automatic logic killed(input branch_mask_t mask);
        return flush_all_i || (resolution_i.valid && resolution_i.mispredict && mask[resolution_i.branch_tag]);
    endfunction
    function automatic int age(input logic [ROB_IDX_WIDTH-1:0] idx);
        return (int'(idx)+CFG.rob.entries-int'(rob_head_i)) % CFG.rob.entries;
    endfunction
    localparam int LEAVES = 1 << $clog2(NUM_SRC);
    localparam int RANK_W = $clog2(NUM_SRC+1);
    logic grant_by_port [WRITE_PORTS][NUM_SRC];
    always_comb begin
        int ages [NUM_SRC];
        logic eligible [NUM_SRC];
        logic [RANK_W-1:0] counts [NUM_SRC][2*LEAVES];
        counts = '{default:'{default:'0}};
        for (int src=0;src<NUM_SRC;src++) begin
            ages[src]=age(src_i[src].tag.rob_idx);
            eligible[src]=src_i[src].valid && src_i[src].tag.dst_dom==o3_types_pkg::RD_FP
                && !killed(src_i[src].tag.br_mask);
        end
        for (int src=0;src<NUM_SRC;src++) begin
            for (int other=0;other<NUM_SRC;other++)
                counts[src][LEAVES+other]=RANK_W'(eligible[other]
                    && (ages[other]<ages[src] || (ages[other]==ages[src] && other<src)));
            for (int node=LEAVES-1;node>0;node--)
                counts[src][node]=counts[src][2*node]+counts[src][2*node+1];
            for (int port=0;port<WRITE_PORTS;port++)
                grant_by_port[port][src]=eligible[src] && port<NUM_SRC
                    && counts[src][1]==RANK_W'(port);
        end
    end

    always_comb begin
        prf_wr_en_o='{default:0}; prf_wr_addr_o='{default:'0}; prf_wr_data_o='{default:'0};
        complete_valid_o='{default:0}; complete_idx_o='{default:'0};
        complete_data_o='{default:'0}; complete_fflags_o='{default:'0};
        for (int s=0;s<NUM_SRC;s++) consume_o[s]=!src_i[s].valid || killed(src_i[s].tag.br_mask);
        for (int p=0;p<WRITE_PORTS;p++) begin
            for (int s=0;s<NUM_SRC;s++) begin
                logic grant;
                grant = grant_by_port[p][s];
                consume_o[s] |= grant;
                prf_wr_en_o[p] |= grant && src_i[s].tag.dst_write_en;
                prf_wr_addr_o[p] |= src_i[s].tag.dst_preg & {PREG_IDX_WIDTH{grant}};
                prf_wr_data_o[p] |= src_i[s].data & {XLEN{grant}};
                complete_valid_o[p] |= grant;
                complete_idx_o[p] |= src_i[s].tag.rob_idx & {ROB_IDX_WIDTH{grant}};
                complete_data_o[p] |= src_i[s].data & {XLEN{grant}};
                complete_fflags_o[p] |= src_i[s].fflags & {o3_isa_pkg::FFLAGS_W{grant}};
            end
        end
    end
endmodule
