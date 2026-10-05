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
不扩展随机组合，不新增 Spike 随机门禁。Alan SHA、结果与耗时待实测追加。

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
