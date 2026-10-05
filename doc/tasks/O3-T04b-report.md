# O3-T04b：整核综合打通——定位报告

日期：2026-10-06。检查源码：`6b95a7d93ac2e002aad42d0d85a4296e1f9d68f0`，
分支 `feat/L1-closure`。本任务插入 L6 与 L7 之间，原时限一天。

**状态：定位完成，改造暂停；整核 OOC 基线未取得，不能作为进入 L7 的完成门禁。**
用户在发现接口时序冲突后明确选择：
“必须保持逐拍接口时序；先提交定位报告，暂停冲突部分改造”。
本次只修改文档，没有修改 RTL、容量、替换策略、并发机制或流水时序，没有开始 L7。

## 1. 已确认的阻塞点

### L1D tag：接纳前必须知道命中结果

`rtl/lsu/dcache.sv:222–226` 对当前输入地址组合读 `tag_q`，得到 `input_hit`；
`:252–259` 用 `(mstate_q == M_IDLE || input_hit)` 决定当拍 load/store 的 ready。
这是“一个 miss 在途时仍接纳已驻留 hit，但第二个 miss 留在 S0 之前”的现有合同，
不是仅用于生成下一拍响应的 tag 查询。

| 时刻 | 当前实现 | 直接替换为同步 BRAM |
| --- | --- | --- |
| N，已有无关 miss 在途 | 上游首次给出地址 A；若 A 命中且其余条件允许，当拍 ready=1 | 尚无 A 的 tag 读结果，不能保持同一个 ready 判定 |
| N 上升沿 | 接纳 A，读取 data，并锁存 tag 命中位 | 才能采样 A 的 tag 地址 |
| N+1 | 处理已接纳的 hit，随后返回结果 | 现在才知道能否接纳 A，接纳拍已变化 |

输入接口没有地址提前一拍有效的合同；valid/ready 要求等待期间保持请求，
不保证首次 valid 之前地址已经可用。仅把 tag 比较移到现有 data 返回拍，不能保留
MSHR 忙时的接纳行为。无条件接纳一个待查请求还会改变“第二个 miss 不占查询级，
维护探测能取得端口”的条件，不在此次授权范围内。

此外，`:270–278` 的 probe tag 查询在探测握手边沿确定命中 way，
`:378–389` 同沿失效并记录 dirty/way；下一拍返回与同步 data 读结果匹配的应答。
`:435` 还组合读 victim tag 形成写回地址。不能只替换需求查询而遗漏这些用途。

### L2 tag：写回错误是握手当拍结果

`rtl/memory/l2_cache.sv:225–234` 对 `l1d_wb_line_paddr_i` 组合查询 tag：
`l1d_wb_ready_o = (state_q == S_IDLE)`，
`l1d_wb_error_o = valid && ready && !wb_hit`。
`:318–327` 在同一握手边沿写 data/dirty 或记录 inclusion error。
L1D 在 `rtl/lsu/dcache.sv:449–457` 的写回握手边沿消费 error。

例如 L2 空闲时，上游首次给出不存在的行地址 B：边沿前 ready=1、error=1；
边沿后 inclusion error 已记录，L1D 已进入 fatal 路径。
同步 BRAM 必须到该边沿后才能给出 B 的 tag，因而不能保持这份逐拍合同。
已有 `sim/cocotb/l2_cache/test_l2_cache.py` 的
`orphan_l1d_writeback_raises_inclusion_error` 明确在首个握手边沿前检查 ready/error。

需求路径也在 `:209–222`、`:329–353` 于接纳边沿决定 hit/victim，下一拍直接进入
响应、recall 或 AXI AR 状态。改造时必须逐项核对首次输出拍、反压和连续 beat；
不能简单增加 LOOKUP 状态而宣称接口时序不变。

### 为什么 flatten / 属性 / retiming 不能消除合同冲突

按 way 分 bank、把存储声明改为一维 word 数组可以消除不支持的多维表达，
但仍需同步读才能推断 BRAM。`ram_style="block"` 和 `-retiming` 不能让 BRAM
在首次地址到达、尚未经过时钟边沿时返回 tag。
保留组合 tag 的 LUTRAM/寄存器副本可服务这两处接口，却不满足“所有大阵列改为 BRAM”
的原要求；未擅自采用这个例外。

## 2. 缓存与其他大阵列检查

以下是源码逻辑容量，不是综合后的 LUT/FF/BRAM 资源。配置来自 `O3_CFG`，物理地址 56 位。
valid/dirty/替换控制位与数据存储分开检查；现有 BRAM 写法也不等于已取得整核映射报告。

| 阵列 | 逻辑位数 / 规模 | 当前写法与结论 |
| --- | --- | --- |
| ICache data | 64 sets × 4 ways × 512 = 131,072 bit | 已按 2 bank × 4 way 实例化 `o3_sram_1r1w`；每实例 128 × 128，同步读，无需先改读延迟 |
| ICache demand tag | 64 × 4 × 44 = 11,264 bit | 已按 bank/way 使用 `o3_sram_1r1w`；每实例 32 × 44，同步读 |
| ICache maintenance tag shadow | 11,264 bit | `tag_shadow_q[BANKS][WAYS][SETS_PER_BANK]`，组合查询供 recall；原日志明确警告展开。不能因 demand tag 已有 SRAM 就漏掉这份副本；复用同步 tag 口时需审查失效生效边沿、应答及紧随的需求请求 |
| L1D data | 64 × 4 × 512 = 131,072 bit | 已按 4 word bank × 4 way 使用 `o3_sram_1r1w`；每实例 64 × 128，同步读，store 使用整 bank 的合并数据写入 |
| L1D tag | 64 × 4 × 44 = 11,264 bit | packed tag word + set/way unpacked 数组；Vivado 称为 3D RAM；组合查询，存在第 1 节硬冲突 |
| L2 data | 256 × 4 × 512 = 524,288 bit | set/way 数组；需求响应与 AXI W 组合读，回填按 128-bit beat 写、L1D 写回及 dirty probe 整行写。需 way/beat 分 bank 或字节/分段写使能，以及持有/预读输出；不能忽略最后回填拍后的首个响应与读写同址 |
| L2 tag | 256 × 4 × 42 = 43,008 bit | set/way 数组，组合需求/写回查询；存在第 1 节硬冲突 |
| DTCM `simple_data_sram.mem_q` | 256 KiB = 2,097,152 bit | byte 数组，8-byte 非对齐 load/store/init 动态索引；已连接 LSU，原日志有 RAM 推断硬错误。可研究 8 个 byte bank、旋转索引和同步读，保持既有一拍 load；必须保留窗口边界、写掩码、初始化优先级及响应反压，不能删除/缩容来绕过 |
| ROB `meta_q` 等 | 64 项宽提交元数据；单个 PC/data 字段各 4,096 bit | 多路分配、组合队头/退休读取及异常/后继 PC 局部更新；日志明确 struct RAM 展开。直接 SRAM 化需重新处理多端口和读取时序，本轮未授权机制改造 |
| Decode Queue、RDQ、INT/MEM/BR IQ | 16 项 decoded/renamed uop，IQ 深度 16/12/8；宽载荷均超过约 4 Kbit | Decode Queue 已有 bank 划分但组合展示队头；RDQ/IQ 每拍压紧、并行选择/取消/唤醒/改写。它们不是一读一写 SRAM；仅强加 BRAM 属性或更换类型不能保留行为 |
| FTQ、fetch buffer | 32/16 项宽前端载荷，均超过约 4 Kbit | FTQ 整表 next-state 与多方更新，fetch buffer 多条组合交付；需按端口/载荷拆分审查。原 FTQ 日志有 struct RAM 展开；本次没有将这些控制阵列自动豁免 |
| 取指返回队列 | 配置目标 8 项，当前实际单槽实现 | `fetch_return_queue.sv` 当前没有 8 项存储阵列；保持单槽现状，不为容量目标扩展功能 |
| 历史快照存储 | 32 × (1,024 events + 132 folds) = 36,992 bit | 两个同步读与一个写，且有同拍写入旁路/owner 校验；适合另行审查双副本 BRAM。当前 BPU 的快照输出恒零，实际可能被优化，需综合结果确认 |
| uBTB/main BTB/TAGE/RAS | main BTB、TAGE 表超过阈值；TAGE base 为 12,288 bit，六张 tagged 表共 37,632 bit | 当前 `bpu.sv` 不实例化这些表；不是本次整核 OOC 的实体资源。记录大表候选，未接入、未推进 L7；RAS 16 × 64 = 1,024 bit |
| RAT/free-list checkpoint | RAT 16 × 32 × 7 = 3,584 bit；free-list 16 × 96 = 1,536 bit | 单独阵列低于约 4 Kbit，但具有整行快照/恢复/并行更新；记录检查结果，保持现状 |
| PRF | 96 × 64 原始容量及现有 FPGA bank/复制 | 按任务明确例外保留现有设计；不把其原日志的 3D RAM 识别提示混同为其他缓存的警告 |

`o3_sram.sv` 与 `o3_sram_1r1w.sv` 本身都是一维 word 数组、同步读。
后者要求调用方排除同址读写。新 byte/beat bank 必须继续维护这个合同，或明确实现并验证
读写冲突处理；本轮没有扩展公共 SRAM。

## 3. 原 OOC 证据复核：另有 DTCM 硬错误

本次只读复核 Alan 的原始文件，未重跑综合。
证据目录：`/home/chen/FUN/CISLC-O3-runs/20261006-l6-ooc-67ec91c/`。
`sha.txt` 为 `67ec91c1c012be2eb0c44bce7eaf55d360d07059`；
`status.txt` 为 `exit=139 elapsed_seconds=812`。

Vivado 2022.2，XCKU040-FFVA1156-2-E，10 ns，
`synth_design -mode out_of_context -flatten_hierarchy rebuilt -retiming`。

- `vivado.log:2911`：`[Synth 8-3391]`，DTCM `mem_q_reg` 无法推断 block/distributed RAM，
  2,097,152 位超过展开限制。这是三项缓存告警之外的独立综合阻塞。
- `vivado.log:3018–3019`：ICache `tag_shadow_q_reg` 不支持的 3D RAM，11,264 位警告。
- `vivado.log:3178–3186`：L1D tag 11,264 位、L2 data 524,288 位、L2 tag 43,008 位
  不支持的 3D RAM / 潜在运行问题警告。
- `hs_err_pid1882256.log:5–10`：SIGSEGV 栈经过 `librdi_synth.so` 的
  `NRealMod::dfGraph` 和 `HARTNDb::processParallelDFGOptPass1`。
  告警先于崩溃，但尚无单独 L2 复现、工具版本对照或 retiming 对照，不能认定因果。

本次检查 `/home/chen/Tool/FPGA/Vivado/` 只发现 `2022.2`；其他路径是否另装版本未全面确认。
未安装/切换版本，也未提高 `dissolveMemorySizeLimit` 来强行展开 2 Mbit DTCM。

| 结果项 | 原 T04 整核 OOC | 本轮 T04b |
| --- | --- | --- |
| 墙钟 | 812 s，exit 139 | 未运行 |
| LUT / FF / BRAM / DSP | 未取得 | 未取得 |
| WNS | 未取得 | 未取得 |
| 最差路径起点 / 终点 | 未取得 | 未取得 |
| DCP / utilization / timing | 未生成 | 未生成 |

MUL/DIV 局部结果仍仅代表局部，不能填入整核基线。

## 4. 验证与后续门禁

本次未改 cache，因此没有运行新的 cocotb、整核 smoke 或 OOC；旧 T04 PASS 不能当作
BRAM 改造后的证据。文档改动执行 `git diff --check`，并核对源码引用与原日志。

恢复改造前需解决两个要求之间的冲突：所有大存储使用同步 BRAM，与首次输入当拍的
组合 tag 判定。当前决定是保留逐拍接口，暂停冲突改造；未自行允许 LUTRAM/tag 副本例外。
若今后授权可保持接口的具体方案，仍需：

1. 逐 cache 修改并运行现有 `sim/cocotb/{icache,dcache,l2_cache}` 和整核 `run-smoke`；
   L1D/L2 修改还需检查现有数据、replay、dirty handoff/容量回收和写回错误路径。
2. 一并处理 DTCM 映射硬错误，保留容量及现有 load/store/init 语义；逐项记录其他
   超过约 4 Kbit 阵列的映射、优化掉的字段，以及任何需用户决定的端口/时序冲突。
3. 在确切 RTL SHA 上重跑整核 OOC，保存耗时、资源、WNS、最差路径两端和报告。
   若仍崩溃，先做 L2 独立 OOC，再对照关闭 retiming / 可用 Vivado 版本。
   成功结果必须区分综合估计与布局布线时序；未设端口延迟的 OOC 不能证明完整接口时序。

T04b 尚未完成整核综合打通；L7 保持未开始。
