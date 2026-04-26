/**
  模块职责：
  - 当前作为 frontend 的最小骨架，从本地指令 SRAM 顺序读取 32 位指令。
  - 通过最简单的 ready/valid 接口向后级输出“当前 PC 对应的指令地址 + 指令内容”。
  - 当前只提供顺序取指能力，用于后续 frontend 功能搭建时保留一个稳定的顶层入口。

  当前已经实现：
  - 8 位顺序 PC，最多顺序访问 256 条 32 位指令。
  - `inst_valid_o` 固定拉高，后级在 `inst_ready_i=1` 时消费当前指令并驱动 PC 前进。
  - 指令内容由 `o3_sram` 按 `pc_q` 读出，指令地址直接由当前 `pc_q` 扩展得到。

  当前没有实现：
  - 不支持分支预测、重定向、flush、异常重启、停顿恢复和多条并行取指。
  - 不支持真实 icache、TLB、跨页取指、对齐检查和访存异常。
  - 不支持和 backend 的成组 fetch 接口对接，当前仍是单条顺序输出骨架。

  后续扩展入口：
  - 可在 `pc_q` 前增加 next-pc 选择、redirect 优先级和预测状态。
  - 可把当前单条 ready/valid 扩展成 fetch group 输出，并在这里接入 BTB/BHT/RAS/icache。

  当前阶段说明：
  - 当前阶段只搭功能骨架，不写测试代码，不写仿真代码。

  逐周期时序说明：
  - 周期 N 组合阶段：
    - `inst_o` 反映 `pc_q` 指向的 SRAM 读出指令。
    - `inst_addr_o` 反映当前 `pc_q` 对应的取指地址。
    - `inst_valid_o` 固定为 1，`inst_fire` 由 `inst_ready_i` 决定是否成交。
  - 周期 N 上升沿：
    - 若 `rst_i=1`，`pc_q` 清零。
    - 若 `rst_i=0` 且 `inst_fire=1`，`pc_q` 自增 1，准备下一条顺序指令。
  - 周期 N+1：
    - 可看到新的 `pc_q`、对应的新 `inst_addr_o` 和下一条 `inst_o`。
*/
module frontend(
    input logic clk_i,
    input logic rst_i,
    // 当前保留最小的单条取指 ready/valid 接口，后续再收敛成统一 fetch bundle
    output logic [38:0] inst_addr_o,
    output logic [31:0] inst_o,
    output logic inst_valid_o,
    input logic inst_ready_i
);
logic [7:0] pc_q;
logic       inst_fire;

o3_sram #(
    .DATA_WIDTH(32),
    .SRAM_ENTRIES(256),
    .INIT_FILE("inst.hex")
) inst_sram (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .we_i(1'b0),
    .data_o(inst_o),
    .data_i('0),
    .addr_i(pc_q)
);

assign inst_fire = inst_valid_o && inst_ready_i;
assign inst_valid_o = 1'b1;
assign inst_addr_o  = {31'b0, pc_q};

always_ff @(posedge clk_i) begin : seq_pc
    if (rst_i) begin
        pc_q <= '0;
    end else if (inst_fire) begin
        // 当前只实现最简单的顺序取指；redirect/flush 以后再接入。
        pc_q <= pc_q + 1'b1;
    end
end

endmodule
