/**
 * Domain-qualified backend issue queue (B14/B15/B33).
 * Every source has a domain and cached readiness; wake/ready checks compare only the
 * corresponding register domain. src3 participates in FMA dependencies. No same-cycle
 * wake-select bypass: a received writeback becomes selectable on the following cycle.
 * FP: depth CFG.dispatch.fp_iq_depth, oldest-ready dual issue; five RegRead capacities
 * prevent repeated FU selection, at most one INT-source FP candidate per cycle.
 * INT: retains MUL/DIV occupancy constraints and fused-pair handling. MEM: single
 * issue lets stores bypass unready entries; loads issue in program order within the IQ,
 * LQ/SQ replay capacity is arbitrated at IS outside the IQ.
 * L3 闭环简化：偏离 B04 非阻塞访存；单 replay 槽下乱序 load 会形成等待环。
 * L8 换成 Breeze 访存时整体替换此 load 顺序限制；store 选择规则保持不变。
 * Only issue_valid && issue_ready deletes a candidate; denied INT read grants leave it queued.
 * Correct resolution clears masks; misprediction removes dependent younger entries.
 * B33 FP early wakeup is deferred to performance work; actual PRF writes wake FP sources.
 * 当前实现状态：闭环简化（L9）；MEM 保留上述 L3 简化。
 * N: select stored-ready candidates and form next queue. N edge: delete accepted candidates,
 * update source readiness, compact narrow slot indices and append dispatch lanes. N+1: new candidates.
 * 测试：sim/cocotb/backend_issue_queue/（MEM load 顺序、store bypass、replay 门控）。
 */
module backend_issue_queue
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  o3_types_pkg::iq_kind_e KIND,          // 实例选择，无默认值
    localparam int ENQ_WIDTH = CFG.dispatch.width,
    localparam int ISSUE_WIDTH = (KIND == o3_types_pkg::IQ_INT) ? CFG.exec.num_alu : (KIND == o3_types_pkg::IQ_FP ? 2 : (KIND==o3_types_pkg::IQ_MEM ? CFG.lsu.agu_pipes:1)),
    parameter int WAKEUP_WIDTH = CFG.exec.int_prf_write_ports,
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
    input logic fp_wakeup_valid_i [CFG.exec.fp_prf_write_ports-1:0],
    input logic [PREG_IDX_WIDTH-1:0] fp_wakeup_preg_i [CFG.exec.fp_prf_write_ports-1:0],
    // FU indices: FMA0, FMA1, DIVSQRT, MISC, CONV; capacity of RegRead slots.
    input logic [4:0] fp_regread_ready_i,
    output logic [2:0] issue_fp_fu_o [ISSUE_WIDTH-1:0],
    input  logic mul_ready_i, mul_pair_ready_i, div_ready_i,
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
    // stays at a fixed physical slot until issue; recovery moves slot indices.
    renamed_uop_t payload_q [DEPTH];
    sched_t sched_q [DEPTH];
    sched_t queue_q [DEPTH];
    index_t order_q [DEPTH], order_next [DEPTH], alloc_index [ENQ_WIDTH];
    logic [DEPTH-1:0] used_q, used_next, keep, remove_mask;
    logic [ENQ_WIDTH-1:0] append;
    logic [COUNT_WIDTH-1:0] rank [DEPTH], append_rank [ENQ_WIDTH];
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
            src1_ready_q[idx] = ready1_q[order_q[idx]];
            src2_ready_q[idx] = ready2_q[order_q[idx]];
            src3_ready_q[idx] = ready3_q[order_q[idx]];
        end
    end

    function automatic logic source_ready(input o3_types_pkg::reg_domain_e dom,
        input logic [PREG_IDX_WIDTH-1:0] preg);
        logic hit;
        hit=dom==o3_types_pkg::RD_NONE;
        if (dom==o3_types_pkg::RD_FP) begin
            if (int'(preg)<CFG.rename.fp_phys_regs) hit=fp_preg_ready_i[preg];
            for (int p=0;p<CFG.exec.fp_prf_write_ports;p++)
                hit |= fp_wakeup_valid_i[p] && fp_wakeup_preg_i[p]==preg;
        end else if (dom==o3_types_pkg::RD_INT) begin
            if (int'(preg)<NUM_PHYS_REGS) hit=preg_ready_i[preg];
            for (int p=0;p<WAKEUP_WIDTH;p++) hit |= wakeup_valid_i[p] && wakeup_preg_i[p]==preg;
        end
        return hit;
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

    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q;

    always_comb begin
        logic selected [DEPTH-1:0];
        logic picked_mul,picked_div,picked_fp_int;
        logic [4:0] fp_available;

        selected = '{default: 1'b0};picked_mul=0;picked_div=0;picked_fp_int=0;
        fp_available=fp_regread_ready_i;
        issue_fp_fu_o='{default:'0};
        issue_uop_o = '{default: '0};
        issue_valid_o = '0;
        issue_selected_valid = '{default: 1'b0};
        issue_selected_idx = '{default: '0};

        // 每个端口依次选当前尚未选择的最老ready uop。
        for (int port = 0; port < ISSUE_WIDTH; port++) begin
            int chosen;
            chosen = -1;
            for (int idx = 0; idx < DEPTH; idx++) begin
                if (!(resolution_valid_i && resolution_mispredict_i) && (chosen < 0) && queue_q[idx].valid && !selected[idx]
                 && (!OLDEST_ONLY || (idx == 0))
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
                issue_uop_o[port] = payload_q[order_q[chosen]];
                issue_uop_o[port].branch_mask = queue_q[chosen].branch_mask;
                issue_uop_o[port].mdu_fuse.lo_tag.br_mask = queue_q[chosen].mdu_fuse.lo_tag.br_mask;
                if (resolution_valid_i) begin
                    issue_uop_o[port].branch_mask[resolution_tag_i] = 1'b0;
                    issue_uop_o[port].mdu_fuse.lo_tag.br_mask[resolution_tag_i] = 1'b0;
                end
                issue_valid_o[port] = 1'b1;
                issue_selected_valid[port] = 1'b1;
                issue_selected_idx[port] = index_t'(chosen);
            end
        end
    end

    // 把candidate选择与ready握手拆开，避免外部资源仲裁读取candidate后回送ready
    // 时形成工具可见的组合环。remove_mask只影响上升沿后的queue_next。
    always_comb begin
        remove_mask = '0;
        for (int port = 0; port < ISSUE_WIDTH; port++) begin
            if (issue_selected_valid[port] && issue_ready_i[port]) begin
                remove_mask[issue_selected_idx[port]] = 1'b1;
            end
        end
    end

    always_comb begin
        logic [DEPTH-1:0] available;
        keep = '0;
        survivors = '0;
        for (int idx = 0; idx < DEPTH; idx++) begin
            rank[idx] = survivors;
            keep[idx] = idx < int'(count_q) && queue_q[idx].valid && !remove_mask[idx]
                && !(resolution_valid_i && resolution_mispredict_i
                     && queue_q[idx].branch_mask[resolution_tag_i]);
            survivors += COUNT_WIDTH'(keep[idx]);
        end
        available = ~used_q;
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

    for (genvar slot = 0; slot < DEPTH; slot++) begin : g_payload
        renamed_uop_t write_data;
        sched_t write_info;
        logic write_valid;
        always_comb begin
            write_data = '0;
            write_valid = 1'b0;
            for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                write_data |= renamed_uop_t'(UOP_BITS'(enq_uop_i[lane]) &
                    {UOP_BITS{append[lane] && alloc_index[lane] == index_t'(slot)}});
                write_valid |= append[lane] && alloc_index[lane] == index_t'(slot);
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
                payload_q[slot] <= write_data;
                payload_q[slot].branch_mask <= '0;
                payload_q[slot].mdu_fuse.lo_tag.br_mask <= '0;
                sched_q[slot] <= write_info;
                ready1_q[slot] <= !write_info.rs1_read_en
                    || source_ready(write_info.ext.rs1_dom, write_info.src1_preg);
                ready2_q[slot] <= !write_info.rs2_read_en
                    || source_ready(write_info.ext.rs2_dom, write_info.src2_preg);
                ready3_q[slot] <= !write_info.ext.rs3_read_en
                    || source_ready(write_info.ext.rs3_dom, write_info.rext.src3_preg);
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
        end else begin
            order_q <= order_next;
            used_q <= used_next;
            count_q <= count_next;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
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
