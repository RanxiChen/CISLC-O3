/**
 * In-order variable-prefix Dispatch planner
 *
 * 已实现：
 * - 从Rename/Dispatch Queue队头按lane0最老的顺序检查最多DISPATCH_WIDTH条uop。
 * - 根据uop类型累计Integer IQ、Memory IQ和Branch IQ的空位消耗。
 * - 只接受从队头开始的最大连续前缀；某lane目标IQ无空位或类型尚未支持时，
 *   该lane及所有年轻lane留在Rename/Dispatch Queue。
 * - 接受前缀内部允许并行分流到三个不同IQ，但不允许年轻uop绕过被阻塞的老uop。
 *
 * 未实现：
 * - 不做跨过队头的selective/skip Dispatch。
 * - 不连接执行单元，不负责IQ内部wakeup/select。
 * - 当前无法分类的非整数、非访存、非控制流uop停在队头，等待后续异常/系统指令通路。
 *
 * 本模块纯组合，无内部状态：周期N根据三个IQ拍初空位产生接受前缀，
 * 周期N上升沿由RDQ删除该前缀、三个IQ分别写入所属uop，周期N+1看到更新后的队列。
 */
module dispatch_stage
    import o3_pkg::*;
#(
    parameter int DISPATCH_WIDTH = BACKEND_DISPATCH_WIDTH,
    parameter int INT_IQ_DEPTH = BACKEND_INT_ISSUE_QUEUE_DEPTH,
    parameter int MEM_IQ_DEPTH = BACKEND_MEM_ISSUE_QUEUE_DEPTH,
    parameter int BR_IQ_DEPTH = BACKEND_BRANCH_ISSUE_QUEUE_DEPTH
) (
    input  renamed_uop_t [DISPATCH_WIDTH-1:0] uop_i,
    input  logic [$clog2(DISPATCH_WIDTH+1)-1:0] visible_count_i,
    input  logic recovery_block_i,
    input  logic [$clog2(INT_IQ_DEPTH+1)-1:0] int_free_count_i,
    input  logic [$clog2(MEM_IQ_DEPTH+1)-1:0] mem_free_count_i,
    input  logic [$clog2(BR_IQ_DEPTH+1)-1:0] br_free_count_i,

    output logic int_lane_o [DISPATCH_WIDTH-1:0],
    output logic mem_lane_o [DISPATCH_WIDTH-1:0],
    output logic br_lane_o [DISPATCH_WIDTH-1:0],
    output logic [$clog2(DISPATCH_WIDTH+1)-1:0] accept_count_o
);
    localparam int COUNT_WIDTH = $clog2(DISPATCH_WIDTH + 1);

    always_comb begin
        int unsigned int_left, mem_left, br_left;
        logic blocked;

        int_left = int'(int_free_count_i);
        mem_left = int'(mem_free_count_i);
        br_left = int'(br_free_count_i);
        blocked = recovery_block_i;
        int_lane_o = '{default: 1'b0};
        mem_lane_o = '{default: 1'b0};
        br_lane_o = '{default: 1'b0};
        accept_count_o = '0;

        for (int lane = 0; lane < DISPATCH_WIDTH; lane++) begin
            logic is_int, is_mem, is_br, supported, target_has_space;

            is_mem = uop_i[lane].valid && (uop_i[lane].is_load || uop_i[lane].is_store);
            is_br = uop_i[lane].valid
                 && (uop_i[lane].is_branch || uop_i[lane].is_jal || uop_i[lane].is_jalr);
            is_int = uop_i[lane].valid && uop_i[lane].is_int_uop && !is_mem && !is_br;
            supported = is_int || is_mem || is_br;
            target_has_space = (is_int && (int_left > 0))
                            || (is_mem && (mem_left > 0))
                            || (is_br && (br_left > 0));

            if (!blocked && (lane < int'(visible_count_i))
             && uop_i[lane].valid && supported && target_has_space) begin
                int_lane_o[lane] = is_int;
                mem_lane_o[lane] = is_mem;
                br_lane_o[lane] = is_br;
                accept_count_o = accept_count_o + COUNT_WIDTH'(1);
                if (is_int) int_left--;
                if (is_mem) mem_left--;
                if (is_br) br_left--;
            end else if ((lane < int'(visible_count_i)) && uop_i[lane].valid) begin
                blocked = 1'b1;
            end
        end
    end

    initial begin
        if (DISPATCH_WIDTH <= 0) $error("dispatch_stage requires DISPATCH_WIDTH > 0");
        if ((INT_IQ_DEPTH <= 0) || (MEM_IQ_DEPTH <= 0) || (BR_IQ_DEPTH <= 0)) begin
            $error("dispatch_stage requires positive IQ depths");
        end
    end
endmodule
