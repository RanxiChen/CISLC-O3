# O3-T12：L7c 前端吞吐与预测补全 RTL spec（已冻结）

日期：2026-10-08。审计快照：`2e2b0fc`（`fix/memory-ram-ooc-20261008`）。行号均指该快照。

依据：[前端基线](../design/CISLC-O3-FRONTEND-DESIGN-BASELINE.md) D01～D35（重点 D02、D08、D14～D19、D23、D24、D29、D31）；[后端基线](../design/CISLC-O3-BACKEND-DESIGN-BASELINE.md) B48；[L7a spec](l7a-predictor-spec.md)、[L7b spec](l7b-rvc-spec.md)；2026-10-08 用户决定：前端重构，本级包含多项返回队列、FTQ 早释放与训练流水、FDIP 预取、loop predictor、预测表 BRAM 化、性能事件补全。

**状态：冻结基线（2026-10-08，用户确认第 12 节 W1～W12 按推荐值）。** 冻结时仅检查代码并修改文档。随后用户授权实施期间自行修正 spec/test 冲突、完成全部机制后统一审查；授权修订见第 16 节，实现与最终同 SHA 门禁见 [T12 报告](../tasks/O3-T12-report.md)。

**明确不改**（用户 2026-10-08）：D09/D22 taken-only 路径历史及其编码、折叠函数；TAGE 每区域共享 tag 的组织；主 BTB 单目标（D05）。这三项等 SoC 上板后用本级补全的计数器测量，再决定是否修改（第 8 节事件为此服务）。D02 的 BTB 两拍、TAGE 三拍查询时序不变。

---

## 0. 任务书

```
目标：L7c —— 把前端从"机制齐全但吞吐受限"补成常规乱序核前端：
      1) 原始返回队列 8 项，多未决、乱序回填、按序交付（D14/D15/D17）；
      2) FTQ 交接训练包后立即释放，训练经队列流水更新，稳态每拍一个区域；
      3) 主 BTB、TAGE 存储映射为同步 BRAM，查询与训练端口分离，训练规则不变；
      4) FTQ 驱动的 FDIP 预取（D18/D19），含翻译复用与 ITLB 命中探测；
      5) loop predictor（新机制，修订前端 4.4 与 v1 计划第 5 节）；
      6) 特性开关 CSR（loop、预取可关，用于上板 A/B 测量）；
      7) 补全上板评估所需性能事件（条件分支 MPKI、JALR/return、预取、返回队列、交付）。
涉及模块（允许改动）：
  rtl/frontend/{ftq,fetch_return_queue,bpu,bpu_slow_check,tage,main_btb,ubtb,
                history_snapshot_store,redirect_arbiter,fetch_prefetcher,
                prefetch_xlate_cache,icache,icache_mshr,itlb,frontend,ras}.sv
  新增 rtl/frontend/loop_predictor.sv
  （sv39_tlb 位于 rtl/frontend/itlb.sv，只有 ITLB 例化它）
  rtl/common/{o3_cfg_pkg,o3_types_pkg,o3_sram_1r1w}.sv
  rtl/system/csr_file.sv（仅 0x7C0 特性开关与 fe_csr_t 字段）
  rtl/rtl.f；对应 sim/cocotb/*；sim/o3/tests 新增程序与 Makefile 目标
闭环简化许可与不做：第 11 节
验收：第 14 节（手写定向 testbench；不跑 Spike/ACT4）
任务拆分：第 15 节（T12a→T12b→T12c→T12d）
```

起点：PMP 范围预解码任务（`doc/tasks/O3-pmp-predecode-task.md`）提交之后的 `fix/memory-ram-ooc-20261008` HEAD；新分支 `feat/l7c-frontend`。本级的预取 PMP 检查直接使用该任务引入的 `pmp_allow_dec`。

## 1. 现状（源码核实）

| 位置 | 现状 | 本级要做 |
| --- | --- | --- |
| `fetch_return_queue.sv:74–133` | 单槽：`occupied_q` 一位，第二笔 demand 被回压；`rsv_idx_o` 恒 0；`perf_o='0` | 第 4 节：8 项槽池 + 程序顺序队列 |
| `icache.sv` | 已非阻塞：4 MSHR、`WAITERS=return_queue_depth` 个等待者、乱序响应带 `rq_idx`；预取端口 `pf_req_*` 已有查 L1/在途/分配 MSHR 逻辑（`:148–157`），但无 MSHR 保留、无 PMP、无 epoch 检查、无来源标记 | 第 5.4 节 |
| `ftq.sv:318–323, 421–445` | 训练交接三拍一项：IDLE 发快照读 → WAIT 组包 → SEND 等 BPU 接受 → 释放（`:349–357`） | 第 2 节：两级流水交接，稳态每拍一项，交接即释放 |
| `ftq.sv:289–294` | prefetch 游标：只看 `!pf_issued`，不看 `slow_done`；被 demand 超过后不追赶 | 第 5.1 节 |
| `ftq.sv:375–395, 447–510` | 解析记录 `actual_cfi_*`、`resolved_*`、`mispredicted` 在部分清除（`kill_self=0`）时**不随被杀槽位清理**：较年轻槽位先执行、记下的 taken CFI 会残留到训练包 | 第 9.1 节：修正（训练正确性） |
| `bpu.sv:72–75` | `train_ready_o` = 三表 ready 之与；训练包直接广播 | 第 3 节：训练队列 + T0/T1 流水 |
| `tage.sv:285–363` | 寄存器阵列，训练在一个沿内读改写（重新检查当前表）；`tagged_q` 6×1024×(1+8+24+16) 位、`base_q` 2048×24 位全为 FF | 第 3.2 节：双副本 BRAM，训练规则逐位不变 |
| `main_btb.sv:137–212` | 同上，`entry_q` 512×4 项全为 FF；`valid_q`/`replace_q` 为 FF | 第 3.3 节 |
| `history_snapshot_store.sv:66–69` | 训练读口响应按"当前输入 id"门控，连续两拍读不同 id 时前一个响应被抑制 | 第 2.2 节：响应带 id 输出，由 FTQ 校验 |
| `fetch_prefetcher.sv`、`prefetch_xlate_cache.sv` | 空壳，输出未驱动；`frontend.sv:506` 把预取事件强制为 0 | 第 5.2、5.3 节 |
| `itlb.sv:7–170`（`sv39_tlb` 与 `itlb`） | 单查询口；未命中即申请 PTW、锁存故障待重试 | 第 5.2 节：增加不产生 PTW/故障/PLRU 更新的命中探测 |
| `ifu_f1.sv:43–73`、`branch_unit.sv:146–152` | **已按 x1/x5 解码 RAS 动作**；`ras.sv:33` 的"尚未实现 x1/x5"注释已过时 | 只改注释；return 正误改为提交事件（第 8 节） |
| `frontend.sv:29, 365` | 注释称 D28 同步序列未实现；实际 L10 T08a 已实现（`commit_ctrl.sv:164/207`、`frontend_sync_ctrl.sv:73`） | 只改注释；PMP 时序问题由独立的 PMP 预解码任务处理，不在本级 |
| `o3_types_pkg.sv` `PE_*` | `PE_TAGE_COND_PRED`、`PE_XLATE_REUSE`、`PE_PF_*`、`PE_RQ_*`、`PE_DELIVER_LT4_*`、`PE_BACKEND_BACKPRESSURE_CYCLE` 有编号无驱动；没有条件分支提交数与方向误预测数 | 第 8 节 |
| `csr_file.sv` | 无自定义 CSR | 第 7 节：0x7C0 |

## 2. FTQ 训练交接与早释放

### 2.1 原则

区域有效指令全部提交（`commit_last`）后，FTQ 把训练所需的全部信息组装成训练包交给 BPU 训练队列；**训练包被队列接收的那个沿即释放该 FTQ 项**，不等预测表写完。训练队列保证不丢包（第 3.1 节信用规则），因此释放安全。

### 2.2 两级交接流水（替换 `ftq.sv:421–445` 的 TRAIN 状态机）

状态：`ho_busy_q`（H1 有在途交接）、`ho_id_q`。

- **H0（周期 t，`!rst`）**：令 `sel = add_idx(head_q, ho_busy_q)`。当 `count_q > ho_busy_q`、`entries_q[sel].valid && entries_q[sel].commit_last`、且 `train_free_i > ho_busy_q` 时，发出快照训练读 `snap_train_rd_req_o=1`、`snap_train_rd_id_o = entries_q[sel].id`；沿上 `ho_busy_d=1`、`ho_id_d=entries_q[sel].id`。
- **H1（周期 t+1，`ho_busy_q=1`）**：快照存储在本拍给出 `{valid, id, folds}`（第 2.3 节），且 `id == ho_id_q == entries_q[head_q].id`（断言）。组合组装训练包（第 2.4 节），`bpu_train_valid_o=1`；BPU 本拍必然接收（信用保证，断言 `bpu_train_ready_i`）。沿上释放 `head_q` 项（现 `ftq.sv:349–357` 的释放动作），并计提交口径事件（第 8 节）。若本拍 H0 也发出，则 `ho_busy` 保持 1，否则清 0。
- 稳态吞吐：每拍一项。`train_free_i` 来自 BPU 训练队列空位数（第 3.1 节）。
- kill 不影响交接：被交接的项都在已提交前缀内，`ftq.sv:447–486` 的保护前缀规则保证它们不被清除（断言）。复位清 `ho_busy_q`。

### 2.3 快照存储训练读口

`history_snapshot_store` 训练读口改为：请求在周期 t 沿上读出，周期 t+1 输出 `rd_train_resp_valid_o`、`rd_train_resp_id_o`、`rd_train_snapshot_o`，**不再与本拍输入 id 比较**（`:66–69` 的训练口门控删除）；身份校验由 FTQ 在 H1 完成。恢复读口不变。

### 2.4 训练包 `bpu_train_t` 变更

- `hist_snapshot_t ctx` 改为 `logic [HIST_FOLD_W-1:0] folds`（训练只用 C；E 不再随包传递，节省约 1024 位）。各表 `train_i.ctx.folds` 改为 `train_i.folds`。
- 新增 `loop_train_t loop`（第 6.5 节）。
- 其余字段与组装来源同 `ftq.sv:428–441`，但 `actual_cfi_*`、`committed_*`、`mispredicted` 按第 9.1 节修正后的记录取值。
- `mispredicted` 改为 `|(mispred_mask & valid_slots)`，`mispred_mask` 见第 9.1 节。

### 2.5 删除的内容

`train_state_q/train_id_q/train_q` 与 `TRAIN_IDLE/WAIT/SEND` 删除。`ftq.sv:594–611` 的提交事件改在 H1 计数，读 `entries_q[head_q]`。

## 3. 训练队列、预测表 BRAM 化与训练流水

### 3.1 训练队列（BPU 内）

- 深度 `CFG.ftq.train_queue_depth`（保持 4），FIFO，每项一个 `bpu_train_t`。
- 输出 `train_free_o = depth − count`（组合，反映本拍开始时的空位）。只有 FTQ H1 写入，因此"H0 时空位 > 在途交接数"保证 H1 必然有空位。
- 队列非空时，队头包每拍出队一个（即第 3.2 节的 T0）；各表训练流水不回压。`train_ready_o` 保留为 `count < depth`，仅供断言。

### 3.2 统一训练流水（uBTB、主 BTB、TAGE、loop 同步）

| 拍 | 动作 |
| --- | --- |
| T0 | 队头包（队列项为寄存器）出队的那一拍：组合计算各表地址（TAGE 6 个 index/tag 与 base index，主 BTB set/tag）；本拍末的沿上向各表**训练副本**发同步读，同沿把包移入 T1 寄存器 |
| T1 | 取得训练副本读数；**写旁路**：若上一包在 T1 写了同一表同一行（TAGE 同表同 index、base 同 index、BTB 同 set 同 way），用其写入值（行内容及 valid）替代 RAM 读数；FF 状态（valid、replace、uBTB、loop 表）在 T1 直接读当前值；uBTB 与 loop 的训练即以 T1 寄存器中的包驱动其现有训练输入。随后执行与现有 RTL **逐位相同**的更新算法；在 T1 末的沿上同时写查询副本与训练副本、更新 FF |

- 写旁路深度只需 1：T1(k) 的写与 T0(k+1) 的读在同一沿；更早的写已在 RAM 中。
- 连续同行训练的结果必须与"每个包在一个沿内顺序读改写"的旧语义完全一致（测试见 14.1）。
- 各表的触发条件保持不变（如 TAGE 仅 `|br_commit_mask`、主 BTB 按 `main_btb.sv:166–168`）。

### 3.3 TAGE 存储

- tagged 表 i：两份 RAM 副本 `q`（查询）、`t`（训练），各 `2^index_bits[i]` 行 × `ROW_W = tag_bits[i] + 8·ctr_bits + 8·useful_bits`（当前 48 位）。行内 `valid` 不进 RAM，改为 FF 阵列 `tvalid_q[i][2^index_bits[i]]`，复位清 0。
- base 表：两份 RAM 副本，`base_entries` 行 × `8·ctr_bits`。另设 FF `base_wr_q[base_entries]`，复位清 0；为 0 的行读出时按复位值处理（每槽 `(1<<(ctr_bits−1))−1`），训练写入置 1。由此复位后无需逐行初始化，复位语义与现在相同。
- 每个 RAM 例化 `rtl/common/o3_sram_1r1w.sv`（单写口、单同步读口，`ram_style="block"`），写地址与数据在例化外统一形成。该封装新增参数 `ALLOW_COLLISION`（默认 0，保持现有断言）：为 1 时不断言同址读写，且在 `ifndef SYNTHESIS` 下把碰撞拍的读数按位取反输出，使遗漏写旁路的实现在仿真中必然出错。本级所有预测表 RAM 取 `ALLOW_COLLISION=1`，碰撞读数一律由调用方旁路覆盖。`rtl/common/o3_sram_1r1w.sv` 与 `sim/cocotb/o3_sram_1r1w` 加入允许改动范围。
- **查询时序不变**：N 组合算 index/tag，N 沿锁存 S1；N+1 沿以 S1 index 读 `q` 副本，同沿锁存 `tvalid/base_wr`；N+2 RAM 输出直接作为现 `s2_row_q/s2_base_q`。现有 `stall_i` 语义保留：stall 时 RAM 读使能为 0，`o3_sram_1r1w` 输出保持（BPU 仍接 0，保留是为了现有单模块测试）；`kill_i` 语义不变。
- **查询与训练同沿同行**：查询读数取**新写入值**（写优先旁路：寄存最近一次写的 `{表, index, 行, valid}`，S2 比较命中则替代）。这改变 `tage.sv:21–22` 注释"同拍读旧值"为"读新值"，只影响训练可见早一拍，属预测性能层面，无正确性影响。

### 3.4 主 BTB 存储

- 每路两份 RAM 副本（`q`、`t`），各 `SETS` 行 × `$bits(btb_entry_t)`。`valid_q`、`replace_q` 保持 FF。
- 查询时序不变：N 沿以 `set_of(s0_region_base_i)` 读 `q` 副本各路、锁存 `valid_q[set]`；N+1 比较输出。`stall_i/kill_i` 处理同 3.3。同沿训练写同 set 同路时，该路读数与 valid 取新值。
- 训练：T0 读 `t` 副本该 set 全部路；T1 加写旁路后执行 `main_btb.sv:166–211` 的选择与更新，写选中路的两份副本。

### 3.5 不 BRAM 化的结构

uBTB（32 项全相联 FF）、RAS、`branch_history`、`history_snapshot_store`、loop predictor 保持 FF。快照存储的 RAM 化不在本级（D23 存储组织仍待定）。

## 4. 原始返回队列 8 项

### 4.1 组织

- `RQ_DEPTH = CFG.fetch.return_queue_depth`（8）个槽，每槽：`state ∈ {FREE, PEND, READY, ZOMBIE}`、`ftq_id`、`region_base`、16B `data`、`exc_valid/exc_cause`。
- 顺序队列 `ord`：深度 `RQ_DEPTH`，按程序顺序保存 PEND/READY 槽号。ZOMBIE 与 FREE 不在其中。
- 不变量：PEND+READY 槽数 = `ord` 占用；PEND+ZOMBIE 槽数 = 已被 ICache 接受、尚未响应的 demand 数 ≤ `RQ_DEPTH`，因此 ICache 等待者（`WAITERS = RQ_DEPTH`）永不耗尽（断言）。

### 4.2 行为（同一沿内按下列顺序合成次态）

1. **预留**：`rsv_ready_o = !rst && !kill_i.valid && ∃FREE`；`rsv_idx_o` = 编号最小的 FREE 槽。`rsv_fire_i` 时分配 `s = rsv_req_i.rq_idx`（断言 `s` 为 FREE），置 PEND，记录身份，`s` 追加到 `ord` 尾。FTQ 的 `demand_hold` 锁存请求时 `rq_idx` 随之锁存；由于只有预留会消耗 FREE 槽，被锁存的槽在握手前保持 FREE。
2. **响应**：`resp_i.valid` 时取槽 `s = resp_i.rq_idx`，要求 `slot[s].ftq_id == resp_i.ftq_id`（否则断言失败）：PEND→READY 并写数据/异常；ZOMBIE→FREE。同沿新预留的槽也可接收响应（保留 `fetch_return_queue.sv:123–127` 的同沿语义）。
3. **kill**：`ord` 中满足 `fe_killed_by(kill_i, ftq_id, 0, ftq_head_i)` 的槽：PEND→ZOMBIE，READY→FREE；被杀槽在 `ord` 中必为连续后缀（断言），截断 `ord`。同沿到达的响应若属于被杀的 PEND 槽，该槽直接 FREE。
4. **出队**：`ord` 队头槽 READY，且 `ftq_brief_i.slow_done && ftq_brief_i.ftq_id == 槽 id`，且 `!kill_i.valid` 时 `deq_valid_o=1`；握手后槽 FREE、`ord` 弹出。`ftq_brief_rd_*` 按 `ord` 队头槽的 id 读取。

ZOMBIE 只占容量，不阻塞队头，符合前端基线第 10 节"killed 且仍 pending 的槽位保留至响应结束再回收"。

### 4.3 事件

| 事件 | 产生处与条件 |
| --- | --- |
| `PE_RQ_FULL_CYCLE` | FTQ：demand 游标项满足除 `rq_rsv_ready_i` 外全部发射条件而 `!rq_rsv_ready_i`，每拍 +1 |
| `PE_RQ_HEAD_WAIT_SLOW_CYCLE` | 队头 READY 但 `!slow_done` |
| `PE_RQ_HEAD_WAIT_DATA_CYCLE` | 队头 PEND |
| `PE_RQ_ZOMBIE`（新） | 每拍加当前 ZOMBIE 槽数 |

## 5. FDIP 预取

### 5.1 FTQ prefetch 游标

- `pf_valid_o = !rst && !hold_i && !kill_i.valid && count_q != 0 && e.valid && e.slow_done && !e.demand_issued && !e.pf_issued`，`e = entries_q[pf_q]`。增加 `slow_done`（只预取慢预测确认后的路径）和 `!demand_issued`（demand 已发的项无需预取）两个条件。
- **追赶规则**：令 `age(x) = (x − head) mod DEPTH`。每个沿的次态在其余更新之后，若 `age(pf_d) < age(demand_d)`，则 `pf_d = demand_d`。即 prefetch 游标永不落后于 demand 游标。
- 领先距离不另设上限，由 FTQ 深度、慢预测与第 5.4 节 MSHR 保留自然限制（W4）。
- kill 时按现有规则回卷（`ftq.sv:514–530`），再套用追赶规则。

### 5.2 预取器（`fetch_prefetcher.sv`）

每拍至多处理 FTQ 游标的一个项。记 `line = region_base[63:6]`，`xlate_on = csr_i.satp_mode == 8 && csr_i.priv != PRIV_M`（与 ICache 一致）。

1. `!ftq_pf_valid_i || kill_i.valid || hold_i`：不消费；放弃进行中的探测（第 4 步），迟到的探测结果丢弃。另外 `kill_i.valid` 沿上清 `last_line_valid_q`。
2. `csr_i.fe_feat.pf_dis`：`ftq_pf_ready_o=1` 直接消费，不发请求、不计事件。
3. `last_line_valid_q && line == last_line_q`：消费，`PE_PF_FILTERED+1`。
4. 翻译：
   - `!xlate_on`：`pa = va`；若 `va >> MEM_PADDR_W != 0`，消费并 `PE_PF_XLATE_MISS+1`。
   - 否则查翻译复用记录（5.3，组合）：命中得 `pa`，`PE_XLATE_REUSE+1`（在请求发出拍计）。
   - 复用未命中且本行尚未探测：发 ITLB 探测（下列），持有该项不消费。探测命中（`hit && !page_fault && !access_fault`）则安装到复用记录，下一拍重查即命中；探测未命中则消费并 `PE_PF_XLATE_MISS+1`。`PE_PF_XLATE_PROBE` 在探测被接受的拍 +1。
5. 发 `pf_req`：`{line_vaddr, paddr_valid=1, line_paddr, asid=csr_i.satp_asid, epoch=csr_i.epoch}`，保持到 `pf_req_ready_i`。握手拍消费 FTQ 项，按 `pf_resp_i.status`：`PF_ISSUED` → `PE_PF_ISSUED+1`；`PF_HIT`/`PF_INFLIGHT`/`PF_XLATE_FAIL` → `PE_PF_FILTERED+1`。
6. 凡消费（第 3～5 步），沿上 `last_line_q = line`、`last_line_valid_q = 1`；`PE_PF_CANDIDATE` 在每次消费（第 2 步除外）+1。

**ITLB 探测接口**（预取器 ↔ ICache）：
- 请求 `xprobe_valid_o`、`xprobe_vaddr_o`；ICache 在本拍 ITLB 查询口空闲时（本拍无 demand `fire`，且无 S1 重查）给 `xprobe_grant_i=1`，以该地址发 ITLB 查询，并标记 `probe=1`。
- N+1：ICache 输出 `xprobe_resp_o = {valid, hit, ppn, level, g}`。ICache S1 逻辑不得把探测结果当作 demand 翻译使用（探测只在 S1 不需要 ITLB 输出的拍发出，见 5.4 第 5 条）。
- `sv39_tlb` 增加 `lookup_probe_i`（仅 ITLB 例化，无其他使用者）：探测查询**不分配 miss、不申请 PTW、不锁存故障、不更新 PLRU**；`perf` 的 `PE_ITLB_HIT/MISS` 不计探测。
- **预取不发起 PTW**（W5，修订 D19 的"miss 才触发页表遍历"）。

### 5.3 翻译复用记录（`prefetch_xlate_cache.sv`）

- `CFG.prefetch.xlate_reuse_entries`（4）项全相联 FF，字段：`valid, vpn[26:0], ppn, level, g, asid, epoch`。
- 查找命中：`valid && epoch == csr_i.epoch && (g || asid == csr_i.satp_asid) && sv39_covers(vpn, va[38:12], level)`；`pa = sv39_pa(ppn, va, level)`。
- 安装来源两处：① ICache 每次 demand 在 S1 得到有效翻译（`v1_q && tlb_valid && tlb_hit && !tlb_pf && !tlb_af && xlate_on`）时输出 `xlate_fill_o = {valid, vpn, ppn, level, g, asid, epoch}`；② 探测命中。已有覆盖该地址的同上下文项则不重复安装；否则空项优先，满时轮转替换。
- 失效：`sfence_i.valid` 时按 D26 四种范围清除匹配项（与 ITLB 同一谓词，含 g 与按 level 覆盖）；epoch 不等的项视为无效。
- ITLB 需新增输出 `s1_g_o`（`resp.perm_g`）。

### 5.4 ICache 改动

1. **MSHR 保留**：`icache_mshr` 输出空闲数 `free_count_o`。预取需要新分配 MSHR 时，要求 `free_count > CFG.prefetch.mshr_reserve`（新字段，取 1）。因此修改 `icache.sv:152` 的 `pf_req_ready_o`。`PE_PF_THROTTLED`：预取请求有效但因保留/`demand_miss_pending` 未就绪，每拍 +1。
2. **权限**：预取在分配前用与 demand S3 相同的 PMP 函数（`pmp_allow_dec`，当前 `priv`，X 权限，64B）和 `pma_main` 检查行地址；失败返回 `PF_XLATE_FAIL`、不分配。`pf_req.epoch != csr_i.epoch` 同样返回 `PF_XLATE_FAIL`。
3. **来源标记**：tag 增加 `pf` 位；MSHR 每项增加 `pf_only`。预取新分配时 `pf_only=1`；demand miss 合并进 `pf_only=1` 的 MSHR 时清 0 并 `PE_PF_LATE+1`。回填安装时行 `pf = pf_only`。demand S3 命中 `pf=1` 的行：`PE_PF_USEFUL+1` 并清该位。回填替换掉 `pf=1` 的有效行：`PE_PF_UNUSED_EVICT+1`。`inv_all_i` 清 tag 时一并清 `pf`。
4. **demand 翻译输出**：5.3 的 `xlate_fill_o`。
5. **探测仲裁**：`xprobe_grant` 条件 = `!fire && !(v1_q && !xlate_saved_q && !(tlb_valid && !tlb_miss))`（即 `icache.sv:103` 的 ITLB `s0_valid_i` 表达式为 0）。探测拍之后一拍 `v1_q` 必为 0 或已保存翻译，S1 不读 ITLB 输出（断言）。

### 5.5 与系统同步的关系

`hold_i` 期间预取器不发请求与探测；`icache_idle` 已包含 MSHR 空闲，FENCE.I 失效前在途预取已完成；SFENCE.VMA 经 5.3 失效复用记录；satp 由 epoch 隔离。这些沿用 D25～D27 的既有序列，不新增同步步骤。

## 6. Loop predictor（`loop_predictor.sv`）

### 6.1 作用与范围

识别"连续若干次同向、然后一次反向"的条件分支，在置信后用记住的循环次数预测出口。补 TAGE 覆盖不到的情况：循环次数超过最长历史窗口（128 个 taken 事件），或循环体内有多个 taken 分支、使有效窗口缩短。每个区域最多跟踪一个循环分支。

### 6.2 存储（FF）

`CFG.loop.entries`（8）项全相联。每项：

| 字段 | 位宽 | 含义 |
| --- | --- | --- |
| `valid` | 1 | |
| `tag` | `CFG.loop.tag_bits`（14） | 区域 tag，`fold(region_base >> 4)` |
| `slot` | 3 | 循环分支槽位（edge 分支按 L7b 记在槽 0） |
| `dir` | 1 | "继续"方向（分配时取出口实际方向的反向） |
| `past_iter` | `iter_bits`（10） | 上次观测到的连续 `dir` 次数 |
| `commit_iter` | `iter_bits` | 提交口径的当前计数 |
| `spec_iter` | `iter_bits` | 推测口径的当前计数 |
| `conf` | `conf_bits`（2） | 连续相同次数的置信 |
| `age` | `age_bits`（3） | 替换保护 |

### 6.3 预测（与 TAGE 慢路径对齐）

- **N+1**：用 `p1.fast.region_base` 全相联匹配，结果 `{hit, idx}` 随 `p1→p2` 寄存。
- **N+2**（`bpu_slow_check` 组合）：`e = table[idx]`；`applicable = hit && e.valid && e.tag == tag(p2.region_base) && e.slot >= p2.fast.entry_slot && btb.hit && btb.br_mask[e.slot]`。
  - `loop_pred = (e.spec_iter == e.past_iter) ? !e.dir : e.dir`。
  - `loop_use = applicable && e.conf == '1 && !csr.fe_feat.loop_dis`。
  - `loop_use` 时把 TAGE `taken_mask[e.slot]` 替换为 `loop_pred`，再按现有 L7a 3.1 规则生成 P。其余规则不变。
- 输出到 `bpu_slow_t.loop`（新类型 `loop_meta_t`）：`hit=applicable, idx, slot, use, pred, upd_valid, upd_taken, ckpt`（6.4）。FTQ 在写入 `slow_i` 的同一处（`ftq.sv:359–367`）把它存入项字段 `loop_meta`，并新增读口 `loop_meta_rd_o`，按 `ras_ckpt_rd_id_i` 同一身份、同一完整 id 校验读出（与 `ras_ckpt_rd_o` 并列）。

### 6.4 推测计数与恢复

**实施修订**：以下冻结描述中的 `upd_valid` 改为记录赢家路径资格，实际 FF 更新另受 kill 门控；赢家 FTQ 元数据在接受拍锁存，下一拍恢复使用锁存值。原因与定向验证见第 16 节。

- **推测更新**（N+2 沿，`p2.valid && !kill_i.valid && applicable` 且槽位在实际采用路径上：`!P.cfi_valid || e.slot <= P.cfi_slot`）：`upd_taken = P.cfi_valid && P.cfi_slot == e.slot`（按实际采用路径；目标缺失按顺序走即视为不跳）；`upd_taken == e.dir` 时 `spec_iter` 饱和加 1，否则清 0。`upd_valid` 记录本次是否更新。
- **检查点**：`ckpt` = 本拍更新**之前**全部项的 `spec_iter`（`entries × iter_bits`，当前 80 位），随 `slow_o` 写入 FTQ 项。
- **恢复**（与 D29 RAS 恢复同拍，即 `snap_recover_valid` 拍，同一 `recover_q` 身份）：BPU 取 FTQ 中赢家区域 W 的 `loop` 元数据，先 `spec_iter[*] = W.ckpt[*]`，再处理 W 自身项（`W.upd_valid` 时，槽 `l = W.slot`，赢家位置 `r = winner.slot`）：

| 条件 | `spec_iter[W.idx]` |
| --- | --- |
| `l < r`，或 `l == r && !kill_self && src != EXEC` | `apply(ckpt, W.upd_taken)` |
| `l == r && !kill_self && src == EXEC && winner.exec_br_valid` | `apply(ckpt, winner.exec_br_taken)` |
| 其余 | `ckpt` |

  `apply(v, t) = (t == dir) ? sat_inc(v) : 0`。`redirect_req_t` 增加 `exec_br_valid/exec_br_taken`，由仲裁器在 EXEC 请求且 `exec_i.cfi_type == CFI_BR` 时填写。
- **系统重定向不恢复**（与当前历史/RAS 对 sys 的处理一致，前端 16.4 未闭合项）。
- **接受的不精确**：恢复后的 W 自身项精确；比 W 年轻、已被清除的区域对其他项的推测更新随整表检查点一起撤销，因此也精确。不精确只来自：检查点之后训练重新分配了某项（新项被写回旧占用者的 `spec_iter`）。该误差由置信机制自愈（W7）。

### 6.5 训练（第 3.2 节 T1，提交顺序）

训练包新增 `loop_train_t = {hit, idx, slot, use, pred}`（取自 FTQ 保存的 `slow_o.loop`）。设 `o = br_taken_mask[slot]`，`tage_wrong[s] = meta_final[s] != br_taken_mask[s]`。

1. **更新**：`hit && table[idx].valid && tag 匹配 && slot 相同 && br_commit_mask[slot]` 时：
   - `o == dir`：`commit_iter + 1`；已达最大值则 `valid = 0`（循环过长）。
   - `o != dir`（出口）：若 `commit_iter == past_iter`，`conf` 饱和加 1；否则 `past_iter = commit_iter`、`conf = 0`。然后 `commit_iter = 0`。
   - `use` 时：`pred == o` 且 `tage_wrong[slot]` → `age` 饱和加 1；`pred != o` → `conf = 0`、`age` 饱和减 1；第 16 节定义的冷启动零迭代退化项同时失效重学。
2. **分配**：本区域无匹配项（`!hit` 或匹配失效），且存在已提交 BR 槽 `s` 满足 `tage_wrong[s]`（取最小 `s`）：victim 取无效项，否则编号最小的 `age == 0` 项；都没有则把轮转指针所指项 `age` 减 1、指针前进，本次不分配。新项：`valid=1, tag, slot=s, dir=!o_s, past_iter=0, commit_iter=0, spec_iter=0, conf=0, age=2^(age_bits−1)`。
3. 同一沿上分配写某项、而恢复或推测更新也写该项 `spec_iter` 时，分配优先（新项从 0 计数）。恢复期间没有推测更新（`p2` 已被 kill 清除）。

### 6.6 事件

`PE_CMT_LOOP_USED`：交接拍 `loop.use && br_commit_mask[loop.slot]`；`PE_CMT_LOOP_WRONG`：其中 `loop.pred != br_taken_mask[loop.slot]`。

## 7. 特性开关 CSR

- 地址 `0x7C0`（M 模式自定义读写区），名 `mo3fecfg`。仅 M 模式可访问，S/U 访问非法。复位 0。
- `[0] LOOP_DIS`：1 时 `loop_use` 恒 0（表照常训练）。`[1] PF_DIS`：1 时预取器只消费不发请求。其余位读 0、写忽略。
- 经 `fe_csr_t` 新增字段 `fe_feat {loop_dis, pf_dis}` 送前端，`frontend` 再接到 `bpu`（新增 `fe_feat_i`）与 `fetch_prefetcher`（已有 `csr_i`）；写入下一拍生效，不需要串行化或重新取指（只影响预测与预取，不影响架构状态）。
- 用途：上板时同一程序开关各跑一次，直接测出 loop predictor 与预取的收益。

## 8. 性能事件

### 8.1 新增（来源 1，按 L7a U4 只追加）

| 号 | 事件 | 产生处与条件 |
| --- | --- | --- |
| 0x34 | `PE_CMT_COND_BR` | FTQ H1：`popcount(committed_br)` |
| 0x35 | `PE_CMT_COND_MISPRED` | FTQ H1：`popcount(committed_br & mispred_mask)` |
| 0x36 | `PE_CMT_COND_TAGE_WRONG` | FTQ H1：已提交 BR 槽中 TAGE 元数据最终方向 ≠ 实际方向的个数（纯 TAGE 精度，不含 loop 覆盖与目标缺失） |
| 0x37 | `PE_CMT_JALR` | FTQ H1：出口为 JALR 且 `ras_action ∈ {NONE, PUSH}` |
| 0x38 | `PE_CMT_JALR_MISPRED` | 上项且 `mispred_mask[actual_cfi_slot]` |
| 0x39 | `PE_CMT_RET` | FTQ H1：出口为 JALR 且 `ras_action ∈ {POP, POP_PUSH}` |
| 0x3A | `PE_CMT_RET_MISPRED` | 上项且 `mispred_mask[actual_cfi_slot]` |
| 0x3B | `PE_CMT_LOOP_USED` | 6.6 |
| 0x3C | `PE_CMT_LOOP_WRONG` | 6.6 |
| 0x3D | `PE_TRAIN_STALL_CYCLE` | FTQ：`sel` 项 `commit_last` 但因训练队列信用不足未发 H0 |
| 0x3E | `PE_RQ_ZOMBIE` | 4.3 |
| 0x3F | `PE_PF_USEFUL` | 5.4 |
| 0x40 | `PE_PF_LATE` | 5.4 |
| 0x41 | `PE_PF_UNUSED_EVICT` | 5.4 |
| 0x42 | `PE_PF_XLATE_MISS` | 5.2 |
| 0x43 | `PE_PF_XLATE_PROBE` | 5.2 |

`PE_NUM` 相应增大。`PERF_INC_W` 不变（最大增量 8）。

0x36 需要在 FTQ 解码 TAGE 元数据：把 `tage.sv:58–63` 的元数据布局常量与"取第 s 槽最终方向"函数移到 `o3_types_pkg`，`tage.sv` 与 `ftq.sv` 共用，布局本身不变。

### 8.2 补驱动的已有事件

| 号 | 事件 | 条件 |
| --- | --- | --- |
| 0x20 | `PE_TAGE_COND_PRED` | 慢核对：`p2.valid && btb.hit` 时 `popcount(btb.br_mask & 有效槽)` |
| 0x29 | `PE_XLATE_REUSE` | 5.2 |
| 0x2A～0x2D | `PE_PF_CANDIDATE/ISSUED/FILTERED/THROTTLED` | 5.2、5.4 |
| 0x2E～0x30 | `PE_RQ_FULL_CYCLE/HEAD_WAIT_SLOW_CYCLE/HEAD_WAIT_DATA_CYCLE` | 4.3 |
| 0x32 | `PE_DELIVER_LT4_BACKEND_READY_CYCLE` | `frontend`：`deliver_ready_i && popcount(deliver_valid_mask_o) < DELIVER_W` |
| 0x33 | `PE_BACKEND_BACKPRESSURE_CYCLE` | `frontend`：`deliver_valid_o && !deliver_ready_i` |

删除 `frontend.sv:506` 的 `perf_pf = '0` 强制及 `:417` 的空输出。`PE_ICACHE_BANK_CONFLICT`、`PE_IFU_CROSS_REGION` 本级仍不驱动。

### 8.3 上板评估口径（供以后决定 D09/D22、BTB 双目标、tag 组织）

- 条件分支方向 MPKI = `CMT_COND_MISPRED / minstret × 1000`；纯 TAGE 精度 = `CMT_COND_TAGE_WRONG / CMT_COND_BR`。
- 目标缺失占比 = `TARGET_MISSING`（推测口径）对照 `CMT_COND_MISPRED`。
- 前端供给 = `DELIVER_LT4_BACKEND_READY_CYCLE / mcycle`。
- 预取收益 = `PF_DIS` 开/关两次运行的 `mcycle`、`ICACHE_DEMAND_MISS` 之差，辅以 `PF_USEFUL/LATE/UNUSED_EVICT`。

## 9. 其他修正

### 9.1 FTQ 解析记录随部分清除清理（正确性）

- 新增项字段 `mispred_mask`（8 位）：`resolve_i.valid && resolve_i.mispredict` 时置 `[slot]`。
- kill 边界落在项内且 `kill_self=0`（`ftq.sv:488–510`）时，同沿清除该项 `slot > kill_i.slot` 的 `resolved_br/resolved_taken/mispred_mask` 位；若 `actual_cfi_valid && actual_cfi_slot > kill_i.slot`，清 `actual_cfi_valid`。`kill_self=1` 时 `>=`。
- 同沿的 `resolve_i` 若属于被清除位置，不写入。
- 原因：乱序执行下，较年轻槽位可先解析并记下 taken CFI；较老分支随后纠错只清除路径，旧记录残留会让训练包把已被取消的 CFI 当作本区域出口，污染 BTB/uBTB 目标。

### 9.2 过时注释

`ras.sv:33`（x1/x5 已在 F1 与后端实现）、`frontend.sv:29, 365`（D28 已在 T08a 实现）、`fetch_return_queue.sv:26–31`、`tage.sv:21–22`、`fetch_prefetcher.sv`/`prefetch_xlate_cache.sv` 的"空壳"说明，按实现后的事实改写。

## 10. 配置变更（`o3_cfg_pkg`）

| 字段 | 旧 | 新 |
| --- | --- | --- |
| `fe.loop`（新） | — | `entries 8, tag_bits 14, iter_bits 10, conf_bits 2, age_bits 3` |
| `fe.prefetch.mshr_reserve`（新） | — | 1 |
| `fe.prefetch.lead_distance`、`req_queue_depth` | 2、4（未使用） | 删除 |
| `fe.ftq.train_queue_depth` | 4（未使用） | 4，含义为 BPU 训练队列深度 |
| 其余 | | 不变 |

`frontend.sv` 配置一致性断言按新增字段补充。

## 11. 闭环简化与不做

允许简化：
- 预取不发起 PTW（W5）；跨页预取依赖复用记录与 ITLB 命中探测。
- 系统重定向不恢复 loop 推测计数（同历史/RAS 现状）。
- loop predictor 每区域只跟踪一个分支。
- 只做 FPGA RAM 推断写法，不在本级跑 OOC 或综合（L11 统一综合）；只用 lint 检查推断写法不报错。

不做：
- D09/D22 历史算法、TAGE 共享 tag 组织、主 BTB 双目标（用户决定上板后按数据再议）。
- SC、ITTAGE、uBTB 机制改动、L2 预取、预取 PTW。
- 快照存储 RAM 化；系统重定向的 committed 预测上下文（前端 16.4）。
- `PE_ICACHE_BANK_CONFLICT`、`PE_IFU_CROSS_REGION` 驱动。
- 不跑 Spike、ACT4、一致性测试；不综合。

## 12. 审阅决定（2026-10-08 用户确认，按推荐值）

| # | 问题 | 推荐 | 理由与代价 |
| --- | --- | --- | --- |
| W1 | 预测表训练如何每拍一个且用 BRAM | 每张表两份副本（查询、训练），训练读改写两拍、写旁路；训练规则逐位不变 | 单份 BRAM 只有一读一写口，"读当前表再写"每包要两次访问。另一做法是 BOOM/香山式"用预测时元数据只写不读"，省 BRAM 但改变训练规则、引入过期计数，与"这次不改算法"冲突。代价：TAGE/BTB 的 BRAM 翻倍，估计增加约 20 个 RAMB36（KCU040 有 600 个） |
| W2 | BRAM 无法复位 | TAGE 行 valid 与 base"写过"位用 FF（约 8k FF），BTB valid 保持 FF | 不需要复位后 2048 拍逐行初始化；复位语义不变，复位后不增加初始化周期 |
| W3 | 返回队列 killed 且未返回的槽 | 槽池 + 顺序队列，僵尸槽只占容量、不阻塞队头 | 若用环形 FIFO，错误路径 miss 会堵住队头几十拍；基线第 10 节只要求不提前复用 |
| W4 | 预取候选与节流 | 只取 `slow_done` 且 demand 未发的项；不设领先上限；保留 1 个 MSHR 给 demand；连续同行去重 | 等慢预测最多晚 2 拍，换来少取错误路径；保留 MSHR 防止预取占满后 demand miss 排队 |
| W5 | 预取跨页翻译 | 复用记录 + ITLB 空闲拍命中探测；**预取不发 PTW**（修订 D19） | ITLB 只有一个 miss 槽（L10 X2），预取遍历会挡住 demand miss；`PF_XLATE_MISS` 计数可在上板后判断是否值得加 |
| W6 | 预取权限与评估 | 预取检查 PMP(X)/PMA/epoch；行上加来源位，统计 useful/late/unused | 不把受保护区域装入 ICache；基线 12.2 要求可归因 |
| W7 | loop predictor 组织 | 8 项全相联、10 位计数、2 位置信（满值才用）、整表推测计数检查点随 FTQ（每项 80 位）、用错只清置信 | 整表检查点使年轻区域的推测更新被精确撤销；只有训练重新分配会造成少量误差，由置信自愈。代价约 3k FF（FTQ 32 项 × 约 90 位） |
| W8 | 特性开关 | CSR 0x7C0 `mo3fecfg`，bit0 关 loop，bit1 关预取 | 上板同程序 A/B 对比 |
| W9 | 事件编号 | 第 8 节，0x34 起追加 | B48 只追加规则 |
| W10 | FTQ 解析记录清理 | 按第 9.1 节修正 | 现状会把被取消的 CFI 写进训练包 |
| W11 | 规划文档 | loop predictor 修订前端 4.4"不是第一版功能"与 v1 计划第 5 节"不加新预测机制" | 用户 2026-10-08 决定 |
| W12 | 顺序 | PMP 预解码任务先完成；L7c 在 L11a 之前 | L7c 改 ICache 预取路径要用 `pmp_allow_dec`；前端吞吐影响上板 Linux 的体验与计数结论 |

## 13. 冻结后同步的设计文档

- 前端基线：新增 D36（训练交接即释放、训练队列与双副本 BRAM，闭合第 6.1 节待定项）、D37（返回队列槽池与僵尸槽，细化第 10 节）、D38（预取策略 W4/W6；D19 修订 W5，闭合第 11.1 节待定项）、D39（loop predictor，修订第 4.4 节）、D40（特性开关 CSR）。第 12.2 节事件表注明本级新增事件；事件编号以 L7a spec 第 6.3 节编号表为起点、本文第 8.1 节为续表（B48 在后端基线中不另列编号）。
- `O3-v1-plan.md` 第 3 节加入 L7c 位置、第 5 节注明 loop predictor 例外；`LOOP.md` 增加 L7c 行。

## 14. 验收

### 14.1 模块级 cocotb

| 目录 | 新/改 | 用例 |
| --- | --- | --- |
| `fetch_return_queue` | 扩展 | 8 笔未决、乱序响应、按序出队；队头 READY 但 `!slow_done` 不出队；kill 后 PEND 变僵尸、响应到达后释放、僵尸不阻塞新路径队头；kill 与响应同沿；`demand_hold` 锁存的 `rq_idx` 被正确分配；满时 `rsv_ready=0` |
| `ftq`（新） | 新 | 连续 N 个已提交区域在 N+1 拍内交接完毕；训练队列信用不足时停顿且不丢包；交接拍释放；9.1 的部分清除清理 `actual_cfi`/`mispred_mask`；prefetch 游标的 `slow_done` 门控与追赶 |
| `tage` | 改 | 现有 seed 1/7/29 用例按两拍训练延迟调整后全部通过；连续同行训练 4 包结果等于逐包顺序读改写的参考模型；查询与训练同沿同行读到新值；复位后未训练 base 行按弱不跳预测 |
| `main_btb` | 改 | 现有用例；连续同 set 同路训练；同沿查询读新值 |
| `bpu` | 改 | 经训练队列训练后命中；`train_free_o` 计数 |
| `loop_predictor`（新） | 新 | 次数 200 的循环：若干次执行后 `conf` 满、出口预测正确；推测计数恢复三种情况（`l<r`、`l==r` EXEC、`l>r`）；整表检查点撤销年轻区域更新；`LOOP_DIS`；计数溢出失效；分配 victim 与 age 衰减 |
| `fetch_prefetcher`（新，含复用记录） | 新 | 同行去重；Bare 直通；复用命中/未命中；探测命中安装后发请求；探测未命中丢弃不发 PTW；SFENCE 四种范围与 epoch 失效；`hold`/kill 放弃探测；`PF_DIS` |
| `icache` | 扩展 | MSHR 保留节流；PMP/epoch 拒绝预取；`pf` 位的 useful/late/unused 事件；探测不分配 miss、不锁存故障、不改 PLRU；`xlate_fill_o` |
| `csr_file` | 扩展 | 0x7C0 M 模式读写、S/U 非法、复位 0、`fe_feat` 输出 |
| `o3_sram_1r1w` | 扩展 | `ALLOW_COLLISION=0` 原断言不变；`=1` 时碰撞拍读数取反、不报错 |
| `ubtb`、`ras`、`redirect_arbiter`、`bpu_slow_check`、`frontend_sync_ctrl`、`mmu` | 重跑 | 字段扩展后不回归；`redirect_arbiter` 增加 `exec_br_*` 填写一例 |

### 14.2 整核定向程序

新增 `sim/o3/tests/l7c_frontend.S`（以 tohost 判定），Makefile 目标 `run-l7c-frontend`，不带 `--spike`；按 L7a 9.2 的暂停/恢复采样方法，按需分组运行：

1. **长循环**：内含 1 个循环分支、次数 300 的计数循环，外层重复 40 次；分别在 `LOOP_DIS=0/1` 下运行，采 `CMT_COND_BR`、`CMT_COND_MISPRED`、`CMT_LOOP_USED`、`CMT_LOOP_WRONG`。
2. **冷代码流**：用 `.rept` 生成不少于 8KiB 的顺序代码（含少量前向分支），只执行一遍；分别在 `PF_DIS=0/1` 下运行，采 `mcycle`、`ICACHE_DEMAND_MISS`、`PF_ISSUED`、`PF_USEFUL`、`PF_LATE`。
3. **密集区域**：每区域 1～2 条指令的短块链，重复 200 次；采 `CMT_REGION`、`TRAIN_STALL_CYCLE`、`FTQ_FULL_CYCLE`、`RQ_FULL_CYCLE`、`DELIVER_LT4_BACKEND_READY_CYCLE`。

程序自查计算结果（正确性）；性能比较写入 trace 标记，由 Makefile 两次运行后提取对比。

回归：lint；`MEM_PIPES=2` 构建下现有 13 项整核程序，`MEM_PIPES=1` 下现有 12 项；`run-l7-predict`。报告列出每项程序本级前后的周期数对比（本级预期周期减少；增加的须说明原因）。

### 14.3 完成标准（沿用 L7a U14 两档，采用 T10 轻量证据规则）

- **正确性项，必须通过才能提交**：14.1 全部用例；14.2 全部程序 tohost 通过（loop、预取开关两种配置均通过）；回归全部通过；lint 0 errors，warnings 不多于基线 357（新增逐条说明）。
- **性能项，未达标可登记后继续**：14.2 第 1 段 `LOOP_DIS=0` 的 `CMT_COND_MISPRED` 小于 `LOOP_DIS=1`；第 2 段 `PF_DIS=0` 的 `ICACHE_DEMAND_MISS` 与 `mcycle` 小于 `PF_DIS=1`；第 3 段 `TRAIN_STALL_CYCLE` 为 0。
- 每个分层提交只需简表（SHA/主机/命令/exit/用例数）与 smoke；完整同 SHA 证据只在 T12d 最终门禁。仿真主机按 `AGENTS.md` 读取共享配置。

## 15. 任务拆分

| 任务 | 内容 | 依赖 | 测试范围 |
| --- | --- | --- | --- |
| T12a | 第 4 节返回队列；4.3 与 8.2 的 RQ/交付事件 | 无 | `fetch_return_queue`、整核回归 |
| T12b | 第 2、3 节交接、训练队列、BRAM 双副本；9.1 修正；8.1 提交口径事件（0x34～0x3A、0x3D） | T12a | `ftq`、`tage`、`main_btb`、`bpu`、整核回归 |
| T12c | 第 5 节预取全部；第 7 节 CSR（含 `LOOP_DIS` 位占位）；预取事件 | T12b | `fetch_prefetcher`、`icache`、`csr_file`、`mmu`、14.2 第 2 段 |
| T12d | 第 6 节 loop predictor；loop 事件；14.2 全部；最终门禁 | T12c | 14.1、14.2 全部 |

每个任务单独提交；失败处理按 14.3。


## 16. 实现交叉核验修订（2026-10-08）

根据用户授权，修正恢复拍接口中两处与完整机制冲突的隐含假设：

- FTQ 的 loop/RAS 检查点读口在接受赢家的拍读取，前端锁存后在下一拍 snapshot RAM 返回时恢复。`kill_self` 可在接受沿删除赢家 FTQ 项，因此不能在恢复拍重新依赖该项仍 valid。完整 id 校验仍在接受拍完成；同拍新 slow 元数据提供写旁路。
- 第 6.4 节 `upd_valid` 记录“赢家所采用路径会经过该 loop 槽”的资格（`p2.valid && applicable && (!P.cfi_valid || slot<=P.cfi_slot)`），实际写推测计数仍由 `!kill_i.valid` 门控。当本区域 SLOW override 在同拍造成 kill 时，物理更新被取消，但下一拍恢复仍须重放赢家自身的正确路径动作；若把 `!kill` 同时写入元数据，会永久漏记该动作。恢复表格与分配优先级保持。

另记录吞吐提升所暴露的既有进展修复：FTQ 全环 issue 后释放不推进 demand 游标；ICache 采用四槽重试 FIFO，避免三个流水级与单槽重试相互等待；正确分支进展断言排除同拍独立 trap/SYS flush。测试保持架构期望与黄金检查。

- 第 6.5 / W7 的“用错只清置信”增加退化项例外：当被采用的预测用错，且 `past_iter==0 && commit_iter==0 && actual==dir`，同时使该项无效，下一次 TAGE 方向错误可重新分配。原因是冷启动首次 taken 错误可分配 `dir=NT`，连续 T 会建立“零次 NT 后 T”的满置信项；它无法学到真实循环的 taken 次数，并在每次 NT 出口失误。普通非零计数项仍只清置信、减 age，TAGE/BTB 训练算法不变。新增退化方向重新学习用例与整核 A/B 验证。
