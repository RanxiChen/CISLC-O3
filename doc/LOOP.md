# CISLC-O3 闭环阶梯与实现状态

本文件是**项目当前状态的唯一权威来源**。规则见 [`agent.md`](../agent.md)，
微架构决策见 [`design/`](design/)。

更新规则：任何改变模块状态或闭环进度的提交，必须同步更新本文件对应的行。
"状态"一栏只描述事实，验证一栏只写有证据的结论（见 agent.md 第 3.3 节）。

## 1. 闭环阶梯

每一级都是一条能在 Alan 上用一条命令验收的端到端路径。只有上一级通过，
才开始下一级。L2 以后的顺序是暂定的，进入时再细化。

| 级 | 目标 | 验收 | 状态 |
|---|---|---|---|
| L0 | RTL 可解析、`o3_core` 可展开 | `scripts/lint.sh` | ✅ 本地 PASS（`c3692d4`）；Alan 未运行 |
| **L1** | **ITCM 中的直线整数指令按序退休** | `sim/o3` 运行 `tests/smoke.hex`（见第 2 节） | **本地 PASS（15 周期、4 条退休）；Alan 未运行** |
| L2 | taken 分支 / JAL：BRU 解析 → 重定向 → 前端恢复 | `sim/o3` 运行 `tests/rv64i_instructions.hex` | 未开始 |
| L3 | DTCM load/store | `sim/o3` 运行 `tests/unified_memory.hex` | 未开始 |
| L4 | ICache miss → L2 → AXI → 平坦内存；ICache 非阻塞 | 待定 | ICache 双 bank/四拍/单 MSHR 已局部实现；L2/返回队列未闭环 |
| L5 | 异常 / CSR / trap / xRET | ACT4 RV64I | 未开始 |
| L6+ | DCache、PTW/TLB、M/F/D、A、L2 inclusive、DMA、Linux | 待定 | 未开始 |

## 2. 当前目标：L1

### 2.1 范围

- 镜像全部装在 ITCM（`0x1000_0000`，64 KiB），复位 PC 指向 ITCM 起点。
- 只有直线整数指令（`tests/smoke.hex`：4 条独立 `addi`）。
- **不含**：分支与重定向、ICache miss、DTCM/外部访存、异常、CSR、FP、M 扩展。

### 2.2 验收

```sh
make -C sim/o3 build
make -C sim/o3 run-smoke
```

通过条件：按序退休 4 条指令，PC 依次为 `0x1000_0000/04/08/0c`，
`x1..x4` 写回值依次为 `1/2/3/4`，无超时。

本地 `make -C sim/o3 run-smoke` 已输出 `PASS cycles=15 retired=4` 和
`RV64I_INSTRUCTION_TRACE_PASS retires=4`；Alan 验收尚未运行。

### 2.3 L1 路径与模块状态

信号流向：

```
ITCM 镜像（TB 经 itcm_init_* 预装）
  → bpu（预测 PC、分配 FTQ）
  → ftq（demand 发射，携带 ftq_id / rq_idx）
  → icache（ITCM 命中，返回带身份的 icache_resp_t）
  → fetch_return_queue（按序出队）
  → ifu_f0（长度识别）→ ifu_f1（生成 fetch_entry_t）
  → fetch_buffer → backend（旧数据流：decode → rename → IQ → ALU → ROB）
  → retire_info_o → sim/o3 退休轨迹
```

| 模块 | 状态 | L1 需要做什么 | 测试 |
|---|---|---|---|
| `frontend/bpu.sv` | **闭环简化（L1）**：目标端口顺序预测与按身份回写完成；旧 32B 合同仍保留 | 待整核确认 FTQ 分配、训练回收；L2 再接 BTB/TAGE/历史/RAS | `sim/cocotb/bpu/` 本地 2/2 PASS；Alan 未运行 |
| `frontend/bpu_slow_check.sv` | 空壳，L1 绕过 | BPU 对每次已分配身份下一拍写回同一顺序预测；FTQ 的 `slow_done` 在返回队列读取 brief 前为真 | 无 |
| `frontend/ftq.sv` | 目标端口单模块实现 | 确认在 L1 中能分配、发射 demand、提交回收；集成未验证 | `tb/ftq_tb.sv`（SV testbench，非 cocotb，提交 `b6d3a34`）；无 cocotb |
| `frontend/icache.sv` | **闭环简化（L1）**：整行双 bank、S0–S3、单 demand MSHR/四拍回填；ITCM 与物理 cache 命中可用 | ITLB/PMP/PMA、预取、recall、多 MSHR、性能事件待后级；尚无综合时序证据 | `sim/cocotb/icache/` 本地 3/3 PASS；Alan 未运行 |
| `frontend/fetch_return_queue.sv` | **闭环简化（L1）**：单槽身份匹配、按序出队和第二笔回压 | L1 整核路径已本地走通；D15/D17 待 L4 | `sim/cocotb/fetch_return_queue/` 本地 2/2 PASS；Alan 未运行 |
| `frontend/ifu_f0.sv` | **闭环简化（L1）**：完整 32 位指令识别 | L1 整核路径已本地走通；RVC 与跨块拼接待 L2 | `sim/cocotb/ifu_f0/` 本地 2/2 PASS；Alan 未运行 |
| `frontend/ifu_f1.sv` | **闭环简化（L1）**：生成 `fetch_entry_t`、`ftq_last`，修正端口无效 | L1 整核路径已本地送入后端；预解码修正待 L2 | `sim/cocotb/ifu_f1/` 本地 2/2 PASS；Alan 未运行 |
| `frontend/redirect_arbiter.sv` | 空壳 | L1 无重定向：输出 tie-off 为无效 | 无 |
| `frontend/fetch_buffer.sv` | 实现 | L1 本地已将 F1 输出交给后端；选择性 kill 待后级 | `sim/o3` 本地 PASS |
| `frontend/frontend.sv` | 总装（连线） | L1 本地路径已接通；其余空壳仍待后级 | `sim/o3` 本地 PASS |
| `backend/backend.sv` 旧数据流 | **闭环简化（L1）**：INT/MEM/BR IQ 已实例化，四条 addi 走 ALU/ROB 退休 | 目标系统与其他执行路径待后级 | `sim/o3` 本地 PASS；`sim/cocotb/backend/` 本地 1/1 PASS；Alan 未运行 |
| `backend/rob.sv` | 实现 | `retire_info_o` 已在 `ENABLE_RETIRE_INFO` 下导出到 `o3_core` | — |
| `core/o3_core.sv` | 总装（连线） | 无需改动（预期） | — |
| `sim/o3/` | **已迁移**：使用 `rtl/rtl.f`、当前 core 端口、SV AXI RAM、ITCM 镜像加载与 JSONL 退休轨迹 | Alan 上复现 L1 四条 addi 验收 | 本地 `make build && make run-smoke` PASS；Alan 未运行 |

## 3. 其他模块状态概览

L1 路径以外的模块现在不需要改。概况（2026-10-03，`55038a4`）：

- **单模块实现、有 cocotb**：`ubtb`、`main_btb`、`tage`、`ras`。
- **本轮新增局部 cocotb**：`icache`（3 项）、`o3_sram_1r1w`（1 项）；
  后端连接由 `sim/cocotb/backend/` 的整核定向测试覆盖（1 项）。均仅本地试跑。
- **单模块实现、有 SV testbench**：`ftq`（`tb/ftq_tb.sv`）、`branch_history`、`history_snapshot_store`（`tb/` 下，仅记录过 lint）。
- **单模块实现、无独立 cocotb**：`fetch_buffer`、
  部分后端旧数据流（`decoder` … `rob`）、`axi_master`、`simple_data_sram`；
  L1 整核冒烟仅覆盖本轮四条 addi 的路径。
- **空壳**（约 50 个）：全部 `lsu/*`、`system/*`、`backend/fpu/*`、乘除法数据通路、
  `l2_cache`/`l2_recall_ctrl`/`dma_line_coord`、`itlb`、`icache_mshr`、预取相关、
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
