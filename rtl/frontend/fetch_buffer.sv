/**
 * Frontend Fetch Buffer
 *
 * 当前已经实现：
 * - 独立的前后端交界取指缓冲。
 * - 入队端每拍最多接收 ENQ_WIDTH 条来自 IFU 的 `fetch_entry_t`。
 * - 出队端每拍最多向后端提供 DEQ_WIDTH 条 `fetch_entry_t`。
 * - 内部队列紧凑存储，只写入有效 lane，不在队列中保留 bubble。
 * - 出队支持 partial group：只要队列非空即可向后端拉高 valid，
 *   不足 DEQ_WIDTH 的 lane 会输出 `valid=0` 的空 entry。
 * - 额外输出 `icache_req_allowed_o`，当前表示至少保留
 *   ICACHE_REQ_FREE_THRESHOLD 个空位，用来指导 IFU 是否继续向 ICache 发请求。
 *
 * 当前没有实现：
 * - 不做 redirect 精确清除。
 * - 不做按 FTQ index 或分支恢复的选择性失效。
 * - 不保存 `ftq_idx`，当前只存前后端共同认可的 `fetch_entry_t`。
 *
 * 后续扩展入口：
 * - 后续可把 `icache_req_allowed_o` 的阈值和 IFU/ICache 在飞请求数量绑定。
 * - 后续可增加 redirect/flush metadata，实现错误路径条目的精确清除。
 * - 如果后端需要 FTQ 回查，可统一扩展公共 `fetch_entry_t` 后再接入。
 *
 * 当前阶段说明：
 * - 当前阶段只实现 RTL 主体，不写测试代码，不写仿真代码。
 *
 * 逐周期说明：
 * - 周期 N 组合阶段：
 *   1) 根据 `count_q` 计算剩余空间、入队 ready、ICache request 允许信号。
 *   2) 若 `count_q != 0`，出队端 `deq_valid_o=1`。
 *   3) 从 `head_q` 开始组合读出最多 DEQ_WIDTH 条 entry；
 *      若队列条目不足 DEQ_WIDTH，剩余 lane 输出 `valid=0` 的空 entry。
 * - 周期 N 上升沿：
 *   1) 若 `flush_i=1`，清空 head/tail/count。
 *   2) 否则若入队 fire，按 lane 顺序只写入有效 entry，tail 前进有效条数。
 *   3) 若出队 fire，head 前进本拍实际出队条数。
 *   4) count 同时加上入队条数并减去出队条数。
 * - 周期 N+1：
 *   1) 后端看到更新后的队头 entry。
 *   2) IFU 看到更新后的 `enq_ready_o` 和 `icache_req_allowed_o`。
 */
module fetch_buffer
    import o3_pkg::*;
#(
    parameter int ENQ_WIDTH = 4,
    parameter int DEQ_WIDTH = 4,
    parameter int DEPTH = 16,
    parameter int ICACHE_REQ_FREE_THRESHOLD = 8
) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic flush_i,

    input  fetch_entry_t       enq_entry_i [ENQ_WIDTH],
    input  logic [ENQ_WIDTH-1:0] enq_valid_i,
    output logic               enq_ready_o,

    output fetch_entry_t       deq_entry_o [DEQ_WIDTH],
    output logic               deq_valid_o,
    input  logic               deq_ready_i,

    output logic               icache_req_allowed_o
);

    localparam int PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);

    fetch_entry_t entries_q [DEPTH];
    logic [PTR_WIDTH-1:0]   head_q;
    logic [PTR_WIDTH-1:0]   tail_q;
    logic [COUNT_WIDTH-1:0] count_q;

    logic [COUNT_WIDTH-1:0] free_count;
    logic [COUNT_WIDTH-1:0] enq_count;
    logic [COUNT_WIDTH-1:0] deq_count;
    logic                   enq_fire;
    logic                   deq_fire;

    function automatic logic [PTR_WIDTH-1:0] ptr_add(
        input logic [PTR_WIDTH-1:0] ptr,
        input int unsigned          offset
    );
        int unsigned next_ptr;
        begin
            if (DEPTH == 1) begin
                ptr_add = '0;
            end else begin
                next_ptr = int'(ptr) + offset;
                ptr_add = PTR_WIDTH'(next_ptr % DEPTH);
            end
        end
    endfunction

    always_comb begin
        enq_count = '0;
        for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
            if (enq_valid_i[lane]) begin
                enq_count = enq_count + COUNT_WIDTH'(1);
            end
        end
    end

    assign free_count = COUNT_WIDTH'(DEPTH) - count_q;
    assign enq_ready_o = free_count >= COUNT_WIDTH'(ENQ_WIDTH);
    assign icache_req_allowed_o = free_count >= COUNT_WIDTH'(ICACHE_REQ_FREE_THRESHOLD);
    assign deq_valid_o = count_q != '0;
    assign deq_count = (count_q >= COUNT_WIDTH'(DEQ_WIDTH))
                     ? COUNT_WIDTH'(DEQ_WIDTH)
                     : count_q;
    assign enq_fire = (enq_count != '0) && enq_ready_o;
    assign deq_fire = deq_valid_o && deq_ready_i;

    always_comb begin
        for (int lane = 0; lane < DEQ_WIDTH; lane++) begin
            if (COUNT_WIDTH'(lane) < deq_count) begin
                deq_entry_o[lane] = entries_q[ptr_add(head_q, lane)];
            end else begin
                deq_entry_o[lane] = '0;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_i) begin
            head_q  <= '0;
            tail_q  <= '0;
            count_q <= '0;
        end else begin
            if (enq_fire) begin
                int unsigned write_idx;
                write_idx = 0;
                for (int lane = 0; lane < ENQ_WIDTH; lane++) begin
                    if (enq_valid_i[lane]) begin
                        entries_q[ptr_add(tail_q, write_idx)] <= enq_entry_i[lane];
                        write_idx = write_idx + 1;
                    end
                end
                tail_q <= ptr_add(tail_q, int'(enq_count));
            end

            if (deq_fire) begin
                head_q <= ptr_add(head_q, int'(deq_count));
            end

            count_q <= count_q
                     + (enq_fire ? enq_count : '0)
                     - (deq_fire ? deq_count : '0);
        end
    end

    initial begin
        if (ENQ_WIDTH <= 0) begin
            $error("fetch_buffer requires ENQ_WIDTH > 0");
        end

        if (DEQ_WIDTH <= 0) begin
            $error("fetch_buffer requires DEQ_WIDTH > 0");
        end

        if (DEPTH <= 0) begin
            $error("fetch_buffer requires DEPTH > 0");
        end

        if (ICACHE_REQ_FREE_THRESHOLD < 0) begin
            $error("fetch_buffer requires ICACHE_REQ_FREE_THRESHOLD >= 0");
        end

        if (ICACHE_REQ_FREE_THRESHOLD > DEPTH) begin
            $error("fetch_buffer requires ICACHE_REQ_FREE_THRESHOLD <= DEPTH");
        end
    end

endmodule
