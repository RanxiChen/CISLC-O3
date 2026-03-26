/**
 * Minimal ROB
 *
 * 当前已经实现的功能：
 * - 采用参数化项数的环形队列结构，默认可配置为 64 项
 * - 在 rename 阶段按真实有效 uop 数量并行分配 ROB entry 编号
 * - 在分配成功的同拍，把每个 entry 对应的 exception 和 old_dst_preg 信息写入 ROB 存储体
 * - 支持执行写回后按 rob_idx 把对应 entry 标记为 complete
 * - 支持从 ROB 队头开始按程序顺序退休最多 3 条指令，并输出对应 old_dst_preg 供 free list 回收
 * - 对外继续提供与 MACHINE_WIDTH 一样多的 ROB entry id
 *
 * 当前没有实现的功能：
 * - 不实现 flush、rollback、checkpoint 恢复
 * - 当前退休条件只看 valid/complete/exception=0，不处理 store、分支恢复等更复杂的提交约束
 * - 当前只存 instruction_id、exception、old_dst_preg、complete，不存 pc、结果值等其他 ROB 元信息
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 统计本拍所有 alloc_req_i 中真正有效的 uop 数量
 *   2) 若剩余 ROB 空位足够，则 alloc_valid_o=1
 *   3) 对请求为 1 的 lane，按 lane 顺序给出连续的 ROB entry 编号
 *   4) 从当前 head 开始最多检查 RETIRE_WIDTH 项，只退休从队头开始连续 complete 且无异常的前缀
 * - 周期 N 上升沿：
 *   1) 若 alloc_valid_o && alloc_ready_i，则真正消耗本拍请求数量个 entry，并把 tail_q 前移
 *   2) 若本拍有退休，则把 head_q 前移退休条数，并清掉对应 entry_valid
 *   3) 同拍把 alloc_exception_i / alloc_old_dst_preg_i / alloc_instruction_id_i 写入新分配到的 ROB entry，并清除 complete 位
 *   4) 若 complete_valid_i=1，则把对应 rob_idx 的 complete 位置 1
 *   5) free_count_q 按“退休数 - 分配数”更新
 * - 周期 N+1：
 *   看到更新后的下一批 ROB entry 编号、剩余空位数量，以及新写入的 ROB 元信息
 */

module rob #(
    parameter int MACHINE_WIDTH = 4,
    parameter int NUM_ROB_ENTRIES = 64,
    parameter int NUM_PHYS_REGS = 64,
    parameter int COMPLETE_WIDTH = 3,
    parameter int RETIRE_WIDTH = 3
) (
    input  logic clk,
    input  logic rst,
    input  logic                               alloc_req_i       [MACHINE_WIDTH-1:0],
    input  logic                               alloc_exception_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_PHYS_REGS)-1:0]   alloc_old_dst_preg_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::INST_ID_WIDTH-1:0]   alloc_instruction_id_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_ready_i,
    input  logic                               complete_valid_i  [COMPLETE_WIDTH-1:0],
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] complete_idx_i    [COMPLETE_WIDTH-1:0],
    output logic                               alloc_valid_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_idx_o       [MACHINE_WIDTH-1:0],
    output logic                               retire_valid_o    [RETIRE_WIDTH-1:0],
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] retire_idx_o      [RETIRE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS)-1:0]   retire_old_dst_preg_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::INST_ID_WIDTH-1:0]   retire_instruction_id_o [RETIRE_WIDTH-1:0]
);

    localparam int ROB_IDX_WIDTH = $clog2(NUM_ROB_ENTRIES);
    localparam int COUNT_WIDTH   = $clog2(NUM_ROB_ENTRIES + 1);
    localparam int INST_ID_WIDTH_LOCAL = o3_pkg::INST_ID_WIDTH;

    logic [ROB_IDX_WIDTH-1:0] head_q;
    logic [ROB_IDX_WIDTH-1:0] tail_q;
    logic [COUNT_WIDTH-1:0]   free_count_q;
    logic [COUNT_WIDTH-1:0]   alloc_req_count;
    logic [COUNT_WIDTH-1:0]   retire_count;
    logic                     alloc_fire;

    localparam int PREG_IDX_WIDTH = $clog2(NUM_PHYS_REGS);

    // 当前 ROB 存储体保存异常位、被覆盖的旧目的物理寄存器和完成位。
    logic                     entry_valid_q     [NUM_ROB_ENTRIES-1:0];
    logic                     entry_exception_q [NUM_ROB_ENTRIES-1:0];
    logic [PREG_IDX_WIDTH-1:0] entry_old_dst_preg_q [NUM_ROB_ENTRIES-1:0];
    logic                      entry_complete_q  [NUM_ROB_ENTRIES-1:0];
    logic [INST_ID_WIDTH_LOCAL-1:0]  entry_instruction_id_q [NUM_ROB_ENTRIES-1:0];

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
                    alloc_idx_o[idx] = wrap_idx(tail_q, req_before_lane);
                end
            end
        end
    endgenerate

    generate
        genvar ridx;
        for (ridx = 0; ridx < RETIRE_WIDTH; ridx++) begin : gen_rob_retire
            logic [ROB_IDX_WIDTH-1:0] retire_idx;
            logic                     retire_prefix_valid;

            assign retire_idx = wrap_idx(head_q, ridx);
            assign retire_idx_o[ridx] = retire_idx;
            assign retire_old_dst_preg_o[ridx] = entry_old_dst_preg_q[retire_idx];
            assign retire_instruction_id_o[ridx] = entry_instruction_id_q[retire_idx];

            always_comb begin
                retire_prefix_valid = 1'b1;

                // 退休必须严格按序，只允许从队头开始连续退休。
                for (int prior = 0; prior <= ridx; prior++) begin
                    logic [ROB_IDX_WIDTH-1:0] prior_idx;
                    prior_idx = wrap_idx(head_q, prior);
                    if (!(entry_valid_q[prior_idx]
                       && entry_complete_q[prior_idx]
                       && !entry_exception_q[prior_idx])) begin
                        retire_prefix_valid = 1'b0;
                    end
                end

                retire_valid_o[ridx] = retire_prefix_valid;
            end
        end
    endgenerate

    always_comb begin
        retire_count = '0;
        for (int port = 0; port < RETIRE_WIDTH; port++) begin
            if (retire_valid_o[port]) begin
                retire_count = retire_count + COUNT_WIDTH'(1);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            head_q       <= '0;
            tail_q       <= '0;
            free_count_q <= COUNT_WIDTH'(NUM_ROB_ENTRIES);
            for (int entry = 0; entry < NUM_ROB_ENTRIES; entry++) begin
                entry_valid_q[entry]     <= 1'b0;
                entry_exception_q[entry] <= 1'b0;
                entry_old_dst_preg_q[entry] <= '0;
                entry_complete_q[entry]  <= 1'b0;
                entry_instruction_id_q[entry] <= '0;
            end
        end else begin
            for (int port = 0; port < RETIRE_WIDTH; port++) begin
                if (retire_valid_o[port]) begin
                    entry_valid_q[retire_idx_o[port]] <= 1'b0;
                end
            end

            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (alloc_fire && alloc_req_i[lane]) begin
                    entry_valid_q[alloc_idx_o[lane]]     <= 1'b1;
                    entry_exception_q[alloc_idx_o[lane]] <= alloc_exception_i[lane];
                    entry_old_dst_preg_q[alloc_idx_o[lane]] <= alloc_old_dst_preg_i[lane];
                    entry_complete_q[alloc_idx_o[lane]]  <= 1'b0;
                    entry_instruction_id_q[alloc_idx_o[lane]] <= alloc_instruction_id_i[lane];
                end
            end

            // 写回阶段返回的执行结果在这里把 ROB 项标记为 complete。
            for (int c = 0; c < COMPLETE_WIDTH; c++) begin
                if (complete_valid_i[c]) begin
                    entry_complete_q[complete_idx_i[c]] <= 1'b1;
                end
            end

            if (retire_count != '0) begin
                head_q <= wrap_idx(head_q, int'(retire_count));
            end

            if (alloc_fire) begin
                tail_q <= wrap_idx(tail_q, int'(alloc_req_count));
            end

            free_count_q <= free_count_q + retire_count - (alloc_fire ? alloc_req_count : COUNT_WIDTH'(0));
        end
    end

    initial begin
        if (MACHINE_WIDTH <= 0) begin
            $error("rob requires MACHINE_WIDTH > 0");
        end

        if (NUM_ROB_ENTRIES <= 0) begin
            $error("rob requires NUM_ROB_ENTRIES > 0");
        end

        if (NUM_PHYS_REGS <= 0) begin
            $error("rob requires NUM_PHYS_REGS > 0");
        end

        if (RETIRE_WIDTH <= 0) begin
            $error("rob requires RETIRE_WIDTH > 0");
        end
    end

endmodule
