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
    localparam int NUM_SRC=CFG.exec.num_fma+CFG.exec.num_fdivsqrt+CFG.exec.num_fmisc+CFG.exec.num_fconv+CFG.lsu.agu_pipes
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
    always_comb begin
        logic selected [NUM_SRC];
        selected='{default:0};
        prf_wr_en_o='{default:0}; prf_wr_addr_o='{default:'0}; prf_wr_data_o='{default:'0};
        complete_valid_o='{default:0}; complete_idx_o='{default:'0};
        complete_data_o='{default:'0}; complete_fflags_o='{default:'0};
        for (int s=0;s<NUM_SRC;s++) consume_o[s]=!src_i[s].valid || killed(src_i[s].tag.br_mask);
        for (int p=0;p<WRITE_PORTS;p++) begin
            int chosen;
            chosen=-1;
            for (int s=0;s<NUM_SRC;s++)
                if (src_i[s].valid && src_i[s].tag.dst_dom==o3_types_pkg::RD_FP &&
                    !killed(src_i[s].tag.br_mask) && !selected[s]) begin
                    if (chosen<0) chosen=s;
                    else if (age(src_i[s].tag.rob_idx)<age(src_i[chosen].tag.rob_idx)) chosen=s;
                end
            if (chosen>=0) begin
                selected[chosen]=1; consume_o[chosen]=1;
                prf_wr_en_o[p]=src_i[chosen].tag.dst_write_en;
                prf_wr_addr_o[p]=src_i[chosen].tag.dst_preg; prf_wr_data_o[p]=src_i[chosen].data;
                complete_valid_o[p]=1; complete_idx_o[p]=src_i[chosen].tag.rob_idx;
                complete_data_o[p]=src_i[chosen].data; complete_fflags_o[p]=src_i[chosen].fflags;
            end
        end
    end
endmodule
