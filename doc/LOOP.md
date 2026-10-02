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
| **L1** | **ITCM 中的直线整数指令按序退休** | `sim/o3` 运行 `tests/smoke.hex`（见第 2 节） | **进行中** |
| L2 | taken 分支 / JAL：BRU 解析 → 重定向 → 前端恢复 | `sim/o3` 运行 `tests/rv64i_instructions.hex` | 未开始 |
| L3 | DTCM load/store | `sim/o3` 运行 `tests/unified_memory.hex` | 未开始 |
| L4 | ICache miss → L2 → AXI → 平坦内存；ICache 非阻塞 | 待定 | 未开始 |
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

（`sim/o3` 的 Makefile、`o3_tandem_top.sv`、`main.cpp` 仍对应 2026-09-06 的旧端口，
迁移是 L1 的一部分。）

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
| `frontend/bpu.sv` | **空壳**（子预测器已实现，总装未实现：预测 PC、`alloc_valid_o` 未驱动） | 闭环简化：顺序预测（每次 +16B），无慢预测、无历史/RAS 推进 | 无 |
| `frontend/bpu_slow_check.sv` | 空壳 | 闭环简化：L1 不做慢预测，`slow_done` 恒为真的来源需明确 | 无 |
| `frontend/ftq.sv` | 目标端口单模块实现 | 确认在 L1 中能分配、发射 demand、提交回收；集成未验证 | `tb/ftq_tb.sv`（SV testbench，非 cocotb，提交 `b6d3a34`）；无 cocotb |
| `frontend/icache.sv` | **闭环简化（L1）**：旧阻塞式逻辑 + 新端口适配层（`55038a4`） | 已完成：`req_ready_o`/`resp_o`/`idle_o`；其余目标端口 tie-off | **缺 cocotb** |
| `frontend/fetch_return_queue.sv` | 空壳 | 闭环简化：浅 FIFO / 直通（ICache 阻塞单未决，不需要 D15/D17） | 无 |
| `frontend/ifu_f0.sv` | 空壳 | 闭环简化：32 位指令长度识别；RVC 与跨块拼接不在 L1 | 无 |
| `frontend/ifu_f1.sv` | 空壳 | 闭环简化：生成 `fetch_entry_t`；预解码修正不发出 | 无 |
| `frontend/redirect_arbiter.sv` | 空壳 | L1 无重定向：输出 tie-off 为无效 | 无 |
| `frontend/fetch_buffer.sv` | 实现 | 确认与 F1 输出、后端 `fetch_entry_i` 对接 | 无 |
| `frontend/frontend.sv` | 总装（连线） | 按上面的简化调整连线 | — |
| `backend/backend.sv` 旧数据流 | 实现（2026-09-06 旧数据流） | 消费 `fetch_entry_t`，退休输出 `retire_info_o` | 旧 `sim/o3` 历史记录，当前不可运行 |
| `backend/rob.sv` | 实现 | `retire_info_o` 已在 `ENABLE_RETIRE_INFO` 下导出到 `o3_core` | — |
| `core/o3_core.sv` | 总装（连线） | 无需改动（预期） | — |
| `sim/o3/` | **未迁移**：Makefile 引用已删除的 `ifu.sv`、不编译新 package；top 和 C++ 驱动对应旧端口 | 改用 `rtl/rtl.f`；top 对齐新端口；C++ 预装 ITCM、采退休、超时保护 | — |

## 3. 其他模块状态概览

L1 路径以外的模块现在不需要改。概况（2026-10-03，`55038a4`）：

- **单模块实现、有 cocotb**：`ubtb`、`main_btb`、`tage`、`ras`。
- **单模块实现、有 SV testbench**：`ftq`（`tb/ftq_tb.sv`）、`branch_history`、`history_snapshot_store`（`tb/` 下，仅记录过 lint）。
- **单模块实现、无测试**：`fetch_buffer`、
  后端旧数据流（`decoder` … `rob`）、`axi_master`、`simple_data_sram`。
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
