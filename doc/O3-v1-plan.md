# CISLC-O3 v1 实施计划

2026-10-05 用户确认。本文规定 v1 的目标、实施方式、闭环顺序和组件来源。微架构决策仍以 [`design/`](design/) 为准（本轮新增 B42～B47，见后端基线第 36 节），实现进度以 [`LOOP.md`](LOOP.md) 为准，工作规则以 [`agent.md`](../agent.md) 为准。

## 1. 目标

在 KCU105 上实现一颗**有规模的单 hart RV64GC 乱序核**，运行 OpenSBI + Linux，带 SD 卡和 FASE 调试。

- 机器宽度统一为 4：解码、重命名、派发、提交均为 4（B42，取代 B01 的六宽重命名）。
- 其余已定机制不削减：TAGE/uBTB/BTB/RAS 预测与恢复、非阻塞多 MSHR 访存与重放、A 扩展、F/D 与浮点重命名、Sv39 MMU、精确异常、L2 inclusive、SD DMA 协调、性能计数。
- 自建 SoC（B28），不使用 LiteX；与 Breeze 不共用 SoC。

## 2. 实施方式

### 2.1 不再并行搭框架

失控的主要原因是 2026-10-02 在旧数据流旁边并行搭了一整套“目标结构”空壳：每个模块都存在，但没有一个机制从头到尾接通。v1 起：

- **在旧数据流上逐级替换和加强。**目标结构到它所属的闭环级才接入；接入方式是替换旧数据流中对应的部分，替换完成后删除被替换的旧代码和空壳（B46）。
- 不在当前级的空壳从 `backend.sv` 中移除实例化，文件保留在 `rtl/` 中但不列入 `rtl/rtl.f`，到所属级时再加入。
- 每一级是一条可在 Alan 上用一条命令验收的端到端功能，见第 3 节。

### 2.2 参考模型逐条比对

从 L5 起，每一级的验收都必须包含**与 Spike 逐条退休比对**：PC、指令、整数/浮点写回值、访存地址与数据、异常 cause/tval、CSR 写入，差异为 0（B45）。乱序核的错误大多出现在分支恢复、重放、异常与访存排序的交织中，只有逐条比对能在随机程序下可靠地发现它们，也是防止实现 agent 幻觉的主要手段。

> 2026-10-06 起暂停：L6 之后不再运行 Spike 比对（含现有回归），推迟到 FPGA 阶段，见第 3 节“验收调整”。

### 2.3 任务流程

每一级拆成若干任务，沿用 `agent.md` 第 7 节的任务书格式，并采用两阶段流程：

1. **阶段一**：实现 agent 写该级的 RTL spec（接口字段、状态机、同拍优先级、断言）和测试计划，不写 RTL；审阅后由用户冻结。
2. **阶段二**：按冻结的 spec 实现，交回 Alan 上的提交号、命令与日志。

规则：不得自行补设计、不得为通过而修改测试或断言、spec 未覆盖的行为先提问。

### 2.4 面积与时序检查点

4 宽 RV64GC 乱序核加 FASE 在 XCKU040（约 242k LUT）上的面积没有可靠的事先估计。参照：Breeze 顺序单核约 34k LUT（其中 FPU 11k、旧乘法器 6.8k）。

**2026-10-06 用户决定：完整 SoC（L11）前不再运行综合。** L6 首次整核 OOC（O3-T04）失败，O3-T04b 定位到 L1D/L2 tag 组合判定与同步 BRAM 的接口时序冲突及 DTCM 映射硬错误（见 `tasks/O3-T04b-report.md`）；这些问题留到完整访存级处理。L6～L10 各级不设 OOC 门禁；首次综合基线在 SoC 集成时取得，届时若面积/时序放不下，再依据数据调整容量参数（不是删除机制）。

## 3. 闭环阶梯

L0～L4 及 L3 的已有证据见 `LOOP.md`。v1 从 L3 收尾开始。

**2026-10-06 顺序调整：先跳过访存。** L6 之后按 L7 → L9 → L10 → L8 → L11 推进。L8 之前访存只要求现有基础实现（L3 闭环的 L1D/L2/DTCM/LSU）能用，不做完整非阻塞访存、BRAM 化或 T04b 所列改造；L9/L10 中需要访存的部分（FLD/FSD、PTW 访存、A/D 更新）接在现有 LSU 上，只做到功能可用。表中级号保持不变，以便沿用既有决策与任务引用。

**2026-10-06 验收调整：完整一致性测试推迟到 FPGA。** L7～L10 表中“验收”列的 ACT4（RV64IMC/RV64GC）、特权测试、riscv-tests p/v、litmus、随机程序及新增 Spike 比对不再作为级门禁，统一推迟到 L11 后在 FPGA 上运行（bootrom 测试程序 + ILA 调试）。现有 Spike 逐条比对与 ACT4 回归也不再运行。各级只要求：手写的本级机制简单定向 testbench 通过；未通过项记为已知问题后继续推进。`sim/cocotb/` 中已有的非访存模块 testbench 可在改动对应模块时顺带运行；访存类（`dcache`、`l2_cache`、`load_queue`、`store_queue`、`load_store_unit`、`load_store_unit_l5`）在 L8 前不运行。

| 级 | 内容 | 主要决策 | 验收 |
| --- | --- | --- | --- |
| L3 收尾 | 完成当前访存闭环；修 B12 缺口 1（任何分支解析都全局停顿）与缺口 2（ALU RegRead 背压时缺 kill）；重命名改为 4 宽；移除当前级不需要的空壳实例 | B12、B42、B46 | 现有 L2/L3 门禁 + 分支密集程序；缺口 2 的定向复现测试 |
| L5 | 接入 Spike 逐条比对；M 模式 CSR、精确异常、ecall/ebreak/illegal、MRET、committed_next_pc | B22、B26、B27、B37、B45 | ACT4 RV64I 全部通过；Spike 比对 0 差异 |
| L6 | M 扩展（MUL 采用 DSP，DIV 沿用 Breeze radix-4，手工翻译）；完成 FIFO 与提前唤醒；JALR | B13、B33、B34、B43 | ACT4 RV64IM；仿真跑 CoreMark（原定首次 OOC 综合已推迟到 L11，见 2.4） |
| L7 | （2026-10-06 拆为 L7a 预测器接入 + B48 计数器；L7b RVC、D33～D35）完整预测：uBTB/BTB/TAGE、FTQ 恢复、RAS 快速修复；RVC（手工翻译 Breeze 解压器） | D01～D24、D29～D35、B30、B48 | M 模式 Zihpm 计数器与前端预测事件（B48）；RV64IMC；误预测率与 IPC 基线；Spike 比对 |
| L8 | 完整非阻塞访存：多 MSHR、重放、同 line 非对齐、A 扩展、FENCE/FENCE.I | B03～B05、B09、B23、B31、B32、B35 | RV64IMAC；litmus；死锁 watchdog；随机访存程序 |
| L9 | F/D：拆分 CVFPU、FP 重命名、fflags/FS 退休 | B14、B15、B40 | ACT4 RV64GC（用户态） |
| L10 | S/U 模式、Sv39 MMU（翻译 Breeze MMU 的 TLB/PTW/walk cache，LSU 侧接口按 O3 重新设计）、SFENCE.VMA、satp、PMP、A/D 更新、WFI；计数器 S/U 访问与 Sscofpmf 溢出中断（B48） | B06、B07、B24、B36、B38、D25～D28 | 特权测试；riscv-tests p/v 变体 |
| L11 | SoC：L2 + DDR4（Vivado MIG）+ CLINT/PLIC + UART + SD（AXI Quad SPI）+ SD DMA 协调 + FASE；fatal 隔离；OpenSBI PMU 与 Linux perf（B48） | B08、B28、B29、B39、B41、B44 | 仿真中启动 OpenSBI + Linux；上板启动 Linux，镜像经 SD 卡加载 |

每一级都可以拆成多个任务；级内的局部 cocotb 测试规则见 `agent.md` 第 2 节。

## 4. 从 Breeze 复用的组件

Breeze 仓库：`/home/chen/leisure/flow`。

| 组件 | 来源 | 方式 | 所属级 |
| --- | --- | --- | --- |
| MUL 数据通路 | Breeze T01 完成后的 DSP 实现 | 手工翻译；O3 自写包装（ROB 身份、按条取消、完成 FIFO） | L6 |
| DIV 数据通路 | `design/src/main/scala/divider/` | 手工翻译；含除零/溢出快速路径与符号恢复 | L6 |
| RVC 解压 | `design/src/main/scala/frontend/BreezeCompressedDecoder.scala` | 手工翻译 | L7 |
| AMO 运算 | `design/src/main/scala/cache/` 中的 AMO ALU | 手工翻译 | L8 |
| CVFPU | `third_party/cvfpu`（已是 SV，含 100 MHz 切分） | 直接复用，按 B14 拆分 | L9 |
| Sv39 MMU | `docs/breeze-mmu-rtl-spec.md` 与 `design/src/main/scala/mmu/sv39/` | 手工翻译 TLB 阵列、PTW、walk cache；LSU 侧接口按 B04/B06 重做 | L10 |
| CSRFile 语义 | `design/src/main/scala/core/RegFile.scala` | 按语义重写，B29 | L5 起逐步 |
| PLIC / CLINT | `litex_wrapper/flow/rtl/FlowPlic.sv`、`FlowClint.sv` | 直接复用，换 AXI-Lite 包装并重查地址与访问宽度 | L11 |
| FASE | `design/src/main/scala/fase/`、`litex_wrapper/flow/rtl/FlowFaseJtag.sv` | 手工翻译，改接 O3 的退休与调试接口 | L11 |

**翻译的对照验证**（B47）：以同一提交的 Chisel 生成 Verilog 为参照，寄存器结构一致的模块用 Yosys `eqy` 做形式化等价检查；结构不一致的用 Verilator 并排运行两份 RTL、随机激励逐拍比较输出。参照 Verilog 只用于验证，不进入 O3 的 `rtl/`。

## 5. 不在 v1

多核、V 扩展（在 Breeze 上另做）、值预测、Sstc、Debug Mode、L2 预取以外的新预测机制。
