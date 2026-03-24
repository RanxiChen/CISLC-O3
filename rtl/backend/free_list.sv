/**
 * Rename Free List
 *
 * 第一阶段实现目标：
 * - 只实现“空闲物理寄存器分配”
 * - 不实现“物理寄存器释放/回收”
 * - 每个周期按解码宽度并行提供空闲物理寄存器
 * - 分配侧接口采用 ready/valid 风格
 * - 只按“本拍实际请求的 lane 数量”分配空闲寄存器
 *
 * 复位后的初始分配约定：
 * - x0 不占用可写物理寄存器
 * - x1 ~ x31 初始映射到物理寄存器 preg 0 ~ 30
 * - 因此 free list 在 reset 后保存的空闲物理寄存器为：
 *   preg 31, 32, 33, ..., NUM_PHYS_REGS-1
 *
 * 周期级行为：
 * - 周期 N 开始时，模块内部持有当前的 head_q 和 count_q
 * - 基于当前状态，模块组合地产生：
 *   1) alloc_valid_o：表示当前 free list 是否还能覆盖本拍所有 alloc_req_i 请求
 *   2) alloc_preg_o[0:DECODE_WIDTH-1]：按 lane 顺序给请求的 lane 分配候选空闲物理寄存器
 * - 在正常流水线中：
 *   1) free list 作为 valid 侧，告诉 rename 阶段“这一拍是否能提供一整组空闲寄存器”
 *   2) rename 阶段作为 ready 侧，用 alloc_ready_i 表示“这一拍是否接受这组空闲寄存器”
 * - 若周期 N 内 alloc_valid_o=1 且 alloc_ready_i=1，则在周期 N 的上升沿：
 *   1) free list 将当前队头的“实际请求数”个寄存器视为已分配
 *   2) head_q 前移请求数
 *   3) count_q 减少请求数
 * - 周期 N+1 开始时，对外可见的是更新后的下一组空闲物理寄存器
 * - 若某一拍有 2 个请求且握手成功，则该拍上升沿会消费连续 2 个空闲寄存器
 * - 若下一拍只有 1 个请求且再次握手成功，则只会继续消费 1 个寄存器
 * - 若某拍没有请求，或者 valid/ready 没有同时成立，则内部状态保持不变
 *
 * 当前明确不做的事情：
 * - 不支持释放/回收物理寄存器
 * - 不支持分支错误恢复
 * - 不支持 checkpoint / rollback
 * - 不支持重复分配保护以外的复杂资源检查
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 */

module free_list #(
    parameter int DECODE_WIDTH  = 4,
    parameter int NUM_PHYS_REGS = 64,
    parameter int NUM_ARCH_REGS = 32
) (
    input  logic clk,
    input  logic rst,

    // 每个 lane 是否需要新的物理寄存器。
    // 当前通常由 backend 用 "rd_write_en && (rd != 0)" 生成。
    input  logic                             alloc_req_i   [DECODE_WIDTH-1:0],

    // rename 阶段的 ready 信号。
    // 当 alloc_valid_o 与 alloc_ready_i 同时为 1 时，本周期完成一次按请求数的分配。
    input  logic                             alloc_ready_i,

    // free list 的 valid 信号。
    // 为 1 表示当前至少还能覆盖本拍所有 alloc_req_i 请求。
    output logic                             alloc_valid_o,

    // 当前可提供给 rename 阶段的一组候选空闲物理寄存器编号。
    // 只有 alloc_req_i[lane]=1 的 lane 才会拿到非零的候选号。
    // 只有当 alloc_valid_o 与 alloc_ready_i 同时为 1 时，这些编号才真正被消费。
    output logic [$clog2(NUM_PHYS_REGS)-1:0] alloc_preg_o [DECODE_WIDTH-1:0]
);

    localparam int PREG_IDX_WIDTH       = $clog2(NUM_PHYS_REGS);
    localparam int INITIAL_MAPPED_PREGS = NUM_ARCH_REGS - 1;
    localparam int FREE_DEPTH           = NUM_PHYS_REGS - INITIAL_MAPPED_PREGS;
    localparam int PTR_WIDTH            = (FREE_DEPTH > 1) ? $clog2(FREE_DEPTH) : 1;
    localparam int COUNT_WIDTH          = $clog2(FREE_DEPTH + 1);

    // 环形队列存储体。每个表项保存一个空闲物理寄存器编号。
    logic [PREG_IDX_WIDTH-1:0] queue_mem [FREE_DEPTH];

    // head_q 指向当前队头，也就是下一次分配的起始位置。
    // count_q 记录当前剩余空闲物理寄存器数量。
    logic [PTR_WIDTH-1:0]   head_q;
    logic [COUNT_WIDTH-1:0] count_q;

    // 内部握手成功条件。
    logic                   alloc_fire;
    logic [COUNT_WIDTH-1:0] alloc_req_count;

    // 计算环形队列下标，超过队列深度时自动回绕。
    function automatic int unsigned wrap_idx(input int unsigned base, input int unsigned offset);
        int unsigned sum;
        begin
            sum = base + offset;
            wrap_idx = sum % FREE_DEPTH;
        end
    endfunction

    // 统计本拍真正需要分配的新物理寄存器个数。
    always_comb begin
        alloc_req_count = '0;
        for (int lane = 0; lane < DECODE_WIDTH; lane++) begin
            if (alloc_req_i[lane]) begin
                alloc_req_count = alloc_req_count + COUNT_WIDTH'(1);
            end
        end
    end

    // 只有当当前剩余空闲寄存器数量足够覆盖本拍请求数时，才允许本拍分配成功。
    assign alloc_valid_o = (count_q >= alloc_req_count);

    // ready/valid 同时为 1，表示本周期 rename 阶段接受了这一组空闲寄存器。
    assign alloc_fire = alloc_valid_o && alloc_ready_i;

    generate
        genvar alloc_idx;
        for (alloc_idx = 0; alloc_idx < DECODE_WIDTH; alloc_idx++) begin : gen_alloc_output
            always_comb begin
                int unsigned req_before_lane;

                alloc_preg_o[alloc_idx] = '0;
                req_before_lane         = 0;

                for (int lane = 0; lane < alloc_idx; lane++) begin
                    if (alloc_req_i[lane]) begin
                        req_before_lane++;
                    end
                end

                if (alloc_valid_o && alloc_req_i[alloc_idx]) begin
                    alloc_preg_o[alloc_idx] = queue_mem[wrap_idx(int'(head_q), req_before_lane)];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            // reset 后将 preg 31 ~ preg NUM_PHYS_REGS-1 顺序装入 free list。
            for (int i = 0; i < FREE_DEPTH; i++) begin
                queue_mem[i] <= PREG_IDX_WIDTH'(INITIAL_MAPPED_PREGS + i);
            end

            head_q  <= '0;
            count_q <= COUNT_WIDTH'(FREE_DEPTH);
        end else begin
            // 如果上游接受了本拍分配结果，则只消耗本拍真正请求的寄存器个数。
            if (alloc_fire) begin
                head_q  <= PTR_WIDTH'(wrap_idx(int'(head_q), int'(alloc_req_count)));
                count_q <= count_q - alloc_req_count;
            end
        end
    end

    initial begin
        if (DECODE_WIDTH <= 0) begin
            $error("free_list requires DECODE_WIDTH > 0");
        end

        if (NUM_ARCH_REGS < 2) begin
            $error("free_list requires NUM_ARCH_REGS >= 2");
        end

        if (FREE_DEPTH <= 0) begin
            $error("free_list requires at least one free physical register after reset");
        end
    end

endmodule
