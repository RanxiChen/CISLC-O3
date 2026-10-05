# CISLC-O3 闭环阶梯与实现状态

本文件是**项目当前状态的唯一权威来源**。规则见 [`agent.md`](../agent.md)，
微架构决策见 [`design/`](design/)。

更新规则：任何改变模块状态或闭环进度的提交，必须同步更新本文件对应的行。
"状态"一栏只描述事实，验证一栏只写有证据的结论（见 agent.md 第 3.3 节）。

## 1. 闭环阶梯

每一级是一条能在 Alan 上用一条命令验收的端到端路径。用户已决定移除 ITCM，
先打通 ICache→inclusive L2→AXI 取指，再推进分支与数据路径；以下按当前顺序记账。

2026-10-05 起按 [`O3-v1-plan.md`](O3-v1-plan.md) 推进：L3 收尾之后依次为 L5～L11，L5 起每级验收都包含 Spike 逐条比对（B45）。

| 级 | 目标 | 验收 | 状态 |
|---|---|---|---|
| L0 | RTL 可解析、`o3_core` 可展开 | `scripts/lint.sh` | Alan PASS（`de9149d`，0 errors、227 warnings） |
| L1（历史） | ITCM 中的直线整数指令按序退休 | 旧 `sim/o3` smoke | Alan 曾 PASS（`a268f16`）；ITCM 已移除，旧验收不再运行 |
| **L4 当前** | **ICache miss → inclusive L2 → AXI RAM → 直线整数退休** | `make -C sim/o3 build && make -C sim/o3 run-smoke` | Alan 回归 PASS（`de9149d`，38 周期、4 条退休、ICache 回填 1 次） |
| **L2 当前** | **taken 分支 / JAL：BRU 解析 → 重定向 → 前端恢复** | `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1 && make -C sim/o3 run-rv64i-instructions` | Alan PASS（`de9149d`；局部 1/1；整核 76 周期、14 条退休、ICache 回填 2 次） |
| L3 部分闭合 | SQ 依赖/转发 → 流水化 DCache → inclusive L2 → AXI 数据访存与退休 | `make -C sim/cocotb/store_queue SIM=verilator`、`make -C sim/cocotb/dcache SIM=verilator`、`make -C sim/cocotb/backend_issue_queue SIM=verilator`、`make -C sim/cocotb/load_store_unit SIM=verilator`、`make -C sim/o3 run-dcache-data run-dcache-replay` | Alan `a8b3fc6`：Memory IQ 1/1、LSU replay/恢复 2/2；整核 `7d59822` 新门禁实测 `load_replays=1`，71 周期退休 6 条且轨迹 PASS；旧 smoke/分支/数据门禁仍 PASS。SQ 3/3、DCache 3/3 沿用前次 Alan 证据。仍缺多 MSHR、多 load pending、跨行异常、FENCE.I、PTW/AMO/DMA；不是完整 B03～B05 |
| L3 收尾 | 完成 L3；修 B12 缺口 1（分支解析全局停顿）与缺口 2（ALU RegRead 背压时缺 kill）；重命名改 4 宽（B42）；移除当前级不需要的空壳实例（B46） | 现有 L2/L3 门禁 + 分支密集程序 + 缺口 2 定向测试 | 阶段二实现与验收通过：四宽/16 项、空壳/filelist 清理、U3/U4、缺口 1 与授权 LQ-M；缺口 2 具名/随机/真实仲裁测试通过。Alan `ac2aed1` 全部门禁与 seed 1/7/29 通过，`1b7885d` 补充 LQ-M 通过；分支密集 1967 周期/365 退休，前后差值 0。同最终交付 SHA 的复验以 [报告 §9](tasks/O3-T01-report.md) 的 final 目录为准 |
| L5 | Spike 逐条比对；M 模式 CSR、精确异常、ecall/ebreak/illegal、MRET、committed_next_pc | ACT4 RV64I + Spike 比对 0 差异 | O3-T02 收尾完成：D24 busy 丢更老重定向 bug 独立修复 `5fe77a2`；Alan `3cbd759` O3-T01 60/60、固定 6/6、ACT4 51/51、随机 200/200 均通过且 0 差异，自测 5/5。CSR/精确 trap 等 O3-T03 随后直接实现；尚不是完整 L5，详见报告 §7 |
| L6 | M 扩展（MUL 采用 DSP，B43）、完成 FIFO/提前唤醒、JALR；首次 OOC 综合 | ACT4 RV64IM + CoreMark（仿真） | 未开始 |
| L7 | uBTB/BTB/TAGE、FTQ 恢复、RAS 快速修复；RVC | RV64IMC + 误预测率/IPC 基线 | 未开始 |
| L8 | 多 MSHR、重放、同 line 非对齐、A 扩展、FENCE/FENCE.I | RV64IMAC + litmus + 死锁 watchdog | 未开始 |
| L9 | F/D：拆分 CVFPU、FP 重命名、fflags/FS 退休 | ACT4 RV64GC（用户态） | 未开始 |
| L10 | S/U、Sv39 MMU、SFENCE.VMA/satp/PMP、A/D、WFI | 特权测试 + riscv-tests p/v | 未开始 |
| L11 | SoC：L2 + DDR4（MIG）+ CLINT/PLIC + UART + SD（AXI Quad SPI，B44）+ SD DMA + FASE | 仿真启动 OpenSBI + Linux；上板经 SD 卡启动 Linux | 未开始 |

## 2. 当前目标：L4 缓存取指闭环

### 2.1 范围

- 镜像装入 AXI RAM（`0x8000_0000`）；复位 PC 从该地址开始。
- 顺序取指经过 ICache miss、L2 miss、AXI 四拍回填，再交给后端退休。
- L2 的同组容量替换须先 recall L1I 并 probe L1D；脏副本先写回 AXI。
- 本节描述 L4 取指门禁的历史范围；彼时 L1D 只能应答空副本探测。此后
  L3 已接入基础有效数据行与 load/store，见上表，不能把 L4 通过当成 L3 证据。

### 2.2 验收

```sh
make -C sim/o3 build
make -C sim/o3 run-smoke
```

通过条件：按序退休 4 条指令，PC 依次为 `0x8000_0000/04/08/0c`，
`x1..x4` 写回值依次为 `1/2/3/4`，至少一次 ICache 回填，无超时。

Alan 在 `1d2caeb` 上输出 `icache_refills=1`、`PASS cycles=38 retired=4`、
`RV64I_INSTRUCTION_TRACE_PASS retires=4`。
Alan 在 `de9149d` 上重建并回归得到相同的 38 周期、4 条退休和 1 次回填。
Alan 的持久环境和重建方法见 [`sim/alan-env.yml`](../sim/alan-env.yml) 与
[`sim/o3/README.md`](../sim/o3/README.md)。

### 2.3 L2 直接控制流恢复验收

顺序预测器下，taken BEQ 和 direct JAL 由 BRU 产生带 FTQ 身份的解析结果；
重定向器在 R0 杀掉年轻项并改写取指 PC，在 R1 等待历史/RAS 的同身份恢复完成，
再允许 R2 重新分配。执行重定向会清空尚未交付的 fetch buffer 项；已经发出的
错路缓存请求可完成，但其返回不会进入退休轨迹。

```sh
make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1
make -C sim/o3 run-rv64i-instructions
```

Alan 在 `de9149d` 上局部测试 1/1 PASS（150 ns）；整核输出
`icache_refills=2`、`PASS cycles=76 retired=14`、
`RV64I_INSTRUCTION_TRACE_PASS retires=14`。退休轨迹包含 taken BEQ 与 direct JAL，
并排除两条错路 `addi`。上述历史 SHA 采用顺序预测与每次分支解析保守暂停一拍；O3-T01 已解除 C 拍暂停，M 恢复不变；
JALR、RVC 和 predecode/slow/system 多来源重定向不在本级范围。

### 2.4 缓存取指路径与模块状态

信号流向：

```
AXI RAM 镜像（TB 经 axi_init_* 预装）
  → bpu（预测 PC、分配 FTQ）
  → ftq（demand 发射，携带 ftq_id / rq_idx）
  → icache（双 bank 四拍查找，miss 发 L2）
  → l2_cache（组相联/PLRU，miss 发 AXI，包含关系回收）
  → ICache 回填（四个 16B beat，带身份的 icache_resp_t）
  → fetch_return_queue（按序出队）
  → ifu_f0（长度识别）→ ifu_f1（生成 fetch_entry_t）
  → fetch_buffer → backend（旧数据流：decode → rename → IQ → ALU → ROB）
  → retire_info_o → sim/o3 退休轨迹
```

| 模块 | 状态 | 后续工作 | 测试 |
|---|---|---|---|
| `frontend/bpu.sv` | **闭环简化（L1）**：目标端口顺序预测与按身份回写完成；旧 32B 合同仍保留 | L2 再接 BTB/TAGE/历史/RAS；训练回收仍待后级 | `sim/cocotb/bpu/` Alan 2/2 PASS；整核 L1 PASS |
| `frontend/bpu_slow_check.sv` | 空壳，L1 绕过 | BPU 对每次已分配身份下一拍写回同一顺序预测；FTQ 的 `slow_done` 在返回队列读取 brief 前为真 | 无 |
| `frontend/ftq.sv` | 目标端口单模块实现 | L1 整核分配、demand 发射和提交回收已走通；后级机制仍待验证 | `tb/ftq_tb.sv`（SV testbench，非 cocotb，提交 `b6d3a34`）；整核 L1 Alan PASS |
| `frontend/icache.sv` | **闭环简化（L4）**：整行双 bank、S0–S3、单 demand MSHR/四拍回填；按行 recall；ITCM 已移除 | ITLB/PMP/PMA、预取、多 MSHR、性能事件与综合时序待后级 | `sim/cocotb/icache/` Alan 3/3 PASS（`1d2caeb`） |
| `memory/l2_cache.sv` | **闭环简化（L4）**：256 set/4-way 配置、tree-PLRU、AXI 回填、双 L1 回收、脏行 AXI 写回 | 普通请求单未决；B03/B41 并发、DMA/维护协调与完整 L1D 数据路径未实现 | `sim/cocotb/l2_cache/` Alan 2/2 PASS（`1d2caeb`） |
| `lsu/dcache.sv` | **闭环简化（L3）**：4 个 16B word bank、整行 tag/valid/dirty、两级查询、单行 miss、hit-under-miss、脏 victim 写回、L2 回填、probe | 多 MSHR/同 line 合并、PTW/AMO/预取、DMA 行保护；clean_all 不会虚假确认但尚未执行 | Alan 3/3 PASS（`022f90c`）；整核基本数据门禁 PASS |
| `backend/store_queue.sv` | **闭环简化（L3）**：SQ 年龄顺序查询、最近完整覆盖旧 store 转发；未知地址与部分覆盖保守等待；DCache 完成后释放，DTCM 保留本地 drain | LQ replay、依赖等待事件、跨行异常与整核冲突覆盖 | Alan 既有三项+四宽/C/M/commit/drain 随机合同 4/4 PASS（`ac2aed1`，seed 1/7/29）；整核数据门禁 PASS |
| `backend/backend_issue_queue.sv` | **闭环简化（L3）**：Memory 选择可越过源未就绪队头；依赖 replay 槽占用时仅放行 store | 多项 replay、多 load 在途及真正多管线发射 | Alan 1/1 PASS（`f038f34`）；整核 replay 门禁 PASS |
| `backend/load_store_unit.sv` | **闭环简化（L3）**：单个 blocked load 让出执行级，SQ 变化唤醒重查；错误路径可取消，仍保留单 load pending | 多项 LQ replay、翻译/异常、跨行与 MMIO | Alan replay/恢复/单 pending/迟到/Result 背压 3/3 PASS（`ac2aed1`，seed 1/7/29），整核 replay PASS |
| `frontend/fetch_return_queue.sv` | **闭环简化（L1）**：单槽身份匹配、按序出队和第二笔回压 | D15/D17 待 L4 | `sim/cocotb/fetch_return_queue/` Alan 2/2 PASS；整核 L1 PASS |
| `frontend/ifu_f0.sv` | **闭环简化（L1）**：完整 32 位指令识别 | RVC 与跨块拼接待 L2 | `sim/cocotb/ifu_f0/` Alan 2/2 PASS；整核 L1 PASS |
| `frontend/ifu_f1.sv` | **闭环简化（L1）**：生成 `fetch_entry_t`、`ftq_last`，修正端口无效 | 预解码修正待 L2 | `sim/cocotb/ifu_f1/` Alan 2/2 PASS；整核 L1 PASS |
| `frontend/redirect_arbiter.sv` | **闭环简化（L2）**：执行误预测 R0 kill/重定向、R1 身份恢复、R2 重新分配；D24 busy 期间更老执行请求按 FTQ 环形年龄/槽位替换 | 系统/预解码/慢预测多来源年龄仲裁待后级 | Alan `3cbd759` branch_recovery 原有/新增 4/4 PASS（seed 1/7/29）；固定 6/6、ACT4 51/51、随机 200/200 0 差异 |
| `frontend/fetch_buffer.sv` | **闭环简化（L2）**：执行重定向整体清空未交付项 | 预解码修正需要按 FTQ 身份/槽位选择性保留 | `sim/cocotb/branch_recovery/` Alan 1/1 PASS；整核 L2 PASS（`de9149d`） |
| `frontend/frontend.sv` | 总装（连线） | L1 路径已接通；其余空壳仍待后级 | `sim/o3` Alan PASS |
| `backend/backend.sv` 旧数据流 | **闭环简化（L3）**：INT/MEM/BR IQ、BRU 恢复、SQ/LSU→DCache；Memory IQ 可越过未就绪队头并受 replay 槽控制 | 四宽/16 项；U3 退休 FTQ 通知、U4 M/Bare/PMP update=0；正确解析正常推进，M 保留恢复边界；JALR/RVC 待后级 | Alan backend 2/2 与 backend_control 同拍合同 PASS（`ac2aed1`）；smoke/分支/数据/replay/dense 门禁 PASS；最终提交复验见报告 |
| `backend/rob.sv` | **闭环简化（L3）**：四宽拍初 complete 前缀退休；保存动态 FTQ id/slot/last；C 推进，M 取消年轻并保留 JAL WB | 精确异常/系统提交待 L5 | Alan normal/C/M、full/异常/回绕/U3 合同 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/uop_queue.sv` | **闭环简化（L3）**：四宽、16 项、bank/回绕/满空/前缀握手/M flush | 更深流水按 B42 时序触发 | Alan WQ 900 周期 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/rename_stage.sv`、`rename_map_table.sv`、`free_list.sv` | **闭环简化（L3）**：四 lane RAW/WAW/x0、原子资源前缀、checkpoint 恢复 | FP 域待 L9；R1 按 B42 时序触发 | Alan WR/RAT/free-list 合同 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/branch_checkpoint_file.sv` | **闭环简化（L3）**：C 释放/清 parent 与不同 tag create 合并；只看拍初空闲，不同拍复用 | 系统整体恢复待 L5 | Alan CK full/C/M 700 周期 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/rename_dispatch_queue.sv`、`dispatch_stage.sv` | **闭环简化（L3）**：四宽连续前缀分流，C 正常推进/清新旧 mask，M 保留老项 | M/FP/系统分类待后级 | Alan RDQ/三个 IQ/backend_control PASS（`ac2aed1`，seed 1/7/29） |
| `backend/backend_issue_queue.sv`、`prf_read_arbiter.sv` | **闭环简化（L3）**：C 选择/删除/入队/唤醒与四读口竞争；M grants=0；未 grant 不删除 | FP/M 读口归属待后级 | Alan INT/MEM/BR IQ 与 RR 合同 PASS（`ac2aed1`，seed 1/7/29）；既有 Memory IQ 门禁保留 |
| `backend/branch_unit.sv`、`alu_pipe.sv` | **闭环简化（L3）**：one-shot C/M 与 JAL 链接解耦；ALU 独立 kill 保留旧 Result | JALR/完整目标边界待后级 | Alan 缺口 2 具名/700 事务 DUT/真实 WB 竞争与总装 C 合同 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/load_queue.sv` | **闭环简化（L3）**：四宽；C 合并正常记账，M 仅取消年轻并保留旧 execute/request/response | 多事务代际/异常待 L8/L5 | Alan LQ-C/M PASS（`ac2aed1`）；240 事务复用/迟到合同 PASS（`1b7885d`，seed 1/7/29） |
| `core/o3_core.sv` | 总装（连线） | ICache/L2/AXI、直接控制流恢复及基础 DCache 数据路径已接通 | 整核 Alan smoke、分支及基础数据门禁 PASS（`6b4c540`） |
| `sim/o3/` | AXI RAM 2 MiB、JSONL v2、进程内固定版本 Spike、LSU/ROB 访存观测、ACT4 迁移、3000 动态退休随机生成与五类自测 | 循环控制流差异已修复；CSR/异常由 O3-T03、RVC 等由后续任务闭合 | Alan `3cbd759` 固定 6/6、自测 5/5、ACT4 51/51、随机 200/200 全部通过，0 差异；准确命令/日志见 O3-T02 报告 §7 |

## 3. 其他模块状态概览

当前缓存取指路径以外的模块概况（2026-10-03）：

- **单模块实现、有 cocotb**：`ubtb`、`main_btb`、`tage`、`ras`。
- **本轮新增局部 cocotb**：`branch_recovery`（BRU/重定向/fetch buffer/ALU kill，Alan 1/1 PASS，`de9149d`）、
  `l2_cache`（2 项）、`dcache` 空副本维护口（1 项）；
  `icache` recall 回归（3 项合计）、`backend` 整核缓存路径（1 项）已在 Alan 通过。
- **单模块实现、有 SV testbench**：`ftq`（`tb/ftq_tb.sv`）、`branch_history`、`history_snapshot_store`（`tb/` 下，仅记录过 lint）。
- **单模块实现、无独立 cocotb**：`fetch_buffer`、
  `decoder`、`axi_master`、`simple_data_sram`；后端主要队列/rename/资源合同已有 O3-T01 cocotb，见上表；
  L1 整核冒烟仅覆盖本轮四条 addi 的路径。
- **空壳/待扩展**：`lsu/*` 的 PTW/AMO/DMA/完整维护路径、`system/*`、`backend/fpu/*`、乘除法数据通路、
  `l2_recall_ctrl`/`dma_line_coord`、`itlb`、`icache_mshr`、预取相关、
  重命名新结构（`rename_dep_r1` 等）、`O3.sv`/`Tile.sv`。

`backend.sv` 保留当前实际数据流，2026-10-02 搭建但未接入的非 L3 目标实例已移除。O3-T01 已移除本级后端空壳实例及独占 filelist 条目；文件保留。
归属：入口/提交/CSR/trap L5，M/FIFO/融合 L6，性能计数 L7，数据预取/非阻塞访存/AMO/LRSC L8，FP L9，PTW/A-D/WFI/PMP/PMA L10，fatal/L2-recall/DMA 协调 L11。
R1 依赖与级间暂存按 B42 综合时序触发，不指定 Ln。

## 4. 已知的文档不一致

- `doc/CISLC_O3.md` 的"当前实现状态"描述的是旧数据流，并引用已删除的
  `rtl/frontend/ifu.sv`、`rtl/backend/issue_queue.sv`。
- `doc/CISLC_O3_frontend.md` 中描述 `ifu.sv` 状态机的章节已失效。
- `rtl/common/o3_cfg_pkg.sv` 保留未使用的空宏 `` `O3_TBD ``；backend 相关过期说明已在 O3-T01 修正。

- 58 个 RTL 文件头注释仍写着"本阶段不写测试代码和仿真代码"（旧规则，已作废，见 agent.md 第 4.1 节）。

以上随相关模块被闭环触及时顺手修正。

## 5. O3-T02 验证边界（2026-10-06）

冻结规格 §8 Q1–Q10 已实施，只增加退休观测字段，不改变执行行为。
`unified_memory` 是旧 ITCM/软件内存地址门禁，按 Q7 排除 Spike；原 checker
及命令保留，当前 AXI 路径无法用它建立闭环证据，标为历史。
随机 200 种子全部执行，参考端每种子 3000 条，DUT 匹配前缀共 114412 条。
种子 120 通过（3001 条，含 tohost 同拍年轻 lane），其余 199 个均首差异为 PC。
12 条指令的缩减复现位于 `sim/o3/repros/branch_loop.hex`，旧 O3-T01 二进制亦复现。
O3-T01 60 条既有命令和全部新门禁的最终提交复验记录见
[O3-T02 阶段二报告](tasks/O3-T02-report.md)，不得以开发轮次替代同 SHA 复验。
用户已授权随后直接执行 O3-T02-fix；需要改 Dxx/Bxx 决策时才停。

O3-T02 收尾（2026-10-06）：上节 15/51、1/200 是修复前历史失败。
修复后补跑 137–200 为 64/64；重新构建后的同 SHA 全量复验为 O3-T01 60/60、
固定 6/6、ACT4 51/51、随机 200/200（600160 条匹配），无新 bug。
日志 Alan `/home/chen/FUN/CISLC-O3-runs/20261006-o3t02-close/final/`；
收尾文档提交原样复验另存 delivery/，其 sha.txt 与 commands.tsv 为准确交付证据。

## 6. O3-T03 实现中（L5）

接入 rename_entry_gate、commit_ctrl、csr_file、trap_ctrl；ROB 保存队头串行/异常/
实际后继元信息；CSR 在队头一次读改写并写回，trap 不退休故障指令，MRET 自身退休。
RAT/free list 从提交态恢复；SQ 只取消未提交项；LSU 保留已发事务的所有权并丢弃迟到结果。
存储访问在退休前通过只读 DCache 探测确认；probe 不修改数据，成功才 complete Store。
FENCE.I 只排空 SQ + 失效 ICache，完整数据 clean 待 L8。Spike 增加 CSR/trap 事件。
本地 lint 待提交前检查，Alan 功能未验证，不能宣称 L5 通过。

O3-T03 首版发现 PRF/ROB unpacked array lane 方向不一致；修正并追加三条静态
指令的固定 Spike 门禁，详情 O3-T03 报告 Bug 1。修复后 Alan 验证待运行。
