/**
 * Speculative and Committed Rename Map Table
 *
 * 职责：
 * - speculative_map_q服务Rename，支持4-wide从老到年轻的RAW/WAW组合旁路。
 * - committed_map_q只在顺序提交时更新，保存精确架构映射基线。
 * - 每个分支checkpoint保存完整speculative map；误预测时一拍恢复。
 *
 * checkpoint快照位于分支lane之后：包含所有更老lane以及控制流指令自身的
 * 目的映射，但不包含同拍更年轻lane的修改。
 *
 * 周期行为：
 * - 周期N组合阶段读取当前speculative map，并让更老lane的新目的映射覆盖基础读值。
 * - 正常Rename上升沿写入接受前缀，并为其中的分支保存对应lane边界快照。
 * - mispredict上升沿优先把目标checkpoint复制回speculative map；commit map仍只随退休更新。
 * - 周期N+1可见新的或恢复后的映射。
 */

module rename_map_table
    import o3_pkg::*;
#(
    parameter int MACHINE_WIDTH = 4,
    parameter int NUM_ARCH_REGS = 32,
    parameter int NUM_PHYS_REGS = 96,
    parameter int NUM_CHECKPOINTS = BACKEND_NUM_BRANCH_CHECKPOINTS,
    parameter int COMMIT_WIDTH = 4
) (
    input  logic clk,
    input  logic rst,

    input  logic                             rename_fire_i,
    input  logic                             lane_valid_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rs1_addr_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rs2_addr_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rd_addr_i [MACHINE_WIDTH-1:0],
    input  logic                             rs1_read_en_i [MACHINE_WIDTH-1:0],
    input  logic                             rs2_read_en_i [MACHINE_WIDTH-1:0],
    input  logic                             rd_write_en_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_PHYS_REGS)-1:0] new_dst_preg_i [MACHINE_WIDTH-1:0],

    input  logic                             checkpoint_create_i [MACHINE_WIDTH-1:0],
    input  branch_tag_t                      checkpoint_create_tag_i [MACHINE_WIDTH-1:0],
    input  logic                             resolution_valid_i,
    input  logic                             resolution_mispredict_i,
    input  branch_tag_t                      resolution_tag_i,

    input  logic                             commit_valid_i [COMMIT_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] commit_rd_i [COMMIT_WIDTH-1:0],
    input  logic                             commit_rd_write_en_i [COMMIT_WIDTH-1:0],
    input  logic [$clog2(NUM_PHYS_REGS)-1:0] commit_new_preg_i [COMMIT_WIDTH-1:0],

    output logic [$clog2(NUM_PHYS_REGS)-1:0] src1_preg_o [MACHINE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS)-1:0] src2_preg_o [MACHINE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS)-1:0] old_dst_preg_o [MACHINE_WIDTH-1:0],
    output logic                             src1_from_older_lane_o [MACHINE_WIDTH-1:0],
    output logic                             src2_from_older_lane_o [MACHINE_WIDTH-1:0]
);

    localparam int ARCH_IDX_WIDTH = $clog2(NUM_ARCH_REGS);
    localparam int PREG_IDX_WIDTH = $clog2(NUM_PHYS_REGS);

    logic [PREG_IDX_WIDTH-1:0] speculative_map_q [NUM_ARCH_REGS-1:0];
    logic [PREG_IDX_WIDTH-1:0] committed_map_q [NUM_ARCH_REGS-1:0];
    logic [PREG_IDX_WIDTH-1:0] checkpoint_map_q [NUM_CHECKPOINTS-1:0][NUM_ARCH_REGS-1:0];

    always_comb begin
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            src1_preg_o[lane] = '0;
            src2_preg_o[lane] = '0;
            old_dst_preg_o[lane] = '0;
            src1_from_older_lane_o[lane] = 1'b0;
            src2_from_older_lane_o[lane] = 1'b0;

            if (lane_valid_i[lane] && rs1_read_en_i[lane] && (rs1_addr_i[lane] != '0)) begin
                src1_preg_o[lane] = speculative_map_q[rs1_addr_i[lane]];
                for (int older = 0; older < lane; older++) begin
                    if (lane_valid_i[older] && rd_write_en_i[older]
                     && (rd_addr_i[older] != '0) && (rd_addr_i[older] == rs1_addr_i[lane])) begin
                        src1_preg_o[lane] = new_dst_preg_i[older];
                        src1_from_older_lane_o[lane] = 1'b1;
                    end
                end
            end

            if (lane_valid_i[lane] && rs2_read_en_i[lane] && (rs2_addr_i[lane] != '0)) begin
                src2_preg_o[lane] = speculative_map_q[rs2_addr_i[lane]];
                for (int older = 0; older < lane; older++) begin
                    if (lane_valid_i[older] && rd_write_en_i[older]
                     && (rd_addr_i[older] != '0) && (rd_addr_i[older] == rs2_addr_i[lane])) begin
                        src2_preg_o[lane] = new_dst_preg_i[older];
                        src2_from_older_lane_o[lane] = 1'b1;
                    end
                end
            end

            if (lane_valid_i[lane] && rd_write_en_i[lane] && (rd_addr_i[lane] != '0)) begin
                old_dst_preg_o[lane] = speculative_map_q[rd_addr_i[lane]];
                for (int older = 0; older < lane; older++) begin
                    if (lane_valid_i[older] && rd_write_en_i[older]
                     && (rd_addr_i[older] != '0) && (rd_addr_i[older] == rd_addr_i[lane])) begin
                        old_dst_preg_o[lane] = new_dst_preg_i[older];
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
                speculative_map_q[arch] <= PREG_IDX_WIDTH'(arch);
                committed_map_q[arch] <= PREG_IDX_WIDTH'(arch);
            end
            checkpoint_map_q <= '{default: '0};
        end else begin
            // Committed map与推测恢复正交；只接受ROB顺序退休提供的新映射。
            for (int port = 0; port < COMMIT_WIDTH; port++) begin
                if (commit_valid_i[port] && commit_rd_write_en_i[port] && (commit_rd_i[port] != '0)) begin
                    committed_map_q[commit_rd_i[port]] <= commit_new_preg_i[port];
                end
            end

            if (resolution_valid_i && resolution_mispredict_i) begin
                for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
                    speculative_map_q[arch] <= checkpoint_map_q[resolution_tag_i][arch];
                end
            end else if (rename_fire_i) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (lane_valid_i[lane] && rd_write_en_i[lane] && (rd_addr_i[lane] != '0)) begin
                        speculative_map_q[rd_addr_i[lane]] <= new_dst_preg_i[lane];
                    end
                end

                for (int cp_lane = 0; cp_lane < MACHINE_WIDTH; cp_lane++) begin
                    if (checkpoint_create_i[cp_lane]) begin
                        for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
                            checkpoint_map_q[checkpoint_create_tag_i[cp_lane]][arch] <= speculative_map_q[arch];
                            for (int older_or_self = 0; older_or_self <= cp_lane; older_or_self++) begin
                                if (lane_valid_i[older_or_self] && rd_write_en_i[older_or_self]
                                 && (rd_addr_i[older_or_self] == ARCH_IDX_WIDTH'(arch))
                                 && (rd_addr_i[older_or_self] != '0)) begin
                                    checkpoint_map_q[checkpoint_create_tag_i[cp_lane]][arch]
                                        <= new_dst_preg_i[older_or_self];
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    initial begin
        if (NUM_CHECKPOINTS != BACKEND_NUM_BRANCH_CHECKPOINTS) begin
            $error("rename_map_table checkpoint count must match branch_mask_t width");
        end
    end

endmodule
