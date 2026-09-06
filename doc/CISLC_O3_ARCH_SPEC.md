# CISLC-O3 架构规格 v1.0

> 最后更新: 2026-09-06
> 状态: 架构目标与当前实现边界并列记录

## 1. 定位

**协处理器计算引擎。** 不作为独立 SoC 主控，设计目标是被宿主机或加速器通过共享内存/专用接口驱动。
M-mode only，无 MMU，物理地址直通。后期增加协处理器通信机制。

## 2. ISA

| 扩展 | 状态 |
|---|---|
| RV64I | 🔧 U/R/I/word、Load/Store、branch/jump已接入；FENCE、ECALL/EBREAK待实现 |
| RV64M (乘除) | 🔧 文件存在，未接入主流水线 |
| RV64A (原子) | ❌ 待实现（LR/SC + AMO） |
| F/D (浮点) | ❌ 不在当前规划 |
| C (压缩指令) | ❌ 不在当前规划 |

## 3. 流水线参数

```
┌───────────────────────────────────────────────────────────┐
│ 前端                                                        │
│   Fetch Width              4 lanes/拍                      │
│   ICache                   4-way set-associative, 64B line │
│   Fetch Window             16B                              │
│   FTQ entries              16                               │
│   BPU                      顺序预测 (pred not-taken)         │
├───────────────────────────────────────────────────────────┤
│ 后端                                                        │
│   Machine Width            4 lanes/拍 (decode + rename)     │
│   Decode Queue             16 条 uop                         │
│   Issue Queue              16 条目, 统一整数 issue queue     │
│   Issue Width              Int 4 / Mem 1 / Branch 1         │
│   ALU Pipelines            4 × int ALU + 1 × branch         │
│   Mul/Div                  待接入                             │
│   PRF                      96 物理寄存器 (32 架构)            │
│   ROB                      64 条目                           │
│   Retire Width             4 uop/拍                          │
│   Checkpoint               4 个                              │
├───────────────────────────────────────────────────────────┤
│ 存储系统                                                     │
│   ITCM                     64 KiB @ 0x10000000               │
│   DTCM                     256 KiB @ 0x11000000              │
│   I-Cache                  4-way, 64B line, 单端口           │
│   外部仿真内存              统一C++稀疏memory，固定延迟         │
│   D-Cache                  待实现                            │
│   LSQ                      LQ 8 + SQ 8 分配/恢复骨架         │
│   Store→Load forwarding    单个最年轻完整覆盖Store            │
│   内存序                    FENCE尚未实现                      │
├───────────────────────────────────────────────────────────┤
│ 特权架构                                                     │
│   M-mode only              ✅ (当前未接入 CSR)               │
│   S/U-mode                 不需要                             │
│   MMU                      无 (物理地址直通)                  │
│   PMP                      待定                               │
│   中断                     待定 (至少需要 timer + software)   │
│   异常                     待定 (至少需要 illegal inst + ecall)│
└───────────────────────────────────────────────────────────┘
```

取指窗口完整落在ITCM时固定一拍返回，其他取指通过blocking ICache refill访问外部
memory。数据访问完整落在DTCM时使用本地单端口SRAM，否则整笔通过LSU外部接口访问
同一份软件memory。跨TCM边界不拆分。该接口后续可以替换为AXI/DCache；当前不支持
自修改代码、PMA、MMU、访问异常或多个Load outstanding。

## 4. 流水线级数

```
  Frontend (多拍) → fetch_entry_q → Decode (组合) → uop_queue (16 entries)
  → Rename → Rename/Dispatch Queue → 三类Issue Queue
  → alu_issue_q (1拍) → alu_regread_q (1拍) → alu_result_q (1拍)
  → Writeback (组合) → ROB Retire (组合)
```

整数 ALU 最小延迟（从 issue 到 writeback）: **3 拍**。
非 store 指令 retire 在 writeback 后取决于 ROB 队列位置。

## 5. 流水线各级宽度

| 级 | 宽度 | 结构 |
|---|---|---|
| Fetch | 4 | frontend 输出 |
| Decode | 4 | 4 lanes 并行组合解码 |
| Decode→Rename buffer | 16条uop | 4-bank紧凑Decode Queue |
| Rename | 0～4 | 最老连续前缀，联合Map/Free List/ROB/LQ/SQ/checkpoint/RDQ分配 |
| Dispatch | 0～4 | RDQ最老连续前缀，分流到Integer/Memory/Branch IQ |
| Issue | Int 4 / Mem 1 / Branch 1 | 三类IQ共同竞争8个PRF读口；Branch单发射 |
| RegRead | 4 | 4个Issue Register使用8个逻辑PRF读口 |
| Execute | 4 | 4个完全流水化整数ALU；其他FU未接入 |
| Writeback | 4 | 4路整数结果写PRF、广播preg并置ROB complete |
| Retire | 4 | ROB head连续complete前缀 |

### 5.1 Lane 有效性、年龄顺序与压紧规则

- 每个 lane 必须带有独立的 `valid` 位；`valid=0` 的 lane 不表示架构指令，不得申请物理寄存器、ROB 或 IQ entry。
- 同一批中 lane 编号定义原始程序顺序：`lane0` 最老，lane 编号越大越年轻。
- 流水级和队列交界使用 packed bundle：所有有效 uop 必须按原始程序顺序连续放在前部，所有无效 lane 连续放在尾部，不允许有效 lane 之间留洞。
- 压紧只改变 uop 的内部 lane 位置，不得改变指令年龄顺序。对输入 lane `i`，其压紧后位置等于它之前有效 lane 的数量。
- 部分出队时只允许发送队头最老的连续前缀；不允许跳过被阻塞的老 uop 而先派发年轻 uop。
- Illegal instruction、指令访问异常或尚未实现的合法指令不得用 `valid=0` 丢弃；它们仍是有效架构指令，后续应通过 ROB/Commit 表达异常或未实现语义。

packed bundle 的合法形态只能是有效前缀加无效后缀，例如：

```text
[A, B, C, D]
[A, B, C, -]
[A, B, -, -]
[A, -, -, -]
[-, -, -, -]
```

`[A, -, B, C]` 等中间带洞的形态不得作为下一级的合法输入。

### 5.2 Rename 阶段合同（当前 R 型整数范围）

Rename 是按原始指令顺序建立推测物理寄存器状态和 ROB 顺序的阶段。对一个 packed bundle，`lane0` 最老，各有效 lane 按顺序完成：

1. 从 speculative Rename Map 读取 `rs1/rs2` 的物理寄存器标签。
2. 对真实写 `rd!=x0` 的指令，从 Free List 分配 `new_dst_preg`，并记录当前映射为 `old_dst_preg`。
3. 对每条有效架构指令申请 ROB entry；是否写通用寄存器不影响其 ROB 顺序位置。
4. 在同一 bundle 内按 lane 年龄做映射旁路：年轻 lane 必须看到最近的更老 lane 刚分配的新目的 preg，覆盖 RAW 和 WAW/`old_dst_preg` 链。
5. 新分配的目的 preg 在 Rename 成功时置为 not-ready；同批年轻消费者的初始源 ready 也必须为 0。
6. 组装 renamed uop，携带 `rob_idx/src*_preg/dst_preg/old_dst_preg` 和执行语义送往 Rename→Dispatch Buffer。

Rename 采用原子推进语义：只有 Free List、ROB 和下游 Buffer 都能接收当前有效前缀时，才允许 `rename_fire`；否则 Rename Map、Free List、ROB 和 Busy/Ready 状态都不得部分更新。`x0` 始终映射到 `p0`，不分配新 preg，`p0` 始终 ready。

当前Rename不负责Dispatch选择、Wakeup/Select、PRF读取、Execute、Writeback和Commit选择。Rename为Load/Store分配LQ/SQ位置，并实现4槽分支checkpoint、完整Map快照、96位分支allocation mask和后端恢复合同；LSU、单发射BRU及Frontend redirect均已接入。

整数`OP-IMM`与R型计算共用Integer IQ和4路IEW。立即数指令只等待`rs1`，I型12位立即数在RegRead符号扩展为64位并独立保存，由ALU输入选择器使用；RV64移位立即数按`funct6 + shamt[5:0]`解码，因此支持0～63位移。

### 5.3 Dispatch阶段合同

Dispatch从Rename/Dispatch Queue队头查看最多4条uop，按年龄累计Integer、Memory和Branch IQ容量，只接受最大连续前缀。前缀内部可以同拍进入不同IQ，但不允许年轻uop绕过目标IQ已满的老uop。三个IQ深度当前分别为16、8、4；均保存完整renamed uop并维护preg ready与branch mask，且已分别接入ALU、LSU和BRU。

## 6. Wakeup / Bypass

- Wakeup: **next-cycle only**（本拍写回的结果下一拍才对 IQ 可见）
- 无同拍旁路（bypass network）
- MCU 频率目标下不构成瓶颈

## 7. 实现路线图

| Phase | 内容 | 验证 |
|---|---|---|
| ✅ Phase 0 | 前端 + 整数后端最小链路 | single_addi, three_alu 系列 |
| ✅ Phase 1 | 后端Branch checkpoint / rollback合同 | 当前整核redirect路径已接入 |
| ✅ Phase 1.25 | 有序可变前缀Dispatch + 三类IQ | ALU/LSU/BRU执行端口已接入 |
| ✅ Phase 1.5 | BRU与Frontend redirect接入 | taken BEQ/JAL定向回归 |
| 🎯 Phase 2 | D-Cache 模块 | 独立 testbench (read/write hit/miss/refill) |
| 🔧 Phase 3 | LQ/SQ分配与恢复骨架已建，补真实LSU字段 | 全局重构后统一验证 |
| 🎯 Phase 4 | LSQ + D-Cache 集成到 backend | sw/lw smoke test |
| 🎯 Phase 5 | M-mode CSR + 异常 + 中断 | ecall/illegal 测试 |
| 🎯 Phase 6 | RV64M 接入 + RV64A LR/SC/AMO | ISA 测试套件 |
| 📋 Phase 7 | 协处理器通信接口 | TBD |
| 📋 Phase 8 | Store→Load forwarding | 性能回归 |
