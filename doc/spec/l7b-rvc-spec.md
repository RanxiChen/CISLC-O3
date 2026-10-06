# O3-T06：L7b RVC 压缩指令 RTL spec（草稿）

日期：2026-10-06。分支：`feat/L1-closure`。审计快照：`f9f8cc2`（L7a T05b 完成后）。行号均指该快照。

依据：[v1 计划](../O3-v1-plan.md) 第 3 节 L7b；[前端基线](../design/CISLC-O3-FRONTEND-DESIGN-BASELINE.md) D33～D35（第 17.4～17.6 节）；
[L7a spec](l7a-predictor-spec.md)（U1～U24，L7b 在其完成后实施，下文“L7a x.y”指该文件章节）。

**前提：** L7a（T05a～T05d）全部完成后开始。本 spec 只写与 L7a 不同或新增的部分；未提到的行为沿用 L7a。
**验证原则（用户 2026-10-06）：先完成后完美。** 每个新行为一个简单定向用例即可；完整测试在 FPGA 上进行。

---

## 0. 任务书

```
目标：L7b —— 支持 RV64C（整数部分）：F0 长度识别、RVC 展开、跨块 edge 指令（D33）、
      跨页后半字异常（D34）、F0/F1 每拍 4 条（D35）；预测器启用 cfi_is_rvc / is_edge；
      后端改为 IALIGN=16。
涉及模块（允许改动）：
  rtl/frontend/{ifu_f0,ifu_f1,bpu,bpu_slow_check,ftq,ubtb,main_btb,frontend}.sv，
  新增 rtl/frontend/rvc_expander.sv
  rtl/common/{o3_cfg_pkg,o3_types_pkg}.sv
  rtl/backend/{branch_execute_unit,rob,backend}.sv，rtl/system/csr_file.sv
  rtl/rtl.f；对应 sim/cocotb/*；sim/o3/tests 新增程序与 Makefile 目标
不做：第 7 节
验收：第 8 节
```

## 1. 现状（源码核实）

| 位置 | 现状 | L7b 要做 |
| --- | --- | --- |
| `ifu_f0.sv:70–106` | 组合直通，IALIGN=32：只认偶相位 32 位指令，短编码按非法指令交付 | 第 2 节重写 |
| `ifu_f1.sv` | L7a 预解码按 `pc+4` | 第 3 节：改按指令长度 |
| `bpu.sv:108`、`bpu_slow_check.sv:95` | RAS push 地址写死 `+4` | 第 4 节 |
| `ubtb.sv`、`main_btb.sv` | T05a 训练时把 `cfi_is_rvc`/`is_edge` 强制写 0 | 第 4 节：存训练值 |
| `ftq.sv:397–407` | 区域只在自身 `region_last` 提交时完成 | 第 4.3 节：空区域 |
| `branch_execute_unit.sv:67` | taken 目标 bit1 报 IALIGN=32 异常 | 删除（5） |
| `rob.sv:317,323` | `inst_len` 写死 4，`succ_pc = pc+4` | 改用指令实际长度（5） |
| `csr_file.sv:75,135` | `misa` = RV64IM；`mepc` 写入与 trap 清低 2 位 | 第 5 节 |
| Flow `AirRvcDecompressor.scala` | 完整 RV64C 整数解压器，浮点 RVC 与保留编码判非法 | 手工翻译为 `rvc_expander.sv`（2.2） |

`f0_inst_t.ftq_id` 注释写“归属起始半字所在区域”，与 D33 冲突，以 D33 为准，改注释。

## 2. F0（`ifu_f0.sv`）

### 2.1 配置与状态

- `O3_CFG.fe.fetch.f0_slots` 改为 **4**，含义改为“F0 每拍最多输出 4 条指令”（D35）；`out_o[0..3]` 为按程序顺序压紧的指令，不再按槽位输出。`f1_width` 保持 4。
- F0 由组合直通改为带状态：
  - `hold_q`：当前块没处理完（多于 4 条）时保留块数据、brief 与下一个待处理槽位 `pos_q`。块处理完那一拍才 `in_ready_o=1`。
  - `pend_q`：edge 前半字暂存：`valid`、16 位数据、存入时所在块的身份 `(ftq_id, slot=7)` 与 `region_base`。

### 2.2 RVC 展开（`rvc_expander.sv`）

- 手工翻译 Flow `~/flow-mem` 提交 `02e3f6fd2219186c9ddbe7cc7dd3e486ae9709f6` 的 `design/src/main/scala/air/AirRvcDecompressor.scala`（238 行）：输入 16 位，输出 32 位 `out` 与 `legal`。纯组合，F0 每条输出 lane 各一份（共 4 份）。
- 浮点 RVC（C.FLD/C.FSD/C.FLDSP/C.FSDSP）与保留编码按原实现判非法；L9 加 F/D 时再放开（记入 L9）。
- 非法：该项 `exc_valid=1`、`cause=ILLEGAL_INSTRUCTION`、`tval` = 16 位原编码（与现有短编码处理相同）。

### 2.3 长度识别与输出

处理一个块（本块区域基址记为 B，`entry = brief.pred.entry_slot`；`pend_q` 来自上一区域 R，顺序时 `B = R+16`）时：

1. 起点：若 `pend_q.valid` 且本块 `region_base == pend_q.region_base + 16` 且 `entry == 0`，先输出 **edge 指令**：`pc = B − 2`，`instruction = {slot0 半字, pend 半字}`，`inst_len=4`，`is_rvc=0`，`ftq_id` = 本块，`slot=0`，新增字段 `is_edge=1`；随后从槽 1 继续，`pend_q` 清除。否则从 `entry` 开始；若 `pend_q.valid` 但条件不满足，丢弃 `pend_q`（不输出）。
2. 在槽 `s`：低 2 位 `!= 2'b11` → 16 位指令，展开，`inst_len=2`，`is_rvc=1`，下一槽 `s+1`。否则 32 位：`s <= 6` 时取 `s, s+1` 两个半字，`inst_len=4`，下一槽 `s+2`；`s == 7` 时把该半字存入 `pend_q`（身份为本块 `(ftq_id, 7)`、`region_base = B`），本块结束（这条指令属于下一区域，D33）。
3. 结束条件（先到者）：处理完槽 7；或已输出覆盖预测出口槽的指令（`pred.cfi_valid` 且指令覆盖 `pred.cfi_slot`，edge 指令只在 `pred.is_edge=1 && pred.cfi_slot==0` 时算覆盖）；或遇到异常项（L7a U20）。
4. 每拍最多输出 4 条；本块剩余部分记入 `hold_q`，下一拍继续（D35）。块的最后一拍（无剩余）标记 `out_last_o=1`，供 F1 生成 `ftq_last`。
5. 本块结束于“槽 7 存入 `pend_q`”时，最后一拍额外置 `out_edge_pend_o=1`（F1 用于 3.2 的 c′）。
6. 一块可能一条指令都不输出（入口槽 7 且为 32 位起点）：F0 仍完成一次 F1 握手（4 条 lane 全无效、`out_last_o=1`、`out_edge_pend_o=1`），F1 照常判定 c′；fetch buffer 不写入任何项。

### 2.4 异常

- 整块取指异常（`in_i.exc_valid`）：只输出一项，`pc` = 起点指令 PC（edge 起点时为 `B−2`），`exc_valid=1`，`inst_len=0`，本块结束；`pend_q` 清除。
- **D34 跨页后半字异常**：起点为 edge 指令且本块 `exc_valid` 时，该项 `pc = B−2`（epc），`tval = B`（本块区域基址），`is_edge=1`。

### 2.5 kill 与同步

- kill 拍阻塞握手（同 L7a）。时钟沿上：`hold_q` 若 `fe_killed_by(kill, hold.ftq_id, pos_q, head)` 为真则清除；`pend_q` 若 `fe_killed_by(kill, pend.ftq_id, 7, head)` 为真则清除。`sync_clear_i` 两者都清。
- 因 kill 拍阻塞握手，F1 发出的修正（寄存一拍）到达前，F0 不会消费下一块，`pend_q` 不会被提前丢弃。

## 3. F1（`ifu_f1.sv`）

### 3.1 按长度推广 L7a 第 4 节

- 输入改为 F0 压紧后的 4 条；每条带 `inst_len`、`is_edge`。L7a 4.2 判定所用指令为 **展开后的 32 位指令**（x1/x5 规则不变；C.JR/C.JALR 展开为 JALR，C.J 为 JAL x0，C.BEQZ/BNEZ 为 BR）。
- L7a 4.2 中所有 `pc_i + 4` 改为 `pc_i + len_i`（c、d 的顺序越过目标，`ras_push_addr`）。
- “指令位置”为 `(slot, is_edge)`；edge 指令位置为 `(0, 1)`。预测出口位置为 `(pred.cfi_slot, pred.is_edge)`。L7a 4.2 的“出口指令”“覆盖出口槽”按位置比较：预测出口为 `(0,1)` 但本块没有 edge 指令，或预测出口为 `(0,0)` 但槽 0 是 edge 后半字，都属于 c（假 CFI）。
- e、f 的 RAS 比较扩展：`ras_i` 含 push 时，`pred.cfi_is_rvc != is_rvc_i` 也算不一致（push 地址不同）。
- `ftq_last`：F0 `out_last_o` 那一拍的最后一条交付项；截断或异常时按 L7a U20。

### 3.2 新增 c′：预测出口在 edge 前半字

- 本节 R 为当前块的区域基址。条件：`pred.cfi_valid && pred.cfi_slot == 7 && !pred.is_edge` 且 F0 本块 `out_edge_pend_o=1`（槽 7 是下一区域 edge 指令的前半字，不是本区域出口）。
- 修正：`slot=7`，`kill_self=0`，`target_pc = R+16`（顺序），`ras_fix=NONE`，`hist_inject=0`，`pred_taken` 不修改任何交付项（本块交付项都在槽 7 之前，原本就是 `pred_taken=0`）。
- 优先级：只在本块其他指令都不触发 a～f 时生效（它位于块末）。
- 边界 `(R,7)` 不杀 `pend_q`（同身份、`kill_self=0`），重取 R+16 时 F0 拼出 edge 指令。

## 4. 预测器与 FTQ

### 4.1 字段启用

- `cfi_is_rvc`、`is_edge` 从“恒 0”改为真实值，含义：出口 CFI 是 16 位 / 是 edge 指令（位置 `(0,1)`）。
- 出口 CFI 的 PC：`is_edge ? region_base − 2 : region_base + 2*cfi_slot`。RAS push 地址 = 该 PC + `(cfi_is_rvc ? 2 : 4)`；历史 `push_branch_pc` 同样用该 PC。改 `bpu.sv:108`、`bpu_slow_check.sv:95` 及 L7a 2.3 的历史推进。
- uBTB、主 BTB 表项从训练写入两字段（删除 T05a 的强制清零），预测时原样输出。
- 慢核对覆盖比较（L7a 3.2）增加 `cfi_is_rvc`、`is_edge`。
- mask 不变：edge BR/JAL 记在 bit 0。同一区域被跳转进入（槽 0 是真实起点）时 bit 0 含义可能错，由预解码 c 修正，不另加机制。

### 4.2 训练来源

FTQ 组装 `bpu_train_t` 时：`cfi_is_rvc = (出口指令 inst_len == 2)`，`is_edge = (出口指令 branch_pc == region_base − 2)`。来源为执行解析 `bru_resolve_t.inst_len / branch_pc`（已有字段）；FTQ 项新增这两位，在记录出口解析时写入。

### 4.3 空区域回收

RVC 下区域可能一条指令都不交付（入口在槽 7 且为 32 位指令起点：只存 `pend_q`）。该区域没有 `region_last` 提交，按现有规则永远不回收。

规则：FTQ 收到区域 Y 的任意提交时，**比 Y 老的所有有效项一并视为提交完成**（置 `commit_last`），按现有流程训练与回收。依据：提交按程序顺序，Y 已提交说明更老区域不会再有指令。

## 5. 后端与 CSR（IALIGN=16）

- `branch_execute_unit.sv:67`：删除 taken 目标 bit1 异常（JALR 仍清 bit0；IALIGN=16 下合法目标不会不对齐）。
- `rob.sv:317,323`：`inst_len` 与 `succ_pc = pc + inst_len` 用分配时 uop 的实际长度（ROB 分配口增加 `inst_len`，由 `backend.sv` 从 `fetch_entry_t.inst_len` 接入）。
- `csr_file.sv`：`misa` 加 C 位（bit 2），即 `64'h8000000000001104`；`mepc` 的 CSR 写入与 trap 写入改为只清 bit 0（`& ~64'd1`）。
- 后端译码不改：前端已展开为 32 位指令。

## 6. 类型改动汇总

- `f0_inst_t`、`fetch_entry_t` 增加 `is_edge`。后端只透传，不使用。
- F0 增加输出 `out_last_o`、`out_edge_pend_o`。
- FTQ 项增加 `cfi_is_rvc`、`is_edge`。
- ROB 分配口增加 `inst_len`。

## 7. 不做

- 浮点 RVC（L9）；Zc* 扩展；RV32 专有编码（C.JAL 在 RV64 为 C.ADDIW，按 Flow 实现）。
- 不为 mask bit 0 的二义性加机制（4.1）；不加辅助取指请求（D33）。
- 不跑 Spike、ACT4；不综合。现有 IALIGN=32 程序（`.option norvc`）照常运行。

## 8. 验收（少量定向用例）

用户原则：每个新行为一个简单用例；正确性失败才阻塞提交，其余记为已知问题继续。

| 位置 | 用例 |
| --- | --- |
| `sim/cocotb/rvc_expander`（新） | 翻译 Flow `design/src/test/scala/air/AirRvcDecompressorSpec.scala` 的测试向量 |
| `sim/cocotb/ifu_f0`（改） | ① 16/32 位混合块；② 一块 8 条 RVC，两拍输出；③ edge 拼接；④ edge 遇非顺序块丢弃 `pend_q`；⑤ D34：edge 起点块取指异常，检查 pc/tval；⑥ kill 清 `hold_q`/`pend_q` 一例 |
| `sim/cocotb/ifu_f1`（改） | ① RVC 出口按 `pc+2` 修正一例；② c′ 一例；③ edge 出口位置匹配/不匹配各一例 |
| 整核 `sim/o3/tests/l7b_rvc.S`（新，`-march=rv64imc`，tohost 自查） | 一个循环里含：C.BEQZ/C.BNEZ、C.J、C.JALR/C.JR 调用返回、一条跨 16B 边界的 32 位分支（edge），循环 100 次后校验累加值；Makefile 目标 `run-l7b-rvc`，不带 `--spike` |
| 回归 | `run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`、`run-l7-predict`；L7a 新增与改动的 cocotb |

交回：提交号、命令、exit code、用例数、失败与修复记录、未做项。不需要 SHA256 清单。
