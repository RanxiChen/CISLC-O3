/**
 * Integer Issue Queue
 *
 * 当前已经实现的功能：
 * - 作为 rename 后、整数执行前的压缩式 issue 队列
 * - 每个表项保存 1 条已经完成 rename 的整数 issue entry
 * - 支持一拍从多个 lane 原子入队到同一个队列
 * - 入队时按 lane0 -> lane1 -> ... 的顺序压紧写入，保持组内隐式程序顺序
 * - 支持根据物理寄存器 ready table 更新队列内源操作数 ready 位
 * - 支持同拍选择多条 ready uop 发往多个 ALU
 * - 被发射的表项会在同拍从队列中删除，后续表项向前补位
 * - 对上游提供 ready/valid 风格背压
 *
 * 当前没有实现的功能：
 * - 不做真实旁路广播网络；当前 wakeup 只观察 preg_ready_i，写回结果下一拍才对队列可见
 * - 不做年龄矩阵或更复杂的选择仲裁；当前严格按队列先后顺序选择
 * - 不做 flush / rollback / checkpoint 恢复
 * - 不做部分入队；同一拍要么整批整数 uop 全部进入，要么全部等待
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 根据当前有效表项和 preg_ready_i 生成 wakeup 后视图；只有真正等到源物理寄存器 ready 的表项才会被唤醒
 *   2) 从队头开始按顺序扫描 wakeup 后的表项，把最靠前的 ready uop 分配给编号更小的可接收 issue 端口
 *   3) 根据“本拍会被发射出去的条数”与“本拍想入队的条数”共同决定 enq_ready_o
 * - 周期 N 上升沿：
 *   1) 先把当前有效表项基于 preg_ready_i 计算出的 ready 位更新写回队列
 *   2) 若本拍有被选中且被接受的表项，则把这些表项从队列中删除，并把后面的表项向前补位
 *   3) 若 enq_valid_i && enq_ready_o，则把本拍所有 valid entry 按 lane 顺序连续追加到队尾
 * - 周期 N+1：
 *   看到更新后的压缩式队列内容、剩余表项数量，以及下一拍可继续参与 wakeup/select 的 issue entry
 */

module issue_queue
    import o3_pkg::*;
#(
    parameter int MACHINE_WIDTH = 4,
    parameter int ISSUE_WIDTH = 3,
    parameter int DEPTH = 16,
    parameter int NUM_PHYS_REGS = 64
) (
    input  logic                                 clk,
    input  logic                                 rst,
    input  issue_queue_entry_t [MACHINE_WIDTH-1:0] enq_entry_i,
    input  logic                                 enq_valid_i,
    output logic                                 enq_ready_o,
    input  logic                                 preg_ready_i [NUM_PHYS_REGS-1:0],
    output issue_queue_entry_t [ISSUE_WIDTH-1:0] issue_entry_o,
    output logic              [ISSUE_WIDTH-1:0]  issue_valid_o,
    input  logic              [ISSUE_WIDTH-1:0]  issue_ready_i,
    output issue_queue_entry_t [DEPTH-1:0]       wakeup_entry_o,
    output logic              [DEPTH-1:0]        wakeup_valid_o
);

    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);

    issue_queue_entry_t queue_q [DEPTH-1:0];
    issue_queue_entry_t queue_wakeup [DEPTH-1:0];
    issue_queue_entry_t queue_after_issue [DEPTH-1:0];
    issue_queue_entry_t queue_next [DEPTH-1:0];
    logic [COUNT_WIDTH-1:0] count_q;
    logic [COUNT_WIDTH-1:0] enq_count;
    logic [COUNT_WIDTH-1:0] issue_count;
    logic [COUNT_WIDTH-1:0] count_after_issue;
    logic                   enq_fire;
    logic [DEPTH-1:0]       remove_mask;

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
            queue_wakeup[idx]   = queue_q[idx];
            wakeup_entry_o[idx] = '0;
            wakeup_valid_o[idx] = 1'b0;

            if (queue_q[idx].valid) begin
                // 队列内只根据物理寄存器 ready table 逐源更新 ready 位。
                // 本次不接写回旁路，因此新写回结果要到下一拍才会体现在 preg_ready_i 上。
                if (queue_q[idx].src1_valid && !queue_q[idx].src1_ready && preg_ready_i[queue_q[idx].src1_preg]) begin
                    queue_wakeup[idx].src1_ready = 1'b1;
                end

                if (queue_q[idx].src2_valid && !queue_q[idx].src2_ready && preg_ready_i[queue_q[idx].src2_preg]) begin
                    queue_wakeup[idx].src2_ready = 1'b1;
                end

                if ((queue_wakeup[idx].src1_ready != queue_q[idx].src1_ready)
                 || (queue_wakeup[idx].src2_ready != queue_q[idx].src2_ready)) begin
                    wakeup_entry_o[idx] = queue_wakeup[idx];
                    wakeup_valid_o[idx] = 1'b1;
                end
            end
        end
    end

    always_comb begin
        remove_mask = '0;
        issue_count = '0;
        for (int port = 0; port < ISSUE_WIDTH; port++) begin
            issue_entry_o[port] = '0;
            issue_valid_o[port] = 1'b0;
        end

        for (int idx = 0; idx < DEPTH; idx++) begin
            if (queue_wakeup[idx].valid
             && queue_wakeup[idx].src1_ready
             && queue_wakeup[idx].src2_ready) begin
                for (int port = 0; port < ISSUE_WIDTH; port++) begin
                    if (!issue_valid_o[port] && issue_ready_i[port]) begin
                        issue_entry_o[port] = queue_wakeup[idx];
                        issue_valid_o[port] = 1'b1;
                        remove_mask[idx]    = 1'b1;
                        issue_count         = issue_count + COUNT_WIDTH'(1);
                        break;
                    end
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
            count_q  <= '0;
            queue_q  <= '{default: '0};
        end else begin
            queue_q <= queue_next;

            if (enq_fire) begin
                count_q <= count_after_issue + enq_count;
            end else begin
                count_q <= count_after_issue;
            end
        end
    end

    initial begin
        if (MACHINE_WIDTH <= 0) begin
            $error("issue_queue requires MACHINE_WIDTH > 0");
        end

        if (ISSUE_WIDTH <= 0) begin
            $error("issue_queue requires ISSUE_WIDTH > 0");
        end

        if (DEPTH <= 0) begin
            $error("issue_queue requires DEPTH > 0");
        end

        if (NUM_PHYS_REGS <= 0) begin
            $error("issue_queue requires NUM_PHYS_REGS > 0");
        end
    end

endmodule
