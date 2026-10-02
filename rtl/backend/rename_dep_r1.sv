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
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 * 现有 rename 仍由 rename_map_table 内部做组内旁路（旧路径）。
 *
 * 逐周期说明（目标）：本模块纯组合。
 * - 周期 N 组合：对 Decode Queue 展示的最老前缀计算依赖，送 rename_stage_buffer。
 * - 周期 N 上升沿：buffer 接受时 Decode Queue 移走对应指令，buffer 保存 uop 与依赖。
 *
 * 验证要点（B02 3.4，未执行）：RAW/WAW 链、同名多写、x0/无目的、0～6 条。
 *
 * 本阶段不写测试代码和仿真代码。
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
    // 未实现：按域比较的优先编码。
endmodule
