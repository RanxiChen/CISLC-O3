/**
 * Frontend Top Placeholder
 *
 * 当前已经实现：
 * - 删除旧的本地 SRAM 单条顺序取指实现。
 * - 保留 `frontend` 模块名作为后续前端顶层重写入口。
 *
 * 当前没有实现：
 * - 暂未实例化 FTQ、IFU、ICache。
 * - 暂未向 backend 输出 fetch group。
 * - 暂未接入 refill、flush、redirect、异常恢复或分支预测。
 *
 * 后续扩展入口：
 * - 在本模块内实例化 `ftq`、`ifu`、`ICache`。
 * - 连接 FTQ -> IFU -> ICache -> IFU Fetch Buffer 的取指链路。
 * - 将 IFU 的 fetch buffer 出队接口收敛成 backend 可消费的 fetch group 接口。
 *
 * 当前阶段说明：
 * - 当前文件只是占位顶层，不写测试代码，不写仿真代码。
 *
 * 逐周期说明：
 * - 当前没有状态寄存器、队列、表项存储或 ready/valid 握手。
 * - 周期 N 组合阶段：所有占位输出保持 0。
 * - 周期 N 上升沿：不更新任何状态。
 * - 周期 N+1：输出仍保持 0。
 */
module frontend
    import o3_pkg::*;
(
    input  logic clk_i,
    input  logic rst_i,

    output fetch_entry_t fetch_entry_o [4],
    output logic [3:0]   fetch_valid_mask_o,
    input  logic         fetch_ready_i
);

    always_comb begin
        for (int i = 0; i < 4; i++) begin
            fetch_entry_o[i] = '0;
        end

        fetch_valid_mask_o = 4'b0;
    end

    // 当前占位模块不使用输入信号；后续接入 FTQ/IFU/ICache 时会消费这些信号。
    logic unused_inputs;
    assign unused_inputs = clk_i ^ rst_i ^ fetch_ready_i;

endmodule
