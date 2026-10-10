# 前端 100 MHz 时序重构

本轮完成了默认完整前端的 RTL 时序重构。当前 `349d919` 在 KU040、10 ns 的布局布线结果为 setup +0.004 ns、寄存器间 hold +0.052 ns，内部路径满足 100 MHz，裕量很小。零输入/输出延迟的独立 OOC 边界仍有外部 hold −0.181 ns，因此不能把这份证据称为完整接口时序闭合，也不能据此宣称整核或板级运行已达标。

测量对象包括 BPU、FTQ、ICache、返回队列、F0/F1、指令缓冲和预取器。后端、L2、SoC、位流、板级运行和整核 IPC 不在本轮证据范围内。

## 源码与约束

- 前一轮基线：`dcb6d0256505aa65fb4fbee7c381f044f8dc8c55`，RTL 与前一轮报告中的 `551dc65` 相同，已经包含 FTQ 环形控制和按写者拆分存储。
- IFU 队列版本：`959635a138d2e89ab554a69e474537220c58cc93`。
- 年龄游标版本：`52899eb00be170398b513adb13450ec8978ff55c`。
- 并行年龄比较版本：`14a9b6a15df566d6d6f38031244a489c0317144d`。
- 训练匹配版本：`6bc365718b4d5d007a578585191a6449a5837dd7`，将 TAGE 当前行匹配标志从 T1 寄存到 T2。
- 当前 RTL：`349d91968ce17620969266e7b53e8d68c64e32f4`，并行准备每行 alternate 使用条件和两种慢预测分歧判断。
- `843be7c` 只强化队列的定向测试，确保任意随机种子都覆盖取消边界两侧的指令；RTL 和综合/布线脚本与测量版本相同。
- Alan，Vivado 2022.2，`xcku040-ffva1156-2-e`，默认 `O3_CFG.fe`，`FPGA_TARGET`。
- 10.000 ns 时钟，输入/输出延迟均为 0 ns；保留相同 OOC wrapper、公开端口和完整 common/frontend 清单。
- 无 retiming、false path、multicycle 或放宽时钟约束。零 I/O 延迟是本次 OOC 边界，不是实际 SoC 的接口预算。

## 电路组织

### TAGE 查询与训练

查询仍是 S0 地址/标签准备、S1 同步 RAM 读、S2 标签比较和方向选择，没有给查询增加流水级。各表标签命中并行产生，provider/alternate 用固定 one-hot 选择。

训练有独立的读副本：T0 接收并同步读行，T1 更新槽 0～3，T2 更新槽 4～7 并原子写回完整行。每个表、每个固定槽有独立驱动；计数器更新不依赖其他表的分配选择。共享 tag、useful 衰减及同一行内的分配优先关系仍按原算法处理。

T0 与 T1 活跃训练包任一表的行地址冲突时反压。T0 可以与 T2 的同行写回重叠，整行写新值旁路保证读取最新内容。查询副本和训练副本在同一写回边沿更新，valid 与 RAM 读在 T0 边界一起采样。非冲突训练可每拍接收，同一行连续训练的接收间隔为两拍。BPU 四项训练队列保留完整包，按所有预测器的 ready 出队，不丢弃冲突训练。

T1 还计算当前行是否属于本训练包的 tag，并把每表 1 bit 的结果寄存到 T2，取代 T2 再做宽 tag 比较。原始 provider 匹配标志单独保留：T1 新分配使当前行匹配，并不代表旧 provider 匹配。T2 仿真断言独立比较 valid/tag，检查传递标志正确；查询和训练拍数、冲突规则均不变。

查询的 weak-counter/useful 判断在各表原始行上并行计算，再用 provider one-hot 选择条件 bit；不再选择完整计数器和 useful 后才比较它们。输出方向、provider/alternate 元数据保持原算法。

### BPU 与恢复仲裁

BTB/TAGE 在分配周期 N 的 N+2 完成慢检查，完整慢预测、修正请求、loop 元数据和事件在下一边沿寄存，N+3 对外呈现。kill 在捕获边沿按 FTQ 年龄过滤查询，保留较老查询；寄存结果不再被自己产生的 kill 组合反向抑制。

uBTB 的固定项并行比较，控制流资格提前计算，地址和 mask 使用 one-hot 合并。快预测的 branch/push 地址按物理槽提前生成；RAS 按物理行译码写入与修复。没有切开快预测下一 PC 反馈环，连续无停顿时仍每拍分配一个区域。

慢检查的分支 PC、fallthrough、RAS 地址提前生成，迟到的 TAGE 方向只选择出口。taken 与顺序两种情况下的快慢分歧也并行提前计算，owner 选择后仅选择 1-bit 结果，不再对迟到方向选择出来的 64-bit PC 作比较。重定向源的年龄比较并行进行，宽赢家 payload 选择之后不再接第二轮年龄比较。

各模块的年龄判断直接使用 FTQ `head_q` 游标。新增 `age_head_idx_o` 是年龄原点，空队列时仍保留游标位置；原 `head_id_o` 继续在空队列输出 0，非空时输出带 generation 的队头身份。年龄比较本来就只读取 head 的 idx，合法活跃项的排序不变；分离后占用计数不再通过队头身份资格判断进入全局取消路径，没有增加拍数。

`fe_before` 用两个并行的 `idx < head` 比较识别回卷段，段不同时选择未回卷者为较老者，段相同时直接比较 idx，同 idx 才比较 slot。不再先对两个身份做减法、取模、拼接年龄，再比较年龄。generation 仍参与 kill-self 身份匹配和仲裁平局规则，没有参与年龄排序。旧 `fe_age` 保留作独立等价参照。

### ICache 与返回队列

waiter 只保存请求区域的 16B 响应数据，代替每项完整 64B cache line。年龄在分配后保持不变；分配时维护两两年龄关系，响应时只用 ready 位和年龄矩阵选出最老 ready waiter，不再串联八次宽记录选择。保留 32-bit 无符号年龄及原索引平局规则；仿真中用原线性年龄选择作独立断言。

返回队列按固定物理槽驱动响应状态，把有序后缀取消与响应写入分开。前一轮引入的 ingress/retry 信用和返回队列数据/预测摘要快照继续保留，命中响应延迟仍为接收后四拍。

### F0、F1 与指令缓冲

F0 半字起点和展开继续并行工作，位置限定为实际所需的 5-bit signed 值，PC 按固定半字位置并行生成。pending 半条指令保存时准备下一顺序区域地址，边界比较不再临时接 64-bit 加法。

F1 每 lane 独立产生修正规则，首个停止点和存活前缀由 one-hot/prefix 选择；位置采用 4-bit 编码。指令缓冲的空闲行分配并行译码，任意取消空洞用分层前缀压缩存活顺序，不再逐条串联宽 payload 的动态写入。

新增两项 `ifu_decode_queue`，在 F0 与 F1 之间拥有完整 beat、预测摘要、last 和 edge-pending 元数据，无旁路。F0 ready 来自寄存占用，切断 fetch buffer → F1 → F0 的组合 ready 链；F1 修正通过原有寄存重定向在下一周期取消年轻 beat。取消时逐指令保留较老前缀并压缩两项记录；同步清除全部队列状态。

空 beat 也必须保留，F1 需要它执行槽 7 的 c-prime 修正。F0 产生 pending 半条指令后，队列的边界等待位阻止下一块消耗它，直到拥有该 pending 的 beat 到达 F1。这样迟到的 c-prime 取消仍能保留较老半条指令，后续正确路径可以拼接。

普通 beat 新增一拍延迟，连续流仍可每拍传递一组；pending 半条边界可能多等待一拍。没有测量整核 IPC，不能把时序改善直接当作 IPC 提升。

### 预取

ICache 先接收候选地址和上下文，再用寄存地址做 PMP/PMA 检查并寄存结果，之后申请 MSHR。ready 只取决于候选寄存器占用。候选处理从两拍变为三拍，当前单项候选处理不重叠，正常接收间隔为三拍；kill、同步、epoch 和上下文失效仍会过滤候选，demand 保留资源规则不变。

## 检查

每次编译/仿真前重新读取共享主机配置。cloud_chen `47.96.71.231:22` SSH 连接超时，Alan `chen@localhost:2286` 经 `clawbot` 预检成功；实际执行 Verilator 5.050、cocotb 2.1.0。

当前 `349d919` 的完整检查入口：

```bash
source /home/chen/miniforge3/bin/activate cislc-o3
EVIDENCE_DIR="$PWD/evidence/checks" TEST_SEED=1 bash scripts/run-frontend-100m-checks.sh
```

`959635a`：19 个 suite，84/84 通过。`52899eb`、`14a9b6a`、`6bc3657` 和当前 `349d919` 均为 85/85 通过，0 failure、0 skip、0 missing XML；完整前端 lint exit 0，无 DUT WIDTH、LATCH、UNOPTFLAT 告警。旧有未连接 legacy 端口等告警保留，没有新增 waiver。新增检查覆盖队头身份/年龄游标在连续退休为空、重新分配以及 32→0 回卷时的行为。

当前版本额外运行 `sim/rtl/frontend_age_tb.sv`：穷举全部 head/左右 idx/左右 slot，组合 valid、all、kill-self 和相同/不同 generation，33,554,432 组输入全部与原取模年龄和取消规则一致，编译及执行 exit 0。

关键检查包括 F0 冻结重构前 RTL 的 10,000 拍逐字段对照、TAGE 256 包同行训练及全部行内容逐拍对照、训练冲突握手、查询/写回旁路、BPU 跨 FTQ 回卷的选择取消、ICache 连续命中/重放/PMP/PMA，以及指令缓冲完整 payload 随机空洞压缩。原有随机规模、断言和预期数据不降低。

新 IFU 队列测试检查无旁路、连续吞吐、背压、1200 拍随机完整 payload 和部分取消；F0→队列→F1 集成测试检查已入队年轻块的取消、空 beat c-prime 后的跨区域拼接，以及同步清除 pending 和队列。`843be7c` 用 seed 2 额外运行队列 3/3，通过。

另有两次在源码同步结束前启动的任务因目录/脚本不存在而退出，未编译或综合 RTL；等待归档提取完成并核对哈希后重跑。索引记录了这两次启动失败的退出码和原因。

早期 Vivado generated-struct 前向引用失败、BPU reset 输出失败、旧测试的延迟迁移失败及检查脚本误列不存在目录的日志都保留。最终测试没有通过改变黄金数据、禁用断言或跳过案例过关。

## 综合与布局布线

当前 `349d919` 综合为 93,960 LUT、52,875 FF、2,368 LUTRAM、93 BRAM tiles，估计 setup +1.483 ns、24 层，最差路径回到 TAGE 训练 `t2_match_q[1]` 到 table 3 valid 状态。相比前一轮基线增加 2,506 LUT（+2.74%）、301 FF（+0.57%）；没有增加 RAM。并行条件计算存在面积代价。综合仅含估计网络延迟，布线结果见下表。

中间版本 `6bc3657` 综合为 92,554 LUT、52,896 FF、2,368 LUTRAM、93 BRAM tiles，估计 setup +1.290 ns、24 层。最差路径已移到 TAGE table 5 查询 RAM 到 BPU 慢预测 override 寄存器。相比 `14a9b6a` 减少 602 LUT、13 FF；布局后估计 setup +0.005 ns，未完成布线；源码被 `349d919` 替代后停止旧布线，exit 143，保留日志和布局 checkpoint，没有该版布线闭合声明。

当前 `349d919` 综合层次资源如下，TAGE 包含在 BPU 中，不能重复相加：

| 模块 | LUT | FF | LUTRAM | RAMB36 / RAMB18 |
| --- | ---: | ---: | ---: | ---: |
| BPU | 29,999 | 20,666 | 236 | 22 / 22 |
| TAGE（BPU 内） | 16,570 | 9,862 | 0 | 14 / 14 |
| FTQ | 7,191 | 2,049 | 872 | 0 / 0 |
| ICache | 22,565 | 17,638 | 44 | 56 / 8 |
| F0→F1 队列 | 14,721 | 2,312 | 0 | 0 / 0 |
| F0 | 4,564 | 613 | 0 | 0 / 0 |
| F1 | 1,158 | 277 | 0 | 0 / 0 |
| 指令缓冲 | 7,336 | 4,709 | 0 | 0 / 0 |

FTQ 的宽 payload 已使用按写者拆分的 LUTRAM。这里是完整前端的层次统计，不能直接与旧独立 FTQ OOC 的端口和约束不同的数字作公平面积比较。新增解码队列仍有较多 LUT，当前优先解决时序，未进行面积最小化。

综合基线与当前版本比较：

| 指标 | 前一轮基线 | 当前 `349d919` 综合 |
| --- | ---: | ---: |
| CLB LUT | 91,454 | 93,960 |
| FF | 52,574 | 52,875 |
| LUT as Memory | 2,368 | 2,368 |
| BRAM tiles | 93 | 93 |
| 综合 WNS（10 ns） | −15.622 ns | +1.483 ns |
| 综合最差逻辑层数 | 73 | 24 |

当前 `349d919` 的完整布局布线于 2026-10-11 04:21:58（北京时间）结束，进程 exit 0、耗时 1,747 秒：

| 布线指标 | 结果 |
| --- | ---: |
| 全局/内部 setup WNS / TNS | +0.004 ns / 0 ns |
| setup 失败端点 | 0 |
| 内部寄存器间 hold WHS | +0.052 ns |
| 全局 hold WHS / THS | −0.181 ns / −2,423.526 ns |
| hold 失败端点 | 37,173 |
| 完全布线网络 / 可布线网络 | 113,057 / 113,057 |
| 布线错误 | 0 |
| 布线后 CLB LUT / FF | 94,507 / 52,898 |
| 布线后 LUTRAM / BRAM tiles | 2,356 / 93 |

当前最差 setup 是 ICache `s3_q.req.region_base[6]` 到 `waiter_data_q[6][28]` 的 CE：22 层、9.914 ns 数据延迟，其中逻辑 2.804 ns、连线 7.110 ns（71.72%）。内部 hold 最差为 TAGE `wb_row_q[1].ctr[5][2]` 到 `t2_rows_q[1].ctr[5][2]`，+0.052 ns。TAGE 查询仍为三拍，当前整体 setup 瓶颈已转移到 ICache 的请求处理/响应暂存控制。

最差全局 hold 是外部 `exec_resolve_i.ftq_id.idx[0]` 到 FTQ `res_mem` 的 LUTRAM 写地址。输入端没有包含上游寄存器的 clock-to-Q 和连接延迟；后续整核集成必须检查真实接口的 setup/hold，当前不能预先判定它会自动通过。4 ps 的 setup 裕量也不能作为充分集成裕量。本轮证明内部路径在该器件/约束下满足 100 MHz，完整零 I/O 延迟 OOC 接口边界仍未闭合。

中间版本 `959635a` 已完成相同约束布线：setup +0.003 ns、内部 hold +0.053 ns、全局 hold −0.181 ns。`14a9b6a` 的对应结果为 +0.009/+0.053/−0.181 ns，93,583 LUT、52,941 FF、2,368 LUTRAM、93 BRAM tiles，exit 0、2,206 秒。最新版综合关键路径有所缩短，但布局布线后最差路径发生变化，整体布线裕量没有继续增加；不能用综合改善声称整体布线性能进一步提高。

`check_timing` 的无时钟、未约束内部端点、缺失/不完整 I/O 延迟、组合环等检查均为 0。DRC 没有 Error/Critical Warning，保留 CFGBVS-1（OOC 未设置板级配置电压）和 RTSTAT-10（无可布线负载）两类 Warning。Vivado 进程成功退出不代表全局 hold 通过。

附加物理延迟缓冲实验没有改变 RTL 或原约束。只修复 RAM 写端后，估计最差 hold 转移到 CSR 输入；整体输入缓冲又形成新的 setup 长路径。分支缓冲实验遇到固定布局的控制线共享和增量布线冲突，未形成可交付的完整闭合结果。这些实验保留诊断文件，未加入 RTL、默认实现脚本或本轮达标证据。

## 复现与证据

```bash
source /home/chen/Tool/FPGA/Vivado/2022.2/settings64.sh
vivado -mode batch -nojournal -nolog -source scripts/vivado/frontend_ooc.tcl \
  -tclargs evidence/synth
vivado -mode batch -nojournal -nolog -source scripts/vivado/frontend_route.tcl \
  -tclargs evidence/synth/frontend_synth.dcp evidence/route
```

远端根目录：`/home/chen/FUN/CISLC-O3-runs/frontend-100m-20261010/`。`r21-959635a/` 保存 IFU 队列版本的检查、综合和物理实现日志、退出码、XML、报告及 checkpoint；`r22-843be7c/` 保存 seed 2 的队列检查；`r23-52899eb/` 保存年龄游标版本；`r24-14a9b6a/` 保存并行年龄比较版本；`r25-6bc3657/` 保存 TAGE 匹配标志版本；`r26-349d919/` 保存当前方向/分歧条件并行版本。`r1`～`r20` 保留迭代和失败证据。

本地收集根目录：`build/evidence/frontend-100m-20261010/`。机器可读索引 `O3-frontend-100m-evidence.json` 记录准确 SHA、命令、cwd、退出码、源码哈希和各阶段边界。最终文档提交不修改已测量的 RTL；最新 RTL 证据绑定 `349d919`；旧版布线结果不能替代新版布线。
