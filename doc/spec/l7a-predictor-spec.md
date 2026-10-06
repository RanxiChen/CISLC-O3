# O3-T05：L7a 预测器接入与性能计数器 RTL spec（已冻结）

日期：2026-10-06。分支：`feat/L1-closure`。审计快照：`306d6ee`。行号均指该快照。

依据：[v1 计划](../O3-v1-plan.md) 第 3 节 L7（2026-10-06 拆为 L7a/L7b）及“验收调整”；[前端基线](../design/CISLC-O3-FRONTEND-DESIGN-BASELINE.md) D01～D35（重点 D02、D05～D09、D22～D24、D29～D32）；[后端基线](../design/CISLC-O3-BACKEND-DESIGN-BASELINE.md) B48。

**状态：已冻结（2026-10-06，用户确认 U1～U6 按推荐值；同日三轮修订补充 U7～U23，见第 8 节）。** 本文是阶段二唯一实施依据；spec 未覆盖的行为先提问，不得自行补设计。本轮只读代码、写文档，未改 RTL、未运行仿真。

---

## 0. 任务书

```
目标：L7a —— 把 uBTB / 主 BTB / TAGE / RAS / 全局历史接入 BPU 主路径，打通
      快预测 → 慢预测核对与覆盖 → F1 预解码修正 → 执行纠错 → 提交训练 的闭环；
      实现 M 模式 Zihpm 性能计数器并接入前端预测事件（B48）。
涉及模块（允许改动）：
  rtl/frontend/{bpu,bpu_slow_check,redirect_arbiter,ftq,ifu_f1,fetch_buffer,
                fetch_return_queue,frontend,ubtb,main_btb,ras}.sv（ras 仅删除 PE_RECOVER_CYCLE 增量，U13）
  rtl/common/{o3_cfg_pkg,o3_types_pkg}.sv
  rtl/system/csr_file.sv，新增 rtl/system/hpm_counters.sv
  rtl/core/o3_core.sv、rtl/backend/backend.sv（仅性能事件连线）
  rtl/rtl.f；对应 sim/cocotb/* 测试；sim/o3/tests 新增程序与 Makefile 目标
闭环简化许可：见第 7 节
验收：第 9 节（只用手写定向 testbench；不跑 Spike、ACT4、访存类 cocotb）
不做：第 7 节
```

## 1. 现状（源码核实）

| 模块 | 现状 | L7a 要做 |
| --- | --- | --- |
| `bpu.sv` | L1 简化：顺序 16B，不实例化任何预测器（`:111–154`）；保留旧 32B 合同（`:156–201`） | 第 2 节：实例化并接通全部子模块；删除旧合同（B46） |
| `ubtb.sv` | 已实现：全相联、提交训练、全局轮转；组合单拍（`:1–25`）。**偏离 D30**：只有 not-taken BR 提交的新区域也会分配项（`:153–155`） | 改配置为 32 项（D30）；预留位（2.6）；新项只为 taken CFI 分配（2.4，U18） |
| `main_btb.sv` | 已实现：组相联、单目标、提交训练；N 拍查、N+1 出结果（`:30–37`） | 改配置；预留位 |
| `tage.sv` | 已实现：base + 6 表，N 查、N+2 出结果（`:22–26`），meta 编码 provider/alt | 改配置 |
| `ras.sv` | 已实现：寄存器栈、单拍操作与恢复、ckpt 输出；不做 x1/x5 解码（`:33`） | 只删除 `PE_RECOVER_CYCLE` 增量（`:182`，U13）；x1/x5 解码在 F1 与后端 |
| `branch_history.sv`、`history_snapshot_store.sv` | 已实现 | 无需改 |
| `bpu_slow_check.sv` | 空壳 | 第 3 节：实现 |
| `redirect_arbiter.sv` | 只接 exec 与 sys（`:48–52`），predecode/slow 未用 | 第 5 节：接入两路，统一年龄仲裁 |
| `ftq.sv` | 慢预测写回、边界清除、exec 修正写回、训练组装已实现（`:355–500`） | 第 6.1 节：brief 带 RAS ckpt；记录慢预测 next_pc 与最终 next_pc；提交分类事件 |
| `ifu_f1.sv` | 直通压紧，`predecode_o='0`（`:62`） | 第 4 节：预解码修正 |
| `fetch_buffer.sv`、`fetch_return_queue.sv`、`ifu_f0.sv` | 任何 kill 都整体清空（`fetch_buffer.sv:150`、`fetch_return_queue.sv:103`） | 第 6.2 节：按年龄选择性清除 |
| 后端 `branch_unit.sv` | 已按 x1/x5 生成 `ras_action`（`:146–151`），按 `predicted_next_pc` 判误预测（`branch_execute_unit.sv:71`） | 不改 |
| `csr_file.sv` | 只有 mcycle/minstret（`:73–150`） | 第 6.3 节：Zihpm |
| `frontend_perf_events.sv` | 空壳收集器，rd_* 占位 | 由 B48 取代：移除实例化与 `rtl.f` 条目（B46） |

## 2. BPU 总装（`bpu.sv`）

### 2.1 配置（D30、D31）

| 字段 | 旧值 | 新值 |
| --- | --- | --- |
| `ubtb.entries` | 16 | **32** |
| `btb.sets` / `ways` | 64 / 2 | **512 / 4** |
| `tage.base_entries` | 512 | **2048** |
| `tage.index_bits` | 7×6 | **10×6** |
| 其余（tag 位宽、hist_len、ctr/useful 位宽） | 不变 | 不变 |

### 2.2 流水与时序

以区域 A 在周期 N 分配成功（`alloc_fire`）为例：

| 周期 | uBTB / RAS / 历史 | 主 BTB | TAGE | BPU 对齐寄存器 |
| --- | --- | --- | --- | --- |
| N 组合 | uBTB 用 `pred_pc` 给快预测；RAS `top_o`、`ckpt_o`；`branch_history.cur_o` 为 A 的入口历史 | `s0` 选 set | `s0` 用 `cur_o.folds` 算 index/tag | — |
| N 上升沿 | RAS 按快预测执行一次动作；历史按快预测推进一次；快照写入 store | 锁存 ways | 锁存 S1 | `p1 <= {valid, ftq_id, fast_pred, ras_ckpt}` |
| N+1 | | `resp_o` 有效 | S1 读表 | `p2 <= p1`；`btb_q <= main_btb.resp_o` |
| N+2 组合 | | | `resp_o` 有效 | `bpu_slow_check` 用 `p2 + btb_q + tage.resp_o` 产生 `slow_o`、`override_o` |

要求：
1. **每个成功分配的区域只做一次 RAS 动作与历史推进**，只在 `alloc_fire` 沿上；`alloc_valid_o` 保持多拍不得重复。
2. `alloc_valid_o = !rst && !hold_i && !recover_busy_i && !kill_i.valid`（保持现有）。
3. 主 BTB、TAGE 的 `stall_i`、`kill_i` 接 0。**在途查询的有效性只由 BPU 的 `p1/p2` valid 位决定**：`kill_i.valid` 的上升沿清 `p1/p2` 的 valid（以及 `btb_q`）；之后到达的 TAGE/BTB 结果因 `p2.valid=0` 被忽略。理由见 2.5。
4. `p2.valid=1` 时，主 BTB 结果必须同在（`btb_q` 有效），TAGE `resp_valid_o` 必须为 1；否则断言失败（仿真 `assert`）。
5. `slow_o` 每个 `p2.valid` 拍输出一次，`override_o.valid = slow_o.override`。

### 2.3 快预测（D30、D32）

`alloc_pred_o` 取 uBTB `pred_o`，并做两处修改：
- **return 用 RAS（D32）**：`hit && cfi_valid && ras_action ∈ {POP, POP_PUSH} && ras.top_valid_o` 时，`next_pc = cfi_target = ras.top_o`。
- uBTB 未命中：顺序（`region_base + 16`，`cfi_valid=0`）。现有 `ubtb.sv` 已如此。

RAS 动作（`alloc_fire` 沿）：`op_valid = cfi_valid && ras_action != RAS_NONE`；`op_push_addr = region_base + 2*cfi_slot + (cfi_is_rvc ? 2 : 4)`。L7a 中 `cfi_is_rvc` 恒为 0。

历史推进（D09）：`push_valid = cfi_valid && cfi_type == CFI_BR && !target_missing`；`push_branch_pc = region_base + 2*cfi_slot`，`push_target_pc = cfi_target`。

### 2.4 训练分发

`train_ready_o = ubtb.train_ready_o && main_btb.train_ready_o && tage.train_ready_o`；三张表的 `train_valid_i = train_valid_i && train_ready_o`，同一 `train_i` 广播。三张表各自按已实现规则更新，不改训练规则，唯一例外是 uBTB 的分配条件（U18）：未命中的区域只有 `train_i.cfi_valid && cfi_type != CFI_NONE`（有 taken CFI）时才分配新项；只有 not-taken BR 提交的区域不分配。已命中的项仍按现有规则接受 not-taken 训练（`br_mask` 累加等）。替换规则不变。

### 2.5 组合环约束（必须遵守）

`redirect_arbiter` 的 `kill_o` 是当拍组合输出，其输入包括 `override_o`（来自 BPU）与 `predecode_o`（来自 F1）。因此：
- `slow_o`、`override_o` **不得组合依赖** `kill_i`。它们只来自寄存器（`p2`、`btb_q`、TAGE S2）。这就是 2.2 第 3 条把 BTB/TAGE 的 `kill_i` 接 0 的原因：两模块的 `resp_valid_o` 会被 `kill_i` 组合压低。
- `predecode_o` 来自寄存器（第 4.3 节）。
- `kill_i` 只能在时钟沿使用，或用于压低本拍的握手（ready/valid），且该握手不得回到任何仲裁输入。

### 2.6 表项预留位（D31、D33）

`bpu_pred_t`、`btb_resp_t`、`bpu_train_t`、uBTB 表项、主 BTB 表项各增加 `cfi_is_rvc` 与 `edge` 两个 1 位字段。L7a 写入、存储、传递均为 0，不参与任何判断；L7b 启用。

## 3. 慢预测核对（`bpu_slow_check.sv`）

输入：`p2` 中的 `fast`（区域 A 的快预测）、`ras_ckpt`（A 的 `ras_before`）；`btb_q`；TAGE `taken_mask`。全部组合，不用 `kill_i`。

### 3.1 慢预测 P 的生成

记 `e = fast.entry_slot`，有效槽位为 `s >= e`。

1. **BTB 未命中**：P = 顺序。`cfi_valid=0`，`next_pc = region_base + 16`，mask 全 0。
2. **BTB 命中**：`br = btb.br_mask & valid(s>=e)`，`jal = btb.jal_mask & valid(s>=e)`，`o = btb.cfi_slot`（目标归属槽）。
   - 候选 taken 槽：`cand = (br & tage.taken_mask) | jal`；另外，若 `o >= e` 且 `btb.cfi_type == CFI_JALR`，`o` 也是候选（JALR 无 mask，恒 taken）。
   - 取最低的候选槽 `c`。
   - `c` 不存在：P = 顺序。
   - 记 `owner_ok = btb.cfi_type != CFI_NONE`（项有已安装的目标归属；首次只提交 not-taken BR 的项 `cfi_type=CFI_NONE`、`target=0`，见 `main_btb.sv:186–197`，U17）。
   - `c == o && owner_ok`：P 在 `o` 退出。`cfi_type/ras_action = btb` 的值；`cfi_target = btb.target`；若 `ras_action ∈ {POP, POP_PUSH}` 且 `ras_ckpt.count != 0`，`cfi_target = ras_ckpt.top_addr`。`next_pc = cfi_target`。
   - `c != o` 或 `!owner_ok`（`c` 没有目标）：`raw_pred_taken=1`、`target_missing=1`，P = 顺序（第 4.3 节；推荐理由见 U1）。
   - P 的 `br_mask/jal_mask` 取 `br/jal`；`tage_meta` 取 TAGE `meta`。
3. P 的 `region_base/entry_slot` 与 `fast` 相同。

### 3.2 是否覆盖

`override = (P.cfi_valid != fast.cfi_valid) || (P.cfi_valid && (P.cfi_slot != fast.cfi_slot || P.cfi_type != fast.cfi_type || P.ras_action != fast.ras_action || P.next_pc != fast.next_pc)) || (!P.cfi_valid && P.next_pc != fast.next_pc)`。

快慢只要在“退出槽、类型、RAS 动作、下一 PC”上有任一差异，A 的推测历史或 RAS 就可能已经错了，必须覆盖并恢复。

### 3.3 覆盖请求

`override_o`：`src=REDIR_SLOW`，`ftq_id=A`，`slot = P.cfi_valid ? P.cfi_slot : 7`，`kill_self=0`，`target_pc = P.next_pc`，`hist_inject = P.cfi_valid && P.cfi_type==CFI_BR`（目标为 `P.cfi_target`，分支 PC 为 `region_base + 2*P.cfi_slot`），`ras_fix = P.cfi_valid ? P.ras_action : RAS_NONE`，`ras_push_addr = region_base + 2*P.cfi_slot + 4`。

`slow_o`：`valid`、`ftq_id=A`、`pred=P`、`tage_meta`、`override`。FTQ 已按 `slow_i` 更新 `final_pred` 并置 `slow_done`（`ftq.sv:355–361`）。

### 3.4 事件

| 事件 | 条件 |
| --- | --- |
| `PE_BTB_HIT` | `p2.valid && btb.hit` |
| `PE_TARGET_MISSING` | `p2.valid && P.target_missing` |
| `PE_FAST_SLOW_DISAGREE` | `p2.valid && override`（推测口径，含之后被杀的） |

`PE_SLOW_OVERRIDE` 在仲裁器按“慢覆盖成为赢家”计数（第 5 节）。

## 4. F1 预解码修正（`ifu_f1.sv`）

L7a 只有 32 位指令（RV64I，`.option norvc`），每块最多 4 条，起点为偶数槽。

### 4.1 输入

- 块内指令（来自 F0）与 `brief`；`brief` 增加 `ras_ckpt`（6.1）。
- `pred = brief.pred`（FTQ `final_pred`）。

### 4.2 修正规则

按程序顺序扫描块内指令 `i`（槽位 `s_i`，PC `pc_i`），直到预测出口为止；遇到 `exc_valid=1` 的项也停止扫描（见本节末“取指异常”，U10）。对每条指令做 x1/x5 解码（与后端 `branch_unit.sv:146–151` 同一规则），得到实际类型 `T_i ∈ {非 CFI, BR, JAL, JALR}` 与 `ras_i`。第一条满足下列条件的指令产生修正，之后的指令不交付：

| # | 情况 | 修正后 target | ras_fix | hist_inject |
| --- | --- | --- | --- | --- |
| a | `s_i` 早于预测出口（或无出口），`T_i = JAL` | `pc_i + imm` | `ras_i` | 0 |
| b | `s_i` 早于预测出口（或无出口），`T_i = JALR` 且 `ras_i ∈ {POP, POP_PUSH}`，且 `brief.ras_ckpt.count != 0` | `ras_ckpt.top_addr` | `ras_i` | 0 |
| c | 预测出口槽 `pred.cfi_slot` 不是指令起点，或该指令不是 CFI（假 CFI） | 下一条指令起点（`pc_i + 4`，`i` 为覆盖该槽的指令） | NONE | 0 |
| d | 出口指令 `T_i` 与 `pred.cfi_type` 不同 | 按 a/b 规则重算；都不满足时为 `pc_i + 4`（顺序越过） | a/b 时 `ras_i`，否则 NONE | 0 |
| e | 出口为 BR 或 JAL，类型相同，但 `pred.cfi_target != pc_i + imm`；或出口为 JAL、类型相同、`pred.ras_action != ras_i`（U9） | `pc_i + imm` | `ras_i` | `T_i==BR` |
| f | 出口为 JALR，类型相同，`pred.ras_action != ras_i` | `ras_i` 为 pop 且 `count!=0`：`top_addr`；否则保持 `pred.next_pc` | `ras_i` | 0 |

判定细则（U19）：
- **位置**：指令 `i` 占槽 `[s_i, s_i+1]`。“早于出口”指 `s_i < pred.cfi_slot`（含 `i` 覆盖出口槽、即 `s_i+1 == pred.cfi_slot` 的情况）或 `pred.cfi_valid=0`；“出口指令”指 `s_i == pred.cfi_slot` 的指令。
- **c～f 的共同前提**：仅在 `pred.cfi_valid=1` 时适用（`pred.cfi_valid=0` 时 `cfi_slot` 无意义，只有 a/b 可触发修正）；c 只判断覆盖出口槽的指令（起点在出口槽或 `s_i+1 == pred.cfi_slot`），d/e/f 只判断出口指令（U22）。
- **实际 taken 目标 `A(i)`**：`T_i=JAL` 时为 `pc_i+imm`；`T_i=JALR`、`ras_i ∈ {POP, POP_PUSH}` 且 `brief.ras_ckpt.count != 0` 时为 `ras_ckpt.top_addr`；其余情况 `A(i)` 不存在。a、b 即“早于出口且 `A(i)` 存在”。
- **d 的重算**只复用 `A(i)` 的类型、RAS 与目标条件，不复用 a/b 的位置条件：`A(i)` 存在则 target=`A(i)`、ras_fix=`ras_i`；否则 target=`pc_i+4`、ras_fix=NONE。
- **同一指令多条成立时的优先级**：a/b > c > d > e > f。例：预测出口 slot 1、slot 0 为 JAL（覆盖 slot 1），a 与 c 同时成立，按 a 修正到 JAL 目标；若 slot 0 为非 CFI 或 BR，a/b 不成立，按 c 修正到 `pc_0+4`。
- **扫描顺序**：按程序顺序逐条判定，第一条有任一规则成立的指令产生唯一一次修正。

不修正：BR 方向（无法知道）；普通 JALR 的目标（等执行，前端基线 4.3）；栈空时 return 的**目标**（b 不触发，d 顺序越过，等执行）。栈空不影响 f：类型同为 JALR 而 `ras_action` 不同时，f 仍修正 RAS 动作，target 保持 `pred.next_pc`。

取指异常（U10）：块内项 `exc_valid=1` 时（含整块取指异常与非法半字），该项及其后的项都不参与 a～f 判定，不产生修正；异常项的 `exc_valid/exc_cause/exc_tval` 原样交付，`pred_taken/predicted_next_pc` 按 4.4 未修正规则给出。第一个异常项之后的项不交付：异常项成为本块最后交付项并置 `ftq_last`（U20）。若异常项之前的项已触发修正，按正常修正截断在该项，异常项不交付。

修正请求字段：`src=REDIR_PREDECODE`，`ftq_id`，`slot=s_i`，`kill_self=0`，`target_pc` 见表，`hist_branch_pc=pc_i`，`hist_target_pc=target`，`ras_push_addr = pc_i + 4`。

### 4.3 时序（寄存器式请求）

- 周期 N：F1 呈现块 X 并计算修正。X 被 fetch buffer 接收的那一拍（握手成功），F1 只写出 `slot <= s_i` 的指令，其中被修正指令的 `predicted_next_pc` 改为修正后 target，`pred_taken` 按修正种类给出（U8）：a、b、e、f 为 1；c 为 0；d 在重算命中 a 或 b 时为 1，顺序越过时为 0。`pred_taken` 只由修正种类决定，不得用“target 是否等于 `pc_i+4`”推断（taken 分支的目标可以恰为 `pc_i+4`）。同一沿把修正请求锁存到 `pd_req_q`。
- 周期 N+1：`predecode_o = pd_req_q`。仲裁器在本拍决定胜负；`pd_req_q` 在 N+1 沿无条件清除（胜出则已生效；败给更老的请求时 X 已被杀）。
- 周期 N 若 `kill_i.valid` 且 X 被该边界杀掉，X 不交付、不锁存请求（现有 `!kill_i.valid` 阻塞握手的写法可保留）。
- N+1 拍 F1 正在呈现的年轻块 Y 被本次 kill 阻塞并在沿上清除（第 6.2 节）。

请求寄存一拍的代价是预解码修正多 1 拍；换来的是不形成 F1 → 仲裁 → kill → F1 的组合环（2.5）。

### 4.4 交付字段

未修正块：出口指令 `pred_taken=pred.cfi_valid && slot==pred.cfi_slot`，`predicted_next_pc = pred.next_pc`；其他指令 `pred_taken=0`，`predicted_next_pc = pc + 4`。后端据此判误预测（`branch_execute_unit.sv:71–72`）。

### 4.5 事件

`PE_PREDECODE_REDIRECT`：在仲裁器按“预解码成为赢家”计数。

## 5. 重定向仲裁（`redirect_arbiter.sv`）

- 接入 `predecode_i`、`slow_i`。四路请求统一按 D24：sys 最高；其余按 `(ftq_id, slot)` 相对 `ftq_head_i` 的程序年龄选最老；同位置 `EXEC > PREDECODE > SLOW`（`redirect_src_e` 编码）。
- 抽出年龄比较函数到 `o3_types_pkg`：`fe_age(id, slot, head)` 与 `fe_killed_by(kill, id, slot, head)`，供仲裁器、FTQ、返回队列、fetch buffer 共用，避免各自实现。
- busy 期间可被更老请求替换的规则扩展到四路（现有只对 exec，`:107–128`）。
- 赢家输出 `winner_o` 已存在；本级增加 `winner_valid_src` 事件：`PE_SLOW_OVERRIDE`、`PE_PREDECODE_REDIRECT`、`PE_REDIRECT_EXEC`、`PE_REDIRECT_SYS` 各在对应来源**新请求被接受的那一拍**加 1（即 `accept_*` 拍；恢复期间 `winner_o` 保持 `recover_q` 供历史/RAS 修复，不重复计数，U13）；`PE_RECOVER_CYCLE` 在 `recover_busy_o` 期间每拍加 1，且只由仲裁器产生（`ras.sv` 的同名增量删除）。
- 后端不因 predecode/slow 赢家清空自身：`backend.sv:92` 的 `fe_redirect_i` 当前未使用，保持不用。

## 6. 其余改动

### 6.1 FTQ

1. `ftq_pred_brief_t` 增加 `ras_ckpt_t ras_ckpt`；brief 读口输出该项的 `ras_ckpt`。
2. 新增项字段 `slow_next_pc`（`slow_i` 写入时记录 `slow_i.pred.next_pc`）与 `final_next_pc`（分配时 = 快预测 next；`slow_i` 写入时更新；**任何**赢家 `kill_self=0` 且 `ftq_id` 为本项时 = 赢家 `target_pc`，写入时机为该赢家被接受的拍，U13）。为此 FTQ 增加输入 `winner_i`（仲裁器 `winner_o`）。现有 exec 修正写 `final_pred` 的逻辑（`:465–476`）保留。
3. 训练握手成功（区域提交并送训练）时产生提交口径事件：
   - `PE_CMT_REGION`：+1
   - `fast_ok = fast_pred.next_pc == final_next_pc`，`slow_ok = slow_next_pc == final_next_pc`
   - `PE_CMT_FAST_OK_SLOW_OK / FAST_OK_SLOW_BAD / FAST_BAD_SLOW_OK / FAST_BAD_SLOW_BAD` 四选一 +1
   - `PE_CMT_MISPRED_REGION`：`mispredicted` 时 +1
4. `PE_FTQ_FULL_CYCLE`：`alloc_valid_i && !alloc_ready_o` 每拍 +1。

说明：提交口径只统计最终走对的路径，用来回答“32 项 uBTB 够不够”：`FAST_BAD_SLOW_OK` 每次约损失 2 拍（慢覆盖）；`FAST_BAD_SLOW_BAD` 要靠预解码或执行纠正。

### 6.2 按年龄选择性清除

D24 要求只清除比边界年轻的项。慢覆盖与预解码修正的边界在前端中间，整体清空会丢掉更老的有效块或指令，必须改：

| 模块 | 时钟沿上的行为 |
| --- | --- |
| `fetch_return_queue` | 槽内块若 `fe_killed_by(kill, id, slot=0, head)` 为真才清；否则保留（含 pending 响应的身份）。kill 拍：阻塞新预留（入队）与出队；**被保留的槽照常接收与其身份匹配的 ICache 响应**，被清除的槽丢弃该响应（U7） |
| `ifu_f0` | L7a 无内部状态（直通），不变 |
| `ifu_f1` | 只有 `pd_req_q`，见 4.3 |
| `fetch_buffer` | 逐项按 `(ftq_id, slot)` 判定，只清年轻项；`kill.all` 全清 |

kill 拍仍阻塞上述模块的握手（现有写法），不需要在 kill 拍内组合地区分年龄。返回队列与 fetch buffer 需要 `ftq_head`（FTQ `head_id_o`）作年龄参照。

### 6.3 性能计数器（B48，`hpm_counters.sv`）

- 新增 `rtl/system/hpm_counters.sv`，由 `csr_file` 实例化。`mcycle`、`minstret` 迁入本模块，便于统一受 `mcountinhibit` 控制。
- 配置：`O3_CFG.core.hpm_counters = 8`，即 `mhpmcounter3～10`、`mhpmevent3～10`。
- 地址与行为（M 模式；S/U 在 L10）：

| CSR | 地址 | 行为 |
| --- | --- | --- |
| `mcycle` / `minstret` | 0xB00 / 0xB02 | 读写；分别受 `mcountinhibit.CY`(bit0) / `IR`(bit2) 暂停 |
| `mhpmcounter3～31` | 0xB03～0xB1F | 3～10 读写 64 位；11～31 读 0、写忽略 |
| `mhpmevent3～31` | 0x323～0x33F | 3～10 的 [15:0] 可写；[63:58]（Sscofpmf 位）L7a 读 0；其余位读 0；11～31 读 0、写忽略（不报非法，U21） |
| `mcountinhibit` | 0x320 | bit0、bit2、bit3～10 可写，其余读 0 |
| `cycle`/`instret`/`hpmcounter3～31` | 0xC00～0xC1F | 只读别名（M 模式可读）；写为非法指令 |

- 事件编号：`mhpmevent[15:8]` 为来源，`[7:0]` 为该来源内的事件号。来源 1 = 前端 `fe_perf_evt_e`，来源 2 = 后端 `be_perf_evt_e`。值为 0 或不存在的事件不计数。
- 计数：每拍 `counter += inc(event)`，增量可大于 1。CSR 读返回本拍旧值。写优先只作用于被写的那个计数器（U11）：写某个 `mcycle`/`minstret`/`mhpmcounterN` 时，该计数器本拍取写入值、丢弃本拍增量，其他计数器照常计数；写 `mhpmevent`/`mcountinhibit` 时，本拍仍按旧配置计数，新配置从下一拍生效。
- 连线：`frontend` 汇总各子模块 `perf_o`（按事件相加）输出 `fe_perf_o`；经 `o3_core` 送入 `backend` → `csr_file` → `hpm_counters`。删除 `frontend_perf_events` 实例化。
- **事件编号冻结**：`fe_perf_evt_e` 改为显式赋值，以后只追加、不重排。删除 D29 已取消的 `PE_RAS_LOG_FULL`（编号不复用）。L7a 新增与已有事件编号如下（来源 1）：

| 号 | 事件 | 产生处 |
| --- | --- | --- |
| 0x01 | `PE_UBTB_LOOKUP` | BPU，`alloc_fire` |
| 0x02 | `PE_UBTB_HIT` | BPU，`alloc_fire && ubtb.hit` |
| 0x03 | `PE_BTB_HIT` | 慢核对 |
| 0x04 | `PE_FAST_SLOW_DISAGREE` | 慢核对 |
| 0x05 | `PE_SLOW_OVERRIDE` | 仲裁器 |
| 0x06 | `PE_TARGET_MISSING` | 慢核对 |
| 0x07 | `PE_PREDECODE_REDIRECT` | 仲裁器 |
| 0x08 | `PE_REDIRECT_EXEC` | 仲裁器 |
| 0x09 | `PE_REDIRECT_SYS` | 仲裁器 |
| 0x0A | `PE_RECOVER_CYCLE` | 仲裁器 |
| 0x0B | `PE_RAS_PUSH` | RAS（已有） |
| 0x0C | `PE_RAS_POP` | RAS（已有） |
| 0x0D | `PE_RAS_UNDERFLOW` | RAS（已有） |
| 0x0E | `PE_RAS_OVERFLOW` | RAS（已有） |
| 0x0F | `PE_CMT_REGION` | FTQ |
| 0x10～0x13 | `PE_CMT_FAST_OK_SLOW_OK` / `_OK_BAD` / `_BAD_OK` / `_BAD_BAD` | FTQ |
| 0x14 | `PE_CMT_MISPRED_REGION` | FTQ |
| 0x15 | `PE_FTQ_FULL_CYCLE` | FTQ |
| 0x20 起 | 其余现有事件（ICache、ITLB、预取、返回队列、交付等）按现有顺序显式编号 | 未实现的保持 0 |

后端事件（来源 2）按 `be_perf_evt_e` 现有顺序从 0x01 起显式编号；本级只连线，已有驱动的事件照常计数。

## 7. 闭环简化与不做

允许简化：
- 预解码与快/慢预测只处理 32 位指令；RVC、edge 指令、跨页后半字异常、F0/F1 每拍 4 条的剩余保留属于 L7b（D33～D35）。
- 返回队列保持单槽现状（`fetch_return_queue.sv` 当前未实现 8 项）。这限制前端吞吐，但不属于本级；在 L7a 报告中记为已知性能限制。
- TAGE/BTB 的表用现有寄存器数组写法，不做 BRAM 映射（综合在 L11）。
- `cfi_is_rvc`、`edge` 只预留、恒 0。

不做：
- 不改 uBTB/BTB/TAGE 的训练与替换规则（D30：不加新机制），唯一例外是 2.4 中 uBTB 分配条件的纠正（U18，使 RTL 符合 D30）。
- 不做 Sscofpmf、`mcounteren/scounteren`、S/U 访问（L10），不做 OpenSBI/设备树（L11）。
- 不做系统重定向的 committed 预测上下文（前端 16.4 未闭合项）；sys 重定向沿用 L5 现有处理。
- 不跑 Spike、ACT4、访存类 cocotb（`dcache`、`l2_cache`、`load_queue`、`store_queue`、`load_store_unit*`）。
- 不综合。

## 8. 审阅决定（2026-10-06 用户确认，按推荐值）

| # | 问题 | 推荐 | 理由 |
| --- | --- | --- | --- |
| U1 | 慢核对中 taken 候选没有目标（`c != o`）时 | 该区域按顺序继续，记 `target_missing` | 符合前端基线 4.3“继续顺序路径”；替代做法“跳到 owner 槽的目标”在 owner 之前有真实 taken 分支时一定走错 |
| U2 | 预解码请求是否寄存一拍 | 寄存 | 避免 F1 → 仲裁 → kill → F1 组合环（2.5）；代价是预解码修正多 1 拍 |
| U3 | 选择性清除放在本级 | 是 | 慢覆盖、预解码的边界在前端中间，整体清空会丢更老的有效块，属于正确性问题，不是优化 |
| U4 | 事件编号格式 | `[15:8]` 来源 + `[7:0]` 序号，显式赋值、只追加 | 前后端各自增删事件不影响对方编号；Linux 里写作 `perf stat -e r0102` |
| U5 | `mcycle`/`minstret` 迁入 `hpm_counters` | 迁入 | `mcountinhibit` 统一管理，csr_file 只做地址分派 |
| U6 | 提交分类口径 | 用 `final_next_pc` 判快/慢对错（6.1） | 只看最终走对的路径，分母清楚；推测口径另由 `PE_FAST_SLOW_DISAGREE` 给出 |

修订（2026-10-06，Codex 审阅发现的边界行为，用户确认）：

| # | 问题 | 决定 | 理由 |
| --- | --- | --- | --- |
| U7 | kill 拍返回队列被保留的槽是否收响应 | 收；被清除的槽丢弃（6.2） | ICache 响应只来一次，保留 pending 身份却丢响应会永久等待 |
| U8 | 修正后的 `pred_taken` | a/b/e/f=1，c=0，d 视重算结果（4.3） | 按修正种类判定；target 恰为 `pc+4` 的 taken 分支不能被误判为不跳 |
| U9 | 同类型 JAL、目标相同但 `ras_action` 不同 | 纳入 e 条，发修正（4.2） | 否则错误 push/漏 push 不被执行级发现，RAS 被悄悄污染 |
| U10 | 已有取指异常的项 | 到首个异常项停止扫描，不修正，异常字段原样交付（4.2） | 异常项指令字为 0 或非法半字，解码会制造假 CFI；该项提交时 trap 清空流水 |
| U11 | CSR 写优先的范围与生效拍 | 只覆盖被写计数器；配置写下一拍生效（6.3） | 配置用寄存器输出即可，不需旁路；差一拍不影响统计 |
| U12 | 8 个计数器容纳不下全部指标 | 分两组事件配置运行（9.2） | 仿真确定，两组只差 `mhpmevent` 写入值，CSR 指令条数与时序相同 |
| U13 | 恢复周期与赢家事件重复计数 | `PE_RECOVER_CYCLE` 只由仲裁器产生，删除 `ras.sv` 增量；赢家事件与 FTQ `final_next_pc` 按接受拍（5、6.1） | 单一来源；`winner_o` 在恢复期间保持有效，按电平计数会重复 |
| U14 | 失败项能否提交、继续 | 两档门禁（9.3），T05a～T05d 统一适用 | 正确性 bug 带到后级更难查；预测精度只影响性能 |

第二轮修订（2026-10-06，Codex 复审）：

| # | 问题 | 决定 | 理由 |
| --- | --- | --- | --- |
| U15 | 门禁范围与分步实施冲突 | 失败处理政策统一；测试范围按各步任务书，完整验收在 T05d（9.3） | 前几步尚未实现慢核对、F1、HPM，不能要求其测试通过 |
| U16 | CMT 分类和缺少共同采样边界 | 用 `mcountinhibit` 暂停全部 HPM 后读取，再恢复；两组边界相同（9.2） | 连续 `csrr` 之间仍有训练握手，读到的总数与分类会错开 |
| U17 | 主 BTB 命中但无已安装目标 | `c==o` 还须 `cfi_type != CFI_NONE`，否则按 U1 `target_missing`（3.1） | 首次 not-taken 训练只装 mask，`target=0` 不能被采用 |
| U18 | uBTB 现有分配条件与 D30 不符 | 新项只为 taken CFI 分配；已有项仍接受 not-taken 训练（2.4） | D30 已确认“只为 taken 分配”；不纠正会让无目标项挤占 32 项 |
| U19 | d 重算条件、同指令多规则优先级、栈空 return 与 f | 定义 `A(i)`；d 不复用位置条件；优先级 a/b > c > d > e > f；栈空只免目标补算，f 照常（4.2） | 消除字面矛盾，保证实现唯一 |
| U20 | 异常项之后是否交付 | 不交付，异常项置 `ftq_last`（4.2） | 异常项提交即 trap，后续项无用；明确 `ftq_last` 位置 |
| U21 | `mhpmevent11～31` 写行为 | 读 0、写忽略（6.3） | 与 `mhpmcounter11～31` 一致；只读别名写仍非法 |

第三轮修订（2026-10-06，Codex 复审）：

| # | 问题 | 决定 | 理由 |
| --- | --- | --- | --- |
| U22 | c～f 的共同前提 | 仅 `pred.cfi_valid=1` 时适用；c 判覆盖出口槽的指令，d/e/f 判出口指令（4.2） | 无出口时 `cfi_slot` 可能为默认 0，字面实现会误用 |
| U23 | 计数起点与统计口径 | 初始化暂停→配置→清零→统一恢复；一律用每段差值；第 2 段重复 100 次；阈值分母为动态 CFI 条数（9.2） | 分类与总数须同起点；“稳态”“分支数”原文未定义 |

## 9. 验收（手写定向 testbench）

### 9.1 模块级 cocotb

| 目录 | 新/改 | 用例 |
| --- | --- | --- |
| `sim/cocotb/bpu` | 改写 | 空表顺序预测；训练 taken BR 后 uBTB 命中、慢核对一致不覆盖；填满 33 个区域挤出 uBTB 后快顺序、慢覆盖（检查 N+2 的 `override_o` 各字段）；call 区域 push、return 区域快预测取 RAS 栈顶；`hold`/FTQ 不就绪期间不重复 RAS/历史动作；kill 后在途查询不产生 `slow_o` |
| `sim/cocotb/bpu_slow_check` | 新 | 表驱动：entry 槽屏蔽、owner taken/不 taken、`target_missing`、无 owner 项（`cfi_type=CFI_NONE`）上 slot 0 被 TAGE 判 taken 时为 `target_missing` 而非采用 `target=0`（U17）、JALR owner、return 栈空/非空、各覆盖比较项 |
| `sim/cocotb/ifu_f1` | 扩展 | 4.2 的 a～f 各一例，以及“不修正”三例；e 的 JAL `ras_action` 不同一例（U9）；a 与 c 同时成立一例、d 重算命中 `A(i)` 与顺序越过各一例、栈空 return 的 f 一例（U19）；每例检查 `pred_taken`（U8，含 BR 目标恰为 `pc+4` 的 e 例）；块首项异常与块中项异常各一例，检查异常后不交付、`ftq_last` 在异常项（U10、U20）；截断后只交付 `slot<=s_i`；请求只出现一次且晚一拍；kill 拍不锁存 |
| `sim/cocotb/redirect_arbiter` | 新 | 四路年龄仲裁、同位置优先级、环形回绕、busy 期间被更老请求替换、赢家事件只在接受拍计 1 次（恢复多拍期间不重复，U13）、`PE_RECOVER_CYCLE` 拍数 |
| `sim/cocotb/fetch_buffer` | 新 | 选择性清除：边界前、边界本身（`kill_self` 0/1）、边界后、`all` |
| `sim/cocotb/fetch_return_queue` | 扩展 | 槽内块比边界老/等/年轻三种 kill；kill 拍同时到达响应：保留槽收下、被清槽丢弃（U7） |
| `sim/cocotb/hpm_counters` | 新 | 事件选择、0 号事件不计、多增量、`mcountinhibit`、写优先只作用于被写计数器、`mhpmevent`/`mcountinhibit` 写入下一拍生效（U11）、11～31 读 0、`mhpmcounter/mhpmevent11～31` 写忽略（U21）、只读别名写非法 |
| `ubtb`、`main_btb`、`tage`、`ras`、`branch_recovery`、`csr_file` | 重跑 | 配置改动与字段扩展后不回归；`ubtb` 增加“只提交 not-taken BR 的新区域不分配”一例（U18）；`main_btb` 现有“无目标 owner”用例保留；`csr_file` 已有 cocotb，`mcycle`/`minstret` 迁入 `hpm_counters`（U5）后若原用例依赖旧实现细节，按 6.3 行为更新期望值（`ftq` 目前没有 cocotb 目录，由 `bpu` 与整核程序覆盖） |

### 9.2 整核定向程序

新增 `sim/o3/tests/l7_predict.S`（`.option norvc`，以 tohost 判通过/失败），Makefile 目标 `run-l7-predict`，**不带 `--spike`**：
1. 条件分支循环：1000 次，内含交替 taken 的分支；校验累加结果。
2. 调用/返回：8 层嵌套调用，返回值逐层校验；整条调用链重复 100 次。
3. 超过 32 个 taken 区域的大循环（预期 uBTB 装不下、主 BTB 装得下）。

每段前后各采样一次（采样方法见下），数值经 trace 可见。共 10 个事件，超过 8 个计数器，按两组事件配置分别运行（U12），程序用汇编宏选择组别，Makefile 目标 `run-l7-predict` 依次跑两组：

| 组 | `mhpmcounter3～10` 的事件 |
| --- | --- |
| A | `UBTB_HIT`、`SLOW_OVERRIDE`、`PREDECODE_REDIRECT`、`REDIRECT_EXEC`、`CMT_REGION`、`CMT_MISPRED_REGION` |
| B | `CMT_REGION`、`CMT_FAST_OK_SLOW_OK`、`CMT_FAST_OK_SLOW_BAD`、`CMT_FAST_BAD_SLOW_OK`、`CMT_FAST_BAD_SLOW_BAD`、`REDIRECT_EXEC` |

采样边界（U16、U23，两组相同）：
- 初始化（程序开头、第 1 段之前，一次）：`csrw mcountinhibit` 置 bit3～10 → 写全部 `mhpmevent3～10` → 全部 `mhpmcounter3～10` 写 0 → `csrw mcountinhibit, 0` 统一恢复。保证所有 HPM 从同一拍、同一起点开始计数。
- 每次采样：`csrw mcountinhibit` 置 bit3～10（暂停全部 HPM；`mcycle`/`minstret` 不暂停）→ 依次 `csrr` 读出 `mhpmcounter3～10` 存入内存 → `csrw mcountinhibit, 0` 恢复。暂停写入按 U11 下一拍生效；由于 CSR 指令在后端串行执行，暂停之后的 `csrr` 必然在生效之后，不需要额外等待。所有 HPM 在同一拍停、同一拍启，因此每次训练握手的 `CMT_REGION` 与分类增量要么同时计入，要么同时不计入，分类和与总数严格相等。
- 两组程序的测量部分逐条指令相同，只有 `mhpmevent` 的写入值不同：每个事件号用单条 `li`（`addi`，值 < 0x800）装载，保证指令条数与地址不变。
- 组别相关的自查与性能标记全部放在**最后一个测量窗口结束之后**的代码段，并位于程序文本末尾，不改变测量段的 PC 布局；`.data` 布局两组相同。
- 组 A 检查：第 1、2 段 `REDIRECT_EXEC` 阈值、第 3 段 `SLOW_OVERRIDE > 0`（性能项，见 9.3）。组 B 检查：分类和等于 `CMT_REGION`（正确性项）。

**统计口径**：报告数值、程序自查与两组比对一律使用**每段差值**（段后采样减段前采样）。

两组都采 `CMT_REGION` 与 `REDIRECT_EXEC` 作一致性检查，不一致属于正确性失败：组 B 中每段四个分类差值之和等于该段 `CMT_REGION` 差值，由程序自查（不等写失败 tohost）；两次运行中这两项的每段差值相等，由 `run-l7-predict` 在两次运行后从 trace 提取比对（不等则目标失败）。报告的数值表注明每列来自哪一组。程序内的宽松检查（只在组 A 做）：第 1、2 段整段 `REDIRECT_EXEC` 差值小于该段动态执行的 CFI 条数（BR + JAL + JALR，由程序作者按程序结构算出、写成常数）的 1/4；第 3 段 `SLOW_OVERRIDE` 差值 > 0。重复执行使冷启动误预测占比足够小，不单独划分稳态窗口。数值本身作为首份基线写进报告。

并重跑：`make -C sim/o3 run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`（均不带 `--spike`）。

### 9.3 完成标准

- 门禁范围（U15）：下述两档**失败处理政策**对 T05a～T05d 统一适用；但每一步的**测试范围**按该步任务书，只覆盖已实现的部分，并加上前序步骤已通过用例与三个整核回归的不回归。9.1、9.2 的完整验收只在最后一步（T05d）执行。
- 两档门禁（U14）：
  - **正确性项，必须全部通过才能提交**：9.1 全部 cocotb 用例；9.2 整核程序 tohost 通过（含两组一致性检查）；`run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense` 回归。
  - **性能阈值，未达标可登记后继续**：9.2 组 A 的宽松检查（`REDIRECT_EXEC` 差值小于动态 CFI 条数的 1/4、`SLOW_OVERRIDE` 差值 > 0）。为此程序中这两项不达标时不写失败 tohost，而是在 trace 中输出标记；报告列为已知性能问题，附复现命令。
- 交回：提交号、命令、日志、9.2 的计数器数值表。
