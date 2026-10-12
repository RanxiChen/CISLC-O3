/**
 * Domain-qualified backend issue queue (B14/B15/B33).
 * Every source has a domain and cached readiness; wake/ready checks compare only the
 * corresponding register domain. src3 participates in FMA dependencies. No same-cycle
 * wake-select bypass: a received writeback becomes selectable on the following cycle.
 * FP: depth CFG.dispatch.fp_iq_depth, oldest-ready dual issue; five RegRead capacities
 * prevent repeated FU selection, at most one INT-source FP candidate per cycle.
 * INT: independent selection width and FU-buffer capacity, fused-pair handling.
 * MEM: two oldest-ready candidates; LQ/SQ/cache capacities arbitrate after its buffers.
 * INT selection budgets per-FU issue-buffer capacity. Only a buffer enqueue handshake
 * deletes an INT candidate; read-port denial keeps it in the buffer, outside this IQ.
 * FP/MEM/BR also leave IQ on registered issue-buffer acceptance.
 * Correct resolution clears masks; misprediction removes dependent younger entries.
 * Notices and ready bits permit scheduling only. Buffer read grants recheck real data.
 * 当前实现状态：闭环简化（L9）；本次重构尚未功能验证。
 * Dispatch source readiness is decoded once per incoming lane in parallel with row allocation.
 * I0: select stored-ready candidates and enqueue independently into FU buffers.
 * I0 edge: record accepted physical rows; exclude them immediately thereafter.
 * I1: compact/reclaim those registered rows and reuse their registered credits.
 * Independent instructions still issue/enqueue at the original width each cycle;
 * branch kill/clear, public capacity and payload visibility retain their old edges.
 * 测试：sim/cocotb/backend_issue_queue/（MEM load 顺序、store bypass、replay 门控）。
 */
module backend_issue_queue
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  o3_types_pkg::iq_kind_e KIND,          // 实例选择，无默认值
    localparam int ENQ_WIDTH = CFG.dispatch.width,
    localparam int ISSUE_WIDTH = (KIND == o3_types_pkg::IQ_INT) ? CFG.exec.int_issue_width : (KIND == o3_types_pkg::IQ_FP ? 2 : (KIND==o3_types_pkg::IQ_MEM ? CFG.lsu.agu_pipes:1)),
    parameter int WAKEUP_WIDTH = CFG.exec.int_prf_write_ports,
    parameter int FP_WAKEUP_WIDTH = CFG.exec.fp_prf_write_ports,
    localparam int DEPTH = (KIND == o3_types_pkg::IQ_INT) ? CFG.dispatch.int_iq_depth
                         : (KIND == o3_types_pkg::IQ_MEM) ? CFG.dispatch.mem_iq_depth
                         : (KIND == o3_types_pkg::IQ_BR)  ? CFG.dispatch.br_iq_depth
                         : CFG.dispatch.fp_iq_depth,
    localparam int NUM_PHYS_REGS = CFG.rename.int_phys_regs,
    localparam bit OLDEST_ONLY = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  renamed_uop_t [ENQ_WIDTH-1:0] enq_uop_i,
    input  logic enq_fire_i,
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,

    input  logic preg_ready_i [NUM_PHYS_REGS-1:0],
    input logic fp_preg_ready_i [CFG.rename.fp_phys_regs-1:0],
    input logic fp_wakeup_valid_i [FP_WAKEUP_WIDTH-1:0],
    input logic [PREG_IDX_WIDTH-1:0] fp_wakeup_preg_i [FP_WAKEUP_WIDTH-1:0],
    // FU indices: FMA0, FMA1, DIVSQRT, MISC, CONV; capacity of RegRead slots.
    input logic [4:0] fp_regread_ready_i,
    output logic [2:0] issue_fp_fu_o [ISSUE_WIDTH-1:0],
    output logic [$clog2(CFG.exec.num_alu+2)-1:0] issue_int_fu_o [ISSUE_WIDTH-1:0],
    input  logic mul_ready_i, mul_pair_ready_i, div_ready_i,
    // INT: destination issue-buffer capacities. Default preserves standalone callers.
    input logic [CFG.exec.num_alu-1:0] alu_buffer_ready_i = '1,
    input  logic wakeup_valid_i [WAKEUP_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0] wakeup_preg_i [WAKEUP_WIDTH-1:0],
    output renamed_uop_t [ISSUE_WIDTH-1:0] issue_uop_o,
    output logic [ISSUE_WIDTH-1:0] issue_valid_o,
    input  logic [ISSUE_WIDTH-1:0] issue_ready_i,

    input  logic resolution_valid_i,
    input  logic resolution_mispredict_i,
    input  branch_tag_t resolution_tag_i
);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);

    localparam int INDEX_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int UOP_BITS = $bits(renamed_uop_t);
    typedef logic [INDEX_WIDTH-1:0] index_t;
    typedef struct packed {
        o3_types_pkg::fu_class_e fu_class;
        o3_types_pkg::reg_domain_e rs1_dom, rs2_dom, rs3_dom;
        logic rs3_read_en;
    } sched_ext_t;
    typedef struct packed { logic [PREG_IDX_WIDTH-1:0] src3_preg; } sched_rext_t;
    typedef struct packed { branch_mask_t br_mask; } sched_tag_t;
    typedef struct packed { logic valid; sched_tag_t lo_tag; } sched_fuse_t;
    typedef struct packed {
        logic valid, rs1_read_en, rs2_read_en;
        logic [PREG_IDX_WIDTH-1:0] src1_preg, src2_preg;
        sched_ext_t ext;
        sched_rext_t rext;
        sched_fuse_t mdu_fuse;
        branch_mask_t branch_mask;
    } sched_t;

    // Scheduling and wakeup inspect only this narrow record. The full uop
    // stays at a fixed physical slot in single-writer RAM banks until issue;
    // recovery moves slot indices. Per-row writer tags choose the live payload.
    localparam int WRITER_W=ENQ_WIDTH>1 ? $clog2(ENQ_WIDTH):1;
    logic [WRITER_W-1:0] writer_q[DEPTH];
    logic [UOP_BITS-1:0] bank_read[ENQ_WIDTH][ISSUE_WIDTH];
    renamed_uop_t payload_read[ISSUE_WIDTH];
    index_t selected_physical[ISSUE_WIDTH];
    sched_t sched_q [DEPTH];
    sched_t queue_q [DEPTH];
    index_t order_q [DEPTH], order_next [DEPTH], alloc_index [ENQ_WIDTH];
    logic [DEPTH-1:0] used_q, used_next, keep, remove_mask;
    // I0 transfers an instruction to its FU buffer. I1 reclaims its IQ row
    // using the registered acknowledgement. No current buffer handshake feeds
    // queue compaction or dispatch allocation. Acknowledged rows are immediately
    // excluded from selection, and their registered credit allows reuse at I1.
    logic [DEPTH-1:0] accepted_q, accepted_next;
    logic [COUNT_WIDTH-1:0] accepted_count;
    logic oldest_live[DEPTH];
    logic [ENQ_WIDTH-1:0] append;
    logic [COUNT_WIDTH-1:0] rank [DEPTH], append_rank [ENQ_WIDTH];
    localparam int PREFIX_LEVELS=$clog2(DEPTH);
    logic [COUNT_WIDTH-1:0] keep_prefix[PREFIX_LEVELS+1][DEPTH];
    logic [COUNT_WIDTH-1:0] count_q, count_next, survivors, incoming;
    logic ready1_q [DEPTH], ready2_q [DEPTH], ready3_q [DEPTH];
    logic src1_ready_q [DEPTH], src2_ready_q [DEPTH], src3_ready_q [DEPTH];
    logic issue_selected_valid [ISSUE_WIDTH-1:0];
    index_t issue_selected_idx [ISSUE_WIDTH-1:0];

    function automatic sched_t scheduling_info(input renamed_uop_t uop);
        sched_t info;
        info = '0;
        info.valid = uop.valid;
        info.rs1_read_en = uop.rs1_read_en;
        info.rs2_read_en = uop.rs2_read_en;
        info.src1_preg = uop.src1_preg;
        info.src2_preg = uop.src2_preg;
        info.ext.fu_class = uop.ext.fu_class;
        info.ext.rs1_dom = uop.ext.rs1_dom;
        info.ext.rs2_dom = uop.ext.rs2_dom;
        info.ext.rs3_dom = uop.ext.rs3_dom;
        info.ext.rs3_read_en = uop.ext.rs3_read_en;
        info.rext.src3_preg = uop.rext.src3_preg;
        info.mdu_fuse.valid = uop.mdu_fuse.valid;
        info.mdu_fuse.lo_tag.br_mask = uop.mdu_fuse.lo_tag.br_mask;
        info.branch_mask = uop.branch_mask;
        return info;
    endfunction

    always_comb begin
        for (int idx = 0; idx < DEPTH; idx++) begin
            queue_q[idx] = idx < int'(count_q) ? sched_q[order_q[idx]] : sched_t'(0);
            queue_q[idx].valid &= !accepted_q[order_q[idx]];
            oldest_live[idx]=queue_q[idx].valid;
            for(int older=0;older<idx;older++) oldest_live[idx] &= !queue_q[older].valid;
            src1_ready_q[idx] = ready1_q[order_q[idx]];
            src2_ready_q[idx] = ready2_q[order_q[idx]];
            src3_ready_q[idx] = ready3_q[order_q[idx]];
        end
    end

    // Decode notices once per physical register, then share the readiness
    // bitmap across all queued operands. This is scheduling only: the operand
    // capture still checks actual PRF/WB/bypass availability before execution.
    // Cover the entire preg encoding so out-of-range notice behavior is unchanged.
    localparam int READY_ENCODINGS = 1 << PREG_IDX_WIDTH;
    logic int_schedule_ready [READY_ENCODINGS], fp_schedule_ready [READY_ENCODINGS];
    for (genvar preg = 0; preg < READY_ENCODINGS; preg++) begin : g_schedule_ready
        always_comb begin
            int_schedule_ready[preg] = 1'b0;
            fp_schedule_ready[preg] = 1'b0;
            if (preg < NUM_PHYS_REGS) int_schedule_ready[preg] = preg_ready_i[preg];
            if (preg < CFG.rename.fp_phys_regs) fp_schedule_ready[preg] = fp_preg_ready_i[preg];
            for (int p = 0; p < WAKEUP_WIDTH; p++)
                int_schedule_ready[preg] |= wakeup_valid_i[p] && wakeup_preg_i[p] == PREG_IDX_WIDTH'(preg);
            for (int p = 0; p < FP_WAKEUP_WIDTH; p++)
                fp_schedule_ready[preg] |= fp_wakeup_valid_i[p] && fp_wakeup_preg_i[p] == PREG_IDX_WIDTH'(preg);
        end
    end
    function automatic logic source_ready(input o3_types_pkg::reg_domain_e dom,
        input logic [PREG_IDX_WIDTH-1:0] preg);
        case (dom)
            o3_types_pkg::RD_NONE: return 1'b1;
            o3_types_pkg::RD_INT: return int_schedule_ready[preg];
            o3_types_pkg::RD_FP: return fp_schedule_ready[preg];
            default: return 1'b0;
        endcase
    endfunction

    function automatic int available_fp_fu(input o3_types_pkg::fu_class_e cls,
        input logic [4:0] available);
        case (cls)
            o3_types_pkg::FU_FMA: begin
                if (available[0]) return 0;
                if (available[1]) return 1;
            end
            o3_types_pkg::FU_FDIVSQRT: if (available[2]) return 2;
            o3_types_pkg::FU_FMISC: if (available[3]) return 3;
            o3_types_pkg::FU_FCONV: if (available[4]) return 4;
            default: ;
        endcase
        return -1;
    endfunction

    for(genvar wb=0;wb<ENQ_WIDTH;wb++) begin : g_write_bank
        for(genvar rp=0;rp<ISSUE_WIDTH;rp++) begin : g_read_replica
            (* ram_style="distributed" *) logic [UOP_BITS-1:0] mem[DEPTH];
            always_ff @(posedge clk) if(!rst && append[wb])
                mem[alloc_index[wb]]<=UOP_BITS'(enq_uop_i[wb]);
            assign bank_read[wb][rp]=mem[selected_physical[rp]];
        end
    end
    for(genvar rp=0;rp<ISSUE_WIDTH;rp++) begin : g_payload_read
        always_comb begin
            payload_read[rp]='0;
            for(int wb=0;wb<ENQ_WIDTH;wb++)
                payload_read[rp]|=renamed_uop_t'(bank_read[wb][rp] &
                    {UOP_BITS{writer_q[selected_physical[rp]]==WRITER_W'(wb)}});
            issue_uop_o[rp]='0;
            if(issue_valid_o[rp]) begin
                issue_uop_o[rp]=payload_read[rp];
                issue_uop_o[rp].branch_mask=sched_q[selected_physical[rp]].branch_mask;
                issue_uop_o[rp].mdu_fuse.lo_tag.br_mask=sched_q[selected_physical[rp]].mdu_fuse.lo_tag.br_mask;
                if(resolution_valid_i) begin
                    issue_uop_o[rp].branch_mask[resolution_tag_i]=0;
                    issue_uop_o[rp].mdu_fuse.lo_tag.br_mask[resolution_tag_i]=0;
                end
            end
        end
    end

    always_comb begin
        accepted_count='0;
        for(int slot=0;slot<DEPTH;slot++) accepted_count+=COUNT_WIDTH'(accepted_q[slot]);
    end
    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q + accepted_count;

    // INT selection: gather the oldest candidates in each independent FU
    // class, then rank their narrow age positions in parallel. No wide payload
    // participates in priority; RAM reads follow the selected physical indices.
    if(KIND==o3_types_pkg::IQ_INT) begin : g_int_select
        localparam int CANDIDATES=CFG.exec.num_alu+2;
        localparam int CAND_RANK_W=$clog2(CANDIDATES+1);
        logic [DEPTH-1:0] group_ready[3],candidate_oh[CANDIDATES],alu_remaining;
        logic [CANDIDATES-1:0] candidate_valid;
        index_t candidate_age[CANDIDATES];
        logic [$clog2(CFG.exec.num_alu+2)-1:0] candidate_fu[CANDIDATES];
        logic [CAND_RANK_W-1:0] candidate_rank[CANDIDATES];
        logic [$clog2(CFG.exec.num_alu+1)-1:0] alu_capacity;
        function automatic logic [DEPTH-1:0] oldest_onehot(input logic [DEPTH-1:0] eligible);
            logic [DEPTH-1:0] result;
            for(int n=0;n<DEPTH;n++)
                result[n]=eligible[n] && !(|(eligible & ((DEPTH'(1)<<n)-DEPTH'(1))));
            return result;
        endfunction
        always_comb begin
            group_ready='{default:'0};
            alu_capacity='0;
            for(int fu=0;fu<CFG.exec.num_alu;fu++)
                alu_capacity+=($clog2(CFG.exec.num_alu+1))'(alu_buffer_ready_i[fu]);
            for(int idx=0;idx<DEPTH;idx++) begin
                logic eligible;
                eligible=!(resolution_valid_i && resolution_mispredict_i) && queue_q[idx].valid &&
                    (!OLDEST_ONLY || oldest_live[idx]) &&
                    (!queue_q[idx].rs1_read_en || src1_ready_q[idx]) &&
                    (!queue_q[idx].rs2_read_en || src2_ready_q[idx]) &&
                    (!queue_q[idx].ext.rs3_read_en || src3_ready_q[idx]);
                case(queue_q[idx].ext.fu_class)
                    o3_types_pkg::FU_MUL:group_ready[1][idx]=eligible &&
                        (queue_q[idx].mdu_fuse.valid ? mul_pair_ready_i:mul_ready_i);
                    o3_types_pkg::FU_DIV:group_ready[2][idx]=eligible && div_ready_i;
                    default:group_ready[0][idx]=eligible;
                endcase
            end
            begin
                int ready_rank;
                ready_rank=0;
                for(int c=0;c<CANDIDATES;c++) candidate_fu[c]=($clog2(CFG.exec.num_alu+2))'(c);
                for(int fu=0;fu<CFG.exec.num_alu;fu++)
                    if(alu_buffer_ready_i[fu]) begin
                        candidate_fu[ready_rank]=($clog2(CFG.exec.num_alu+2))'(fu);
                        ready_rank++;
                    end
            end
            alu_remaining=group_ready[0];
            for(int c=0;c<CFG.exec.num_alu;c++) begin
                candidate_oh[c]=oldest_onehot(alu_remaining);
                if(c>=int'(alu_capacity)) candidate_oh[c]='0;
                alu_remaining &= ~candidate_oh[c];
            end
            candidate_oh[CFG.exec.num_alu]=oldest_onehot(group_ready[1]);
            candidate_oh[CFG.exec.num_alu+1]=oldest_onehot(group_ready[2]);
            for(int c=0;c<CANDIDATES;c++) begin
                candidate_valid[c]=|candidate_oh[c];
                candidate_age[c]='0;
                for(int idx=0;idx<DEPTH;idx++)
                    candidate_age[c]|=index_t'(idx) & {INDEX_WIDTH{candidate_oh[c][idx]}};
            end
        end
        always_comb begin
            for(int c=0;c<CANDIDATES;c++) begin
                candidate_rank[c]='0;
                for(int older=0;older<CANDIDATES;older++)
                    candidate_rank[c]+=CAND_RANK_W'(candidate_valid[older] && candidate_age[older]<candidate_age[c]);
            end
            issue_fp_fu_o='{default:'0};issue_int_fu_o='{default:'0};
            selected_physical='{default:'0};issue_valid_o='0;
            issue_selected_valid='{default:'0};issue_selected_idx='{default:'0};
            for(int port=0;port<ISSUE_WIDTH;port++)
                for(int c=0;c<CANDIDATES;c++)
                    if(candidate_valid[c] && candidate_rank[c]==CAND_RANK_W'(port)) begin
                        issue_valid_o[port]=1'b1;issue_selected_valid[port]=1'b1;
                        issue_int_fu_o[port]|=candidate_fu[c];
                        issue_selected_idx[port]|=candidate_age[c];
                        selected_physical[port]|=order_q[candidate_age[c]];
                    end
        end
    end else begin : g_other_select
    always_comb begin
        logic selected [DEPTH-1:0];
        logic picked_mul,picked_div,picked_fp_int;
        logic [4:0] fp_available;
        logic [$clog2(CFG.exec.num_alu+1)-1:0] alu_left;

        selected = '{default: 1'b0};picked_mul=0;picked_div=0;picked_fp_int=0;
        fp_available=fp_regread_ready_i;
        alu_left = 0;
        for (int lane = 0; lane < CFG.exec.num_alu; lane++)
            alu_left += ($clog2(CFG.exec.num_alu+1))'(alu_buffer_ready_i[lane]);
        issue_fp_fu_o='{default:'0};issue_int_fu_o='{default:'0};
        selected_physical = '{default:'0};
        issue_valid_o = '0;
        issue_selected_valid = '{default: 1'b0};
        issue_selected_idx = '{default: '0};

        // 每个端口依次选当前尚未选择的最老ready uop。
        for (int port = 0; port < ISSUE_WIDTH; port++) begin
            int chosen;
            chosen = -1;
            for (int idx = 0; idx < DEPTH; idx++) begin
                if (!(resolution_valid_i && resolution_mispredict_i) && (chosen < 0) && queue_q[idx].valid && !selected[idx]
                 && (!OLDEST_ONLY || oldest_live[idx])
                 && (KIND != o3_types_pkg::IQ_INT
                     || (queue_q[idx].ext.fu_class inside {o3_types_pkg::FU_MUL,o3_types_pkg::FU_DIV})
                     || alu_left > 0)
                 && (queue_q[idx].ext.fu_class!=o3_types_pkg::FU_MUL ||
                     (!picked_mul && (queue_q[idx].mdu_fuse.valid ? mul_pair_ready_i:mul_ready_i)))
                 && (queue_q[idx].ext.fu_class!=o3_types_pkg::FU_DIV || (!picked_div && div_ready_i))
                 && (KIND!=o3_types_pkg::IQ_FP ||
                     (available_fp_fu(queue_q[idx].ext.fu_class,fp_available)>=0 &&
                      !(picked_fp_int && queue_q[idx].rs1_read_en && queue_q[idx].ext.rs1_dom==o3_types_pkg::RD_INT)))
                 && (!queue_q[idx].ext.rs3_read_en || src3_ready_q[idx])
                 && (!queue_q[idx].rs1_read_en || src1_ready_q[idx])
                 && (!queue_q[idx].rs2_read_en || src2_ready_q[idx])) begin
                    chosen = idx;
                end
            end
            if (chosen >= 0) begin
                selected[chosen] = 1'b1;
                if (KIND==o3_types_pkg::IQ_FP) begin
                    issue_fp_fu_o[port]=3'(available_fp_fu(queue_q[chosen].ext.fu_class,fp_available));
                    fp_available[issue_fp_fu_o[port]]=0;
                    if (queue_q[chosen].rs1_read_en && queue_q[chosen].ext.rs1_dom==o3_types_pkg::RD_INT)
                        picked_fp_int=1;
                end
                if(queue_q[chosen].ext.fu_class==o3_types_pkg::FU_MUL) picked_mul=1;
                if(queue_q[chosen].ext.fu_class==o3_types_pkg::FU_DIV) picked_div=1;
                if (KIND == o3_types_pkg::IQ_INT
                    && !(queue_q[chosen].ext.fu_class inside {o3_types_pkg::FU_MUL,o3_types_pkg::FU_DIV})) alu_left--;
                selected_physical[port]=order_q[chosen];
                issue_valid_o[port] = 1'b1;
                issue_selected_valid[port] = 1'b1;
                issue_selected_idx[port] = index_t'(chosen);
            end
        end
    end

    end

    // I0 acknowledgement is the only state fed by the current buffer handshake.
    // I1 retirement/reuse uses accepted_q, never the current selection/ready path.
    always_comb begin
        accepted_next = '0;
        for (int port = 0; port < ISSUE_WIDTH; port++)
            if (issue_selected_valid[port] && issue_ready_i[port])
                accepted_next[selected_physical[port]] = 1'b1;
        remove_mask = '0;
        for(int idx=0;idx<DEPTH;idx++)
            remove_mask[idx]=accepted_q[order_q[idx]];
    end

    always_comb begin
        logic [DEPTH-1:0] available;
        keep = '0;
        survivors = '0;
        for (int idx = 0; idx < DEPTH; idx++) begin
            keep[idx] = idx < int'(count_q) && queue_q[idx].valid && !remove_mask[idx]
                && !(resolution_valid_i && resolution_mispredict_i
                     && queue_q[idx].branch_mask[resolution_tag_i]);
            keep_prefix[0][idx]=COUNT_WIDTH'(keep[idx]);
        end
        // Parallel prefix over survivor bits. Each level doubles the covered
        // age range; no DEPTH-long carry chain follows the issue handshake.
        for(int level=0;level<PREFIX_LEVELS;level++)
            for(int idx=0;idx<DEPTH;idx++) begin
                keep_prefix[level+1][idx]=keep_prefix[level][idx];
                if(idx >= (1<<level))
                    keep_prefix[level+1][idx]+=keep_prefix[level][idx-(1<<level)];
            end
        for(int idx=0;idx<DEPTH;idx++)
            rank[idx]=idx==0 ? COUNT_WIDTH'(0):keep_prefix[PREFIX_LEVELS][idx-1];
        survivors=keep_prefix[PREFIX_LEVELS][DEPTH-1];
        available = ~used_q | accepted_q;
        incoming = '0;
        append = '0;
        alloc_index = '{default:'0};
        append_rank = '{default:'0};
        for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
            logic found;
            found = 1'b0;
            append_rank[lane] = incoming;
            append[lane] = enq_fire_i && enq_uop_i[lane].valid
                && !(resolution_valid_i && resolution_mispredict_i);
            incoming += COUNT_WIDTH'(append[lane]);
            for (int slot = 0; slot < DEPTH; slot++) begin
                if (append[lane] && available[slot] && !found) begin
                    found = 1'b1;
                    alloc_index[lane] = index_t'(slot);
                    available[slot] = 1'b0;
                end
            end
        end
        count_next = survivors + incoming;
    end

    always_comb begin
        order_next = '{default:'0};
        used_next = '0;
        for (int src = 0; src < DEPTH; src++)
            if (keep[src]) used_next[order_q[src]] = 1'b1;
        for (int lane = 0; lane < ENQ_WIDTH; lane++)
            if (append[lane]) used_next[alloc_index[lane]] = 1'b1;
        for (int dst = 0; dst < DEPTH; dst++) begin
            for (int src = 0; src < DEPTH; src++)
                order_next[dst] |= order_q[src] &
                    {INDEX_WIDTH{keep[src] && rank[src] == COUNT_WIDTH'(dst)}};
            for (int lane = 0; lane < ENQ_WIDTH; lane++)
                order_next[dst] |= alloc_index[lane] &
                    {INDEX_WIDTH{append[lane] && survivors + append_rank[lane] == COUNT_WIDTH'(dst)}};
        end
    end

    // Readiness of incoming operands depends on the dispatch packet, not on
    // the IQ physical-row allocation. Resolve it once per incoming lane in
    // parallel with that allocation; each row selects only these narrow bits.
    logic incoming_ready1[ENQ_WIDTH],incoming_ready2[ENQ_WIDTH],incoming_ready3[ENQ_WIDTH];
    for(genvar lane=0;lane<ENQ_WIDTH;lane++) begin : g_ingress_ready
        assign incoming_ready1[lane]=!enq_uop_i[lane].rs1_read_en ||
            source_ready(enq_uop_i[lane].ext.rs1_dom,enq_uop_i[lane].src1_preg);
        assign incoming_ready2[lane]=!enq_uop_i[lane].rs2_read_en ||
            source_ready(enq_uop_i[lane].ext.rs2_dom,enq_uop_i[lane].src2_preg);
        assign incoming_ready3[lane]=!enq_uop_i[lane].ext.rs3_read_en ||
            source_ready(enq_uop_i[lane].ext.rs3_dom,enq_uop_i[lane].rext.src3_preg);
    end

    for (genvar slot = 0; slot < DEPTH; slot++) begin : g_payload
        renamed_uop_t write_data;
        sched_t write_info;
        logic write_valid,write_ready1,write_ready2,write_ready3;
        always_comb begin
            write_data = '0;
            write_valid = 1'b0;
            write_ready1=0;write_ready2=0;write_ready3=0;
            for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                write_data |= renamed_uop_t'(UOP_BITS'(enq_uop_i[lane]) &
                    {UOP_BITS{append[lane] && alloc_index[lane] == index_t'(slot)}});
                write_valid |= append[lane] && alloc_index[lane] == index_t'(slot);
                write_ready1 |= incoming_ready1[lane] && append[lane] && alloc_index[lane]==index_t'(slot);
                write_ready2 |= incoming_ready2[lane] && append[lane] && alloc_index[lane]==index_t'(slot);
                write_ready3 |= incoming_ready3[lane] && append[lane] && alloc_index[lane]==index_t'(slot);

            end
            write_info = scheduling_info(write_data);
            if (resolution_valid_i) begin
                write_info.branch_mask[resolution_tag_i] = 1'b0;
                write_info.mdu_fuse.lo_tag.br_mask[resolution_tag_i] = 1'b0;
            end
        end
        always_ff @(posedge clk) begin
            if (rst) begin
                sched_q[slot] <= '0;
                ready1_q[slot] <= 1'b0;
                ready2_q[slot] <= 1'b0;
                ready3_q[slot] <= 1'b0;
            end else if (write_valid) begin
                for(int wb=0;wb<ENQ_WIDTH;wb++) if(append[wb] && alloc_index[wb]==index_t'(slot))
                    writer_q[slot]<=WRITER_W'(wb);
                sched_q[slot] <= write_info;
                ready1_q[slot] <= write_ready1;
                ready2_q[slot] <= write_ready2;
                ready3_q[slot] <= write_ready3;
`ifndef SYNTHESIS
                assert(write_ready1==(!write_info.rs1_read_en || source_ready(write_info.ext.rs1_dom,write_info.src1_preg)));
                assert(write_ready2==(!write_info.rs2_read_en || source_ready(write_info.ext.rs2_dom,write_info.src2_preg)));
                assert(write_ready3==(!write_info.ext.rs3_read_en || source_ready(write_info.ext.rs3_dom,write_info.rext.src3_preg)));
`endif
            end else if (used_q[slot]) begin
                if (resolution_valid_i) begin
                    sched_q[slot].branch_mask[resolution_tag_i] <= 1'b0;
                    sched_q[slot].mdu_fuse.lo_tag.br_mask[resolution_tag_i] <= 1'b0;
                end
                ready1_q[slot] <= !sched_q[slot].rs1_read_en || ready1_q[slot]
                    || source_ready(sched_q[slot].ext.rs1_dom, sched_q[slot].src1_preg);
                ready2_q[slot] <= !sched_q[slot].rs2_read_en || ready2_q[slot]
                    || source_ready(sched_q[slot].ext.rs2_dom, sched_q[slot].src2_preg);
                ready3_q[slot] <= !sched_q[slot].ext.rs3_read_en || ready3_q[slot]
                    || source_ready(sched_q[slot].ext.rs3_dom, sched_q[slot].rext.src3_preg);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            order_q <= '{default:'0};
            used_q <= '0;
            count_q <= '0;
            accepted_q <= '0;
        end else begin
            order_q <= order_next;
            used_q <= used_next;
            count_q <= count_next;
            accepted_q <= accepted_next;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if(!rst) begin
            assert((accepted_q & ~used_q)=='0)
                else $fatal(1,"IQ acknowledgement lost its physical owner");
            assert((accepted_next & accepted_q)=='0)
                else $fatal(1,"IQ repeated an acknowledged owner");
        end
        if (!rst && enq_fire_i) begin
            int unsigned enq_count;
            enq_count = 0;
            for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                if (enq_uop_i[lane].valid) enq_count++;
            end
            if (enq_count > int'(free_count_o)) begin
                $fatal(1, "backend_issue_queue Dispatch exceeded free capacity");
            end
        end
    end
`endif

    initial begin
        if ((ENQ_WIDTH <= 0) || (ISSUE_WIDTH <= 0) || (WAKEUP_WIDTH <= 0) || (DEPTH <= 0)) begin
            $error("backend_issue_queue parameters must be positive");
        end
    end
endmodule
