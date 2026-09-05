/**
 * Minimal ROB
 *
 * 当前已经实现的功能：
 * - 采用参数化项数的环形队列结构，默认可配置为 64 项
 * - 在 rename 阶段按真实有效 uop 数量并行分配 ROB entry 编号
 * - 在分配成功的同拍，把每个 entry 对应的 exception 和 old_dst_preg 信息写入 ROB 存储体
 * - 支持执行写回后按 rob_idx 把对应 entry 标记为 complete
 * - 支持从 ROB 队头开始按程序顺序退休最多 4 条指令，并输出对应 old_dst_preg 供 free list 回收
 * - 对外继续提供与 MACHINE_WIDTH 一样多的 ROB entry id
 * - 在 `ENABLE_RETIRE_INFO` 下保存 ALU retire 观测所需的 pc/inst/rd/rd_wdata，并在退休口输出
 * - 每项保存branch mask、new/old preg和LQ/SQ索引；误预测时清除目标分支之后的项并恢复tail
 *
 * 当前没有实现的功能：
 * - Store在AGU写SQ后complete；ROB退休通过is_store/sq_idx让SQ entry转为committed，
 *   真正写Data SRAM和SQ释放由Store Queue负责
 * - checkpoint本体由branch_checkpoint_file管理，ROB只执行其恢复tail合同
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
 *   6) mispredict时恢复优先：分支本身标记完成、年轻表项失效、tail回到checkpoint位置
 * - 周期 N+1：
 *   看到更新后的下一批 ROB entry 编号、剩余空位数量，以及新写入的 ROB 元信息
 */

module rob #(
    parameter int MACHINE_WIDTH = 4,
    parameter int NUM_ROB_ENTRIES = 64,
    parameter int NUM_PHYS_REGS = 96,
    parameter int COMPLETE_WIDTH = 4,
    parameter int RETIRE_WIDTH = 4
) (
    input  logic clk,
    input  logic rst,
    input  logic                               alloc_req_i       [MACHINE_WIDTH-1:0],
    input  logic                               alloc_exception_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_PHYS_REGS)-1:0]   alloc_old_dst_preg_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_PHYS_REGS)-1:0]   alloc_new_dst_preg_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::REG_ADDR_WIDTH-1:0]  alloc_rd_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_rd_write_en_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_is_load_i [MACHINE_WIDTH-1:0],
    input  logic                               alloc_is_store_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::LQ_IDX_WIDTH-1:0]     alloc_lq_idx_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::SQ_IDX_WIDTH-1:0]     alloc_sq_idx_i [MACHINE_WIDTH-1:0],
    input  o3_pkg::branch_mask_t                alloc_branch_mask_i [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::INST_ID_WIDTH-1:0]   alloc_instruction_id_i [MACHINE_WIDTH-1:0],
`ifdef ENABLE_RETIRE_INFO
    input  logic [o3_pkg::PC_WIDTH-1:0]         alloc_pc_i        [MACHINE_WIDTH-1:0],
    input  logic [o3_pkg::ILEN-1:0]             alloc_instruction_i [MACHINE_WIDTH-1:0],
`endif
    input  logic                               alloc_ready_i,
    input  logic                               complete_valid_i  [COMPLETE_WIDTH-1:0],
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] complete_idx_i    [COMPLETE_WIDTH-1:0],
    input  logic                               resolution_valid_i,
    input  logic                               resolution_mispredict_i,
    input  o3_pkg::branch_tag_t                resolution_tag_i,
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] resolution_rob_idx_i,
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] restore_tail_i,
`ifdef ENABLE_RETIRE_INFO
    input  logic [o3_pkg::XLEN-1:0]             complete_rd_wdata_i [COMPLETE_WIDTH-1:0],
`endif
    output logic                               alloc_valid_o,
    output logic [$clog2(NUM_ROB_ENTRIES+1)-1:0] free_count_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] head_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] tail_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] alloc_idx_o       [MACHINE_WIDTH-1:0],
    output logic                               retire_valid_o    [RETIRE_WIDTH-1:0],
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] retire_idx_o      [RETIRE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS)-1:0]   retire_old_dst_preg_o [RETIRE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS)-1:0]   retire_new_dst_preg_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::REG_ADDR_WIDTH-1:0]  retire_rd_o [RETIRE_WIDTH-1:0],
    output logic                               retire_rd_write_en_o [RETIRE_WIDTH-1:0],
    output logic                               retire_is_load_o [RETIRE_WIDTH-1:0],
    output logic                               retire_is_store_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::LQ_IDX_WIDTH-1:0]     retire_lq_idx_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::SQ_IDX_WIDTH-1:0]     retire_sq_idx_o [RETIRE_WIDTH-1:0],
    output logic [o3_pkg::INST_ID_WIDTH-1:0]   retire_instruction_id_o [RETIRE_WIDTH-1:0]
`ifdef ENABLE_RETIRE_INFO
    ,output o3_pkg::retire_info_t              retire_info_o     [RETIRE_WIDTH-1:0]
`endif
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
    logic [PREG_IDX_WIDTH-1:0] entry_new_dst_preg_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::REG_ADDR_WIDTH-1:0] entry_rd_q [NUM_ROB_ENTRIES-1:0];
    logic entry_rd_write_en_q [NUM_ROB_ENTRIES-1:0];
    logic entry_is_load_q [NUM_ROB_ENTRIES-1:0];
    logic entry_is_store_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::LQ_IDX_WIDTH-1:0] entry_lq_idx_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::SQ_IDX_WIDTH-1:0] entry_sq_idx_q [NUM_ROB_ENTRIES-1:0];
    o3_pkg::branch_mask_t entry_branch_mask_q [NUM_ROB_ENTRIES-1:0];
    logic                      entry_complete_q  [NUM_ROB_ENTRIES-1:0];
    logic [INST_ID_WIDTH_LOCAL-1:0]  entry_instruction_id_q [NUM_ROB_ENTRIES-1:0];
`ifdef ENABLE_RETIRE_INFO
    logic [o3_pkg::PC_WIDTH-1:0]         entry_pc_q          [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::ILEN-1:0]             entry_instruction_q [NUM_ROB_ENTRIES-1:0];
    logic [o3_pkg::XLEN-1:0]             entry_rd_wdata_q    [NUM_ROB_ENTRIES-1:0];
`endif

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
    assign free_count_o  = free_count_q;
    assign head_o        = head_q;
    assign tail_o        = tail_q;

    generate
        genvar idx;
        for (idx = 0; idx < MACHINE_WIDTH; idx++) begin : gen_rob_alloc
            always_comb begin
                int unsigned req_before_lane;

                alloc_idx_o[idx] = '0;
                req_before_lane  = 0;

                for (int lane = 0; lane < int'(idx); lane++) begin
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
            assign retire_new_dst_preg_o[ridx] = entry_new_dst_preg_q[retire_idx];
            assign retire_rd_o[ridx] = entry_rd_q[retire_idx];
            assign retire_rd_write_en_o[ridx] = entry_rd_write_en_q[retire_idx];
            assign retire_is_load_o[ridx] = entry_is_load_q[retire_idx];
            assign retire_is_store_o[ridx] = entry_is_store_q[retire_idx];
            assign retire_lq_idx_o[ridx] = entry_lq_idx_q[retire_idx];
            assign retire_sq_idx_o[ridx] = entry_sq_idx_q[retire_idx];
            assign retire_instruction_id_o[ridx] = entry_instruction_id_q[retire_idx];
`ifdef ENABLE_RETIRE_INFO
            always_comb begin
                retire_info_o[ridx] = '0;
                retire_info_o[ridx].valid          = retire_valid_o[ridx];
                retire_info_o[ridx].rob_idx        = o3_pkg::ROB_IDX_WIDTH'(retire_idx);
                retire_info_o[ridx].instruction_id = entry_instruction_id_q[retire_idx];
                retire_info_o[ridx].pc             = entry_pc_q[retire_idx];
                retire_info_o[ridx].instruction    = entry_instruction_q[retire_idx];
                retire_info_o[ridx].rd             = entry_rd_q[retire_idx];
                retire_info_o[ridx].rd_write_en    = entry_rd_write_en_q[retire_idx];
                retire_info_o[ridx].rd_wdata       = entry_rd_wdata_q[retire_idx];
            end
`endif

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

                retire_valid_o[ridx] = retire_prefix_valid && !resolution_valid_i;
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
                entry_new_dst_preg_q[entry] <= '0;
                entry_rd_q[entry] <= '0;
                entry_rd_write_en_q[entry] <= 1'b0;
                entry_is_load_q[entry] <= 1'b0;
                entry_is_store_q[entry] <= 1'b0;
                entry_lq_idx_q[entry] <= '0;
                entry_sq_idx_q[entry] <= '0;
                entry_branch_mask_q[entry] <= '0;
                entry_complete_q[entry]  <= 1'b0;
                entry_instruction_id_q[entry] <= '0;
`ifdef ENABLE_RETIRE_INFO
                entry_pc_q[entry]          <= '0;
                entry_instruction_q[entry] <= '0;
                entry_rd_wdata_q[entry]    <= '0;
`endif
            end
        end else if (resolution_valid_i && resolution_mispredict_i) begin
            int unsigned kept_count;
            kept_count = 0;
            for (int entry = 0; entry < NUM_ROB_ENTRIES; entry++) begin
                if (entry_valid_q[entry] && entry_branch_mask_q[entry][resolution_tag_i]) begin
                    entry_valid_q[entry] <= 1'b0;
                end else if (entry_valid_q[entry]) begin
                    kept_count++;
                end
            end
            entry_complete_q[resolution_rob_idx_i] <= 1'b1;
            tail_q <= restore_tail_i;
            free_count_q <= COUNT_WIDTH'(NUM_ROB_ENTRIES - kept_count);
        end else begin
            if (resolution_valid_i) begin
                for (int entry = 0; entry < NUM_ROB_ENTRIES; entry++) begin
                    entry_branch_mask_q[entry][resolution_tag_i] <= 1'b0;
                end
                entry_complete_q[resolution_rob_idx_i] <= 1'b1;
            end
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
                    entry_new_dst_preg_q[alloc_idx_o[lane]] <= alloc_new_dst_preg_i[lane];
                    entry_rd_q[alloc_idx_o[lane]] <= alloc_rd_i[lane];
                    entry_rd_write_en_q[alloc_idx_o[lane]] <= alloc_rd_write_en_i[lane];
                    entry_is_load_q[alloc_idx_o[lane]] <= alloc_is_load_i[lane];
                    entry_is_store_q[alloc_idx_o[lane]] <= alloc_is_store_i[lane];
                    entry_lq_idx_q[alloc_idx_o[lane]] <= alloc_lq_idx_i[lane];
                    entry_sq_idx_q[alloc_idx_o[lane]] <= alloc_sq_idx_i[lane];
                    entry_branch_mask_q[alloc_idx_o[lane]] <= alloc_branch_mask_i[lane];
                    entry_complete_q[alloc_idx_o[lane]]  <= 1'b0;
                    entry_instruction_id_q[alloc_idx_o[lane]] <= alloc_instruction_id_i[lane];
`ifdef ENABLE_RETIRE_INFO
                    entry_pc_q[alloc_idx_o[lane]]          <= alloc_pc_i[lane];
                    entry_instruction_q[alloc_idx_o[lane]] <= alloc_instruction_i[lane];
                    entry_rd_wdata_q[alloc_idx_o[lane]]    <= '0;
`endif
                end
            end

            // 写回阶段返回的执行结果在这里把 ROB 项标记为 complete。
            for (int c = 0; c < COMPLETE_WIDTH; c++) begin
                if (complete_valid_i[c]) begin
                    entry_complete_q[complete_idx_i[c]] <= 1'b1;
`ifdef ENABLE_RETIRE_INFO
                    entry_rd_wdata_q[complete_idx_i[c]] <= complete_rd_wdata_i[c];
`endif
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
