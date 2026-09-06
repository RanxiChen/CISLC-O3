/**
 * Generic backend Issue Queue
 *
 * 已实现：
 * - 接收Dispatch同拍分流到本队列的0..ENQ_WIDTH条renamed uop并按lane年龄压紧。
 * - 保存完整renamed uop，依据preg_ready_i持续更新两个源操作数的ready状态。
 * - Writeback广播目的preg，同拍更新等待项的next ready状态；下一拍参与Select。
 * - 从队列年龄最老端扫描，给出最多ISSUE_WIDTH条ready候选。
 * - 只有issue_valid_o && issue_ready_i握手的候选才从队列删除。
 * - 正确分支解析清除branch-mask bit；误预测删除目标分支之后的uop并压紧。
 *
 * 未实现：
 * - 不区分整数、访存或分支执行语义；类型隔离由Dispatch保证。
 * - 不做写回同拍旁路、年龄矩阵、端口亲和性和多周期FU占用仲裁。
 * - 是否真正发射完全由每个实例的issue_ready_i决定；Integer实例接四路ALU，
 *   Integer/Memory/Branch实例均由共享读口和对应FU可用性回送ready。
 * - OLDEST_ONLY=1时只允许物理队头成为候选；当前Memory实例用它避免年轻Load
 *   占住唯一执行寄存器后等待尚未执行的老Store形成死锁。
 *
 * 周期N组合阶段更新ready视图、选择候选并计算压缩后的next状态；
 * 周期N上升沿原子删除已握手候选、追加Dispatch输入或执行恢复；
 * 周期N+1对外看到新的free count和最老ready候选。
 */
module backend_issue_queue
    import o3_pkg::*;
#(
    parameter int ENQ_WIDTH = BACKEND_DISPATCH_WIDTH,
    parameter int ISSUE_WIDTH = 1,
    parameter int WAKEUP_WIDTH = BACKEND_NUM_INT_ALUS,
    parameter int DEPTH = 8,
    parameter int NUM_PHYS_REGS = BACKEND_NUM_PHYS_REGS,
    parameter bit OLDEST_ONLY = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  renamed_uop_t [ENQ_WIDTH-1:0] enq_uop_i,
    input  logic enq_fire_i,
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,

    input  logic preg_ready_i [NUM_PHYS_REGS-1:0],
    input  logic wakeup_valid_i [WAKEUP_WIDTH-1:0],
    input  logic [$clog2(NUM_PHYS_REGS)-1:0] wakeup_preg_i [WAKEUP_WIDTH-1:0],
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
    renamed_uop_t queue_next [DEPTH-1:0];
    logic src1_ready_next [DEPTH-1:0];
    logic src2_ready_next [DEPTH-1:0];
    logic [COUNT_WIDTH-1:0] count_q, count_next;
    logic [DEPTH-1:0] remove_mask;
    logic issue_selected_valid [ISSUE_WIDTH-1:0];
    logic [$clog2(DEPTH)-1:0] issue_selected_idx [ISSUE_WIDTH-1:0];

    function automatic logic wakeup_hits(
        input logic [$clog2(NUM_PHYS_REGS)-1:0] preg
    );
        logic hit;
        begin
            hit = 1'b0;
            for (int port = 0; port < WAKEUP_WIDTH; port++) begin
                hit |= wakeup_valid_i[port] && (wakeup_preg_i[port] == preg);
            end
            wakeup_hits = hit;
        end
    endfunction

    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q;

    always_comb begin
        logic selected [DEPTH-1:0];

        selected = '{default: 1'b0};
        issue_uop_o = '{default: '0};
        issue_valid_o = '0;
        issue_selected_valid = '{default: 1'b0};
        issue_selected_idx = '{default: '0};

        // 每个端口依次选当前尚未选择的最老ready uop。
        for (int port = 0; port < ISSUE_WIDTH; port++) begin
            int chosen;
            chosen = -1;
            for (int idx = 0; idx < DEPTH; idx++) begin
                if (!resolution_valid_i && (chosen < 0) && queue_q[idx].valid && !selected[idx]
                 && (!OLDEST_ONLY || (idx == 0))
                 && (!queue_q[idx].rs1_read_en || src1_ready_q[idx])
                 && (!queue_q[idx].rs2_read_en || src2_ready_q[idx])) begin
                    chosen = idx;
                end
            end
            if (chosen >= 0) begin
                selected[chosen] = 1'b1;
                issue_uop_o[port] = queue_q[chosen];
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
                end
                src1_ready_next[write_idx] = !queue_q[idx].rs1_read_en
                                           || src1_ready_q[idx]
                                           || preg_ready_i[queue_q[idx].src1_preg]
                                           || wakeup_hits(queue_q[idx].src1_preg);
                // use_imm只描述执行单元的立即数输入，不能代替真实rs2依赖。
                // Branch同时使用B型立即数和rs2；只看use_imm会让Load->Branch
                // 在Load写回前错误发射。
                src2_ready_next[write_idx] = !queue_q[idx].rs2_read_en
                                           || src2_ready_q[idx]
                                           || preg_ready_i[queue_q[idx].src2_preg]
                                           || wakeup_hits(queue_q[idx].src2_preg);
                write_idx++;
            end
        end

        // 恢复拍禁止Dispatch，因此只有正常拍会追加新项。
        if (enq_fire_i && !resolution_valid_i) begin
            for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                if (enq_uop_i[lane].valid) begin
                    queue_next[write_idx] = enq_uop_i[lane];
                    src1_ready_next[write_idx] = !enq_uop_i[lane].rs1_read_en
                                               || preg_ready_i[enq_uop_i[lane].src1_preg]
                                               || wakeup_hits(enq_uop_i[lane].src1_preg);
                    src2_ready_next[write_idx] = !enq_uop_i[lane].rs2_read_en
                                               || preg_ready_i[enq_uop_i[lane].src2_preg]
                                               || wakeup_hits(enq_uop_i[lane].src2_preg);
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
            count_q <= '0;
        end else begin
            queue_q <= queue_next;
            src1_ready_q <= src1_ready_next;
            src2_ready_q <= src2_ready_next;
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
