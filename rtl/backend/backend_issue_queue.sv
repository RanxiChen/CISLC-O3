/**
 * Domain-qualified backend issue queue (B14/B15/B33).
 * Every source has a domain and cached readiness; wake/ready checks compare only the
 * corresponding register domain. src3 participates in FMA dependencies. No same-cycle
 * wake-select bypass: a received writeback becomes selectable on the following cycle.
 * FP: depth CFG.dispatch.fp_iq_depth, oldest-ready dual issue; five RegRead capacities
 * prevent repeated FU selection, at most one INT-source FP candidate per cycle.
 * INT: retains MUL/DIV occupancy constraints and fused-pair handling. MEM: single
 * issue lets stores bypass unready entries; loads issue in program order within the IQ,
 * retaining allow_load_i suppression while the replay slot is occupied.
 * L3 闭环简化：偏离 B04 非阻塞访存；单 replay 槽下乱序 load 会形成等待环。
 * L8 换成 Breeze 访存时整体替换此 load 顺序限制；store 选择规则保持不变。
 * Only issue_valid && issue_ready deletes a candidate; denied INT read grants leave it queued.
 * Correct resolution clears masks; misprediction removes dependent younger entries.
 * B33 FP early wakeup is deferred to performance work; actual PRF writes wake FP sources.
 * 当前实现状态：闭环简化（L9）；MEM 保留上述 L3 简化。
 * N: select stored-ready candidates and form next queue. N edge: delete accepted candidates,
 * update source readiness, compact survivors and append dispatch lanes. N+1: new candidates.
 * 测试：sim/cocotb/backend_issue_queue/（MEM load 顺序、store bypass、replay 门控）。
 */
module backend_issue_queue
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  o3_types_pkg::iq_kind_e KIND,          // 实例选择，无默认值
    localparam int ENQ_WIDTH = CFG.dispatch.width,
    localparam int ISSUE_WIDTH = (KIND == o3_types_pkg::IQ_INT) ? CFG.exec.num_alu : (KIND == o3_types_pkg::IQ_FP ? 2 : 1),
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
    input  logic allow_load_i,  // Memory replay 槽已占用/将占用时仍可选 store
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

    renamed_uop_t queue_q [DEPTH-1:0];
    logic src1_ready_q [DEPTH-1:0];
    logic src2_ready_q [DEPTH-1:0];
    logic src3_ready_q [DEPTH-1:0];
    renamed_uop_t queue_next [DEPTH-1:0];
    logic src1_ready_next [DEPTH-1:0];
    logic src2_ready_next [DEPTH-1:0];
    logic src3_ready_next [DEPTH-1:0];
    logic [COUNT_WIDTH-1:0] count_q, count_next;
    logic [DEPTH-1:0] remove_mask;
    logic issue_selected_valid [ISSUE_WIDTH-1:0];
    logic [$clog2(DEPTH)-1:0] issue_selected_idx [ISSUE_WIDTH-1:0];

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
                logic older_load;
                older_load = 1'b0;
                if (KIND == o3_types_pkg::IQ_MEM && queue_q[idx].is_load) begin
                    // 队列按程序顺序压紧，queue_q[0] 是最老有效项；沿用 ROB 环形
                    // 距离比较，跨索引回绕仍按年龄排序。未就绪的旧 load 也必须挡住。
                    for (int other = 0; other < DEPTH; other++) begin
                        if (queue_q[other].valid && queue_q[other].is_load
                         && ((int'(queue_q[other].rob_idx) + CFG.rob.entries - int'(queue_q[0].rob_idx)) % CFG.rob.entries
                           < (int'(queue_q[idx].rob_idx) + CFG.rob.entries - int'(queue_q[0].rob_idx)) % CFG.rob.entries)) begin
                            older_load = 1'b1;
                        end
                    end
                end
                if (!(resolution_valid_i && resolution_mispredict_i) && (chosen < 0) && queue_q[idx].valid && !selected[idx]
                 && (!OLDEST_ONLY || (idx == 0))
                 && (KIND != o3_types_pkg::IQ_MEM || !queue_q[idx].is_load || (allow_load_i && !older_load))
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
                issue_uop_o[port] = queue_q[chosen];
                if (resolution_valid_i) begin
                    issue_uop_o[port].branch_mask[resolution_tag_i] = 1'b0;
                    issue_uop_o[port].mdu_fuse.lo_tag.br_mask[resolution_tag_i] = 1'b0;
                end
                issue_valid_o[port] = 1'b1;
                issue_selected_valid[port] = 1'b1;
                issue_selected_idx[port] = $clog2(DEPTH)'(chosen);
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
        int unsigned write_idx;

        queue_next = '{default: '0};
        src1_ready_next = '{default: 1'b0};
        src2_ready_next = '{default: 1'b0};
        src3_ready_next = '{default: 1'b0};
        write_idx = 0;

        // 先保留未发射、未被错误分支杀死的旧项，并清理正确解析的branch bit。
        for (int idx = 0; idx < DEPTH; idx++) begin
            logic killed;
            killed = resolution_valid_i && resolution_mispredict_i
                  && queue_q[idx].branch_mask[resolution_tag_i];
            if (queue_q[idx].valid && !remove_mask[idx] && !killed) begin
                queue_next[write_idx] = queue_q[idx];
                if (resolution_valid_i) begin
                    queue_next[write_idx].branch_mask[resolution_tag_i] = 1'b0;
                    queue_next[write_idx].mdu_fuse.lo_tag.br_mask[resolution_tag_i] = 1'b0;
                end
                src1_ready_next[write_idx] = !queue_q[idx].rs1_read_en
                                           || src1_ready_q[idx]
                                           || source_ready(queue_q[idx].ext.rs1_dom, queue_q[idx].src1_preg);
                // use_imm只描述执行单元的立即数输入，不能代替真实rs2依赖。
                // Branch同时使用B型立即数和rs2；只看use_imm会让Load->Branch
                // 在Load写回前错误发射。
                src2_ready_next[write_idx] = !queue_q[idx].rs2_read_en
                                           || src2_ready_q[idx]
                                           || source_ready(queue_q[idx].ext.rs2_dom, queue_q[idx].src2_preg);

                src3_ready_next[write_idx] = !queue_q[idx].ext.rs3_read_en || src3_ready_q[idx] || source_ready(queue_q[idx].ext.rs3_dom, queue_q[idx].rext.src3_preg);
                write_idx++;
            end
        end

        // 恢复拍禁止Dispatch，因此只有正常拍会追加新项。
        if (enq_fire_i && !(resolution_valid_i && resolution_mispredict_i)) begin
            for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                if (enq_uop_i[lane].valid) begin
                    queue_next[write_idx] = enq_uop_i[lane];
                    if (resolution_valid_i) begin
                        queue_next[write_idx].branch_mask[resolution_tag_i] = 1'b0;
                        queue_next[write_idx].mdu_fuse.lo_tag.br_mask[resolution_tag_i] = 1'b0;
                    end
                    src1_ready_next[write_idx] = !enq_uop_i[lane].rs1_read_en
                                               || source_ready(enq_uop_i[lane].ext.rs1_dom, enq_uop_i[lane].src1_preg);
                    src2_ready_next[write_idx] = !enq_uop_i[lane].rs2_read_en
                                               || source_ready(enq_uop_i[lane].ext.rs2_dom, enq_uop_i[lane].src2_preg);

                    src3_ready_next[write_idx] = !enq_uop_i[lane].ext.rs3_read_en || source_ready(enq_uop_i[lane].ext.rs3_dom, enq_uop_i[lane].rext.src3_preg);
                    write_idx++;
                end
            end
        end

        count_next = COUNT_WIDTH'(write_idx);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            queue_q <= '{default: '0};
            src1_ready_q <= '{default: 1'b0};
            src2_ready_q <= '{default: 1'b0};
            src3_ready_q <= '{default: 1'b0};
            count_q <= '0;
        end else begin
            queue_q <= queue_next;
            src1_ready_q <= src1_ready_next;
            src2_ready_q <= src2_ready_next;
            src3_ready_q <= src3_ready_next;
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
