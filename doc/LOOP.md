# CISLC-O3 闭环阶梯与实现状态

本文件是**项目当前状态的唯一权威来源**。规则见 [`agent.md`](../agent.md)，
微架构决策见 [`design/`](design/)。

更新规则：任何改变模块状态或闭环进度的提交，必须同步更新本文件对应的行。
"状态"一栏只描述事实，验证一栏只写有证据的结论（见 agent.md 第 3.3 节）。

## 1. 闭环阶梯

每一级是一条能在 Alan 上用一条命令验收的端到端路径。用户已决定移除 ITCM，
先打通 ICache→inclusive L2→AXI 取指，再推进分支与数据路径；以下按当前顺序记账。

| 级 | 目标 | 验收 | 状态 |
|---|---|---|---|
| L0 | RTL 可解析、`o3_core` 可展开 | `scripts/lint.sh` | Alan PASS（`de9149d`，0 errors、227 warnings） |
| L1（历史） | ITCM 中的直线整数指令按序退休 | 旧 `sim/o3` smoke | Alan 曾 PASS（`a268f16`）；ITCM 已移除，旧验收不再运行 |
| **L4 当前** | **ICache miss → inclusive L2 → AXI RAM → 直线整数退休** | `make -C sim/o3 build && make -C sim/o3 run-smoke` | Alan 回归 PASS（`de9149d`，38 周期、4 条退休、ICache 回填 1 次） |
| **L2 当前** | **taken 分支 / JAL：BRU 解析 → 重定向 → 前端恢复** | `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1 && make -C sim/o3 run-rv64i-instructions` | Alan PASS（`de9149d`；局部 1/1；整核 76 周期、14 条退休、ICache 回填 2 次） |
| L3 部分闭合 | SQ 依赖/转发 → 流水化 DCache → inclusive L2 → AXI 数据访存与退休 | `make -C sim/cocotb/store_queue SIM=verilator`、`make -C sim/cocotb/dcache SIM=verilator`、`make -C sim/o3 run-dcache-data` | Alan `fe6922d`：SQ 3/3、DCache 3/3；整核 `6b4c540` 数据门禁 69 周期退休 7 条且轨迹 PASS。单项依赖 replay RTL/测试已写，待 Alan。仍缺多 MSHR、多 load pending、跨行异常、FENCE.I、PTW/AMO/DMA；不是完整 B03～B05 |
| L5 | 异常 / CSR / trap / xRET | ACT4 RV64I | 未开始 |
| L6+ | DCache 多 MSHR、PTW/TLB、M/F/D、A、L2 并发/DMA、Linux | 待定 | 未开始 |

## 2. 当前目标：L4 缓存取指闭环

### 2.1 范围

- 镜像装入 AXI RAM（`0x8000_0000`）；复位 PC 从该地址开始。
- 顺序取指经过 ICache miss、L2 miss、AXI 四拍回填，再交给后端退休。
- L2 的同组容量替换须先 recall L1I 并 probe L1D；脏副本先写回 AXI。
- 当前 L1D 没有有效行，只能应答空副本探测；并发 MSHR、DMA、分支、
  数据 load/store、异常/CSR/FP/M 不在此验收范围。

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
并排除两条错路 `addi`。这仍采用顺序预测与每次分支解析保守暂停一拍；
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
| `backend/store_queue.sv` | **闭环简化（L3）**：SQ 年龄顺序查询、最近完整覆盖旧 store 转发；未知地址与部分覆盖保守等待；DCache 完成后释放，DTCM 保留本地 drain | LQ replay、依赖等待事件、跨行异常与整核冲突覆盖 | Alan 3/3 PASS（`fe6922d`）；整核基本数据门禁 PASS |
| `backend/backend_issue_queue.sv` | **闭环简化（L3，新增待验）**：Memory 选择可越过源未就绪队头；依赖 replay 槽占用时仅放行 store | 多项 replay、多 load 在途及真正多管线发射 | `sim/cocotb/backend_issue_queue/` 已写，待 Alan |
| `backend/load_store_unit.sv` | **闭环简化（L3，新增待验）**：单个 blocked load 让出执行级，SQ 变化唤醒重查；仍保留单 load pending | 多项 LQ replay、翻译/异常、跨行与 MMIO | `sim/cocotb/load_store_unit/`、整核 `run-dcache-replay` 已写，待 Alan |
| `frontend/fetch_return_queue.sv` | **闭环简化（L1）**：单槽身份匹配、按序出队和第二笔回压 | D15/D17 待 L4 | `sim/cocotb/fetch_return_queue/` Alan 2/2 PASS；整核 L1 PASS |
| `frontend/ifu_f0.sv` | **闭环简化（L1）**：完整 32 位指令识别 | RVC 与跨块拼接待 L2 | `sim/cocotb/ifu_f0/` Alan 2/2 PASS；整核 L1 PASS |
| `frontend/ifu_f1.sv` | **闭环简化（L1）**：生成 `fetch_entry_t`、`ftq_last`，修正端口无效 | 预解码修正待 L2 | `sim/cocotb/ifu_f1/` Alan 2/2 PASS；整核 L1 PASS |
| `frontend/redirect_arbiter.sv` | **闭环简化（L2）**：执行误预测 R0 kill/重定向、R1 身份恢复、R2 重新分配 | 系统/预解码/慢预测多来源年龄仲裁待后级 | `sim/cocotb/branch_recovery/` Alan 1/1 PASS（`de9149d`） |
| `frontend/fetch_buffer.sv` | **闭环简化（L2）**：执行重定向整体清空未交付项 | 预解码修正需要按 FTQ 身份/槽位选择性保留 | `sim/cocotb/branch_recovery/` Alan 1/1 PASS；整核 L2 PASS（`de9149d`） |
| `frontend/frontend.sv` | 总装（连线） | L1 路径已接通；其余空壳仍待后级 | `sim/o3` Alan PASS |
| `backend/backend.sv` 旧数据流 | **闭环简化（L2）**：INT/MEM/BR IQ、BRU 完整执行解析、checkpoint 恢复；taken branch/JAL 接前端重定向 | 正确解析仍保守暂停一拍；JALR/RVC、目标系统与其他执行路径待后级 | `sim/cocotb/branch_recovery/` 1/1、整核分支门禁 PASS（`de9149d`）；旧缓存路径 1/1 PASS（`1d2caeb`） |
| `backend/rob.sv` | 实现 | `retire_info_o` 已在 `ENABLE_RETIRE_INFO` 下导出到 `o3_core` | — |
| `core/o3_core.sv` | 总装（连线） | ICache/L2/AXI、直接控制流恢复及基础 DCache 数据路径已接通 | 整核 Alan smoke、分支及基础数据门禁 PASS（`6b4c540`） |
| `sim/o3/` | 使用 `rtl/rtl.f`、SV AXI RAM、缓存镜像加载与 JSONL 退休轨迹；taken BEQ/JAL 与 DCache 数据门禁 | JALR/RVC、LQ replay、异常及并发访存后续扩展 | Alan smoke、分支及基础数据门禁 PASS（`6b4c540`） |

## 3. 其他模块状态概览

当前缓存取指路径以外的模块概况（2026-10-03）：

- **单模块实现、有 cocotb**：`ubtb`、`main_btb`、`tage`、`ras`。
- **本轮新增局部 cocotb**：`branch_recovery`（BRU/重定向/fetch buffer/ALU kill，Alan 1/1 PASS，`de9149d`）、
  `l2_cache`（2 项）、`dcache` 空副本维护口（1 项）；
  `icache` recall 回归（3 项合计）、`backend` 整核缓存路径（1 项）已在 Alan 通过。
- **单模块实现、有 SV testbench**：`ftq`（`tb/ftq_tb.sv`）、`branch_history`、`history_snapshot_store`（`tb/` 下，仅记录过 lint）。
- **单模块实现、无独立 cocotb**：`fetch_buffer`、
  部分后端旧数据流（`decoder` … `rob`）、`axi_master`、`simple_data_sram`；
  L1 整核冒烟仅覆盖本轮四条 addi 的路径。
- **空壳/待扩展**：`lsu/*` 数据路径、`system/*`、`backend/fpu/*`、乘除法数据通路、
  `l2_recall_ctrl`/`dma_line_coord`、`itlb`、`icache_mshr`、预取相关、
  重命名新结构（`rename_dep_r1` 等）、`O3.sv`/`Tile.sv`。

`backend.sv` 中同时存在旧数据流（实际运行）和 2026-10-02 搭建的目标结构
（空壳，未接入旧数据流）。目标结构按闭环阶梯逐级接入，不一次性迁移。

## 4. 已知的文档不一致

- `doc/CISLC_O3.md` 的"当前实现状态"描述的是旧数据流，并引用已删除的
  `rtl/frontend/ifu.sv`、`rtl/backend/issue_queue.sv`。
- `doc/CISLC_O3_frontend.md` 中描述 `ifu.sv` 状态机的章节已失效。
- `rtl/common/o3_cfg_pkg.sv` 仍定义空宏 `` `O3_TBD ``，但全仓未使用；
  `backend.sv` 头注释称其阻止编译，与事实不符。

- 58 个 RTL 文件头注释仍写着"本阶段不写测试代码和仿真代码"（旧规则，已作废，见 agent.md 第 4.1 节）。

以上随相关模块被闭环触及时顺手修正。
