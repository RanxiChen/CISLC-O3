# 前端时序与混合指令带宽重构

本轮完成已有流水级的重新分工，将默认 IFU 改为一个 16B 区域最多八条入队、后端四条出队。最终源码 `be00de6d54d973301236095cb6ca6b6c0c705b6a` 的完整回归 26 个 suite、141/141 用例通过，综合使用 84,465 LUT、47,698 FF。完整前端 OOC 布线完成：100 MHz setup WNS +0.239 ns，内部寄存器路径 hold +0.052 ns；零 I/O 延迟边界仍有外部 hold 违例，不能声称所有接口时序或整核时序闭合。

## 最终结构

ICache 不新增 S4。S2 并行完成 tag 命中、16B 数据选择、PMA/PMP 判断和 MSHR 地址匹配；S3 用寄存结论进行分配、合并、响应或重放。上一沿新分配的 MSHR 使用地址旁路，已完成的槽用 live mask 排除；权限跨拍变化则重放。每个请求携带一位 set 回填失效标记，覆盖 S1 停留及 S1→S2、S2→S3 的同拍回填；独立 32 位版本号 oracle 仅用于仿真断言。空闲 waiter one-hot 指针提前寄存，每项本地产生写使能。无冲突 demand 命中从外部握手到响应仍为四拍。

F0/F1 默认处理八条，一拍覆盖区域中的全部指令。默认 whole-region 控制删除了不再需要的 remainder hold 存储和反馈路径，原四条参数路径保留。尾半字保存按指令起点、异常和出口覆盖判断，保留 pending 检测先于出口截断的原始优先级。跨区域半条指令的 ownership barrier 仍可能等待 owner beat，这一等待不属于本轮消除的区域剩余指令浪费。

F0→F1 已有双项队列改成固定两项 payload 存储，用一位队头和占用计数控制读写。出队和 kill 修改指针及 mask/last/edge 元数据，宽 payload 留在原物理位置。F1 使用有效前缀输入，lane 数据不再经过由迟到截断控制的压紧选择器。不增加 F1 后寄存级。

默认指令 buffer 是 **八 bank、32 项环形 FIFO**：物理索引低三位选择 bank，高两位选择行。每拍连续入队 0～8 条、连续读出最多四条，每个 bank 只需要一写一读；宽 payload 使用无复位 distributed RAM。队头、队尾和占用计数控制顺序，出队或 kill 不搬动宽数据。窄身份/slot sidecar 用于 kill，保留程序顺序前缀，由断言检查。原通用 buffer 保留任意稀疏入队及 kill 空洞的独立测试。这里交叠 bank 解决同一个接口访问连续多项的需要，与 FTQ 的多个无关地址访问不同。

FTQ kill 用占用范围失效尾部项，去掉向无效行广播状态清零；重新分配完整初始化状态，迟到回写由代际和存活判断拒绝。空队头公开训练元数据保持零。存活且不杀自身的边界已有 `keep_count >= kill_age+1`，删除边界截断中的冗余比较，仿真保留旧条件的断言对照。按写者拆存储和退休规则保持。

预取翻译复用缓存先捕获 demand/probe 输入，再作 duplicate/victim 选择；安装中的 probe 不重复发起，epoch/SFENCE 阻止过期输入安装。只增加预取翻译安装延迟。

TAGE 训练仅删除冗余 usefulness 更新依赖：provider 更新要求 `provider==t`，分配候选要求 `provider<t` 或无 provider，互斥条件允许 eligibility 使用更新前的 usefulness。三拍查询、4+4 slot 训练、同行训练间隔两拍、写回转发和不丢训练规则保持。本轮没有扩为 32B 取指。

## 带宽与观测

默认完整 IFU 测试接真实 F0、双项队列、F1 和八 bank buffer。连续 80 个五条区域共 400 条指令，启动后连续 100 拍每拍交付四条；F0 接收 80 个 beat，remainder beat 为零。这证明混合长度区域不再因四条处理上限拆成两拍，是热数据独立 IFU 的供给证明。它不代表整核 IPC=4，也没有消除 16B 取指在 RVI taken 分支上的字节带宽损失。

新增 source-1 事件 0x16～0x1a 统计后端 ready 时交付 0～4 条的周期直方图，0x1b 统计 F0 处理保留区域剩余部分的握手 beat。`PE_NUM=0x44` 及已有编号保持；HPM CSR 接入新编号，未分配的 0x1c～0x1f 继续不计数。直方图不把后端反压计为前端不足。

## 验证

按共享策略重读主机配置并校验 cloud_chen；`47.96.71.231:22` 的有限超时免密连接失败后使用 Alan。全部编译/仿真和 Vivado 在 Alan，版本分别为 Verilator 5.050、cocotb 2.1.0、Vivado 2022.2。最终远端快照与本地 601 个源码、脚本和测试文件逐项哈希相同。

完整检查 exit 0：26 个 cocotb suite 共 **141/141**，0 failure、0 skip、0 missing；加上 lint 和 33,554,432 次原生年龄比较，28/28 状态门通过。定向 FIFO/IFU/FTQ 检查另有 11/11 通过。DUT 没有 WIDTH、LATCH、UNOPTFLAT 警告。

- 原四条 F0/F1/队列测试保留。八条 F0 覆盖全部 34 种 16/32 位区域铺排、起点、出口、背压、跨区域、pending 优先级和 10,000 次串行参考对照。
- 四条/八条 F1 各 19 项；双项队列两种宽度各三项，含 1,200 拍随机完整 payload/mask/kill 对照。
- 通用、prefix 及 native FIFO 使用完整 payload 参考模型；FIFO 保留 1,800 拍随机流，另有 257 次强制代际复用，检查实际八位 generation 回卷、满队列、指针旋转、同时入出队和各种 kill。
- 真实 IFU 四项检查包括持续四条流、360 个混合长度区域随机背压、迟到 JAL 修正/部分 kill，以及 c-prime ownership、拼接异常和同步清空。
- FTQ 新增 35 次旧状态复用检查，跨队头回卷并拒绝旧 generation 的 slow/resolve/commit 回写。ICache 11 项含同 line MSHR 旁路、同 set 回填竞争、晚 PMP 改变和四拍无冲突命中。预取五项、HPM 19 项覆盖真实事件驱动及 CSR 选择。

原随机规模、断言和独立参考模型没有削弱。中间失败保留：四条 fixture 与新八条配置分离；C.NOP oracle 修为展开后的 RV64I NOP；新 HPM 测试发现旧范围判断屏蔽新增事件后修正 RTL；默认 F0 的 early-exit/pending 优先级由对照发现并修正。FIFO 第一次定向运行的功能对照通过，但固定 20 次复用不足以覆盖实际八位 generation，coverage assertion 失败；改为 `gen_mask+2`（257 次），保留回卷断言和 1,800 拍规模后通过。该失败没有被当成主机故障，其完整回归和 FPGA 流程未启动。

## 资源与时序

所有数据使用同一个完整前端 OOC wrapper、KU040 和 10 ns 约束。综合估计不代替实际布线。

| 综合指标 | 原四条版 `349d919` | 初次八条版 `4c43742` | 最终版 `be00de6` |
|---|---:|---:|---:|
| CLB LUT | 93,960 | 133,506 | 84,465 |
| FF | 52,875 | 56,438 | 47,698 |
| LUT as Memory | 2,368 | 2,368 | 3,712 |
| BRAM tiles | 93 | 93 | 93 |
| 估计 setup WNS | +1.483 ns | +1.794 ns | +1.794 ns |
| 最差逻辑层数 | 24 | 20 | 20 |

最终综合耗时 569 秒；相对原四条版 LUT 减少 9,495（10.11%）、FF 减少 5,177（9.79%）；相对初次八条版减少 49,041 LUT、8,740 FF。综合层次中，生产指令 buffer 为 5,432 LUT / 637 FF / 1,344 LUTRAM，双项队列为 10,150 LUT / 4,068 FF，FTQ 为 6,899 LUT / 2,044 FF。层次边界可能吸收邻接逻辑，不能把相邻模块单项数字当作独立电路成本。最终综合最差路径为 TAGE table 5 查询 BRAM 到 loop predictor speculative iteration CE。

最终完整布线 exit 0，耗时 902 秒：

| 布线指标 | 原四条版 `349d919` | 初次八条版 `4c43742` | 最终版 `be00de6` |
|---|---:|---:|---:|
| CLB LUT | 94,507 | 133,997 | 84,860 |
| FF | 52,898 | 56,455 | 47,696 |
| LUT as Memory | 2,356 | 2,352 | 3,702 |
| BRAM tiles | 93 | 93 | 93 |
| setup WNS | +0.004 ns | +0.003 ns | +0.239 ns |
| 内部寄存器路径 hold | +0.052 ns | +0.051 ns | +0.052 ns |
| 全局 hold WHS | −0.181 ns | −0.181 ns | −0.181 ns |

最终布线相对原四条版减少 9,647 LUT（10.21%）和 5,202 FF（9.83%）；相对初次八条版减少 49,137 LUT 和 8,759 FF。当前最差 setup 路径位于 TAGE：`t2_rows_q[5].useful` 到 table 3 的 `tvalid_q`，22 层、数据延迟 9.784 ns，其中连线 7.151 ns（73.09%）。这一版本没有通过增加查询或训练拍数取得时序通过。

全局 setup TNS=0、失败端点 0/169,443；内部报告分别使用原脚本的 `all_registers -output_pins` 到 `all_registers -data_pins` 查询。全局 hold THS=−2,340.123 ns、35,231 个失败端点，最差路径为外部 `exec_resolve_i.ftq_id.idx[0]` 到 FTQ `res_mem` LUTRAM 写地址，WHS=−0.181 ns。原零输入/输出延迟 OOC 模型仍报告“Timing constraints are not met”；本轮证明的是 100 MHz setup 和上述内部寄存器路径 hold 通过，不是包含这些外部边界的全局时序闭合。整核集成需使用实际相邻寄存器路径再检查。

109,860/109,860 个可布线 net 全部完成，routing error 为零；`check_timing` 的 12 个类别均为零，包括无时钟、未约束内部端点和组合环。DRC 没有 Error 或 Critical Warning，保留 CFGBVS-1（OOC 未配置板级电压）和 RTSTAT-10（虚拟接口等无 routable load）两项 Warning。

初次八条版 `4c43742` 完整布线 exit 0、setup WNS +0.003 ns、内部 hold +0.051 ns，但有零 I/O 延迟边界的外部 hold 违例；它仅作为中间版本证据。随后两次被最终结构取代的布线在 placement 阶段明确取消（exit 143）。

本轮没有整核负载 IPC、SoC 时序、bitstream 或板级证明。完整前端 OOC 外部零 I/O 延迟的 hold 边界与内部寄存器时序分别报告。

## 复现与证据

测量源码：`be00de6d54d973301236095cb6ca6b6c0c705b6a`。远端目录：`/home/chen/FUN/CISLC-O3-runs/frontend-throughput-20261011/r13-be00de6`；本地日志、XML、报告、退出码及文件哈希：`build/evidence/frontend-throughput-20261011/r13-be00de6/`。完整 checkpoints 留在远端，机器可读索引见 [证据索引](O3-frontend-throughput-evidence.json)。最终文档提交只改文档，源码/脚本/测试仍绑定测量版本。

```bash
source /home/chen/miniforge3/bin/activate cislc-o3
EVIDENCE_DIR="$PWD/evidence/checks" bash scripts/run-frontend-100m-checks.sh

source /home/chen/Tool/FPGA/Vivado/2022.2/settings64.sh
vivado -mode batch -source scripts/vivado/frontend_ooc.tcl \
  -tclargs "$PWD/evidence/synth"
vivado -mode batch -source scripts/vivado/frontend_route.tcl \
  -tclargs "$PWD/evidence/synth/frontend_synth.dcp" "$PWD/evidence/route"
```

器件 `xcku040-ffva1156-2-e`、时钟 10 ns、输入/输出延迟 0 ns；无 retiming、false path、multicycle 或放宽时钟。综合使用 `rtl/rtl.f` 的 common/frontend 文件和原完整前端 wrapper，定义 `FPGA_TARGET`。布线按原 `Explore`/`AggressiveExplore` 流程执行。
