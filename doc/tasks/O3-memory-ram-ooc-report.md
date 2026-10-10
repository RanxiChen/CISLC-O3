# 访存 RAM 映射与整核 OOC 修复

2026-10-08 用户要求同时修复，不再停留在方案讨论。分支 `fix/memory-ram-ooc-20261008`，起点 `59938310e8f09b270cc7e046d59307f13c522430`。本任务不修改冻结设计、容量、接口逐拍时序、黄金值与原有测试规模。T10 报告现有未提交修改属于此前工作，不纳入本修复提交。

## 改动与证据范围

- L2 directory：每 way 一个 packed 一维 RAM，单写口复用逐 set 初始化与运行更新，同步读保持 S0/S1/S2。
- L1D tag：每 lane/way 一个一维 LUTRAM；数据：每 bank/way 一个一维 BRAM，固定 byte enable。CPU 与 probe/WB 共用已有预约的 S0 读口，保持响应拍数；增加预约冲突断言。既有测试监视阵列只在非综合视图中保留。
- L2 AXI 行组装与 slot 更新：固定 beat/slot 切片加使能，去除动态位段写入形成的巨大选择/插入逻辑。原层级 LUT：u_mem 76171、u_slots 27478、L2 Home 自身21441；不能把全部125149 LUT都归因于meta。
- TAGE：遍历静态表范围，在循环体保留 first_longer 候选门控与原分配优先级。
- 诊断脚本与 boundary wrappers 复用 Alan OOC `42968c2`；增加 hold 最差路径和内部寄存器 hold 报告，无 false path/multicycle 豁免。
- 新增独立 byte oracle 的所有 word bank 边界掩码写/probe回读回归，以及TAGE每个provider/空候选集合定向回归。

## 原始 OOC

主机 Alan；证据 `/home/chen/FUN/20261008-ooc-42968c2/runs/`。三份相关 RTL 与本地起点 SHA256 一致。L2 no-retiming：125149 LUT、124575 FF、57 RAMB36、WNS +1.227 ns、WHS -0.143 ns、2516 hold endpoints。dcache rt：exit143/1445s；no-rt：exit124/2700s。整核 `/home/chen/FUN/20261008-ooc-02a88fe/runs/core_rt/`：TAGE Synth8-3380失败，exit1/97s。

## 开发检查

cloud_chen 首选SSH/环境成功，Verilator5.050/cocotb2.1.0。独立WIP目录 `/home/cloud_chen/work/20261008-o3-ram-fix-wip`，证据 `/home/cloud_chen/evidence/o3-ram-fix/wip`。首次传输缺CVFPU导致41个缺文件错误，补齐准确本地submodule内容后lint exit0/0 errors/357 warnings。这是WIP开发检查，尚不声明最终功能或映射通过。

## 最终验收

当前 RTL 提交为 `2e2b0fcf3e3a4906094f724157d9ef5ce20e666b`。memory 单元及 OOC 的执行提交为 `94ec4e27717b636a864f0b64cb3e3a881f1597fd`；相关 RAM/TAGE RTL、定向测试、OOC 约束与脚本 SHA256 在94ec4e27、499a8fb4、2e2b0fcf三提交相同，逐文件身份与实际执行记录见 [evidence.json](O3-memory-ram-ooc-evidence.json)。FPU 改动后重新执行 lint、FPU、TAGE 带断言及两种整核配置。随后ICache映射修正再次执行lint、ICache/前端同步及整核两配置。不得将组件证据冒充全部在最后提交重新执行。综合估计不等于布局布线/SoC/FPGA证据。

## 首轮结果与后续修正

源码候选 `baa4441be2197adcf4f0371b94653acc0e1e5187`：cloud_chen lint0/357 warnings；dcache MSHR4共49/49、MSHR1基础26/26、MSHR1 N2原子20/20；TAGE seed1/7/29各3/3；L2 12/12（含原随机规模）；pressure N3 MSHR1/4各3/3。其他门禁仍在运行，不能提前计入通过。

Alan首轮L2 OOC完成（201.5秒）。directory已识别为LUTRAM，不再展开FF，但block属性被Vivado拒绝。进一步将RAM读结果先作为完整packed word寄存，再在RAM过程外转换为struct；初始化/运行写地址与数据在外部统一，RAM内部只留一条写表达式。该修正不改变读写拍数或优先级，WIP整核lint再次exit0/357 warnings；随后在新准确SHA复验。

## 目录 BRAM 与整核首次复验

`94ec4e27717b636a864f0b64cb3e3a881f1597fd` 的 Alan L2 OOC exit0/215.5秒：24002 LUT（9.90%）、34264 FF、57 RAMB36+8 RAMB18（61 tiles），WNS+1.709ns。directory八个way各512×22明确推断为RAMB18，属性不再不可实现。全局WHS仍-0.143ns/2516边界输入违例；内部hold另有报告，不能宣称实现时序闭合。

该候选cloud_chen默认MEM_PIPES=2整核构建exit0/220.6秒，13项既有短程序全部exit0：smoke、dcache data/replay、branch-dense、predict、l8a mem、FP、priv、VM及四项L8b。VM保持17534周期/6434退休/tohost1；AMO42937周期/7802退休、MMIO4416/1245、拆分18941/7048、DMA12762/3346。未执行Spike/ACT4或修改黄金。

Alan整核首次复验已经越过TAGE，58.8秒后在`rtl/backend/fpu/fpu_fma_fu.sv:54`报Synth8-27：条件表达式中的数组assignment pattern缺赋值上下文。修为独立显式类型localparam，再用条件表达式选择它们；所有format流水级数与unit类型逐值保持。WIP lint exit0/357 warnings。此次只变FPU参数写法，L1D/L2/TAGE及其测试源码与94ec4e27逐字节相同；既有memory证据明确归于94ec4e27，不冒充后续候选新跑。随后复跑FPU定向、整核短程序与整核OOC。

## 完成的功能与映射验收

每个任务重新读取共享主机配置并进行 SSH/环境预检。cloud_chen 工作区 `/home/cloud_chen/work/20261008-o3-ram-fix-<sha8>`，证据 `/home/cloud_chen/evidence/o3-ram-fix/<sha8>/<job>`；Alan 工作区 `/home/chen/FUN/20261008-o3-ram-fix-<sha8>`，证据 `/home/chen/FUN/CISLC-O3-runs/o3-ram-fix/<sha8>/<scope>`。各准确命令、exit、规模、耗时记录在 evidence.json，远端保留 run.log/results.xml/status.txt；OOC 额外保留 DCP、资源层级、setup/hold、busy 路径与 RAM primitive 报告。CVFPU `1b220f3bc89df99e246b72e3574a3a533cf87653`，common_cells `6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea`。

| 执行 SHA | 门禁 | 结果 |
|---|---|---|
| 94ec4e27 | dcache MSHR4 基础及 N2、MSHR1 基础、MSHR1 N2 | 49/49、26/26、20/20，exit0；包含新增 byte-mask/bank/probe oracle |
| 94ec4e27 | L2 原有单元/随机 | 12/12，exit0 |
| 94ec4e27 | memsys 基础 pressure/default，MSHR4 | 各5/5，exit0 |
| 94ec4e27 | N3 pressure/default × MSHR1/4，RFO1 | 四组各3/3，exit0；原种子、CPU/DMA/I 规模及 Y11 保留 |
| 499a8fb4 | lint | exit0，0 errors / 357 warnings |
| 499a8fb4 | FPU seed1/7/29 | 各2/2，exit0 |
| 499a8fb4 | TAGE seed1/7/29，启用 --assert | 各3/3，exit0；每种 provider 起点与空候选集合均检查 |
| 499a8fb4 | MEM_PIPES=2 build + 13项整核程序 | 全部exit0；含原 M6 l8a_mem 严格参考检查 |
| 499a8fb4 | MEM_PIPES=1 build + 12项整核程序 | 全部exit0；原 M5 范围及 FP/priv/VM/L8b 回归 |
| 2e2b0fcf | lint、ICache三种子、frontend_sync_ctrl | exit0；ICache各4/4，sync 3/3 |
| 2e2b0fcf | MEM_PIPES=2 build + 13项整核程序 | 全部exit0，构建207.7秒 |
| 2e2b0fcf | MEM_PIPES=1 build + 12项整核程序 | 全部exit0，构建208.0秒 |

| Alan OOC，94ec4e27，无 retiming | LUT | FF | RAMB36 / RAMB18 | 综合秒数 | WNS / TNS ns |
|---|---:|---:|---:|---:|---:|
| L2 Home | 24002 | 34264 | 57 / 8 | 178.116 | +1.709 / 0 |
| dcache | 32600 | 19635 | 64 / 0 | 325.768 | -0.073 / -0.073 |

L2 LUT 相比125149减少80.8%；directory八way均为512×22 BRAM，数据阵列仍57 RAMB36。dcache 数据阵列64 RAMB36，tags LUTRAM；原262144寄存器展开与不可实现属性警告消失，综合不再卡到45分钟。

dcache 最差setup是PMP entry2.addr[28]边界寄存器到`internal_launch_q[0].permission.pmp_ok`，30级逻辑、10.097ns数据路径（逻辑2.925/估计布线7.172ns）。因此不声明100MHz时序通过。单模块`full_line_busy_o`与`internal_busy_o`到边界输出寄存器余量分别+7.605/+6.825ns；这两项不等于busy→LSU→IQ整核路径。

两模块内部寄存器间最差hold均+0.094ns；全局仍-0.143ns，L2/dcache分别2516/4116个外部端口到边界寄存器违例，来自零外部延迟的诊断约束。保留全部违例，需结合真实板级I/O约束与布局布线复核，不以“工具会自动修”判定已关闭。

## 保留的额外诊断与执行错误

额外将 **M6仅要求MEM_PIPES=2** 的`run-l8a-mem`用于MEM_PIPES=1，94ec4e27在cycles24037/retired3301无退休超时（exit2）。修改前59938310以相同编译参数/程序复跑，同样cycles24037/retired3301、writebacks514、MSHR_average1.630528（exit2）。这是修改前已存在且超出本次M5门禁范围的单访存压力问题，未关闭；不修改watchdog、参考值或程序以通过。

开发过程中曾用无效Verilator `-j4`参数，后改为`verilator -j 4`；TAGE补充断言的旧launcher使用默认共享XML路径，seed1/29取证cp失败，seed7日志为空，这轮不计验收。最终499a8fb4显式`sim`目标、独立build/XML路径、`EXTRA_ARGS='--timing -Wno-fatal --assert'`三种子重新运行，完整日志/XML均通过。首轮被后续源码取代的 OOC/重复编排器中止保留为取消记录，不计通过。

## 整核 OOC

499a8fb4 已越过 TAGE 与 FPU 语法阻塞，随后 worker 日志出现 `[Synth 8-5856] 3D RAM data_q_reg ... not supported`、`[Synth 8-11357] ...131072 registers`，对应ICache 16KiB数据阵列。执行917.7秒后由本任务主动取消（exit143），不计成功或超时；原工作区与日志保留。

2e2b0fcf将ICache data改为每bank/way一个packed一维RAM，同步读；在同一S0边沿锁存bank选择，S1停顿时一起保持，因此仍是原3拍命中响应。填充写条件仍为fill_done且无error；tag初始化/失效/组合查找行为保持。lint exit0/357 warnings，ICache seed1/7/29各4/4（已有逐拍3周期检查、bank交错、fill冲突、PMP/失效等），frontend_sync_ctrl 3/3。

2e2b0fcf的cloud_chen两种整核配置复验均通过。用户随后要求停止并整理时序问题；Alan整核OOC在796.7秒时按用户要求终止（exit143），证据根保留cancellation.txt、运行日志和未完成的synth_status.txt，不计综合成功、工具超时或时序失败。尚无整核资源及busy→LSU→IQ路径结论；未启动后续RTL改造。

## 暂停时的时序清单

时钟100MHz（10ns），均为Alan Vivado2022.2综合估计、无retiming，尚未布局布线。模块OOC执行SHA94ec4e27；相关RTL与当前2e2b0fcf一致。

| 项目 | 已测结果 | 当前判定 |
|---|---|---|
| L1D setup：PMP entry2.addr[28]→internal_launch_q[0].permission.pmp_ok | WNS/TNS均-0.073ns，1个失败endpoint；30级逻辑，数据路径10.097ns | 未过，需优化PMP组合路径并复验 |
| L2 setup | WNS+1.709ns，TNS0 | 本次综合估计通过 |
| L1D全局hold | WHS-0.143ns，4116个失败endpoint | 未关闭；零外部延迟下外部端口→边界寄存器 |
| L2全局hold | WHS-0.143ns，2516个失败endpoint | 未关闭；同类边界约束问题 |
| L1D/L2内部寄存器hold | 最差均+0.094ns | 本次综合估计通过 |
| L1D full_line_busy/internal_busy→wrapper输出寄存器 | 分别+7.605/+6.825ns | 单模块输出段通过，不能代替跨模块路径 |
| busy→LSU→Memory IQ | 整核OOC未完成 | 未测到，不计通过或已确认违例 |
| 整核全局setup/hold及真实布局布线 | 未取得报告/未执行 | 未关闭 |

TAGE/BTB的寄存器展开是已发现的映射/面积风险，不能称作已测出的时序违例；其时序数字尚未取得。TAGE静态循环与FPU赋值上下文报错已修，但综合语法修复不等于整核时序通过。

## 当前阶段

核心已有前端、重命名/ROB/发射/退休、整数与浮点、特权/Sv39，以及 coherent L1D/L2、原子、MMIO、拆分访存和DMA通路。本次是既有访存功能的RAM映射与整核综合收尾；L8b最终同SHA总门禁仍受T10报告自己的acceptance要求约束，不由本修复代替。L11a规格已冻结，SoC/DDR/中断/SD与Linux/FPGA集成尚未开始。不能把这些定向回归当成全RV64GC/Spike/ACT4/Linux/上板验收。
