/**
 * IFU F0 —— 长度识别、跨块拼接、RVC 展开
 *
 * 作用：
 * - 消费返回队列出队的 16B 原始块，按 FTQ 最终预测的有效范围（入口槽位到选中出口）
 *   识别每条指令起始与长度，RVC 展开为规范 32 位指令。
 * - 区域末尾开始的 32 位指令跨块时，保存前半字，等待顺序地址的下一块后半字再拼接。
 * - 保留原 PC、原始长度、归属 FTQ 身份与起始槽位（第 3.3、10 节）。
 *
 * 目标机制：
 * - 已定：32 位指令的后半字不能被当作独立指令或分支槽位（第 3.1 节）。
 * - 已定：跨块只拼接顺序地址的后半字；即使该指令预测会跳转，也不能用预测目标处的
 *   数据代替（第 3.3 节）。
 * - 已定：选中跳转之后的槽位不属于本次动态路径。
 * - 已定（D25）：FENCE.I 等同步时清除残留半字；kill_i 按 D24 边界清除。
 * - 正常跨块拼接由本级保存前半字并消费下一顺序块完成，不是待发明机制（第 13 节）。
 *
 * 细节待定：
 * - 每拍最多处理槽位数 F0_SLOTS；超过下游宽度时的保存方式（第 10 节）。
 * - 跨块补半字的辅助请求（预测出口在本块，但后半字需要顺序下一块）如何占用
 *   返回队列和 FTQ 资源、与普通顺序请求合并的规则（第 3.3 节）。
 * - 后半字取指异常如何携带原指令 PC 与故障地址（第 3.3 节）。
 * - 非法 RVC 编码的异常 tval 内容。
 *
 * 当前实现状态：空壳。只有端口与注释，没有任何逻辑，输出未驱动。
 *
 * 目标周期行为：
 * - 周期 N 组合：in_valid_i 时识别本块指令，生成 out_*；跨块时不输出该指令。
 * - 周期 N 上升沿：out 握手后接受下一块；保存跨块前半字。
 * - 周期 N+1：F1 看到 F0 输出寄存（寄存边界待定）。
 *
 * 本阶段不写测试代码和仿真代码。
 */
module ifu_f0
    import o3_types_pkg::*;
#(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
) (
    input  logic            clk_i,
    input  logic            rst_i,

    input  logic            in_valid_i,
    output logic            in_ready_o,
    input  rq_out_t         in_i,
    input  ftq_pred_brief_t in_brief_i,

    output logic [F0_SLOTS-1:0] out_valid_o,
    input  logic            out_ready_i,
    output f0_inst_t        out_o [F0_SLOTS],
    output ftq_pred_brief_t out_brief_o,

    input  fe_kill_t        kill_i,
    input  logic            sync_clear_i,   // D25：清除残留半字

    output fe_perf_t        perf_o
);
    // 未实现：长度识别、RVC 展开、跨块半字保存与拼接。
endmodule
