/**
 * Branch Issue Queue
 *
 * 独立的分支 issue 队列：
 * - rename 端每拍最多按 lane 顺序接收 MACHINE_WIDTH 条 branch uop
 * - 队列深度默认 4
 * - 每拍最多发射 1 条最老 ready branch
 * - 本拍新入队的 branch 不参与本拍 issue
 * - wakeup 只观察 preg_ready_i，不接同拍旁路
 */
module branch_issue_queue
    import o3_pkg::*;
#(
    parameter int MACHINE_WIDTH = 4,
    parameter int DEPTH = 4,
    parameter int NUM_PHYS_REGS = 64
) (
    input  logic                                 clk,
    input  logic                                 rst,
    input  logic                                 flush_i,
    input  logic                                 squash_valid_i,
    input  logic [o3_pkg::ROB_IDX_WIDTH-1:0]     squash_branch_idx_i,
    input  logic [o3_pkg::ROB_IDX_WIDTH-1:0]     rob_head_i,
    input  branch_issue_entry_t [MACHINE_WIDTH-1:0] enq_entry_i,
    input  logic                                 enq_valid_i,
    output logic                                 enq_ready_o,
    input  logic                                 preg_ready_i [NUM_PHYS_REGS-1:0],
    output branch_issue_entry_t                  issue_entry_o,
    output logic                                 issue_valid_o,
    input  logic                                 issue_ready_i
);

    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int ROB_IDX_WIDTH = o3_pkg::ROB_IDX_WIDTH;

    branch_issue_entry_t queue_q [DEPTH-1:0];
    branch_issue_entry_t queue_wakeup [DEPTH-1:0];
    branch_issue_entry_t queue_after_issue [DEPTH-1:0];
    branch_issue_entry_t queue_next [DEPTH-1:0];
    logic [COUNT_WIDTH-1:0] enq_count;
    logic [COUNT_WIDTH-1:0] count_after_issue;
    logic                   enq_fire;
    logic [DEPTH-1:0]       remove_mask;

    function automatic logic is_older_or_same(
        input logic [ROB_IDX_WIDTH-1:0] candidate,
        input logic [ROB_IDX_WIDTH-1:0] branch_idx,
        input logic [ROB_IDX_WIDTH-1:0] head_idx
    );
        int unsigned cand_age;
        int unsigned branch_age;
        begin
            cand_age      = (int'(candidate) + BACKEND_NUM_ROB_ENTRIES - int'(head_idx)) % BACKEND_NUM_ROB_ENTRIES;
            branch_age    = (int'(branch_idx) + BACKEND_NUM_ROB_ENTRIES - int'(head_idx)) % BACKEND_NUM_ROB_ENTRIES;
            is_older_or_same = (cand_age <= branch_age);
        end
    endfunction

    always_comb begin
        enq_count = '0;
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            if (enq_entry_i[lane].valid) begin
                enq_count = enq_count + COUNT_WIDTH'(1);
            end
        end
    end

    always_comb begin
        for (int idx = 0; idx < DEPTH; idx++) begin
            queue_wakeup[idx] = queue_q[idx];

            if (queue_q[idx].valid) begin
                if (squash_valid_i && !is_older_or_same(queue_q[idx].rob_idx, squash_branch_idx_i, rob_head_i)) begin
                    queue_wakeup[idx].valid = 1'b0;
                end
                if (!queue_q[idx].src1_ready && preg_ready_i[queue_q[idx].src1_preg]) begin
                    queue_wakeup[idx].src1_ready = 1'b1;
                end

                if (!queue_q[idx].src2_ready && preg_ready_i[queue_q[idx].src2_preg]) begin
                    queue_wakeup[idx].src2_ready = 1'b1;
                end
            end
        end
    end

    always_comb begin
        remove_mask   = '0;
        issue_entry_o = '0;
        issue_valid_o = 1'b0;

        if (issue_ready_i) begin
            for (int idx = 0; idx < DEPTH; idx++) begin
                if (!issue_valid_o
                 && queue_wakeup[idx].valid
                 && queue_wakeup[idx].src1_ready
                 && queue_wakeup[idx].src2_ready) begin
                    issue_entry_o = queue_wakeup[idx];
                    issue_valid_o = 1'b1;
                    remove_mask[idx] = 1'b1;
                end
            end
        end
    end

    always_comb begin
        int unsigned write_idx;

        queue_after_issue = '{default: '0};
        write_idx         = 0;

        for (int idx = 0; idx < DEPTH; idx++) begin
            if (queue_wakeup[idx].valid && !remove_mask[idx]) begin
                queue_after_issue[write_idx] = queue_wakeup[idx];
                write_idx++;
            end
        end

        count_after_issue = COUNT_WIDTH'(write_idx);
    end

    assign enq_ready_o = (count_after_issue + enq_count <= COUNT_WIDTH'(DEPTH));
    assign enq_fire    = enq_valid_i && enq_ready_o;

    always_comb begin
        int unsigned write_idx;

        queue_next = queue_after_issue;
        write_idx  = int'(count_after_issue);

        if (enq_fire) begin
            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (enq_entry_i[lane].valid) begin
                    queue_next[write_idx] = enq_entry_i[lane];
                    write_idx++;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            queue_q <= '{default: '0};
        end else if (flush_i) begin
            queue_q <= '{default: '0};
        end else begin
            queue_q <= queue_next;
        end
    end

    initial begin
        if (MACHINE_WIDTH <= 0) begin
            $error("branch_issue_queue requires MACHINE_WIDTH > 0");
        end

        if (DEPTH <= 0) begin
            $error("branch_issue_queue requires DEPTH > 0");
        end

        if (NUM_PHYS_REGS <= 0) begin
            $error("branch_issue_queue requires NUM_PHYS_REGS > 0");
        end
    end

endmodule
