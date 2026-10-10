# O3 T12d — loop predictor 与最终门禁

最终源码 SHA **`c522369c11b88b819e2ca9192f491e266bd16cee`**，分支 `feat/l7c-frontend`；T12 起点（PMP 已完成）`10235be8c09ae8f2f8820ff6519ec6e81e8f6962`。PMP → T12a → T12b → T12c → T12d 已按顺序实现并提交。功能、性能门禁全部通过。阶段报告保存在本地工作区，原 T10/RAM 报告与其他用户文档未纳入这些实现提交。

## 完成内容

8 项全相联 FF loop 表，14 位 tag、10 位迭代、2 位 confidence、3 位 age；P1 命中索引注册到 P2 并重新校验 tag/slot/BTB mask，满置信时只覆盖 TAGE 最终方向，原始 TAGE 元数据保留。slow 出口生成更新前整表 80 位检查点与 loop 元数据，FTQ 存储、提交事件与 T1 训练全部接通。EXEC 重定向传递实际条件分支方向，赢家恢复覆盖三种槽位关系；分配同项优先、初始计数为 0；计数溢出失效、invalid/age-zero 优先与轮转 age 衰减均实现。

新增 `run-l7c-frontend`：300 次循环重复 40 次；80×128B 冷代码段（10KiB，前向分支，仅执行一次）；24 个短区域重复 200 次。开关两组程序保持相同 PC 与指令数量，分别写 `mo3fecfg=0/3`，三段均自查并成功写 tohost。计数采样遵循暂停/恢复 HPM 方法；独立 Python 提取退休 CSR 读和 SD 写，检查冻结状态、样本地址/身份及关功能时事件为零，不读取 DUT 内部计数器。

## 自行决定与授权修订

- **赢家检查点身份**：`kill_self` 可在接受沿删除 FTQ 项，故在接受沿校验完整 id 并锁存 loop/RAS 检查点，下一拍与 history 返回一同恢复；同沿新 slow 元数据写旁路。涉及 `frontend.sv`、`ftq.sv`。
- **SLOW override 本区域动作**：`upd_valid` 记录赢家路径是否经过 loop 槽，物理推测计数更新另由 `!kill` 门控；否则同拍 SLOW kill 会把恢复需要重放的动作也删除。涉及 `bpu.sv`、`loop_predictor.sv`，新增同拍 kill 定向检查。
- **冷启动反向退化项**：首次 TAGE 错误可能分配 `dir=NT` 并学习成零次迭代项，真实出口持续错误；仅对 USED 预测错误且 `past_iter==0 && commit_iter==0 && actual==dir` 失效重学，普通项仍只清置信/减 age。独立用例验证重新分配后 200 次循环学习。涉及 `loop_predictor.sv`。
- 上述行为变化已按用户“spec 有问题自行修正”授权写入 [spec 第 16 节](../spec/l7c-frontend-throughput-spec.md#16-实现交叉核验修订2026-10-08)，优先于旧任务书的逐阶段停下询问规则。历史算法、TAGE tag 组织与 BTB 单目标规则保持。
- 冷流用四个独立寄存器交错执行 28 条 ALU，结果各 560；保留 10KiB、前向分支、一次执行、自查与相同布局。早期单寄存器依赖链把前端收益掩盖在 ALU RAW 延迟中（当时预取减少 miss，但周期相同）；最终程序测量可供给的独立指令流，未删减性能判据。

## 最终同 SHA 证据

主机 `cloud_chen@47.96.71.231`（hostname `iZbp16rhtg91v96m32vggjZ`），环境 `source /home/cloud_chen/setup/activate-o3.sh`；cwd `/home/cloud_chen/work/l7c-t12d`；证据根 `/home/cloud_chen/evidence/o3-l7c/t12d`。每次编译/仿真前读取共享主机配置，确认 cloud SSH、工具和资源；全部功能仿真在 cloud 执行。Verilator `Verilator 5.050 2026-07-01 rev vUNKNOWN-built20261007`，cocotb `2.1.0`。

[机器可读证据](O3-T12d-evidence.json) 记录 SHA、cwd、完整命令、exit、耗时、每份 XML 的测试数、日志/原轨迹/ELF/汇总文件 SHA256。`source-manifest.json` 对比本地提交源码与远端实际源码（包括 CVFPU 与 common_cells 文件），一致。CVFPU 固定为 `1b220f3bc89df99e246b72e3574a3a533cf87653`。文档改动不计入编译源码。

| 门禁 | 结果 | 证据相对根目录 |
|---|---|---|
| `bash scripts/lint.sh` | exit0；0 errors / 357 warnings，与基线一致 | release-core2/run.log |
| 全部 58 个 cocotb 默认目录 | **251/251，FAIL/SKIP=0** | release-modules/*-1.{xml,log} |
| 15 个冻结模块 seed7/29 | **130/130，FAIL/SKIP=0** | release-modules/*-{7,29}.{xml,log} |
| FTQ metadata、SRAM poison、DCache MSHR1/4 附加配置、PTE cache | **72/72，FAIL/SKIP=0** | release-modules/ 相应 XML/log |
| SRAM 禁止碰撞负向门禁 | 原断言触发，模拟器非零退出，校验脚本 exit0 | release-modules/sram-negative.log |
| MEM_PIPES2/MSHRS4：原13个目标 + L7c开/关 | 全部通过；16次整核程序运行；exit0 | release-core2/{run.sh,run.log,status.txt,artifacts/} |
| MEM_PIPES1/MSHRS1：原12个目标 + L7c开/关 | 全部通过；15次整核程序运行；exit0 | release-core1/{run.sh,run.log,status.txt,artifacts/} |
| 四个共享文件名原始门禁串行复验 | 两种配置各4个目标，exit0，各自保存原轨迹 | primitive{2,1}/{run.log,status.txt,traces/} |

合计 **94 个正向模块命令、453 次测试执行全部通过，无跳过**；加 1 个预期断言负向命令。整核计数包含 `run-l7-predict` A/B 和 L7c ON/OFF，不把同一目标的多个 ELF 混算成新增目标。

模块复现：`EVIDENCE_DIR=<新绝对目录> bash scripts/run-l7c-modules.sh`。整核命令与构建参数逐字保存在每个 `run.sh`，按 `build` 后 `make -j1` 运行指定目标。复验前按 AGENTS 重新选择主机；XML 使用新路径，避免 make 复用旧结果。两种配置共享的四个 primitive trace 已在所有整核任务结束后先2后1复验并复制到各自证据目录，解决并行文件覆盖，最终统计使用串行结果。

### 第 14.1 节模块覆盖

每个 seed1/7/29：RQ3、TAGE4、BTB3、BPU7、loop5、prefetch3、ICache6、CSR12、MMU8、uBTB3、RAS2、arbiter1、slow_check1、sync3、PMP3。FTQ4 + metadata3；SRAM 默认读写1 + poison1 + 单独禁止碰撞断言。TAGE/BTB 包含冻结旧训练参考逐位比对、连续同行/同组写旁路与暂停输出保持；loop 包括三种恢复关系、整表检查点、disable、溢出、victim/age、同项分配优先及退化项重新学习。MMU 保留原7例，新增探测连续miss不发PTW、resident hit不改PLRU、fault不锁存检查；CSR 新例含M读写/WARL/无refetch及S/U非法。

## 第 14.2 / 14.3 节性能计数

以下为 MEM_PIPES2/MSHRS4 的冻结采样差值；ON `mo3fecfg=0`，OFF `=3`。同程序前置设置以外 PC/指令数量一致，整程序均退休48848条、tohost=1。性能布尔值在两种整核配置均全部为 true。

### 长循环

| 计数 | ON | OFF |
|---|---:|---:|
| COND_BR | 12041 | 12041 |
| COND_MISPRED | 12 | 45 |
| TAGE_WRONG | 45 | 45 |
| LOOP_USED | 10482 | 0 |
| LOOP_WRONG | 3 | 0 |
| CMT_REGION | 12091 | 12124 |
| TRAIN_STALL | 0 | 0 |
| UNUSED | 0 | 0 |
| cycles | 36295 | 36942 |

loop 误预测 45→12（−73.3%），采样周期 36942→36295（−1.75%）；`LOOP_USED=10482`、`LOOP_WRONG=3`，保留冷学习误差，不声称零误预测。

### 冷代码流

| 计数 | ON | OFF |
|---|---:|---:|
| DEMAND_MISS | 750 | 795 |
| PF_ISSUED | 155 | 0 |
| PF_USEFUL | 3 | 0 |
| PF_LATE | 152 | 0 |
| PF_UNUSED | 0 | 0 |
| PF_THROTTLED | 389 | 0 |
| PF_XLATE_MISS | 0 | 0 |
| PF_CANDIDATE | 1187 | 0 |
| cycles | 2539 | 3587 |

周期3587→2539（−29.2%），demand miss事件795→750（−5.66%）。152次预取在首次demand前尚未完成，记late；只有3次先填完记useful。收益主要来自提前启动回填。该事件按ICache demand miss请求口径（含合并/重试请求），不是750条唯一cache line；本段10KiB，不能把该计数直接解释成唯一行回填数。

### 密集区域

| 计数 | ON | OFF |
|---|---:|---:|
| CMT_REGION | 5003 | 5003 |
| TRAIN_STALL | 0 | 0 |
| FTQ_FULL | 9306 | 9310 |
| RQ_FULL | 10 | 14 |
| DELIVER_LT4 | 14399 | 14408 |
| BACKPRESSURE | 30 | 30 |
| RQ_WAIT_DATA | 9368 | 9382 |
| ZOMBIE | 280 | 415 |
| cycles | 14539 | 14547 |

训练停顿为0，性能项达标；FTQ满9306拍、等待数据9368拍、后端就绪但不足4条交付14399拍仍有计数，不能据此声称前端已达到每拍4条。MEM_PIPES1长循环/冷流数值与上表相同；短段ON相同，OFF cycles14550、FTQ_FULL9310、RQ_FULL14、DELIVER_LT414411、RQ_WAIT_DATA9384、ZOMBIE428，其余同上。

| 性能项 | 判定 |
|---|---|
| loop开启的条件分支误预测更少 | PASS，12 < 45 |
| 预取开启的demand miss更少 | PASS，750 < 795 |
| 预取开启的冷流mcycle更少 | PASS，2539 < 3587 |
| 短区域TRAIN_STALL_CYCLE=0 | PASS，两种整核配置均0 |

## 原整核程序起点与最终周期对比

PMP阶段同程序基线日志保存在 `.../o3-l7c/pmp/core{2,1}/run.log`。下表为cycles；括号为最终减起点。P2/P1分别为MEM_PIPES2/MSHRS4与MEM_PIPES1/MSHRS1。L8a-mem只要求P2；其原golden退休前缀检查仍通过，62786条退休保持。

| 程序 | P2起点 | P2最终（差） | P1起点 | P1最终（差） |
|---|---:|---:|---:|---:|
| icache_smoke | 545 | 545 (+0) | 545 | 545 (+0) |
| dcache_data | 583 | 598 (+15) | 589 | 604 (+15) |
| dcache_replay | 597 | 612 (+15) | 597 | 612 (+15) |
| l3_branch_dense | 2477 | 1595 (-882) | 2478 | 1595 (-883) |
| l7_predict_a | 44300 | 24217 (-20083) | 44296 | 24271 (-20025) |
| l7_predict_b | 44345 | 24207 (-20138) | 44362 | 24302 (-20060) |
| l8a_mem | 123750 | 96345 (-27405) | — | — |
| l9_fp | 2354 | 1412 (-942) | 2361 | 1412 (-949) |
| l10_priv | 4047 | 3795 (-252) | 4047 | 3795 (-252) |
| l10_vm | 17534 | 11526 (-6008) | 17548 | 17076 (-472) |
| l8b_amo | 42937 | 41330 (-1607) | 42942 | 41413 (-1529) |
| l8b_mmio | 4416 | 3808 (-608) | 4420 | 3820 (-600) |
| l8b_misalign | 18941 | 12553 (-6388) | 18973 | 18342 (-631) |
| l8b_dma | 12762 | 13240 (+478) | 12770 | 13256 (+486) |

增加项逐项记录：

- **dcache-data P2/P1 +15**：P2在T12a/B为585（基线583，+2），T12c开启PF后598（再+13）；P1最终604，对照基线589。P2回填由2→5→8，load replay保持3；额外推测取指与预取增加回填、共享L2资源竞争。小程序供给不受益，增加发生在PF接入阶段。
- **dcache-replay P2/P1 +15**：T12a/B604（基线597，+7），T12c后612（再+8）；P2回填2→7→8，replay2→3→2。多项返回改变取指/访存交错，PF又改变回填仲裁，未修改该程序原store/load黄金值或回放要求。
- **DMA P2 +478、P1 +486**：增量主要出现在T12b（P2由T12a11686变13232，PF后13248，最终13240）。P2从起点到最终，正确解析1219→2160、误预测271→217、load replay261→332、I回填10→14；P1 replay133→392。早释放/训练节拍改变了wait_dma轮询分支、数据访问与DMA invalidation的交错，更多可执行的年轻路径随后取消/重放。该128轮并发DMA程序的吞吐回退保留为已知性能问题；以上是阶段与计数定位，尚未把478/486拍逐拍分摊为单一原因，不能宣称所有程序加速。

退休数差异：FP615→616、VM6434→6435、AMO7802→7803、DMA3346→3347、predictB19445→19444包含与周期/设备进展相关的动态轮询或终止同拍槽位。原架构自查、异常/PTE/MMIO/DMA检查和tohost前缀规则保持，不用最终周期替换golden数据。

## 测试修订与中间失败

- BPU/arbiter适配器与模型扩展EXEC实际方向、loop元数据；旧用例保持，并新增覆盖。FTQ训练由同步快照返回及H0/H1信用握手，等待拍数按真实接口调整。
- HPM旧例把新FE事件0x34当保留号，BE增量扫描止于旧末项；改用当前FE/BE事件末尾，完整增量检查仍在，19例全通过。
- PTE cache Makefile与MMU主测试共用构建目录会加载错误顶层，独立`SIM_BUILD=sim_build/pte`后两例通过，未改变PTE golden。
- SRAM默认禁止碰撞用例单独运行，要求非零退出且匹配原断言文本；合法碰撞poison单独运行，未跳过或放宽禁碰撞断言。
- 首次整核编译调试打印错用`arb_redirect_valid`，改为实际`arb_bpu_redirect_valid`；最终同SHA重编译。之前失败日志仍在`t12d/final-core2`、`final-modules`、`all-modules`等中间目录；这些结果不用于通过声明。
- 单寄存器冷流和loop退化方向的中间结果亦保留在`verified-core{2,1}`等目录；最终收益以本报告`release-*`和机器证据中的SHA为准。

## 时序结果与已知边界

PMP预解码将NAPOT/TOR地址范围运算从访问路径搬到CSR更新沿；[PMP报告](O3-pmp-predecode-report.md)绑定该阶段SHA，Alan L1D综合中原PMP端点−0.073ns→+2.290ns，30→25逻辑级；全模块setup WNS +1.376ns，TNS0，RAMB36仍64。全局外部零延迟边界hold −0.143ns/6020端点保留，独立reg→reg最差hold +0.094ns。

TAGE/BTB采用同步1R1W双副本RAM、读使能保持、外部碰撞与训练写回旁路，结构性移除原异步查表/长训练读改写；功能和逐位算法等价已验证。按照L7c冻结范围，本级未对这些表重新综合/OOC，不把推断写法当作RAMB资源或布线证明。未运行Spike、ACT4、SoC或FPGA；整核布线时序仍待L11物理门禁。FTQ/检查点FF规模、短块供给及DMA吞吐回退也保留供后续实测。

所有本级正确性门禁通过，无未解决的新测试失败。报告与授权spec修订保留在工作区供整体审查，原有用户文档未自动提交。
