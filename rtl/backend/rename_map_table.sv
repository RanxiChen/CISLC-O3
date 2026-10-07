/**
 * Per-domain speculative/committed rename map and shared-tag checkpoints (B02/B15).
 * Three source ports and same-domain intra-group RAW/WAW bypass. Input read/write
 * enables must be qualified for this DOMAIN by the caller. HAS_ZERO_REG preserves
 * x0->p0 only in INT; f0 and fp0 are ordinary FP state.
 * Checkpoints include older/self destinations, exclude younger lanes, and use the
 * same branch tag in both domains. Global flush restores committed state including
 * actual same-boundary retirement. Misprediction restores the selected snapshot.
 * 当前实现状态：闭环简化（L9）；single-cycle rename retained (B42), lint/测试未运行。
 * N: read speculative maps with older-lane bypass. N edge: update accepted mappings,
 * checkpoint snapshots and retired committed mappings, or apply recovery. N+1: new maps.
 */
module rename_map_table
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  o3_types_pkg::reg_domain_e DOMAIN,     // RD_INT / RD_FP，无默认值
    localparam int MACHINE_WIDTH = BACKEND_MACHINE_WIDTH,
    localparam int NUM_ARCH_REGS = o3_isa_pkg::NUM_ARCH_REGS,
    localparam int NUM_PHYS_REGS = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.rename.fp_phys_regs
                                                                   : CFG.rename.int_phys_regs,
    localparam int NUM_CHECKPOINTS = CFG.rename.checkpoints,
    localparam int COMMIT_WIDTH = o3_cfg_pkg::O3_CFG.core.commit_width,
    // 整数域 x0 恒映射 p0；FP 域 f0 正常可写，不做恒零映射（B15）。
    localparam bit HAS_ZERO_REG = (DOMAIN == o3_types_pkg::RD_INT)
) (
    input logic flush_all_i,
    input  logic clk,
    input  logic rst,

    input  logic                             rename_fire_i,
    input  logic                             lane_valid_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rs1_addr_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rs2_addr_i [MACHINE_WIDTH-1:0],
    input logic [$clog2(NUM_ARCH_REGS)-1:0] rs3_addr_i [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rd_addr_i [MACHINE_WIDTH-1:0],
    input  logic                             rs1_read_en_i [MACHINE_WIDTH-1:0],
    input  logic                             rs2_read_en_i [MACHINE_WIDTH-1:0],
    input logic rs3_read_en_i [MACHINE_WIDTH-1:0],
    input  logic                             rd_write_en_i [MACHINE_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0] new_dst_preg_i [MACHINE_WIDTH-1:0],

    input  logic                             checkpoint_create_i [MACHINE_WIDTH-1:0],
    input  branch_tag_t                      checkpoint_create_tag_i [MACHINE_WIDTH-1:0],
    input  logic                             resolution_valid_i,
    input  logic                             resolution_mispredict_i,
    input  branch_tag_t                      resolution_tag_i,

    input  logic                             commit_valid_i [COMMIT_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] commit_rd_i [COMMIT_WIDTH-1:0],
    input  logic                             commit_rd_write_en_i [COMMIT_WIDTH-1:0],
    input  logic [PREG_IDX_WIDTH-1:0] commit_new_preg_i [COMMIT_WIDTH-1:0],

    output logic [PREG_IDX_WIDTH-1:0] src1_preg_o [MACHINE_WIDTH-1:0],
    output logic [PREG_IDX_WIDTH-1:0] src2_preg_o [MACHINE_WIDTH-1:0],
    output logic [PREG_IDX_WIDTH-1:0] src3_preg_o [MACHINE_WIDTH-1:0],
    output logic [PREG_IDX_WIDTH-1:0] old_dst_preg_o [MACHINE_WIDTH-1:0],
    output logic                             src1_from_older_lane_o [MACHINE_WIDTH-1:0],
    output logic                             src2_from_older_lane_o [MACHINE_WIDTH-1:0],
    output logic src3_from_older_lane_o [MACHINE_WIDTH-1:0]
);

    localparam int ARCH_IDX_WIDTH = $clog2(NUM_ARCH_REGS);
    // preg 字段宽度统一使用 o3_pkg::PREG_IDX_WIDTH（两域共用，o3_types_pkg::PREG_W）。

    logic [PREG_IDX_WIDTH-1:0] speculative_map_q [NUM_ARCH_REGS-1:0];
    logic [PREG_IDX_WIDTH-1:0] committed_map_q [NUM_ARCH_REGS-1:0];
    logic [PREG_IDX_WIDTH-1:0] checkpoint_map_q [NUM_CHECKPOINTS-1:0][NUM_ARCH_REGS-1:0];

    always_comb begin
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            src1_preg_o[lane] = '0;
            src2_preg_o[lane] = '0;
            src3_preg_o[lane] = '0;
            old_dst_preg_o[lane] = '0;
            src1_from_older_lane_o[lane] = 1'b0;
            src2_from_older_lane_o[lane] = 1'b0;
            src3_from_older_lane_o[lane] = 1'b0;

            if (lane_valid_i[lane] && rs1_read_en_i[lane] && (!HAS_ZERO_REG || rs1_addr_i[lane] != '0)) begin
                src1_preg_o[lane] = speculative_map_q[rs1_addr_i[lane]];
                for (int older = 0; older < lane; older++) begin
                    if (lane_valid_i[older] && rd_write_en_i[older]
                     && (!HAS_ZERO_REG || rd_addr_i[older] != '0) && (rd_addr_i[older] == rs1_addr_i[lane])) begin
                        src1_preg_o[lane] = new_dst_preg_i[older];
                        src1_from_older_lane_o[lane] = 1'b1;
                    end
                end
            end

            if (lane_valid_i[lane] && rs2_read_en_i[lane] && (!HAS_ZERO_REG || rs2_addr_i[lane] != '0)) begin
                src2_preg_o[lane] = speculative_map_q[rs2_addr_i[lane]];
                for (int older = 0; older < lane; older++) begin
                    if (lane_valid_i[older] && rd_write_en_i[older]
                     && (!HAS_ZERO_REG || rd_addr_i[older] != '0) && (rd_addr_i[older] == rs2_addr_i[lane])) begin
                        src2_preg_o[lane] = new_dst_preg_i[older];
                        src2_from_older_lane_o[lane] = 1'b1;
                    end
                end
            end

            if (lane_valid_i[lane] && rs3_read_en_i[lane] && (!HAS_ZERO_REG || rs3_addr_i[lane] != '0)) begin
                src3_preg_o[lane] = speculative_map_q[rs3_addr_i[lane]];
                for (int older = 0; older < lane; older++) begin
                    if (lane_valid_i[older] && rd_write_en_i[older]
                     && (!HAS_ZERO_REG || rd_addr_i[older] != '0) && (rd_addr_i[older] == rs3_addr_i[lane])) begin
                        src3_preg_o[lane] = new_dst_preg_i[older];
                        src3_from_older_lane_o[lane] = 1'b1;
                    end
                end
            end

            if (lane_valid_i[lane] && rd_write_en_i[lane] && (!HAS_ZERO_REG || rd_addr_i[lane] != '0)) begin
                old_dst_preg_o[lane] = speculative_map_q[rd_addr_i[lane]];
                for (int older = 0; older < lane; older++) begin
                    if (lane_valid_i[older] && rd_write_en_i[older]
                     && (!HAS_ZERO_REG || rd_addr_i[older] != '0) && (rd_addr_i[older] == rd_addr_i[lane])) begin
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
            for (int checkpoint = 0; checkpoint < NUM_CHECKPOINTS; checkpoint++) begin
                for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
                    checkpoint_map_q[checkpoint][arch] <= '0;
                end
            end
        end else begin
            // Committed map与推测恢复正交；只接受ROB顺序退休提供的新映射。
            for (int port = 0; port < COMMIT_WIDTH; port++) begin
                if (commit_valid_i[port] && commit_rd_write_en_i[port] && (!HAS_ZERO_REG || commit_rd_i[port] != '0)) begin
                    committed_map_q[commit_rd_i[port]] <= commit_new_preg_i[port];
                end
            end

            if (flush_all_i) begin
                // Include MRET/other actual retirement on this same boundary.
                for (int arch=0;arch<NUM_ARCH_REGS;arch++) begin
                    speculative_map_q[arch] <= committed_map_q[arch];
                    for (int lane=0;lane<COMMIT_WIDTH;lane++)
                        if (commit_valid_i[lane] && commit_rd_write_en_i[lane] && commit_rd_i[lane]==ARCH_IDX_WIDTH'(arch))
                            speculative_map_q[arch] <= commit_new_preg_i[lane];
                end
            end else if (resolution_valid_i && resolution_mispredict_i) begin
                for (int arch = 0; arch < NUM_ARCH_REGS; arch++) begin
                    speculative_map_q[arch] <= checkpoint_map_q[resolution_tag_i][arch];
                end
            end else if (rename_fire_i) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    if (lane_valid_i[lane] && rd_write_en_i[lane] && (!HAS_ZERO_REG || rd_addr_i[lane] != '0)) begin
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
                                 && (!HAS_ZERO_REG || rd_addr_i[older_or_self] != '0)) begin
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
