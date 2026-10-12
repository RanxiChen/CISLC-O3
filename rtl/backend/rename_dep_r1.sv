/**
 * Rename R1 —— 组内依赖预处理（B02 第一拍）
 *
 * 作用（已定，B02 3.1）：
 * - 对最多 RENAME_W 条有序指令，用架构寄存器编号查找：rs1、rs2、rs3 的最近更老写入者，
 *   以及 rd 的最近更老同名写入者。前三项用于 RAW 源旁路，后一项用于 WAW 下生成正确的
 *   old_dst_preg。
 * - 比较区分寄存器域（INT/FP），排除无效 lane、无目的写入、整数域 rd=x0；源比较按读使能。
 * - 不读 RAT，不消耗 preg/ROB/LQ/SQ/checkpoint，不修改任何推测状态。
 *
 * 不负责：资源检查、物理编号选择、RAT 更新（全部属于 R2 原子事务）。
 *
 * 例（B02 3.2）：I0 写 x5，I1 读 x5 写 x6。R1 只记录 I1.src1 依赖槽 0；R2 分配 p32/p33 后
 * 让 I1 源选 p32，而不是 RAT 中 x5 的旧映射。
 *
 * 当前实现状态：目标实现。四宽纯组合依赖预处理，接入实际 R1/R2 路径。
 *
 * 逐周期说明（目标）：本模块纯组合。
 * - 周期 N 组合：对 Decode Queue 展示的最老前缀计算依赖，送 rename_stage_buffer。
 * - 周期 N 上升沿：buffer 接受时 Decode Queue 移走对应指令，buffer 保存 uop 与依赖。
 *
 * 验证待后端重构后统一进行：RAW/WAW 链、同名多写、INT/FP、src3、x0/f0。
 */
module rename_dep_r1
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int WIDTH = CFG.rename.width
) (
    input  decoded_uop_t [WIDTH-1:0]            uop_i,
    input  logic [$clog2(WIDTH+1)-1:0]          count_i,
    output o3_types_pkg::r1_lane_dep_t          dep_o [WIDTH-1:0]
);
    always_comb begin
        for (int lane = 0; lane < WIDTH; lane++) begin
            dep_o[lane] = '0;
            if (lane < int'(count_i) && uop_i[lane].valid) begin
                // Ascending scan: the nearest older writer wins for each operand.
                for (int older = 0; older < lane; older++) begin
                    if (older < int'(count_i) && uop_i[older].valid
                        && uop_i[older].rd_write_en
                        && (uop_i[older].ext.rd_dom == o3_types_pkg::RD_FP
                            || uop_i[older].rd != '0)) begin
                        if (uop_i[lane].rs1_read_en
                            && uop_i[lane].ext.rs1_dom == uop_i[older].ext.rd_dom
                            && uop_i[lane].rs1 == uop_i[older].rd)
                            dep_o[lane].src1 = '{valid:1'b1, slot:o3_types_pkg::RENAME_SLOT_W'(older)};
                        if (uop_i[lane].rs2_read_en
                            && uop_i[lane].ext.rs2_dom == uop_i[older].ext.rd_dom
                            && uop_i[lane].rs2 == uop_i[older].rd)
                            dep_o[lane].src2 = '{valid:1'b1, slot:o3_types_pkg::RENAME_SLOT_W'(older)};
                        if (uop_i[lane].ext.rs3_read_en
                            && uop_i[lane].ext.rs3_dom == uop_i[older].ext.rd_dom
                            && uop_i[lane].ext.rs3 == uop_i[older].rd)
                            dep_o[lane].src3 = '{valid:1'b1, slot:o3_types_pkg::RENAME_SLOT_W'(older)};
                        if (uop_i[lane].rd_write_en
                            && uop_i[lane].ext.rd_dom == uop_i[older].ext.rd_dom
                            && uop_i[lane].rd == uop_i[older].rd)
                            dep_o[lane].rd_prev = '{valid:1'b1, slot:o3_types_pkg::RENAME_SLOT_W'(older)};
                    end
                end
            end
        end
    end
endmodule
