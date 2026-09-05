/**
 * Load Queue
 *
 * Rename按程序顺序分配entry；AGU按lq_idx补写有效地址，LSU发出SRAM请求时
 * 记录outstanding。每次重新分配都会翻转generation，SRAM返回携带
 * {generation,lq_idx}，从而能够丢弃flush后迟到或entry复用后的旧响应。
 * Load只在ROB顺序退休时从队头释放。
 *
 * 周期N组合阶段给出分配索引、容量、当前执行entry的generation以及响应是否仍存活；
 * 周期N上升沿原子执行allocate/AGU/request/response/commit，mispredict恢复优先；
 * 周期N+1可见更新后的entry状态。本阶段不实现Load replay或异常。
 */
module load_queue
    import o3_pkg::*;
#(
    parameter int RENAME_WIDTH = 4,
    parameter int DEPTH = BACKEND_LOAD_QUEUE_DEPTH,
    parameter int NUM_ROB_ENTRIES = BACKEND_NUM_ROB_ENTRIES
) (
    input logic clk,
    input logic rst,
    input logic alloc_req_i [RENAME_WIDTH-1:0],
    input logic alloc_fire_i,
    input logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_rob_idx_i [RENAME_WIDTH-1:0],
    input branch_mask_t alloc_branch_mask_i [RENAME_WIDTH-1:0],
    output logic [$clog2(DEPTH)-1:0] alloc_idx_o [RENAME_WIDTH-1:0],
    output logic [$clog2(DEPTH+1)-1:0] free_count_o,
    output logic [$clog2(DEPTH)-1:0] tail_o,

    input logic execute_valid_i,
    input logic [$clog2(DEPTH)-1:0] execute_idx_i,
    input logic [XLEN-1:0] execute_addr_i,
    output logic execute_generation_o,
    input logic request_fire_i,
    input logic [$clog2(DEPTH)-1:0] request_idx_i,
    input logic response_valid_i,
    input logic [$clog2(DEPTH):0] response_tag_i,
    output logic response_live_o,

    input logic [$clog2(RENAME_WIDTH+1)-1:0] release_count_i,
    input logic resolution_valid_i,
    input logic resolution_mispredict_i,
    input branch_tag_t resolution_tag_i,
    input logic [$clog2(DEPTH)-1:0] restore_tail_i
);
    localparam int IDX_WIDTH = $clog2(DEPTH);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    logic [IDX_WIDTH-1:0] head_q, tail_q;
    logic [COUNT_WIDTH-1:0] count_q;
    logic valid_q [DEPTH-1:0];
    logic generation_q [DEPTH-1:0];
    logic addr_valid_q [DEPTH-1:0];
    logic outstanding_q [DEPTH-1:0];
    logic [XLEN-1:0] addr_q [DEPTH-1:0];
    logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_idx_q [DEPTH-1:0];
    branch_mask_t branch_mask_q [DEPTH-1:0];

    function automatic logic [IDX_WIDTH-1:0] add_idx(
        input logic [IDX_WIDTH-1:0] base, input int unsigned offset
    );
        add_idx = IDX_WIDTH'((int'(base) + offset) % DEPTH);
    endfunction

    assign free_count_o = COUNT_WIDTH'(DEPTH) - count_q;
    assign tail_o = tail_q;
    assign execute_generation_o = generation_q[execute_idx_i];
    assign response_live_o = response_valid_i
                           && valid_q[response_tag_i[IDX_WIDTH-1:0]]
                           && generation_q[response_tag_i[IDX_WIDTH-1:0]]
                              == response_tag_i[IDX_WIDTH];

    always_comb begin
        for (int lane = 0; lane < RENAME_WIDTH; lane++) begin
            int unsigned req_before_lane;
            req_before_lane = 0;
            for (int older = 0; older < lane; older++) begin
                if (alloc_req_i[older]) req_before_lane++;
            end
            alloc_idx_o[lane] = add_idx(tail_q, req_before_lane);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
            valid_q <= '{default: 1'b0};
            generation_q <= '{default: 1'b0};
            addr_valid_q <= '{default: 1'b0};
            outstanding_q <= '{default: 1'b0};
            addr_q <= '{default: '0};
            rob_idx_q <= '{default: '0};
            branch_mask_q <= '{default: '0};
        end else if (resolution_valid_i && resolution_mispredict_i) begin
            int unsigned kept;
            kept = 0;
            for (int entry = 0; entry < DEPTH; entry++) begin
                if (valid_q[entry] && branch_mask_q[entry][resolution_tag_i]) begin
                    valid_q[entry] <= 1'b0;
                    addr_valid_q[entry] <= 1'b0;
                    outstanding_q[entry] <= 1'b0;
                end else if (valid_q[entry]) begin
                    kept++;
                end
            end
            for (int released = 0; released < RENAME_WIDTH; released++) begin
                if (released < int'(release_count_i)) begin
                    valid_q[add_idx(head_q, released)] <= 1'b0;
                    addr_valid_q[add_idx(head_q, released)] <= 1'b0;
                    outstanding_q[add_idx(head_q, released)] <= 1'b0;
                end
            end
            head_q <= add_idx(head_q, int'(release_count_i));
            tail_q <= restore_tail_i;
            count_q <= COUNT_WIDTH'(kept) - COUNT_WIDTH'(release_count_i);
        end else begin
            int unsigned alloc_count;
            alloc_count = 0;

            for (int released = 0; released < RENAME_WIDTH; released++) begin
                if (released < int'(release_count_i)) begin
                    valid_q[add_idx(head_q, released)] <= 1'b0;
                    addr_valid_q[add_idx(head_q, released)] <= 1'b0;
                    outstanding_q[add_idx(head_q, released)] <= 1'b0;
                end
            end
            if (release_count_i != '0) head_q <= add_idx(head_q, int'(release_count_i));

            for (int entry = 0; entry < DEPTH; entry++) begin
                if (resolution_valid_i) branch_mask_q[entry][resolution_tag_i] <= 1'b0;
            end

            if (alloc_fire_i) begin
                for (int lane = 0; lane < RENAME_WIDTH; lane++) begin
                    if (alloc_req_i[lane]) begin
                        valid_q[alloc_idx_o[lane]] <= 1'b1;
                        generation_q[alloc_idx_o[lane]] <= ~generation_q[alloc_idx_o[lane]];
                        addr_valid_q[alloc_idx_o[lane]] <= 1'b0;
                        outstanding_q[alloc_idx_o[lane]] <= 1'b0;
                        addr_q[alloc_idx_o[lane]] <= '0;
                        rob_idx_q[alloc_idx_o[lane]] <= alloc_rob_idx_i[lane];
                        branch_mask_q[alloc_idx_o[lane]] <= alloc_branch_mask_i[lane];
                        alloc_count++;
                    end
                end
                tail_q <= add_idx(tail_q, alloc_count);
            end

            if (execute_valid_i && valid_q[execute_idx_i]) begin
                addr_q[execute_idx_i] <= execute_addr_i;
                addr_valid_q[execute_idx_i] <= 1'b1;
            end
            if (request_fire_i && valid_q[request_idx_i]) begin
                outstanding_q[request_idx_i] <= 1'b1;
            end
            if (response_live_o) begin
                outstanding_q[response_tag_i[IDX_WIDTH-1:0]] <= 1'b0;
            end

            count_q <= count_q + COUNT_WIDTH'(alloc_count) - COUNT_WIDTH'(release_count_i);
        end
    end

    initial if (DEPTH <= 0) $error("load_queue requires DEPTH > 0");
endmodule
