# O3 T12a — 多项返回队列

源码 SHA：`a7d395bbd7a9d3189c69bb3575506dc7f994a037`；分支 `feat/l7c-frontend`。

实现 8 槽 FREE/PEND/READY/ZOMBIE 池及紧凑顺序队列；完整 FTQ id 检查，选择性清除后未返回槽转僵尸，新路径不被僵尸队头阻塞。保留握手前锁存的 RQ 槽，响应、清除、出队同拍优先顺序及采样断言。补全 RQ/交付事件的独立整核聚合核对。

吞吐增加暴露两处原有进展问题并修复：FTQ 整环已发完后释放旧 head 不得推进 demand 游标，否则新分配项被跳过；ICache 单槽重试在 S1/S2/S3 均受阻时死锁，改为四槽重试 FIFO（外部请求在重试期间暂停）。FTQ 回绕用例先在旧实现失败后通过。MMIO 暴露正确分支解析与独立陷阱同拍的断言误判；进展断言现在仅排除实际全局清除/系统重定向，分支 mask 与分配检查保持。

执行主机 `cloud_chen@47.96.71.231`；每次执行读取共享 simulation-host 配置并 SSH/环境校验。cwd `/home/cloud_chen/work/l7c-t12a-final`，Verilator 5.050，证据 `/home/cloud_chen/evidence/o3-l7c/t12a-final/verified/{run.sh,run.log,status.txt}`，exit 0。

- `bash scripts/lint.sh`：0 errors、357 warnings。
- RQ seed 1/7/29：每次 3/3；FTQ 回绕 1/1。
- ICache 改动的 seed 1/7/29：每次 4/4，补充证据 `t12a-live/gate`（WIP）。最终后续统一 SHA 再回归。
- `make -C sim/o3 build`；`make -j1 -C sim/o3 run-smoke run-dcache-data run-dcache-replay run-l3-branch-dense run-l7-predict run-l8a-mem run-l9-fp run-l10-priv run-l10-vm run-l8b-amo run-l8b-mmio run-l8b-misalign run-l8b-dma` 全部通过。

| 程序 | cycles | retired |
|---|---:|---:|
| smoke |545|4|
| dcache-data |585|7|
| dcache-replay |604|6|
| branch-dense |1717|365|
| predict A/B |30915 / 30905|19396 / 19444|
| L8a mem |100160|62786|
| FP |1611|615|
| privilege |3821|437|
| VM |11544|6435|
| AMO |41291|7803|
| MMIO |3816|1245|
| misalign |12561|7048|
| DMA |11686|3347|

以上是指定整核定向回归，无 Spike/ACT4、无 SoC/FPGA/布线时序闭合声明。性能按程序采样范围解释；不同运行路径的循环末端计数不作为逐条同轨迹比较。

## 自行决定

- 槽池与排序分离：槽状态保留未完成请求的身份，顺序数组只存活路径；由此满足僵尸占容量但不挡队头。涉及 `fetch_return_queue.sv`、`frontend.sv`。
- 多笔请求暴露 FTQ 环游标和 ICache 重试进展问题，分别增加回绕定向检查、四槽重试 FIFO；修复机制后保留原架构断言与 golden。涉及 `ftq.sv`、`icache.sv` 与单模块用例。
- 正确分支进展断言与同拍独立系统清除冲突，仅对真实全局清除/系统重定向增加条件，其他分支 mask/分配断言保持。涉及 `backend.sv`。
