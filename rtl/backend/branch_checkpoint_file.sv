/**
 *
 * 【2026-10-02 框架：目标机制与缺口】
 * - checkpoint 数 CFG.rename.checkpoints 待定。FP 映射快照与 FP allocation mask 分别由
 *   FP 实例的 rename_map_table / free_list 保存，本模块合同不变（B15）。
 * - 恢复入口：目标由 D24 统一赢家边界驱动（执行纠错）；提交端异常/xRET 的整体恢复
 *   （使用 committed map）未设计，随 trap_ctrl 闭合。
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
 * - 周期N上升沿写入本拍真正接受的checkpoint；C 同时释放/清位和新建不同 tag；M 禁止新建。
 * - 周期N+1 active_mask_o反映仍未解析的分支集合。
 */
// 当前实现状态：闭环简化（L3）；正确解析不停顿，四宽合同。测试：sim/cocotb/branch_checkpoint_file/。
module branch_checkpoint_file
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int NUM_CHECKPOINTS = CFG.rename.checkpoints,
    localparam int NUM_ROB_ENTRIES = CFG.rob.entries,
    localparam int LQ_DEPTH = CFG.lsu.lq_depth,
    localparam int SQ_DEPTH = CFG.lsu.sq_depth
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

    // 候选 tag 只用拍初 valid_q；rename 依赖集合立即去掉已解析 t。
    always_comb begin
        active_mask_o = branch_mask_t'(valid_q);
        if (resolution_valid_i) active_mask_o[resolution_tag_i] = 1'b0;
    end
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
        end else begin
          if (resolution_valid_i) begin
            for (int tag = 0; tag < NUM_CHECKPOINTS; tag++) begin
                if ((tag == int'(resolution_tag_i))
                 || (resolution_mispredict_i && parent_mask_q[tag][resolution_tag_i])) begin
                    valid_q[tag] <= 1'b0;
                end else begin
                    // 正确解析后，存活的年轻checkpoint不再依赖已经释放的tag。
                    parent_mask_q[tag][resolution_tag_i] <= 1'b0;
                end
            end
          end
          if (!(resolution_valid_i && resolution_mispredict_i)) begin
            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (create_i[lane]) begin
                    valid_q[alloc_tag_o[lane]] <= 1'b1;
                    parent_mask_q[alloc_tag_o[lane]] <= create_parent_mask_i[lane];
                    if (resolution_valid_i) parent_mask_q[alloc_tag_o[lane]][resolution_tag_i] <= 1'b0;
                    assert (alloc_grant_o[lane] && !valid_q[alloc_tag_o[lane]]);
                    assert (!resolution_valid_i || alloc_tag_o[lane] != resolution_tag_i)
                        else $error("checkpoint cannot release/create same tag in one cycle");
                    rob_tail_q[alloc_tag_o[lane]] <= create_rob_tail_i[lane];
                    lq_tail_q[alloc_tag_o[lane]] <= create_lq_tail_i[lane];
                    sq_tail_q[alloc_tag_o[lane]] <= create_sq_tail_i[lane];
                end
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
