/**
 * Rename 入口放行门 —— Decode→Rename 串行阻塞、WFI 停顿与 fatal 隔离（B22/B23/B24/B38/B39）
 *
 * 位置：Decode Queue 出口 → mul_fusion_detect → 本模块 → rename_dep_r1。纯组合截断加一个阻塞状态位。
 *
 * 负责：
 * - 串行阻塞（B22）：在可见有序前缀中找最老的 ext.block_younger=1 的 uop，只放行它及更老的连续
 *   前缀；它本身正常进入 Rename 并分配 ROB。放行后进入阻塞状态，直到该串行指令退休
 *   （serial_retire_i）或被取消（flush_i），期间不放行任何年轻指令；同组多条串行指令只放行到最老一条。
 *   不在多路 ROB 分配组合路径中增加截断判断。
 * - WFI（B38）：WFI 同样 block_younger；退休后 wfi_stall_i 有效期间继续不放行（暂停新指令推进，
 *   不关时钟）。
 * - fatal（B39）：isolate_i 有效后永久不放行，直到复位。
 * - 融合对（B34）：截断点不得落在 pair_head 与其成员之间；串行指令本身不参与融合。
 * - 观测（B22）：串行阻塞且确有年轻指令等待的每拍给出 block_younger_cycle_o。
 *
 * 不负责：串行指令在 ROB 队头的执行（commit_ctrl）；前端反压（Decode Queue 满时自然反压取指）。
 *
 * 当前实现状态：闭环简化（L5）：M/Bare 单 hart；后续级的中断/S/U/FP 接口显式 tie-off。
 *
 * 逐周期说明（目标）：
 * - 周期 N 组合：pass_count_o = 阻塞状态 ? 0 : 截断到最老串行 uop（含）为止的前缀长度。
 * - 周期 N 上升沿：下游接受了含串行 uop 的前缀时阻塞状态置 1；serial_retire_i 或 flush_i 清 0。
 * - 周期 N+1：阻塞状态生效，年轻指令留在 Decode Queue。
 *
 * 测试：sim/cocotb/rename_entry_gate/。
 */
module rename_entry_gate
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    localparam int WIDTH = CFG.rename.width
) (
    input  logic                       clk,
    input  logic                       rst,

    input  decoded_uop_t [WIDTH-1:0]   uop_i,
    input  logic [$clog2(WIDTH+1)-1:0] count_i,
    input  logic [WIDTH-1:0]           pair_head_i,     // 来自 mul_fusion_detect
    output logic [$clog2(WIDTH+1)-1:0] pass_count_o,
    input  logic [$clog2(WIDTH+1)-1:0] accepted_count_i, // 下游本拍实际接受数

    input  logic                       serial_retire_i,  // 阻塞所属串行指令退休
    input  logic                       flush_i,          // 该串行指令被取消（更老分支误预测/trap）
    input  logic                       wfi_stall_i,
    input  logic                       isolate_i,

    output logic                       block_younger_cycle_o
);
    logic blocked_q, isolate_q;
    always_comb begin
        logic stopped;
        stopped = blocked_q || isolate_q || isolate_i || wfi_stall_i || flush_i;
        pass_count_o = '0;
        for (int lane=0; lane<WIDTH; lane++) begin
            if (!stopped && lane<int'(count_i)) begin
                pass_count_o = pass_count_o + 1'b1;
                if (uop_i[lane].ext.block_younger) stopped = 1'b1;
            end
        end
        block_younger_cycle_o = blocked_q && count_i != '0;
    end
    always_ff @(posedge clk) begin
        if (rst) begin blocked_q <= 1'b0; isolate_q <= 1'b0; end
        else begin
            if (isolate_i) isolate_q <= 1'b1;
            if (flush_i || serial_retire_i) blocked_q <= 1'b0;
            else for (int lane=0; lane<WIDTH; lane++)
                if (lane<int'(accepted_count_i) && uop_i[lane].ext.block_younger)
                    blocked_q <= 1'b1;
            assert (accepted_count_i <= pass_count_o);
        end
    end
endmodule
