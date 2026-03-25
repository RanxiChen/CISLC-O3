/**
 * Decode Uop Queue
 *
 * 当前已经实现的功能：
 * - 作为 decode 后、rename 前的成组 uop 缓冲
 * - 每个表项保存一整组 MACHINE_WIDTH 的 decoded_uop
 * - 支持 enqueue / dequeue 同拍发生
 * - 采用 ready/valid 风格对 decode 级和 rename 级背压
 *
 * 当前没有实现的功能：
 * - 不做 lane 级部分入队、部分出队
 * - 不做按年龄选择，不做 issue / wakeup / select
 * - 不做 flush / rollback / checkpoint 恢复
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 根据 count_q 产生 enq_ready_o / deq_valid_o
 *   2) 若队列非空，则 deq_uop_o 直接看到当前 head_q 指向的整组 uop
 * - 周期 N 上升沿：
 *   1) 若 enq_valid_i && enq_ready_o，则把一整组 decoded_uop 写入 tail_q
 *   2) 若 deq_valid_o && deq_ready_i，则弹出当前 head_q 指向的整组 uop
 *   3) 若同拍既入队又出队，则 count_q 保持不变，只更新 head_q / tail_q
 * - 周期 N+1：
 *   看到更新后的队列头部、空满状态和下一组可供 rename 的 uop
 */

module uop_queue
    import o3_pkg::*;
#(
    parameter int MACHINE_WIDTH = 4,
    parameter int DEPTH = 2
) (
    input  logic                            clk,
    input  logic                            rst,
    input  decoded_uop_t [MACHINE_WIDTH-1:0] enq_uop_i,
    input  logic                            enq_valid_i,
    output logic                            enq_ready_o,
    output decoded_uop_t [MACHINE_WIDTH-1:0] deq_uop_o,
    output logic                            deq_valid_o,
    input  logic                            deq_ready_i
);

    localparam int PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);

    decoded_uop_t [MACHINE_WIDTH-1:0] queue_mem [DEPTH-1:0];
    logic [PTR_WIDTH-1:0]             head_q;
    logic [PTR_WIDTH-1:0]             tail_q;
    logic [COUNT_WIDTH-1:0]           count_q;
    logic                             enq_fire;
    logic                             deq_fire;

    function automatic logic [PTR_WIDTH-1:0] next_ptr(input logic [PTR_WIDTH-1:0] ptr);
        if (DEPTH == 1) begin
            next_ptr = '0;
        end else if (ptr == PTR_WIDTH'(DEPTH - 1)) begin
            next_ptr = '0;
        end else begin
            next_ptr = ptr + PTR_WIDTH'(1);
        end
    endfunction

    assign enq_ready_o = (count_q < COUNT_WIDTH'(DEPTH));
    assign deq_valid_o = (count_q != '0);
    assign enq_fire    = enq_valid_i && enq_ready_o;
    assign deq_fire    = deq_valid_o && deq_ready_i;
    assign deq_uop_o   = queue_mem[head_q];

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q  <= '0;
            tail_q  <= '0;
            count_q <= '0;
            queue_mem <= '{default: '0};
        end else begin
            if (enq_fire) begin
                queue_mem[tail_q] <= enq_uop_i;
                tail_q            <= next_ptr(tail_q);
            end

            if (deq_fire) begin
                head_q <= next_ptr(head_q);
            end

            unique case ({enq_fire, deq_fire})
                2'b10: count_q <= count_q + COUNT_WIDTH'(1);
                2'b01: count_q <= count_q - COUNT_WIDTH'(1);
                default: count_q <= count_q;
            endcase
        end
    end

    initial begin
        if (MACHINE_WIDTH <= 0) begin
            $error("uop_queue requires MACHINE_WIDTH > 0");
        end

        if (DEPTH <= 0) begin
            $error("uop_queue requires DEPTH > 0");
        end
    end

endmodule
