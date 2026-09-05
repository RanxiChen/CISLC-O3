/**
 * Branch Checkpoint File
 *
 * 职责：
 * - 管理有限个未决分支tag，并为同拍最多MACHINE_WIDTH个分支给出不同候选tag。
 * - 保存每个分支建立时的父branch mask以及ROB/LQ/SQ恢复tail。
 * - 正确解析时只释放本分支；误预测时同时释放本分支和它的所有年轻后代。
 *
 * Rename Map快照和preg allocation mask分别由rename_map_table/free_list保存，
 * 本模块只保存跨顺序队列共享的恢复位置和checkpoint年龄关系。
 *
 * 周期行为：
 * - 周期N组合阶段从当前空闲tag集合按lane年龄产生候选tag。
 * - 周期N上升沿写入本拍真正接受的checkpoint；resolution与新建互斥且优先处理resolution。
 * - 周期N+1 active_mask_o反映仍未解析的分支集合。
 */

module branch_checkpoint_file
    import o3_pkg::*;
#(
    parameter int MACHINE_WIDTH = 4,
    parameter int NUM_CHECKPOINTS = BACKEND_NUM_BRANCH_CHECKPOINTS,
    parameter int NUM_ROB_ENTRIES = BACKEND_NUM_ROB_ENTRIES,
    parameter int LQ_DEPTH = BACKEND_LOAD_QUEUE_DEPTH,
    parameter int SQ_DEPTH = BACKEND_STORE_QUEUE_DEPTH
) (
    input  logic clk,
    input  logic rst,

    input  logic        alloc_req_i [MACHINE_WIDTH-1:0],
    output logic        alloc_grant_o [MACHINE_WIDTH-1:0],
    output branch_tag_t alloc_tag_o [MACHINE_WIDTH-1:0],

    input  logic        create_i [MACHINE_WIDTH-1:0],
    input  branch_mask_t create_parent_mask_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ROB_ENTRIES)-1:0] create_rob_tail_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(LQ_DEPTH)-1:0] create_lq_tail_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(SQ_DEPTH)-1:0] create_sq_tail_i [MACHINE_WIDTH-1:0],

    input  logic        resolution_valid_i,
    input  logic        resolution_mispredict_i,
    input  branch_tag_t resolution_tag_i,

    output branch_mask_t active_mask_o,
    output logic [$clog2(NUM_ROB_ENTRIES)-1:0] restore_rob_tail_o,
    output logic [$clog2(LQ_DEPTH)-1:0] restore_lq_tail_o,
    output logic [$clog2(SQ_DEPTH)-1:0] restore_sq_tail_o
);

    logic [NUM_CHECKPOINTS-1:0] valid_q;
    branch_mask_t parent_mask_q [NUM_CHECKPOINTS-1:0];
    logic [$clog2(NUM_ROB_ENTRIES)-1:0] rob_tail_q [NUM_CHECKPOINTS-1:0];
    logic [$clog2(LQ_DEPTH)-1:0] lq_tail_q [NUM_CHECKPOINTS-1:0];
    logic [$clog2(SQ_DEPTH)-1:0] sq_tail_q [NUM_CHECKPOINTS-1:0];

    assign active_mask_o = branch_mask_t'(valid_q);
    assign restore_rob_tail_o = rob_tail_q[resolution_tag_i];
    assign restore_lq_tail_o = lq_tail_q[resolution_tag_i];
    assign restore_sq_tail_o = sq_tail_q[resolution_tag_i];

    always_comb begin
        logic [NUM_CHECKPOINTS-1:0] available;

        available = ~valid_q;
        alloc_grant_o = '{default: 1'b0};
        alloc_tag_o = '{default: '0};

        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            int chosen_tag;
            chosen_tag = -1;
            if (alloc_req_i[lane]) begin
                for (int tag = 0; tag < NUM_CHECKPOINTS; tag++) begin
                    if ((chosen_tag < 0) && available[tag]) begin
                        chosen_tag = tag;
                    end
                end
                if (chosen_tag >= 0) begin
                    alloc_grant_o[lane] = 1'b1;
                    alloc_tag_o[lane] = branch_tag_t'(chosen_tag);
                    available[chosen_tag] = 1'b0;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_q <= '0;
            parent_mask_q <= '{default: '0};
            rob_tail_q <= '{default: '0};
            lq_tail_q <= '{default: '0};
            sq_tail_q <= '{default: '0};
        end else if (resolution_valid_i) begin
            for (int tag = 0; tag < NUM_CHECKPOINTS; tag++) begin
                if ((tag == int'(resolution_tag_i))
                 || (resolution_mispredict_i && parent_mask_q[tag][resolution_tag_i])) begin
                    valid_q[tag] <= 1'b0;
                end else begin
                    // 正确解析后，存活的年轻checkpoint不再依赖已经释放的tag。
                    parent_mask_q[tag][resolution_tag_i] <= 1'b0;
                end
            end
        end else begin
            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (create_i[lane]) begin
                    valid_q[alloc_tag_o[lane]] <= 1'b1;
                    parent_mask_q[alloc_tag_o[lane]] <= create_parent_mask_i[lane];
                    rob_tail_q[alloc_tag_o[lane]] <= create_rob_tail_i[lane];
                    lq_tail_q[alloc_tag_o[lane]] <= create_lq_tail_i[lane];
                    sq_tail_q[alloc_tag_o[lane]] <= create_sq_tail_i[lane];
                end
            end
        end
    end

    initial begin
        if (NUM_CHECKPOINTS != BACKEND_NUM_BRANCH_CHECKPOINTS) begin
            $error("branch_checkpoint_file checkpoint count must match branch_mask_t width");
        end
    end

endmodule
