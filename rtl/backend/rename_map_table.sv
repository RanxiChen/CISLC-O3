/**
 * Rename Map Table
 *
 * 当前已经实现的功能：
 * - 维护架构寄存器到当前物理寄存器的映射
 * - reset 后默认建立：
 *   x1 ~ x31 -> p0 ~ p30
 * - x0 固定视为常量零寄存器：
 *   1) 组合读取时始终返回物理寄存器 p0
 *   2) 时序更新时不会写入 map table
 * - 支持按 MACHINE_WIDTH 并行读取 rs1 / rs2 / rd 的当前映射
 * - 支持在 rename_fire 时，用 free list 分配的新物理寄存器更新 rd 的当前映射
 * - 额外输出 old_dst_preg，作为后续接入 commit / 释放旧物理寄存器时的扩展预留
 *
 * 当前没有实现的功能：
 * - 不处理同拍 lane 之间的组内依赖
 * - 不处理同拍 lane 之间对同一个 rd 的覆盖优先级
 * - 不维护 commit map / speculative map 的双份结构
 * - 不支持 checkpoint / rollback / flush
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 根据 rs1 / rs2 / rd 直接读取当前映射表
 *   2) 输出 src1_preg / src2_preg / old_dst_preg
 *   3) backend 同拍还会拿到 free list 给出的 new_dst_preg
 * - 周期 N 上升沿：
 *   1) 若 rename_fire=1
 *   2) 且 rd_write_en=1
 *   3) 且 rd!=0
 *   则把 map_table[rd] 更新为 new_dst_preg
 * - 周期 N+1 组合阶段：
 *   重新读取同一个 rd 时，可以看到更新后的新物理寄存器编号
 */

module rename_map_table #(
    parameter int MACHINE_WIDTH = 4,
    parameter int NUM_ARCH_REGS = 32,
    parameter int NUM_PHYS_REGS = 64
) (
    input  logic clk,
    input  logic rst,

    input  logic                             rename_fire_i,
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rs1_addr_i     [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rs2_addr_i     [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_ARCH_REGS)-1:0] rd_addr_i      [MACHINE_WIDTH-1:0],
    input  logic                             rs1_read_en_i  [MACHINE_WIDTH-1:0],
    input  logic                             rs2_read_en_i  [MACHINE_WIDTH-1:0],
    input  logic                             rd_write_en_i  [MACHINE_WIDTH-1:0],
    input  logic [$clog2(NUM_PHYS_REGS)-1:0] new_dst_preg_i [MACHINE_WIDTH-1:0],

    output logic [$clog2(NUM_PHYS_REGS)-1:0] src1_preg_o    [MACHINE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS)-1:0] src2_preg_o    [MACHINE_WIDTH-1:0],
    output logic [$clog2(NUM_PHYS_REGS)-1:0] old_dst_preg_o [MACHINE_WIDTH-1:0]
);

    localparam int ARCH_IDX_WIDTH = $clog2(NUM_ARCH_REGS);
    localparam int PREG_IDX_WIDTH = $clog2(NUM_PHYS_REGS);

    logic [PREG_IDX_WIDTH-1:0] map_table_q [NUM_ARCH_REGS-1:0];

    always_comb begin
        for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
            src1_preg_o[lane]    = '0;
            src2_preg_o[lane]    = '0;
            old_dst_preg_o[lane] = '0;

            if (rs1_read_en_i[lane]) begin
                if (rs1_addr_i[lane] == ARCH_IDX_WIDTH'(0)) begin
                    src1_preg_o[lane] = '0;
                end else begin
                    src1_preg_o[lane] = map_table_q[rs1_addr_i[lane]];
                end
            end

            if (rs2_read_en_i[lane]) begin
                if (rs2_addr_i[lane] == ARCH_IDX_WIDTH'(0)) begin
                    src2_preg_o[lane] = '0;
                end else begin
                    src2_preg_o[lane] = map_table_q[rs2_addr_i[lane]];
                end
            end

            if (rd_write_en_i[lane] && (rd_addr_i[lane] != ARCH_IDX_WIDTH'(0))) begin
                old_dst_preg_o[lane] = map_table_q[rd_addr_i[lane]];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            map_table_q[0] <= '0;
            for (int arch = 1; arch < NUM_ARCH_REGS; arch++) begin
                map_table_q[arch] <= PREG_IDX_WIDTH'(arch - 1);
            end
        end else if (rename_fire_i) begin
            // 当前版本按 lane 顺序独立写表，但不处理组内覆盖。
            // 如果同拍多个 lane 写同一个 rd，最终结果取决于 for 循环最后一次赋值。
            // 这正是当前阶段“组内关系暂不处理”的明确限制之一。
            for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                if (rd_write_en_i[lane] && (rd_addr_i[lane] != ARCH_IDX_WIDTH'(0))) begin
                    map_table_q[rd_addr_i[lane]] <= new_dst_preg_i[lane];
                end
            end
        end
    end

    initial begin
        if (NUM_ARCH_REGS < 2) begin
            $error("rename_map_table requires NUM_ARCH_REGS >= 2");
        end
    end

endmodule
