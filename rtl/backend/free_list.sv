/**
 * Rename Free List with branch allocation lists
 *
 * 职责：
 * - 复位时p0..p31承担初始架构映射，p32..p95空闲；提交后被覆盖的p1..p31也可回收。
 * - 只有p0永久保留，永不进入候选或释放集合。
 * - 按 lane0 到 laneN 的年龄顺序，每拍最多选择 MACHINE_WIDTH 个空闲 preg。
 * - 为每个未决分支维护 allocation mask，记录该分支之后分配的 preg。
 * - 分支预测失败时一拍返还错误路径 preg；预测正确时只释放 mask 槽位。
 *
 * 不负责：不维护架构映射，也不分配 branch tag。
 *
 * 周期行为：
 * - 周期 N 组合阶段：从 free_bitmap_q 连续优先选择候选 preg并给出空闲数量。
 * - 周期 N 上升沿：正常拍原子清除分配位、加入commit释放位并更新分支分配掩码。
 * - mispredict上升沿：禁止正常分配，把目标分支allocation mask与commit释放合并回空闲位图。
 * - 周期 N+1：Rename看到恢复后的空闲集合；PRF中的旧数据不需要清零。
 */

module free_list
    import o3_pkg::*;
#(
    parameter int MACHINE_WIDTH = 4,
    parameter int NUM_PHYS_REGS = 96,
    parameter int NUM_ARCH_REGS = 32,
    parameter int RELEASE_WIDTH = 4,
    parameter int NUM_CHECKPOINTS = BACKEND_NUM_BRANCH_CHECKPOINTS
) (
    input  logic clk,
    input  logic rst,

    input  logic                              alloc_req_i [MACHINE_WIDTH-1:0],
    input  logic                              alloc_fire_i,
    output logic                              alloc_available_o,
    output logic [$clog2(NUM_PHYS_REGS)-1:0]  alloc_preg_o [MACHINE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS+1)-1:0] free_count_o,

    input  logic                              release_valid_i [RELEASE_WIDTH-1:0],
    input  logic [$clog2(NUM_PHYS_REGS)-1:0]  release_preg_i [RELEASE_WIDTH-1:0],

    input  logic                              checkpoint_create_i [MACHINE_WIDTH-1:0],
    input  branch_tag_t                       checkpoint_create_tag_i [MACHINE_WIDTH-1:0],
    input  branch_mask_t                      alloc_branch_mask_i [MACHINE_WIDTH-1:0],

    input  logic                              resolution_valid_i,
    input  logic                              resolution_mispredict_i,
    input  branch_tag_t                       resolution_tag_i
);

    localparam int PREG_IDX_WIDTH = $clog2(NUM_PHYS_REGS);
    localparam int COUNT_WIDTH = $clog2(NUM_PHYS_REGS + 1);

    logic [NUM_PHYS_REGS-1:0] free_bitmap_q;
    logic [NUM_PHYS_REGS-1:0] allocation_mask_q [NUM_CHECKPOINTS-1:0];
    logic [NUM_PHYS_REGS-1:0] candidate_bitmap_after_alloc;

    always_comb begin
        logic [NUM_PHYS_REGS-1:0] candidate_bitmap;
        int unsigned request_count;
        int unsigned selected_count;

        candidate_bitmap = free_bitmap_q;
        request_count = 0;
        selected_count = 0;
        alloc_preg_o = '{default: '0};

        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            int chosen_preg;
            chosen_preg = -1;
            if (alloc_req_i[lane]) begin
                request_count++;
                for (int preg = 1; preg < NUM_PHYS_REGS; preg++) begin
                    if ((chosen_preg < 0) && candidate_bitmap[preg]) begin
                        chosen_preg = preg;
                    end
                end
                if (chosen_preg >= 0) begin
                    alloc_preg_o[lane] = PREG_IDX_WIDTH'(chosen_preg);
                    candidate_bitmap[chosen_preg] = 1'b0;
                    selected_count++;
                end
            end
        end

        candidate_bitmap_after_alloc = candidate_bitmap;
        alloc_available_o = (selected_count == request_count);

        free_count_o = '0;
        for (int preg = 1; preg < NUM_PHYS_REGS; preg++) begin
            if (free_bitmap_q[preg]) begin
                free_count_o = free_count_o + COUNT_WIDTH'(1);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            free_bitmap_q <= '0;
            for (int preg = NUM_ARCH_REGS; preg < NUM_PHYS_REGS; preg++) begin
                free_bitmap_q[preg] <= 1'b1;
            end
            allocation_mask_q <= '{default: '0};
        end else begin
            logic [NUM_PHYS_REGS-1:0] free_next;
            logic [NUM_PHYS_REGS-1:0] allocation_next [NUM_CHECKPOINTS-1:0];

            free_next = free_bitmap_q;
            allocation_next = allocation_mask_q;

            for (int port = 0; port < RELEASE_WIDTH; port++) begin
                if (release_valid_i[port]
                 && (release_preg_i[port] != '0)
                 && (release_preg_i[port] < PREG_IDX_WIDTH'(NUM_PHYS_REGS))) begin
                    free_next[release_preg_i[port]] = 1'b1;
                end
            end

            if (resolution_valid_i && resolution_mispredict_i) begin
                free_next |= allocation_mask_q[resolution_tag_i];
            end else if (alloc_fire_i) begin
                free_next = candidate_bitmap_after_alloc;

                // 候选位图从拍初状态产生，因此需要重新合入本拍commit释放。
                for (int port = 0; port < RELEASE_WIDTH; port++) begin
                    if (release_valid_i[port]
                     && (release_preg_i[port] != '0)
                     && (release_preg_i[port] < PREG_IDX_WIDTH'(NUM_PHYS_REGS))) begin
                        free_next[release_preg_i[port]] = 1'b1;
                    end
                end

                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (checkpoint_create_i[lane]) begin
                        allocation_next[checkpoint_create_tag_i[lane]] = '0;
                    end
                end

                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (alloc_req_i[lane]) begin
                        for (int cp = 0; cp < NUM_CHECKPOINTS; cp++) begin
                            if (alloc_branch_mask_i[lane][cp]) begin
                                allocation_next[cp][alloc_preg_o[lane]] = 1'b1;
                            end
                        end
                    end
                end
            end

            if (resolution_valid_i) begin
                allocation_next[resolution_tag_i] = '0;
            end

            free_bitmap_q <= free_next;
            allocation_mask_q <= allocation_next;
        end
    end

    initial begin
        if (NUM_PHYS_REGS <= NUM_ARCH_REGS) begin
            $error("free_list requires NUM_PHYS_REGS > NUM_ARCH_REGS");
        end
        if (NUM_CHECKPOINTS != BACKEND_NUM_BRANCH_CHECKPOINTS) begin
            $error("free_list checkpoint count must match branch_mask_t width");
        end
    end

endmodule
