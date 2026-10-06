# O3-T06：L7b RVC 压缩指令 RTL spec（已冻结）

日期：2026-10-06。分支：`feat/L1-closure`。审计快照：`cbe3372`（L7a T05c/d 提交后）。行号均指该快照。

依据：[v1 计划](../O3-v1-plan.md) 第 3 节 L7b；[前端基线](../design/CISLC-O3-FRONTEND-DESIGN-BASELINE.md) D33～D35（第 17.4～17.6 节）；
[L7a spec](l7a-predictor-spec.md)（U1～U24，下文“L7a x.y”指该文件章节）。

**前提：** L7a 已于 `cbe3372` 完成（报告 [O3-T05cd](../tasks/O3-T05cd-report.md)）。本 spec 只写与 L7a 不同或新增的部分；未提到的行为沿用 L7a。
**验证原则（用户 2026-10-06）：先完成后完美。** 每个新行为一个简单定向用例即可；完整测试在 FPGA 上进行。

**状态：已冻结（2026-10-06，用户要求“根据这个写rtl吧”，确认按正文 V1～V8 实施）。**

**修订说明（相对草稿 `28ff6b7`）：** 按 `cbe3372` 重新核对第 1 节；补齐草稿的三处缺口——F0 何时消费块（V1）、
F1 截断后 F0 剩余部分如何作废（V2）、零指令块如何握手（V3）；用“半字索引”统一出口/覆盖判定（V4）；
`crosses_region` 改为 `is_edge`（V5）。全部决定见第 9 节。

---

## 0. 任务书

```
目标：L7b —— 支持 RV64C（整数部分）：F0 长度识别、RVC 展开、跨块 edge 指令（D33）、
      跨页后半字异常（D34）、F0/F1 每拍 4 条（D35）；预测器启用 cfi_is_rvc / is_edge；
      后端与 CSR 改为 IALIGN=16。
涉及模块（允许改动）：
  rtl/frontend/{ifu_f0,ifu_f1,bpu,bpu_slow_check,ftq,ubtb,main_btb,frontend}.sv，
  新增 rtl/frontend/rvc_expander.sv
  rtl/common/{o3_cfg_pkg,o3_types_pkg}.sv
  rtl/backend/{branch_execute_unit,rob,backend}.sv，rtl/system/csr_file.sv
  rtl/rtl.f；对应 sim/cocotb/*；sim/o3/tests 新增程序与 sim/o3/Makefile 目标
不做：第 7 节
验收：第 8 节
```

## 1. 现状（`cbe3372` 源码核实）

| 位置 | 现状 | L7b 要做 |
| --- | --- | --- |
| `o3_cfg_pkg.sv:290` | `f0_slots: 8`（含义“F0 每拍处理槽位数”） | 改 4，含义改为每拍最多输出条数（2.1） |
| `o3_types_pkg.sv:265–277` | `f0_inst_t` 有 `crosses_region`（“后半字来自下一区域”，与 D33 相反） | 改为 `is_edge`（6） |
| `ifu_f0.sv:70–106` | 组合直通、IALIGN=32：只认与入口同相位的 32 位指令；短编码报非法；按槽位输出 8 lane | 第 2 节重写 |
| `ifu_f1.sv:135–143` | 扫描过滤 `slot <= cfi_slot`；覆盖判定 `slot+1 == cfi_slot` | 按半字索引（3.1） |
| `ifu_f1.sv:153,203,226` | 顺序目标、未修正 `predicted_next_pc`、`ras_push_addr` 都是 `pc+4` | 改 `pc+inst_len` |
| `ifu_f1.sv:229` | 每拍最后一项置 `ftq_last` | 只在块的最后一拍（3.1） |
| `ifu_f1.sv:237` | 请求锁存条件含 `|out_valid_o` | 零指令拍也要能锁存（3.3） |
| `bpu.sv:97,108`；`bpu_slow_check.sv:92,95` | 历史 branch PC = `base+2*slot`；RAS push = `base+2*slot+4` | 4.1 出口 PC 公式 |
| `ubtb.sv:184–185`；`main_btb.sv:192–193` | 训练写入时强制 `cfi_is_rvc/is_edge = 0` | 存训练值（4.1） |
| `ftq.sv:383–389` | 出口解析只记 slot/type/ras/target | 增加两位（4.2） |
| `ftq.sv:396–408` | 只在本区域 `region_last` 提交时置 `commit_last` | 4.3 空区域 |
| `branch_execute_unit.sv:65–69` | taken 目标 bit1 报 IALIGN=32 异常 | 删除（5） |
| `branch_execute_unit.sv:41,76` | 顺序后继与 link 已用 `pc+inst_len` | 不改 |
| `rob.sv:317,323` | `inst_len` 写死 4，`succ_pc = pc+4` | 用实际长度（5） |
| `backend.sv:649–650` | 译码 uop 已带 `inst_len/is_rvc` | 接到 ROB 分配口（5） |
| `csr_file.sv:79,117,144` | `MISA` = RV64IM（`…1100`）；`mepc` CSR 写入与 trap 写入清低 2 位 | 第 5 节 |
| `redirect_arbiter.sv:74` | 执行重定向 RAS push 已用 `branch_pc + inst_len` | 不改 |
| `sim/cocotb/csr_file/test_csr_file.py:12,21` | 期望 `misa=…1100`、`mepc` 清低 2 位 | 随 5 节更新期望 |
| Flow `~/flow-mem` `design/src/main/scala/air/AirRvcDecompressor.scala` | 完整 RV64C 整数解压器（已确认文件存在） | 手工翻译为 `rvc_expander.sv`（2.2） |

## 2. F0（`ifu_f0.sv`）

### 2.1 配置与状态

- `O3_CFG.fe.fetch.f0_slots` 改为 **4**，含义“F0 每拍最多输出 4 条指令”（D35）；`out_o[0..3]` 按程序顺序压紧，不再按槽位输出。`f1_width` 保持 4。
- F0 由组合直通改为带状态：
  - `hold_q`：块在一拍内处理不完时保存块数据、brief、下一个待处理槽位 `pos_q`（V1）。
  - `pend_q`：edge 前半字暂存：`valid`、16 位数据、存入时所在块的 `ftq_id` 与 `region_base`（身份槽位固定为 7）。

### 2.2 RVC 展开（`rvc_expander.sv`）

- 手工翻译 Flow `~/flow-mem` 提交 `02e3f6fd2219186c9ddbe7cc7dd3e486ae9709f6` 的 `AirRvcDecompressor.scala`：输入 16 位，输出 32 位 `out` 与 `legal`。纯组合；F0 每条输出 lane 一份（4 份）。
- 浮点 RVC（C.FLD/C.FSD/C.FLDSP/C.FSDSP）与保留编码按原实现判非法；L9 加 F/D 时再放开（记入 L9）。
- 非法：该项 `exc_valid=1`、`cause=ILLEGAL_INSTRUCTION`、`tval` = 16 位原编码零扩展（与现有短编码处理相同）。
- `raw_instruction`：RVC 为低 16 位原编码、高 16 位清零；`instruction` 为展开结果。

### 2.3 半字索引（V4）

本节和第 3 节统一用有符号半字索引描述位置：

- 区域内槽位 `s` 的索引为 `s`（0～7）；edge 指令的起点索引为 **−1**。
- 指令占用：RVC `[s, s]`；32 位 `[s, s+1]`；edge `[−1, 0]`。下文 `start(i)`、`end(i)` 指占用区间两端。
- 预测出口索引 `e = pred.is_edge ? −1 : pred.cfi_slot`，仅在 `pred.cfi_valid=1` 时有定义（L7a U22）。
- 交付项的 `slot` 字段：普通指令为 `start`；edge 指令为 **0**（同时 `is_edge=1`）。区域内 slot 0 若是 edge 后半字，就不可能是另一条指令的起点，所以 `(ftq_id, 0)` 仍唯一，`fe_age/fe_killed_by` 不改。

### 2.4 长度识别与输出

处理一个块（区域基址 B，`entry = brief.pred.entry_slot`）时：

1. **起点。** 若 `pend_q.valid && region_base == pend_q.region_base + 16 && entry == 0`，先输出 edge 指令：`pc = B − 2`，`instruction = {slot0 半字, pend 半字}`（不经展开器；前半字低 2 位必为 `11`），`inst_len=4`，`is_rvc=0`，`ftq_id` = 本块，`slot=0`，`is_edge=1`；随后从槽 1 继续，清 `pend_q`。否则从 `entry` 开始；若 `pend_q.valid` 但条件不满足，丢弃 `pend_q`（不输出）。
2. **逐条识别。** 在槽 `s`：低 2 位 `!= 2'b11` → 16 位指令，展开，`inst_len=2`，`is_rvc=1`，下一槽 `s+1`。否则 32 位：`s <= 6` 时取 `s, s+1` 两个半字，`inst_len=4`，下一槽 `s+2`；`s == 7` 时把该半字存入 `pend_q`（`ftq_id`、`region_base = B`），本块结束（这条指令属于下一区域，D33）。
3. **结束条件**（先到者为准）：
   - 已输出**到达出口的指令**：`pred.cfi_valid` 时，第一条满足 `end(i) >= e` 的指令（含 edge）。输出它之后结束，不论它是否真的起于 `e`（是否需要修正由 F1 判，3.1）。
   - 输出了异常项（L7a U20）。
   - 处理完槽 7，或槽 7 存入 `pend_q`。
4. **每拍最多 4 条（D35）。** edge 指令也算一条。块在本拍结束时置 `out_last_o=1`；否则剩余部分写入 `hold_q`，下一拍从 `pos_q` 继续。
5. 块结束于“槽 7 存入 `pend_q`”时，最后一拍置 `out_edge_pend_o=1`（F1 用于 3.2 的 c′）。
6. **零指令块**（入口槽 7 且该半字是 32 位起点，例如跳转目标恰为 edge 指令起点）：F0 仍以 `out_beat_valid_o=1`、4 lane 全无效、`out_last_o=1`、`out_edge_pend_o=1` 与 F1 握手一次（V3）；fetch buffer 不写入任何项。

### 2.5 握手（V1）

- 新增 `out_beat_valid_o`：本拍有一拍输出（可以 0 条指令）。F0→F1 握手为 `out_beat_valid_o && out_ready_i`。
- `hold_q` 无效时，F0 直接用返回队列出队块组合输出（与现状相同的时序）；`in_ready_o = out_ready_i && !hold_q.valid && !kill && !sync_clear && !rst`。即**块在第一拍握手时就从返回队列取走**；处理不完的部分在同一沿写入 `hold_q`。
- `hold_q` 有效时，从 `hold_q` 输出，`in_ready_o=0`；块结束那一拍沿上清 `hold_q`。下一拍才接受新块（8 条 RVC 的块两拍输出，与 4 条/拍吞吐一致，不额外插泡）。

### 2.6 异常

- 整块取指异常（`in_i.exc_valid`）：只输出一项，`pc` = 起点指令 PC（edge 起点时为 `B−2`），`exc_valid=1`，`inst_len=0`，`instruction/raw_instruction=0`，本块结束；清 `pend_q`。
- **D34 跨页后半字异常：** 起点为 edge 且本块 `exc_valid` 时，该项 `pc = B−2`（epc），`tval = B`（区域基址），`is_edge=1`，`slot=0`。
- 非 edge 起点的整块异常：`tval = pc`（同现状）。

### 2.7 kill、截断与同步（V2）

- kill 拍阻塞握手（同 L7a）。时钟沿上按下列边界清除状态：`hold_q` 用 `(hold.ftq_id, pos_q)`，`pend_q` 用 `(pend.ftq_id, 7)`。
  - kill：`fe_killed_by(kill, id, slot, head)` 为真则清除。
  - **F1 截断：** F1 新增输出 `trunc_o`（本拍交付握手且产生修正请求，见 3.3）与边界 `trunc_slot_o`（修正项的 slot）。F0 在该沿把 `{valid:1, all:0, ftq_id:本拍块, slot:trunc_slot_o, kill_self:0}` 当作 kill 对 `hold_q`、`pend_q` 做同一判定。
  - 效果：普通修正（slot < 7）清掉本块剩余部分与本块 `pend_q`；c′（slot 7，3.2）不清 `pend_q`，重取 R+16 时拼出 edge。
- `sync_clear_i` 同时清 `hold_q`、`pend_q`。
- F1 修正请求晚一拍到仲裁器；这一拍内 F0 已靠截断清掉剩余部分，不依赖仲裁结果（V2）。

## 3. F1（`ifu_f1.sv`）

### 3.1 按长度与半字索引推广 L7a 第 4 节

- 输入为 F0 压紧的 4 条；每条带 `inst_len`、`is_rvc`、`is_edge`；另有 `in_beat_valid_i`、`in_last_i`、`in_edge_pend_i`。L7a 4.2 的判定一律使用**展开后的 32 位指令**（x1/x5 规则不变；C.JR/C.JALR 展开为 JALR，C.J 为 JAL x0，C.BEQZ/BNEZ 为 BR）。直接目标仍为 `pc + imm`（edge 的 pc 为 `B−2`）。
- L7a 4.2 中所有 `pc + 4` 改为 `pc + inst_len`：c/d 的顺序越过目标、未修正非出口项的 `predicted_next_pc`、`ras_push_addr`。`hist_branch_pc` 仍为指令 pc。
- 位置判定改用 2.3 的半字索引（仅 `pred.cfi_valid=1` 时，L7a U22）：
  - `is_exit(i)`：`start(i) == e`；
  - `earlier(i)`：`start(i) < e`（`cfi_valid=0` 时恒真，同 L7a）；
  - c 的判定对象由“覆盖出口槽的指令”改为“**到达出口的指令**”（2.4 第 3 条，即第一条 `end(i) >= e` 的交付项）：该项 `!is_exit || type == NONE` 时触发 c。L7a 下两者等价；RVC 下还覆盖“预测出口在 edge 但本块无 edge 指令”和“预测出口在槽 0 但槽 0 是 edge 后半字”两种情况。
  - d/e/f 仍只判出口指令（`is_exit`）。
- e 的 JAL 与 f 的 JALR：除 L7a 的 `ras_action` 不同外，若实际 `ras_action` 含 push（`PUSH`/`POP_PUSH`）且 `pred.cfi_is_rvc != is_rvc`，也触发修正（push 地址不同）。修正字段与 L7a 相同。
- `ftq_last`：只在 `in_last_i=1` 那拍的最后一条交付项置位；本拍因修正截断时，截断项置位（L7a U20 的异常项规则不变——F0 已在异常项结束块，必然 `in_last_i=1`）。零指令拍不产生 `ftq_last`（区域回收见 4.3）。

### 3.2 新增 c′：预测出口在 edge 前半字

- 条件：`pred.cfi_valid && !pred.is_edge && pred.cfi_slot == 7`，且本拍 `in_last_i && in_edge_pend_i`，且本拍没有交付项触发 a～f（c′ 位于块末，优先级最低）。这种情况下没有交付项到达出口（槽 7 是下一区域 edge 指令的前半字）。
- 修正：`ftq_id` = 本块，`slot=7`，`kill_self=0`，`target_pc = region_base + 16`，`ras_fix=NONE`，`hist_inject=0`。不修改任何交付项的 `pred_taken`（本块交付项都在槽 7 之前，原本就是 0）。
- 边界 `(R,7)`、`kill_self=0` 不杀 `pend_q`（2.7）；重取 R+16 时 F0 拼出 edge 指令。

### 3.3 请求锁存与截断输出

- `pd_req_q` 锁存条件改为 `in_ready_o && in_beat_valid_i && pd_req.valid`（去掉 `|out_valid_o`，零指令拍的 c′ 也能锁存）。其余同 L7a 4.3（下一拍送仲裁器、不组合依赖 kill）。
- 新增 `trunc_o = in_ready_o && in_beat_valid_i && pd_req.valid`，`trunc_slot_o = pd_req.slot`，组合送 F0（2.7）。F0 只在时钟沿使用，不构成组合环。

## 4. 预测器与 FTQ

### 4.1 字段启用

- `cfi_is_rvc`、`is_edge` 从“恒 0”改为真实值：出口 CFI 是 16 位 / 是 edge 指令。`o3_types_pkg.sv` 中 “L7b reserved; L7a always zero” 注释同步改掉。
- 出口 CFI 的 PC：`exit_pc = is_edge ? region_base − 2 : region_base + 2*cfi_slot`（edge 时 `cfi_slot=0`）。
  - RAS push 地址 = `exit_pc + (cfi_is_rvc ? 2 : 4)`：改 `bpu.sv:108`、`bpu_slow_check.sv:95`。
  - 历史 branch PC = `exit_pc`：改 `bpu.sv:97`、`bpu_slow_check.sv:92`。
- uBTB、主 BTB：删除 `ubtb.sv:184–185`、`main_btb.sv:192–193` 的强制清零，从 `train_i` 写入两字段；预测时原样输出（输出侧已接好）。
- 慢核对覆盖比较（L7a 3.2）增加 `cfi_is_rvc`、`is_edge`。
- mask 不变：edge 的 BR/JAL 记在 bit 0。同一区域被跳转进入（槽 0 是真实起点）时 bit 0 含义可能错，由预解码 c 修正，不另加机制。

### 4.2 训练来源

- FTQ 项新增 `actual_cfi_is_rvc`、`actual_cfi_is_edge`，在 `ftq.sv:383–389` 记录出口解析时写入：`is_rvc = (resolve_i.inst_len == 2)`，`is_edge = (resolve_i.branch_pc == region_base − 2)`（`region_base` 取该项 `fast_pred.region_base`）。
- 组装 `bpu_train_t`（`ftq.sv:424` 附近）时把两位填入 `train_d.cfi_is_rvc / is_edge`。

### 4.3 空区域回收

RVC 下区域可能一条指令都不交付（2.4 第 6 条）。该区域没有 `region_last` 提交，按现有规则永远不回收，FTQ 会被占满。

- 规则：FTQ 在同一沿收到区域 Y 的任意提交时，**所有比 Y 老的有效项一并置 `commit_last`**，按现有流程逐个训练与回收。依据：提交按程序顺序，Y 已提交说明更老区域不会再有指令。
- “比 Y 老”按 FTQ 环形顺序（`head` 到 Y 之间）。多个提交 lane 时取本沿最年轻的那个 Y 即可。

## 5. 后端与 CSR（IALIGN=16）

- `branch_execute_unit.sv:65–69`：删除 taken 目标 bit1 异常与注释，`result_o.exc` 恒 0（JALR 仍清 bit0；IALIGN=16 下直接目标不会不对齐）。
- `rob.sv`：分配口新增 `t_alloc_inst_len_i [MACHINE_WIDTH]`；`rob.sv:317` 写入该值，`rob.sv:323` 的 `succ_pc = pc + inst_len`。`backend.sv` 从 `decoded_uop[i].inst_len` 接入（`backend.sv:649`）。
- `csr_file.sv`：`MISA`（`:79`）改为 `64'h8000000000001104`（加 C）；`mepc` 的 CSR 写入（`:117`）与 trap 写入（`:144`）改为 `& ~64'd1`。`mtvec` 不变。
- 后端译码不改：前端已展开为 32 位指令。`raw_instruction` 只透传。

## 6. 类型与端口改动汇总

- `f0_inst_t`：`crosses_region` 改名为 `is_edge`，注释改为 D33 含义；`ftq_id` 注释改为“归属：edge 为后半字所在区域，其余为起始半字所在区域”（V5）。
- `fetch_entry_t`：增加 `is_edge`。后端只透传，不使用。
- F0 新增输出：`out_beat_valid_o`、`out_last_o`、`out_edge_pend_o`；新增输入：`trunc_i`、`trunc_slot_i`。
- F1 新增输入：`in_beat_valid_i`、`in_last_i`、`in_edge_pend_i`；新增输出：`trunc_o`、`trunc_slot_o`。`frontend.sv` 连线。
- FTQ 项增加 `actual_cfi_is_rvc`、`actual_cfi_is_edge`。
- ROB 分配口增加 `t_alloc_inst_len_i`。

## 7. 不做

- 浮点 RVC（L9）；Zc* 扩展；RV32 专有编码（C.JAL 在 RV64 为 C.ADDIW，按 Flow 实现）。
- 不为 mask bit 0 的二义性加机制（4.1）；不加辅助取指请求（D33）。
- F0/F1 性能事件不新增；`perf_o` 保持 0。
- 不跑 Spike、ACT4；不综合。现有 IALIGN=32 程序（`-march=rv64im…`）照常运行，作为回归。
- Spike trace 对 RVC 的 `raw_instruction` 比对不处理（L7b 整核程序不带 `--spike`）。

## 8. 验收（少量定向用例）

用户原则：每个新行为一个简单用例；正确性失败才阻塞提交，其余记为已知问题继续。

| 位置 | 用例 |
| --- | --- |
| `sim/cocotb/rvc_expander`（新） | 翻译 Flow `design/src/test/scala/air/AirRvcDecompressorSpec.scala` 的测试向量 |
| `sim/cocotb/ifu_f0`（改） | ① 16/32 位混合块；② 一块 8 条 RVC，两拍输出且第一拍即取走返回队列项；③ edge 拼接；④ edge 遇非顺序块丢弃 `pend_q`；⑤ D34：edge 起点块取指异常，检查 pc/tval；⑥ 零指令块握手；⑦ kill 清 `hold_q`/`pend_q` 一例；⑧ 截断：普通 slot 清 `hold_q`/`pend_q`，slot 7 保留 `pend_q` |
| `sim/cocotb/ifu_f1`（改） | ① RVC 出口按 `pc+2` 修正一例；② c′（含零指令拍）一例；③ edge 出口位置匹配 / 预测 edge 但无 edge / 预测槽 0 但槽 0 是 edge 后半字 各一例；④ `cfi_is_rvc` 不一致的 call 修正一例；⑤ 两拍块只在末拍置 `ftq_last`；L7a 原有用例全部保留 |
| `sim/cocotb/bpu` 或 `ubtb`（改） | 训练写入 `cfi_is_rvc/is_edge` 后预测读回，RAS push 地址 `+2` 一例 |
| `sim/cocotb/csr_file`（改） | `misa` 含 C；`mepc` 写 `…2` 读回保留 bit1 |
| 整核 `sim/o3/tests/l7b_rvc.S`（新，`-march=rv64imc_zicsr`，tohost 自查） | 一个循环里含：C.BEQZ/C.BNEZ、C.J、C.JALR/C.JR 调用返回、一条跨 16B 边界的 32 位分支（edge）、一个入口在槽 7 的 32 位跳转目标（零指令块）；循环 100 次后校验累加值；Makefile 目标 `run-l7b-rvc`，不带 `--spike` |
| 回归 | `run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`、`run-l7-predict`（含 `+L7_CHECK`）；L7a 全部 cocotb；`scripts/lint.sh` 0 errors |

交回：提交号、命令、exit code、用例数、失败与修复记录、未做项。不需要 SHA256 清单。

## 9. 审阅决定（V1～V8 已确认，正文为实施依据）

| 编号 | 问题 | 推荐（已写入） | 理由 |
| --- | --- | --- | --- |
| V1 | F0 何时从返回队列取走一个需要两拍的块（草稿写“处理完才 ready”，又说 `hold_q` 保存块数据，自相矛盾） | 第一拍握手即取走，剩余部分存 `hold_q`（2.5） | 若块留在返回队列，F1 在第一拍截断时该区域仍存活（kill 边界在区域内），F0 会从头重送重复指令；拷贝进 `hold_q` 后可直接按 `(id, pos_q)` 清除 |
| V2 | F1 截断后，F0 `hold_q` 的剩余部分谁来作废 | F1 组合输出 `trunc_o/trunc_slot_o`，F0 在沿上按同一 kill 判定清除（2.7、3.3） | 不依赖“下一拍仲裁器必然 kill 到它”的推理；与 c′ 的“slot 7 不清 `pend_q`”自然一致 |
| V3 | 零指令块如何与 F1 握手（草稿要求 F1 判 c′，但现有锁存条件要求有交付项） | 新增 `out_beat_valid_o`；锁存去掉 `|out_valid_o`（2.4、3.3） | 否则 c′ 在零指令块上永远不发出，预测器一直错 |
| V4 | 出口 / 覆盖 / 更早的判定如何处理 edge（槽 −1） | 统一用半字索引，c 改判“到达出口的指令”（2.3、3.1） | 一套规则覆盖 edge 的匹配和两种不匹配；L7a 下行为不变 |
| V5 | `f0_inst_t.crosses_region` 与新 `is_edge` | 改名为 `is_edge`，不并存 | 原字段语义（指令属于前一区域）与 D33 相反，且无任何使用者 |
| V6 | edge 指令的交付 `slot` | 0（配 `is_edge=1`） | 槽 0 此时是后半字，不会冲突；`fe_age`、仲裁、FTQ 提交按 slot 的逻辑都不用改 |
| V7 | 空区域回收 | 提交 Y 时更老的项一并 `commit_last`（4.3） | 不改 ROB 合同；程序顺序保证正确 |
| V8 | 任务拆分 | T06a（类型、展开器、后端/CSR IALIGN=16）→ T06b（F0/F1/预测器/FTQ 与整核程序），连续执行 | T06a 不改前端行为，IALIGN=32 回归就能验证；T06b 必须整体完成才能跑 RVC 程序 |
