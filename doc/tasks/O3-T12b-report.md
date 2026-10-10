# O3 T12b — 逐拍交接与双副本训练

源码 SHA `8533b28cb14845b034d475b2bb281d47729c1288`。实现 FTQ H0 信用预留、H1 快照身份校验并交接释放，深度 4 训练队列，T0 出队/同步读、T1 计算并写两个副本。TAGE/BTB 查询延迟及暂停保持不变，训练相邻同址转发和查询写新转发独立；SRAM 不复位数据，valid/base-written FF 保留复位语义。允许碰撞时仿真故意返回按位取反数据。部分清除剔除被取消槽的解析记录、taken CFI 和 mispred_mask；提交口径事件追加。

改 RTL 前保存旧 Python 算法为 `legacy_tage_reference.py`、`legacy_btb_reference.py`。新 cycle model 只改变训练延迟/写新查询的调度。连续 256 个 TAGE 同行包、128 个 BTB 同组包由测试适配器导出真实 RAM 行，与冻结参考逐位比较；没有把内部实现作为 golden。新增 FTQ 12 区域在 13 拍交接、无信用不丢包、部分清除及 SRAM poison 用例。

cloud_chen，cwd `/home/cloud_chen/work/l7c-t12b`，Verilator 5.050。模块证据 `/home/cloud_chen/evidence/o3-l7c/t12b/{unit3,extra}` 为提交前快照（提交另加局部变量默认赋值以消除 9 条 latch 警告），整核证据 `final-gate` 为上述 SHA。各目录含命令、日志、退出码。

- TAGE seeds 1/7/29 每次 4/4；BTB 原用例每次 2/2，加逐位同行用例 3/3；BPU 每次 5/5。
- FTQ 元数据 3/3；新增 FTQ 3/3；SRAM ALLOW_COLLISION=1 2/2。
- 最终 lint 0 errors、357 warnings；13 个整核目标全部 exit 0。predict A/B cycles 从 T12a 30915/30905 降至 24249/24239；L8a mem 96461 cycles、62786 retired、原参考提交前缀检查通过；priv 3821/437、VM 11544/6435；AMO 41291/7803、MMIO 3808/1245、misalign 12561/7048、DMA 13232/3347。

最终 T12d 门禁会在统一 SHA 重跑这些模块（含 seeds），这里不宣称 SoC 或 FPGA 物理时序闭合。

## 自行决定

- H0 保存完整 id 并预留训练信用，H1 接受时校验快照返回 id；下一项 H0 与当前 H1 可以重叠。信用预留不计为已入训练队列，释放发生在交接沿。涉及 `ftq.sv`、`history_snapshot_store.sv`、`bpu.sv`。
- 训练 RAM 与查询 RAM 同写，分别保留上一拍训练写回与当前查询碰撞的旁路；旁路有效/数据随 BRAM 读使能一同保持。base 未写标记及 tagged valid 存 FF，避免复位 RAM 数据破坏同步推断。涉及 `tage.sv`、`main_btb.sv`、`o3_sram_1r1w.sv`。
- 旧算法参考独立保存后只调整新 cycle model 的调度；额外适配器导出真实行值，连续包逐位比对。接口扩展、等待训练完成拍数和 Makefile 顶层过滤均按新流水调整，未修改旧训练的算法期望。
