# 前端结构重构与独立综合

本轮按用户批准的顺序，先改 F0 逻辑结构，不增加 F0→F1 流水级；同时切断 ICache S3 到入口 ready 的组合背压，增加预测摘要快照和预取请求寄存器。没有修改 BPU 快预测反馈环，也没有运行整核仿真、布局布线或 FPGA 验证。

## 源码与测量边界

- 基线：`f0f6b7b088b8dd44d00cead590f0995291314cfc`，已经包含上一轮 FTQ 存储/环形控制重构；不是最早的原版前端。
- 重构 RTL：`551dc65`；针对性最终检查版本：`63890ea1022db83a1ef2353142eca93145bdf65b`。两者的 `rtl/` 与 `scripts/vivado/` 完全相同，后一提交只增加检查脚本及测试。
- Vivado 2022.2，Alan，`xcku040-ffva1156-2-e`，100 MHz（10 ns），`FPGA_TARGET`，默认 `O3_CFG.fe`，不启用 retiming。
- `frontend_ooc_wrapper` 保留完整前端的公开输入输出。依赖从权威 `rtl/rtl.f` 筛选 common/frontend，不包含后端和 L2 实例；保留前端到 PTW、L2 和后端的接口。
- 两轮使用相同 wrapper、Tcl 和约束。输入/输出延迟均为 0 ns，无 false-path/multicycle 例外；这是一致的 OOC 比较边界，不代表真实 SoC 的接口时序预算。
- 综合时序包含未放置布线的网络延迟估计，不能作为 routed timing 或频率闭合证据。

## 结构变化

### F0 与 F1

F0 用 8 个固定半字位置并行判断长度、展开 RVC。窄的起点标记网络描述哪些半字是指令起点，前缀计数选择第 k 条指令；展开后的数据使用 one-hot AND/OR 选择，不再逐 lane 串联动态半字选择、长度判断和位置加法。跨区域半条指令、入口槽、异常、预测出口、保留区域和 trunc 语义保留。F1 每个 lane 独立解码控制流与直接目标，顺序扫描仅选择首个修正及存活前缀。

F0/F1 之间仍无新数据寄存级；F1 的 trunc 到 F0 下一状态寄存器的路径，以及 fetch buffer 到 F1/F0 的 ready 传递仍存在。先测量本轮结构变化，再判断是否需要进一步增加恢复延迟。

### 数据与预测摘要快照

预测摘要合并后，在返回队列出口与区域数据、FTQ ID 一起寄存。输出未消费时，原队头槽仍归返回队列所有。缓存当前输出的同时预读下一项，允许持续每拍交付一个区域。

kill 立即阻止输出握手并清除快照；slow 或 resolve 对缓存身份的更新同样阻止交付并使快照失效，下一拍读取更新后的 FTQ 内容。对预读候选的同拍更新阻止锁存。以失效重读处理 alloc/slow/fix 合并后的更新，不假定锁存后 FTQ 不再变化。

### ICache 入口与重放

新增两槽 ingress 环形 FIFO。入口 ready 只检查同步控制、FIFO 占用、重放队列状态和信用计数，不包含 tag/PMP/PMA、waiter 或 MSHR 的本拍结果。实际 SRAM 发射仍避开同 bank 回填，并遵守 ITLB 查询条件。

每个尚未从 S3 完成的请求占一个重放信用：

`replay_used = ingress_count + v1 + v2 + v3 + retry_count <= 8`

S2/S3 每拍推进。S3 能响应则响应，能登记 miss 则交给 waiter/MSHR；版本失效、响应端口竞争或资源不足则进入预留的 retry 槽。retry 优先重查翻译及 cache，不能直接复用旧的 hit/权限结果。重放容量从 4 增加为 8，避免新增 ingress 后的正常命中流水因信用过少而周期性停顿。保留信用与队列容量断言。

S2 已经知道区域偏移，只截取每个 way 的 16B 数据送到 S2/S3，后两级不再携带每个 way 的完整 64B 行。Cache 数据存储仍是原来的 bank/way 同步读 RAM；只缩窄后续流水记录。

### 预取

ICache 增加单项物理行请求寄存器。PMP/PMA 检查在接收边沿锁存，后续重新检查 epoch、过滤 cache 命中/在途行并申请 MSHR。预取入口 ready 由寄存器占用决定；候选被接收与最终 PF status 分开。prefetcher 在返回 status 的拍数独立计入 issued/filtered，支持没有 FTQ 候选时收到延迟结果。

尚未发到 MSHR 的预取在 kill 时丢弃；已经被 MSHR 接收的事务保持原有回填语义。仍保留 demand 优先和一个 demand 保留 MSHR，不启动预取 PTW。

## 延迟与吞吐

- F0/F1 逻辑重组本身不增加拍数，F1 修正寄存语义不变。
- 返回队列首次准备好数据和摘要后，增加一拍出口快照延迟；预读下一项使连续交付无额外间隔。
- ICache 增加一拍入口缓冲：命中响应从接收后 3 拍变为 4 拍。连续命中请求仍每拍接收、每拍响应；已有测试继续逐项检查零 stall 和连续响应拍数。
- 预取 buffer admission 与最终 status 变为不同拍。
- 未测整核 IPC，不能把组合路径缩短解释为已测得的性能提升。

## 针对性检查

每次开始检查前读取共享主机配置。cloud_chen `47.96.71.231:22` SSH 连接超时（包含提升权限后的重试），Alan `chen@localhost:2286` 经 `clawbot` 预检成功；使用 Verilator 5.050、cocotb 2.1.0。最终命令：

```bash
source /home/chen/miniforge3/bin/activate cislc-o3
EVIDENCE_DIR="$PWD/evidence" TEST_SEED=1 bash scripts/run-frontend-structural-checks.sh
```

最终 41/41 模块测试通过，无失败、无 skip；完整前端 lint exit 0，无新增宽度或组合环警告。现有未连接 legacy 端口等告警保留，未加入新的 waiver。

| 模块 | 测试数 | 关键覆盖 |
| --- | ---: | --- |
| F0 | 7 | 冻结重构前 RTL 逐拍、逐字段对照，含 10,000 拍混合长度随机流、跨区域、异常、背压与 trunc |
| F1 | 18 | 预解码、首个修正、截断及已有随机合同 |
| fetch return queue | 4 | 原有顺序/身份/zombie 检查迁移到出口快照时刻；新增更新失效重读和连续交付 |
| fetch prefetcher | 4 | 去重、翻译、探测和独立延迟 status 计数 |
| ICache | 8 | 全速命中、回填 bank 冲突、错误回填、PMP/PMA、预取保留/来源及 MSHR 全满后的重放完成 |

首轮 ICache 失败日志保留：旧测试把输入接收等同 SRAM 发射、假定同拍 PF status，并在前一失败遗留响应时采集了 reset 拍数据。实现补充 reset 抑制响应；测试迁移到新的 ingress/decision 边界，保留数据、异常、身份、资源保留的期望值，并明确检查新的 4 拍命中延迟，没有降低随机规模或取消断言。

## 综合结果

两轮 Vivado 均 exit 0。资源报告结果：

| 指标 | 基线 | 重构 | 变化 |
| --- | ---: | ---: | ---: |
| CLB LUT | 90,632 | 91,454 | +822（+0.91%） |
| FF | 55,003 | 52,574 | −2,429（−4.42%） |
| LUT as Memory | 2,368 | 2,368 | 不变 |
| BRAM tiles | 93 | 93 | 不变 |
| 综合 WNS（10 ns） | −22.517 ns | −15.622 ns | +6.895 ns |
| 最差路径逻辑层数 | 103 | 73 | −30 |

这是以少量 LUT 增长换取 FF 减少和综合时序改善，不是所有资源同时下降。前后均未满足 100 MHz。新增并行展开、输出快照和请求缓冲有资源开销；提前截取区域数据降低后续 ICache 流水宽度。

基线最差路径是 TAGE 查询 RAM → 慢预测/重定向 → F0 hold 状态，数据路径估计 32.541 ns。重构后的最差路径转为 TAGE `t1_packet_q.region_base[4]` → tagged table 训练写回 → query RAM `DINADIN[0]`，数据路径估计 25.185 ns，73 级逻辑。当前最差路径属于训练更新，不是 uBTB 的一拍下一 PC 反馈环。本轮保留快预测，也没有继续给 F0/F1 加级；下一步应先针对训练读、更新、写回的边界和局部路径做分析。

层次资源报告会因 `flatten_hierarchy rebuilt` 把跨模块组合逻辑归到不同层次，不能用单个模块行的跳变直接解释该模块增加或消除了多少逻辑；以上整体前端总数是本轮比较依据。

全局 WHS 两轮均为 −0.181 ns，最差内部寄存器间 hold 均为 +0.091 ns；TNS 从 −583,275.875 ns 变为 −385,278.406 ns，setup 失败端点从 52,336 降至 41,622。

setup/hold 与时序检查完整保留。OOC 的零输入延迟会产生外部输入到 RAM 地址口的 hold 诊断，不能据此断言内部寄存器间 hold 失败，也不能称时序闭合。两轮 `check_timing` 均无未约束内部端点、缺失 I/O delay、组合环或 latch loop。

## 可复现入口与证据

```bash
source /home/chen/Tool/FPGA/Vivado/2022.2/settings64.sh
vivado -mode batch -source scripts/vivado/frontend_ooc.tcl -tclargs OUT_DIR
```

远端根目录：`/home/chen/FUN/CISLC-O3-runs/frontend-structural-20261010/`。

- `baseline/`：基线 SHA 加完全相同的独立综合 wrapper/Tcl，Vivado exit 0。
- `revised-0bc772d/`：首轮检查及失败日志。
- `revised-551dc65/`：重构 RTL 检查与综合。
- `final-63890ea/`：最终检查脚本、日志、XML、test-results.json 和退出码。

小型机器可读索引：[O3-frontend-structural-evidence.json](O3-frontend-structural-evidence.json)，包含准确 SHA、文件哈希、命令、退出码、资源及时序结果。

本地收集根目录：`build/evidence/frontend-structural-20261010/`（忽略的大型证据）。源码哈希、约束、资源、内部 setup/hold、最差路径和 timing 检查均保存；checkpoint 保留在远端。
