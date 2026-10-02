/**
 * MULH 类 + MUL 执行融合检测（B34，2026-10-02 用户确认的本项目方案）
 *
 * 位置：Decode Queue（uop_queue）出口之后、Rename R1（rename_dep_r1）之前，纯组合标记。
 * 这是本项目方案，不是 BOOM/香山已实现的双结果融合。
 *
 * 负责：
 * - 在当前可见的有序前缀中匹配程序顺序相邻的 MULH/MULHU/MULHSU（前） + MUL（后）。
 * - 配对条件：两条源寄存器顺序一致（前.rs1==后.rs1 且 前.rs2==后.rs2），前条 rdh 不得覆盖
 *   任一源寄存器（rdh!=rs1 且 rdh!=rs2），两条都没有异常。
 * - 可覆盖 buffer/本拍输入边界（配对的两条可以分别来自 Decode Queue 已有内容和本拍新进入的
 *   内容，只要它们都出现在本拍可见前缀里且相邻）；不任意向前搜索，不为未来可能出现的配对而
 *   强行等待：后条尚未可见时，前条按普通 MULH 放行。
 * - 单步、触发器、异常（任一条 exception_valid）等不能安全合并的情况不融合（no_fuse_i）。
 * - 输出标记：前条 ext.fuse_role=FUSE_HEAD，后条 ext.fuse_role=FUSE_MEMBER。
 * - pair_head_o[i]=1 表示 lane i 与 lane i+1 是一个融合对：下游 R1/R2 的接受前缀不得在
 *   i 与 i+1 之间截断（成对资源接纳必须完整：两个目的 preg、两个 ROB 项都拿到，否则两条都不
 *   接受，或不融合）。pair 恰好落在可接受前缀末端时，由 R2 选择“整对等待”或“去掉融合标记后
 *   只接受前条”，不能留下半个融合对。具体选哪一种待 R2 实现时确定。
 *
 * 不负责：
 * - 不改变两条指令的 rename：两个目的映射、两个 ROB 身份、两次架构退休全部保留。
 * - 不形成执行请求：融合后的唯一一次乘法请求由 IQ/发射侧为 FUSE_HEAD 生成，携带 mdu_fuse_t
 *   中的第二个结果归属；FUSE_MEMBER 不进 IQ、不读 PRF，由该请求的低位结果完成（不是 NOP）。
 *
 * 当前实现状态：空壳。只有端口与注释，没有逻辑，输出未驱动。
 *
 * 逐周期说明（目标）：本模块纯组合。
 * - 周期 N 组合：对 Decode Queue 展示的最老前缀给出带融合标记的 uop_o 与 pair_head_o。
 * - 周期 N 上升沿：R1/级间暂存接受前缀时，融合对必须整对被接受或整对留下。
 * - 周期 N+1：被留下的对在下一拍重新参与匹配，结果必须与上一拍一致（输入不变则输出不变）。
 *
 * 观测：BE_MUL_FUSED_PAIR（口径待定：建议按“融合对两条都实际退休”计数）。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module mul_fusion_detect
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int WIDTH = CFG.rename.width
) (
    input  decoded_uop_t [WIDTH-1:0]   uop_i,
    input  logic [$clog2(WIDTH+1)-1:0] count_i,
    input  logic                       no_fuse_i,      // 单步/触发器/debug 等全局禁止
    output decoded_uop_t [WIDTH-1:0]   uop_o,
    output logic [WIDTH-1:0]           pair_head_o
);
    // 未实现：相邻比较、源/目的条件、角色标记。
endmodule
