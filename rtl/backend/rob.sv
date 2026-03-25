/**
 * Minimal ROB
 *
 * 当前已经实现的功能：
 * - 采用参数化项数的环形队列结构，默认可配置为 64 项
 * - 在 rename 阶段按真实有效 uop 数量并行分配 ROB entry 编号
 * - 在分配成功的同拍，把每个 entry 对应的 exception 信息写入 ROB 存储体
 * - 对外继续提供与 MACHINE_WIDTH 一样多的 ROB entry id
 *
 * 当前没有实现的功能：
 * - 不实现完成、提交、释放、回收
 * - 不实现 flush、rollback、checkpoint 恢复
 * - 当前只存 exception，不存 pc、dst_preg、完成状态等其他 ROB 元信息
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 统计本拍所有 alloc_req_i 中真正有效的 uop 数量
 *   2) 若剩余 ROB 空位足够，则 alloc_valid_o=1
 *   3) 对请求为 1 的 lane，按 lane 顺序给出连续的 ROB entry 编号
 * - 周期 N 上升沿：
 *   1) 若 alloc_valid_o && alloc_ready_i，则真正消耗本拍请求数量个 entry
 *   2) head_q 前移，free_count_q 减少
 *   3) 同拍把 alloc_exception_i 写入本拍真正分配到的 ROB entry
 * - 周期 N+1：
 *   看到更新后的下一批 ROB entry 编号、剩余空位数量，以及新写入的 exception 表项
 */

module rob #(
    parameter int MACHINE_WIDTH = 4,
    parameter int NUM_ROB_ENTRIES = 64
) (
    input  logic clk,
    input  logic rst,
    input  logic                               alloc_req_i       [MACHINE_WIDTH-1:0],
    input  logic                               alloc_exception_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_ready_i,
    output logic                               alloc_valid_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_idx_o       [MACHINE_WIDTH-1:0]
);

    localparam int ROB_IDX_WIDTH = $clog2(NUM_ROB_ENTRIES);
    localparam int COUNT_WIDTH   = $clog2(NUM_ROB_ENTRIES + 1);

    logic [ROB_IDX_WIDTH-1:0] head_q;
    logic [COUNT_WIDTH-1:0]   free_count_q;
    logic [COUNT_WIDTH-1:0]   alloc_req_count;
    logic                     alloc_fire;

    // 当前 ROB 存储体只保存每个 entry 的 exception 位。
    logic                     entry_valid_q     [NUM_ROB_ENTRIES-1:0];
    logic                     entry_exception_q [NUM_ROB_ENTRIES-1:0];

    function automatic logic [ROB_IDX_WIDTH-1:0] wrap_idx(
        input logic [ROB_IDX_WIDTH-1:0] base,
        input int unsigned              offset
    );
        int unsigned sum;
        begin
            sum      = int'(base) + offset;
            wrap_idx = ROB_IDX_WIDTH'(sum % NUM_ROB_ENTRIES);
        end
    endfunction

    always_comb begin
        alloc_req_count = '0;
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            if (alloc_req_i[lane]) begin
                alloc_req_count = alloc_req_count + COUNT_WIDTH'(1);
            end
        end
    end

    assign alloc_valid_o = (free_count_q >= alloc_req_count);
    assign alloc_fire    = alloc_valid_o && alloc_ready_i;

    generate
        genvar idx;
        for (idx = 0; idx < MACHINE_WIDTH; idx++) begin : gen_rob_alloc
            always_comb begin
                int unsigned req_before_lane;

                alloc_idx_o[idx] = '0;
                req_before_lane  = 0;

                for (int lane = 0; lane < idx; lane++) begin
                    if (alloc_req_i[lane]) begin
                        req_before_lane++;
                    end
                end

                if (alloc_valid_o && alloc_req_i[idx]) begin
                    alloc_idx_o[idx] = wrap_idx(head_q, req_before_lane);
                end
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q       <= '0;
            free_count_q <= COUNT_WIDTH'(NUM_ROB_ENTRIES);
            for (int entry = 0; entry < NUM_ROB_ENTRIES; entry++) begin
                entry_valid_q[entry]     <= 1'b0;
                entry_exception_q[entry] <= 1'b0;
            end
        end else if (alloc_fire) begin
            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (alloc_req_i[lane]) begin
                    entry_valid_q[alloc_idx_o[lane]]     <= 1'b1;
                    entry_exception_q[alloc_idx_o[lane]] <= alloc_exception_i[lane];
                end
            end

            head_q       <= wrap_idx(head_q, int'(alloc_req_count));
            free_count_q <= free_count_q - alloc_req_count;
        end
    end

    initial begin
        if (MACHINE_WIDTH <= 0) begin
            $error("rob requires MACHINE_WIDTH > 0");
        end

        if (NUM_ROB_ENTRIES <= 0) begin
            $error("rob requires NUM_ROB_ENTRIES > 0");
        end
    end

endmodule
