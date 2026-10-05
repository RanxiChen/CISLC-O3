# O3-T04：L6 M 扩展、完成 FIFO、提前唤醒、JALR

2026-10-06 用户直接授权实现，覆盖阶段一冻结和原全回归要求：机制先行、验证从简。
L5 按 T03 报告带已知问题退出；不在这里继续修 T03。

## 实现

- B43：65×65 有符号 `*` + `use_dsp=yes`，四个真实寄存边界，II=1（容量允许时）。
  完成 FIFO 再增加一个寄存边界；不是“组合算完再计数”。Vivado 是否使用 DSP 以本级 OOC 为准。
- B21：手工翻译 Flow `ee4a56ceefd49befc08741a59f714f6c37261010` 的
  `design/src/main/scala/divider/UnsignedRadix4Divider.scala`：MSB 对齐、每拍两步 restoring，最多 32 次。
  O3 包装自行实现除零、signed overflow、符号恢复和所有 W 变体。一个迭代请求，两个完成槽。
  未做 Chisel/eqy 对照；按本次用户要求，只跑典型/边界运算和接口定向验证。
- B33：完成容量覆盖流水在途和已完成项；接受时原子预留一项/两项，乘法首版容量 8。
  流水按条清 live，保留占用直到出口退还被取消项信用；FIFO 按条取消/压紧存活结果。
  仅对下一拍会成为可交付头部的结果提前唤醒；非头部不承诺，WB 背压期间头部持续 bypass。
  PRF 读数据加入 MUL/DIV 头部 bypass；结果出队边沿同时写 PRF，之后由 PRF 提供。
- B34：Decode Queue 可见前缀组合检测相邻 MULH/HU/HSU + MUL，不为尚未可见的成员等待。
  Rename 两个目的/ROB/RDQ 项成对接纳；RDQ 展示边界处 head 等整对可见。
  Dispatch 只把 head 放 INT IQ，携带成员独立 tag；一次乘积双结果入 FIFO，独立完成和退休。
- B13：共享 INT IQ，选择时分别检查 MUL 单/双信用与 DIV 空闲；各拍最多一条 MUL、DIV。
  PRF 读口仍按 ROB 年龄原子分配，M 不进入 ALU 管线。M 完成头参与已有整数年龄优先写回。
- JALR：原 BRU 的 rs1+imm、bit0 清零、链接 PC+长度和 one-shot 解析接入定向验证；
  补 x1/x5 的 push/pop/pop-push 提示，以及 L7 RVC 之前 IALIGN=32 的 target bit1 异常。
  异常禁止重定向/链接写回；和 LSU 共用 ROB 异常口，LSU 优先时 BRU 持有异常结果到下一拍。
  完整 RV64 非规范地址边界仍留后续地址机制。
- CSR misa / Spike ISA capability 从 RV64I 更新为 RV64IM；随机生成器不变。

跨模块合同：完成 FIFO 增加双入队/取消信用归还/独立单双容量口；renamed_uop 增加融合成员 tag；
IQ 增加 MUL/DIV 可用性及两路唤醒；WB extra 源增加独立完成输出；BRU result 增加精确目标异常。
Dxx/Bxx 机制选择未改；没有实现 WFI 等待、中断或 B38。

## 定向验证

入口：`sim/cocotb/mdu`（`DIV=0/1`）、`fu_completion_fifo`、`mul_fusion_detect`、`jalr`、`early_wakeup`。
整核短程序：`make -C sim/o3 run-l6-smoke`，自检 M 典型/边界值、依赖、取消和间接 call/return。
不扩展随机组合，不新增 Spike 随机门禁。Alan SHA、结果与耗时见下文。

## 首次 OOC

入口：`vivado -mode batch -source scripts/vivado/o3_ooc.tcl -tclargs <out>`，
`o3_core` / XCKU040-FFVA1156-2-E / 100 MHz / `synth_design -mode out_of_context -retiming`。
报告 elapsed、LUT/FF/BRAM/DSP 与综合后估计 WNS；综合结果不代替布局布线或板上测量。

## 首轮 Alan 结果

RTL `0cb022b2f4236ac715ca8f832602a49923a4b99e`，目录
`/home/chen/FUN/CISLC-O3-runs/20261006-l6-0cb022b/`：
FIFO、融合检测、JALR、MUL、DIV 定向测试各 1/1 PASS；lint 0 errors / 92 warnings；
整核 build PASS，L6 短程序 297 周期 / 71 条退休、tohost=1、Spike 0 差异；
原 smoke PASS。尚未运行完整回归、ACT4 RV64IM 或 CoreMark。早唤醒消费者时序与 OOC 随后追加。

## Vivado 首次工具适配

`aea910b` 的首轮 18 秒退出：`read_verilog -define` 需要 compile-unit 模式。
`c3806af` 的第二轮 24 秒退出：包通配导出的异常常量不可见。
`66be163` 的第三轮 23 秒退出：相同原因造成 XLEN 不可见。
`c1310b3` 的第四轮 21 秒退出：不支持对 DCache merge_store 函数返回值直接 part-select。
修正为 in-memory fileset 的 FPGA_TARGET 宏、ISA 符号显式导入、函数返回值命名后切片。
这些都是综合器可移植性修改，没有改变 T03 恢复逻辑或 Dxx/Bxx 机制。
最终综合/功能源码为 `67ec91c1c012be2eb0c44bce7eaf55d360d07059`；各失败轮次日志保留在
`/home/chen/FUN/CISLC-O3-runs/20261006-l6-ooc[-<sha>]/`。

## 最终功能证据

Alan `67ec91c1c012be2eb0c44bce7eaf55d360d07059`，Python 3.12.12 / cocotb 2.1.0 / Verilator 5.050。
`/home/chen/FUN/CISLC-O3-runs/20261006-l6-final-67ec91c/`：

- `make -C sim/o3 build VERILATOR='verilator -DFPGA_TARGET' BUILD_DIR=<out>/core-build`：exit 0，61 秒。
- `make -C sim/o3 run-l6-smoke BUILD_DIR=<out>/core-build RISCV_GCC=<Alan GCC>`：exit 0，
  297 周期退休 71 条，ICache refill 6，17 correct resolve / 7 mispredict，tohost=1，Spike 0 差异。
- 原有 `run-spike-all` 只顺手跑一次：11/11 PASS，0 差异；不是 ACT4/随机全回归。
- `scripts/lint.sh`：PASS（0 errors / 92 warnings）。本地默认和 FPGA_TARGET 解析也通过。

六项定向复验目录为 `/home/chen/FUN/CISLC-O3-runs/20261006-l6-directed-67ec91c/`，
逐项命令为 `make -C sim/cocotb/{fu_completion_fifo,mul_fusion_detect,jalr,early_wakeup}`，
以及 `make -C sim/cocotb/mdu DIV=0` 和 `DIV=1`；六项均 1/1 PASS，exit 0（合计 6/6）；`status.txt`、`sha.txt`、`tools.txt` 与各项 `.log` 已保留。
提前唤醒测试实际连接 INT IQ，覆盖 WB 背压下 PRF 写入前发射、错过原承诺的晚到消费者及出队到 PRF 的交接。
没有运行 ACT4 RV64IM、CoreMark、大量算术组合、200 种子随机回归或 Chisel/eqy 等价检查。
用户新策略覆盖了这些旧门禁要求，保留为后续工作，不宣称验证完备。

## 整核 OOC 实测：工具崩溃，PPA 未取得

Vivado 2022.2、上述 `67ec91c`，证据目录
`/home/chen/FUN/CISLC-O3-runs/20261006-l6-ooc-67ec91c/`。
墙钟 812 秒（13 分 32 秒），exit 139 / SIGSEGV，未生成 utilization、timing 或 DCP。
因此整核 LUT/FF/BRAM/DSP 和 WNS 均为 **未取得**，不能用日志推算成资源结果。
崩溃栈保留在 checkout 的 `hs_err_pid1882256.log`，位于 `librdi_synth.so` 的
`NRealMod::dfGraph / processParallelDFGOptPass1`。没有内存耗尽证据。
日志先提示 L1D tag 11,264 位、L2 data 524,288 位和 L2 tag 43,008 位三维 RAM
不受支持、很可能展开成寄存器。L2 data 对应 256 sets × 4 ways × 64 B；
这提示缓存 FPGA 映射是后续综合的主要检查点，但尚未定位工具崩溃根因。
未修改缓存机制、缩减容量或修 T03 恢复回路。

补充诊断入口：同一 Tcl 可传第二参数 `mul` / `div`，复用定向测试的标量端口包装，
保留完成 FIFO、取消/握手和唤醒逻辑，测局部资源/时序；它们不能代替整核 PPA。

## MUL/DIV 局部 OOC 结果与运行策略

Alan 源码 `c6acd37`（相对 `67ec91c` 的 RTL 修改仅为状态注释），同一 Vivado 2022.2、
XCKU040、10 ns 时钟、`-retiming`；包装顶层为 `mdu_tb_top`，以 `DIV_UNIT=0/1` 区分。
证据目录分别为 `/home/chen/FUN/CISLC-O3-runs/20261006-l6-ooc-mul-c6acd37/`
与 `/home/chen/FUN/CISLC-O3-runs/20261006-l6-ooc-div-c6acd37/`，两者 exit 0。

| 范围（含对应完成 FIFO） | 总墙钟 / 读入至 synth 完成 | CLB LUT | FF | BRAM tile | DSP | 综合估计 WNS |
| --- | --- | --- | --- | --- | --- | --- |
| MUL，8 完成槽、融合双结果 | 70 s / 43 s | 2,936 | 1,201 | 0 | 16 | +6.583 ns |
| DIV，2 完成槽 | 56 s / 31 s | 2,023 | 492 | 0 | 0 | +4.487 ns |

局部统计确认 B43 的乘法确实映射到 DSP。DCP、utilization、timing、DRC、SHA 和 exit/耗时
均已保留。WNS 只覆盖有时钟约束的内部寄存器路径；未设置端口 input/output delay，
没有布局布线、整核互连或板上测量，不能据此宣称整核 100 MHz 达标或推算板上 Fmax。

以当前数据，建议保持简单定向 cocotb，并在机制完成后增加局部 OOC：一次约一分钟，
能够及时发现 DSP 未推断、资源膨胀和内部长路径。整核首次 OOC 耗时 13 分 32 秒后崩溃，
暂不适合高频运行；先在后续 FPGA 映射工作中检查缓存 RAM 表达和综合器问题，再取得完整
资源/时序基线。Vivado 无法验证按条取消、握手和唤醒时序，当前轻量定向测试仍应保留。

本次 L6 机制与用户要求的简化功能验证已收口；首次整核 OOC 已执行并记录失败，
**整核资源/时序测量仍未完成**，以已知工具/映射问题保留，不宣称全部门禁通过。
没有为追求综合全绿扩展缓存改造或随机回归。
