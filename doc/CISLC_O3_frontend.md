# CISLC_O3 Frontend Notes

## 文档定位
- 本文件保留为"前端当前实现状态 + 代码索引 + 时序入口"文档。
- 面向后续 agent / 协作者的执行规则、注释规范、阶段边界，统一遵循 [`agent.md`](/home/chen/work/CISLC-O3/agent.md)。
- 与后端主文档 [`doc/CISLC_O3.md`](/home/chen/work/CISLC-O3/doc/CISLC_O3.md) 的分工：
  - `doc/CISLC_O3.md` 记录后端现状和后端主链路。
  - 本文件记录前端现状和前端后续开发入口。
- 使用顺序建议：
  1. 先读本文件，确认当前前端实现边界与受影响模块。
  2. 再读相关 frontend RTL 和顶层连接文件。
  3. 最后按 [`agent.md`](/home/chen/work/CISLC-O3/agent.md) 中的规则落修改。

## 当前实现状态

### BPU（Branch Prediction Unit）
- `rtl/frontend/bpu.sv` 已实现 sequential-only 第一版 BPU。
- BPU 从 `frontend.reset_pc_i` 指定的复位 PC 开始，按 32B fetch block 顺序生成 `ftq_entry_t`。
- 当前 BPU 固定不跳转：
  - `has_branch=0`
  - `pred_taken=0`
  - `fallthrough_pc=next_pc=start_pc+FTQ_BLOCK_BYTES`
- BPU 通过 ready/valid 接口写入 FTQ：
  - FTQ 未满时 `ftq_ready_i=1`，BPU 入队成功后内部 PC 前进 32B。
  - FTQ 满时 BPU 保持当前 block，不跳过任何 PC。
- BPU 只消费 redirect 来重置 `pred_pc_q`，不负责修复历史 FTQ entry。
  - 收到 `redirect_valid_i=1` 时，内部 `pred_pc_q` 立即被重置为 `redirect_pc_i`，优先级高于正常顺序推进。
  - 下一拍 `ftq_entry_o` 从新的 `redirect_pc_i` 开始顺序生成。
- 当前未实现 BTB/BHT/RAS/history、真实分支预测和预测器训练。

### IFU（Instruction Fetch Unit）
- `rtl/frontend/ifu.sv` 已实现取指流水线骨架，包含 S0/S1/S2/S3；Fetch Buffer 已拆成独立 `rtl/frontend/fetch_buffer.sv`。
- **S0**：FTQ block 消费端。通过 ready/valid 从 FTQ 拉取 block，组合生成 16B 对齐的 `group_pc` 和 4-bit `mask`。
  - 若真实 fetch PC 不满足 32-bit 指令对齐，S0 直接产生 `fetch_addr_misaligned=1` 的 `fetch_entry_t`，不向 ICache 发请求。
  - misaligned bypass 只有在 IFU 内部没有更老待落地请求且外部 fetch buffer ready 时才会 fire，避免异常 entry 越过更老指令。
  - 块内指针 `fetch_ptr_q` 跟踪当前 block 内的下一个 group 地址，每次推进 +16B。
  - `mask` 基于 `[start_pc, end_pc)` 开区间计算，标记当前 16B window 内哪些指令属于当前 block。
- **S1**：向 icache 发请求。接收 S0 输出，暂存 `group_pc`/`mask`/`ftq_idx`，驱动 icache s0 接口。
  - 只有 ICache ready、S2 有空间且外部 fetch buffer 的 `icache_req_allowed_i=1` 时才会发新 ICache request。
- **S2**：双槽移位 FIFO，暂存已发 icache 但尚未返回的请求上下文。
  - 槽位保存 `group_pc`、`mask`、`ftq_idx`，以及 icache 返回后回填的 128-bit `data` 和 `fetch_access_fault`。
  - 最大深度 2，对应 icache 单流处理最多 1 个 s1 请求 + 1 个 replay 请求。
  - 弹出条件：头部数据完整（`data_valid=1`）且外部 fetch buffer 入队 ready。
- **S3**：组合直通，零状态。将 icache 返回的 128-bit 数据拆成 4×32-bit 指令。
  - 用 S2 头部槽位的 `mask` 标记每条指令的 `valid`。
  - 4 条指令的 PC 依次为 `group_pc + 0/4/8/12`。
  - S3 直接输出公共 `fetch_entry_t` 给外部 fetch buffer，entry 内包含 `valid/pc/instruction/fetch_addr_misaligned/fetch_access_fault/ftq_idx`。

### Fetch Buffer
- `rtl/frontend/fetch_buffer.sv` 已实现独立前后端交界取指缓冲。
- 内部用紧凑环形队列保存公共 `fetch_entry_t`，只写入有效 lane，不保留 bubble。
- 入队端接 IFU 的 `fetch_entry_t[4]` 和 lane valid，出队端提供 ready/valid fetch group。
- 出队支持 partial group：只要队列非空即可向后端方向拉高 valid，不足的 lane 输出 `valid=0`。
- 额外输出 `icache_req_allowed_o`，当前表示至少保留 8 个空位，用来提前阻塞 IFU 继续向 ICache 发新请求。

### FTQ
- `rtl/frontend/ftq.sv` 已改成 BPU 入队、IFU 消费的三指针骨架。
- Reset 后 FTQ 为空，不再预置顺序 block；运行时由 BPU 写入 `ftq_entry_t`。
- 内部维护：
  - `alloc_tail_q`：BPU 下一次写入位置。
  - `ifu_head_q`：IFU 下一次消费位置。
  - `release_head_q`：后续 release/commit 回收位置，当前只 reset，不推进。
  - `allocated_count_q`：已分配但尚未 release 的 entry 数量。
- IFU 消费只设置 `consumed_q[ifu_head_q]` 并推进 `ifu_head_q`，不清 entry、不释放容量。
- FTQ 模块内部已经实现 redirect repair / rewind 语义：
  - younger wrong-path entries 会被清空并从当前 window 移除；
  - branch entry 会被截断到 `branch_pc + 4`，`next_pc` 改写成 `redirect_pc`；
  - `alloc_tail_q` / `ifu_head_q` 回到 branch entry 的下一槽位；
  - `allocated_count_q` 收缩到保留窗口大小。
- 当前未实现 release/commit 回收，所以 FTQ 最多接收 `FTQ_DEPTH` 个 block；但 redirect rewind 会把 wrong-path slot 重新变成可覆盖空间，避免 stale full-state。
- 当前还未把 redirect 从 backend/frontend top 真正接到 FTQ，也未实现 IFU / fetch_buffer 级 flush；因此现在只有 FTQ 本地 repair 语义落地，完整 frontend redirect 闭环仍在后续 Task。

### Frontend Top
- `rtl/frontend/frontend.sv` 已实例化并连接 `bpu`、`ftq`、`ifu`、`ICache` 和 `fetch_buffer`。
- 当前顶层数据流是 `BPU -> FTQ -> IFU -> ICache -> IFU -> fetch_buffer -> frontend output`。
- 顶层新增 `reset_pc_i`，用于指定 BPU reset 后开始生成 fetch block 的起始 PC。
- 在 `O3_FRONTEND_DEBUG` 宏下，frontend 会透出 FTQ debug 信号，用于前端仿真统计 FTQ 向 IFU 出队的 block 数。
- fetch buffer 出队口暂时直接作为 frontend 顶层输出：`fetch_valid_o` 表示本拍有 fetch group，`fetch_valid_mask_o` 由每个 `fetch_entry_t.valid` 生成。
- ICache refill request/response 当前从 frontend 顶层透出，后续可接 L2、总线或测试内存模型。
- ICache line 大小当前由 `o3_pkg::ICACHE_LINE_BYTES` 统一定义，frontend 实例化点不单独覆盖。
- `flush_i` 当前只接到 ICache 和 fetch buffer；尚未驱动 BPU、FTQ 和 IFU 做 redirect/flush 精确清除。

### Core Top Connection
- `rtl/core/o3_core.sv` 已经实例化真实 frontend 和 backend。
- core 层不再额外实例化 fetch buffer；frontend 内部已有 fetch buffer，core 直接把 frontend 出队口接到 backend。
- frontend 的 4-lane fetch group 与 backend 当前 `BACKEND_MACHINE_WIDTH=4` 对齐。
- frontend `fetch_valid_o/fetch_ready_i` 与 backend `fetch_valid_i/fetch_ready_o` 在 core 层形成 group 级 ready/valid 握手。
- ICache refill request/response 仍从 core 顶层透出，由 `sim/core_single_inst` 或后续存储系统驱动。

### 尚未实现
- frontend standalone 顶层仍只暴露 fetch buffer 出队口；真实 backend 连接位于 `rtl/core/o3_core.sv`。
- BPU 只实现顺序 not-taken 生成和 redirect reseed，未实现真实分支预测、BTB、BHT、RAS。
- FTQ 未实现 release/commit 回收；当前顺序前端若没有 redirect rewind 干预，最多分配 `FTQ_DEPTH` 个 fetch block 后会停止接收 BPU。
- 未实现完整 redirect、异常恢复和跨模块精确清除；当前只实现了 FTQ 本地 redirect repair / rewind 语义和 BPU redirect reseed 能力。
- `rtl/O3.sv` 和 `rtl/Tile.sv` 仍是占位顶层，未接入真实 IFU/FTQ/icache 链路。

### 当前测试
- `sim/frontend/frontend_basic` 是当前前端固定 smoke/regression。
- `sim/core_single_inst/single_addi` 是当前 core 级单指令 smoke，使用真实 frontend + backend，从 `reset_pc_i=0` 跑 `addi x1, x0, 1` 到 retire。
- 运行命令：

```bash
cd sim/frontend
make clean-test TEST=frontend_basic
make test TEST=frontend_basic
```

- 该测试设置 `reset_pc_i=0`，通过 `O3_FRONTEND_DEBUG` 统计 FTQ 向 IFU 成功出队 4 个 block 后停止。
- checker 不要求每拍输出 4 条，也不要求每拍都有输出；只检查已经从 frontend output 出队的有效 lane 是否保持 PC 和 instruction 顺序递增，且没有 fetch 异常。

## 当前集成边界
- frontend 和 backend 已经通过 `rtl/core/o3_core.sv` 组装成最小核心闭环。
- 当前 core smoke 目标是从 `reset_pc_i=0` 取到 `addi x1, x0, 1`，经 backend decode/rename/issue/regread/execute/writeback/retire 后退出。
- 该阶段仍不要求：
  - 完整指令集。
  - 完整程序运行。
  - 分支预测、redirect、异常恢复。
  - FTQ 的真实 commit/release。
- 当前仍需要后续处理：
  - `rtl/O3.sv` / `rtl/Tile.sv` 包住真实 `o3_core`。
  - ICache refill response 接真实存储系统。
  - FTQ release/commit 回收。
  - redirect/flush 精确恢复。

## 当前前端数据流

```
frontend
  BPU ──ready/valid──> FTQ ──ready/valid──> IFU S0 ──ready/valid──> IFU S1 ──ready/valid──> ICache s0
                                                               │
                                                               │ out_valid + out_data + out_error
                                                               ▼
                                                        IFU S2（双槽 FIFO）
                                                               │
                                                               │ s2_pop（data_valid && fetch_buffer enq_ready）
                                                               ▼
                                                        IFU S3（128b → 4×fetch_entry_t）
                                                               │
                                                               │ fetch_entry_o / fetch_valid_o[3:0]
                                                               ▼
                                                 Fetch Buffer（独立紧凑环形 buffer）
                                                               │
                                                               │ deq ready/valid
                                                               ▼
                                                        frontend output
```

- BPU 从 `reset_pc_i` 开始顺序生成 32B block，并在 FTQ backpressure 时冻结当前 PC。
- FTQ 保存 BPU 生成的 block；因为当前没有 release，正常顺序流在填满 `FTQ_DEPTH` 后会停止接收新 block。
- 若未来接入 redirect，FTQ 本地 rewind 会把 branch 后的 wrong-path slots 重新变成可覆盖空间，但 older 保留 entry 仍留在窗口中等待后续 release 机制。
- S0 每拍输出一个 group（`group_pc` + `mask`）。
- S1 将 group 发给 icache。
- S2 等 icache 返回 128-bit 数据，匹配请求上下文。
- S3 把 128-bit 拆成最多 4 条 `fetch_entry_t`，用 mask 标记 entry 内 valid。
- Fetch Buffer 按顺序只收 valid 指令，并通过 `icache_req_allowed_o` 告诉 IFU 是否允许继续发 ICache 请求。
- Frontend 顶层把 fetch buffer 出队 scalar valid 作为 `fetch_valid_o`，并把每个输出 entry 的 `valid` 收敛成 `fetch_valid_mask_o`。

## 受影响模块

### IFU（`rtl/frontend/ifu.sv`）
- 职责：前端取指主流水线，管理 FTQ block 消费、icache 请求、数据拆分，并向外部 Fetch Buffer 输出公共 `fetch_entry_t`。
- 当前实现：S0/S1/S2/S3、misaligned bypass、ICache error 到 `fetch_access_fault` 的传播。
- 当前未做：flush/redirect 传播、预解码、与 backend 的最终顶层连接。

### Fetch Buffer（`rtl/frontend/fetch_buffer.sv`）
- 职责：前后端交界取指缓冲，接收 IFU 输出的公共 `fetch_entry_t`，向后端方向提供 ready/valid fetch group。
- 当前实现：紧凑环形队列、partial group 出队、`icache_req_allowed_o` 空间余量信号。
- 当前未做：redirect 精确清除、按 FTQ index 选择性失效。

### FTQ（`rtl/frontend/ftq.sv`）
- 职责：保存 fetch block 的预测边界和元信息。
- 当前实现：BPU 入队端、IFU 消费端、三指针骨架、allocated-count 满判断，以及 FTQ 本地 redirect repair / rewind。
- 当前未做：release/commit 回收、frontend 顶层 redirect 接线、IFU/fetch_buffer flush、回查端口。

### BPU（`rtl/frontend/bpu.sv`）
- 职责：生成前端预测 fetch block。
- 当前实现：sequential-only，按 32B 从 `reset_pc_i` 顺序生成 `ftq_entry_t`。
- 已支持 redirect reseed：收到 redirect 后立即重置 `pred_pc_q`，从 `redirect_pc_i` 开始重新生成。
- 当前未做：BTB/BHT/RAS、真实方向/目标预测、flush 恢复和训练接口。

### ICache（`rtl/frontend/icache.sv`）
- 职责：指令缓存，提供 hit/miss 判断和 refill。
- 当前实现：4-way set-associative，64B line，16B fetch window，带 refill FSM。
- 与 IFU 接口：S0 请求（`s0_valid/s0_ready/s0_pc`），返回（`out_valid/out_data/out_error`）。
- 与 Frontend 顶层接口：refill request/response 透出到顶层。

### O3 / Tile
- 职责：核心顶层和系统封装。
- 当前实现：仍为占位模块，未接入真实前端链路。

## 代码索引

- `rtl/frontend/ifu.sv`
  - IFU 主模块，包含 S0/S1/S2/S3，输出 `fetch_entry_t` 给独立 Fetch Buffer。
- `rtl/frontend/fetch_buffer.sv`
  - 独立 Fetch Buffer，保存前后端共同认可的 `fetch_entry_t`。
- `rtl/frontend/bpu.sv`
  - 顺序 BPU，生成 32B `ftq_entry_t` 并写入 FTQ。
- `rtl/frontend/ftq.sv`
  - FTQ 模块，当前实现 BPU 入队、IFU 消费和三指针骨架。
- `rtl/frontend/icache.sv`
  - ICache 模块，IFU S1 向其发请求，S2 接收其返回。
- `rtl/frontend/frontend.sv`
  - 前端顶层，实例化并连接 BPU、FTQ、IFU、ICache 和 fetch buffer。
- `rtl/O3.sv`
  - O3 核心顶层入口；真正集成前后端时需要一起修改。
- `rtl/Tile.sv`
  - 更上层系统封装入口。

## 关键时序行为

### BPU 周期级行为

周期 N 组合阶段：
- `ftq_valid_o=1`。
- `ftq_entry_o.start_pc = pred_pc_q`。
- `ftq_entry_o.end_pc = pred_pc_q + FTQ_BLOCK_BYTES`。
- `ftq_entry_o.has_branch=0`，`pred_taken=0`，`fallthrough_pc=next_pc=end_pc`。

周期 N 上升沿：
- reset 时 `pred_pc_q <= reset_pc_i`。
- 否则若 `redirect_valid_i=1`，`pred_pc_q <= redirect_pc_i`，优先级最高。
- 否则若 `ftq_valid_o && ftq_ready_i`，BPU 当前 block 被 FTQ 接收，`pred_pc_q += FTQ_BLOCK_BYTES`。
- 否则 `pred_pc_q` 保持不变。

周期 N+1：
- `ftq_entry_o` 组合反映更新后的 `pred_pc_q`。
- 若上一拍发生了 redirect，本拍从 `redirect_pc_i` 开始生成新 block。

### FTQ 周期级行为

周期 N 组合阶段：
- `bpu_ready_o = (allocated_count_q < FTQ_DEPTH)`。
- `ifu_valid_o = allocated_q[ifu_head_q] && entries_q[ifu_head_q].valid && !consumed_q[ifu_head_q]`。
- `ifu_entry_o / ifu_ftq_idx_o` 反映 `ifu_head_q` 指向的 entry 和 index。

周期 N 上升沿：
- reset 时清空 FTQ，`alloc_tail_q/ifu_head_q/release_head_q/allocated_count_q` 全部归零。
- 若 `bpu_valid_i && bpu_ready_o`，写 `entries_q[alloc_tail_q]`，置 `allocated_q=1`、`consumed_q=0`，推进 `alloc_tail_q`，`allocated_count_q += 1`。
- 若 `ifu_valid_o && ifu_ready_i`，置 `consumed_q[ifu_head_q]=1`，推进 `ifu_head_q`。
- 若 `redirect_valid_i=1`，优先于普通 enqueue/consume：
  - 清空 branch 之后、旧 `alloc_tail_q` 之前的 younger wrong-path slots；
  - 修复 branch entry 的 `end_pc/next_pc/pred_taken/target_pc/fallthrough_pc`；
  - 将 `alloc_tail_q` / `ifu_head_q` 回到 branch entry 的下一槽位；
  - 将 `allocated_count_q` 收缩为 redirect 后保留窗口大小；
  - `release_head_q` 不变。
- IFU 消费不释放容量，不减少 `allocated_count_q`。

### IFU S0 周期级行为

周期 N 组合阶段：
- `active_block` = `ftq_fire ? ftq_entry_i : current_block_q`
- `active_ptr` = `ftq_fire ? ftq_entry_i.start_pc : fetch_ptr_q`
- `group_pc = {active_ptr[38:4], 4'b0}`（16B 对齐）
- `mask[3:0]` 基于 `[active_block.start_pc, active_block.end_pc)` 计算
- `block_done = (group_pc + 16 >= active_block.end_pc)`
- 若 FTQ 新 entry 的 `start_pc[1:0] != 0`，且 IFU 内没有更老 S1/S2 请求、外部 fetch buffer ready，则 `misalign_fire=1`。
- `misalign_fire=1` 时，IFU 输出单 lane `fetch_addr_misaligned=1` 的 `fetch_entry_t`，不进入 S1/S2。
- 正常路径下，`s0_s1_fire` 成立时 S0 输出进入 S1。

周期 N 上升沿：
- 若 `misalign_fire`：该 FTQ entry 被消费，IFU 不保留该 block。
- 若 `ftq_fire && !active_misaligned`：锁存新 block，`fetch_ptr_q = group_pc + 16`，`block_valid_q = !block_done`
- 若 `s0_s1_fire && block_done`：`block_valid_q = 0`
- 若 `s0_s1_fire && !block_done`：`fetch_ptr_q = group_pc + 16`

周期 N+1：
- IFU 继续观察当前 block 或下一条 FTQ entry；misaligned entry 已经作为异常 fetch entry 进入外部 fetch buffer。

### IFU S1 周期级行为

周期 N：
- S1 接收 S0 的 `group_pc` + `mask` + `ftq_idx`。
- `icache_valid_o = s1_valid_q && s2_has_space && icache_req_allowed_i`。
- `icache_pc_o = s1_group_pc_q`。
- `s1_ready_i = !s1_valid_q || s1_icache_fire`。

周期 N 上升沿：
- 若 `s0_s1_fire`：锁存 S0 输出到 S1 寄存器。
- 若 `s1_icache_fire`：S1 数据发给 icache，并把请求上下文压入 S2。

### IFU S2/S3 周期级行为

- S1 `fire` 时，请求上下文压入 S2 FIFO。
- `icache_out_valid` 来时，icache 数据和 `icache_out_error` 回填 S2 头部槽位。
- 当头部 `data_valid=1` 且外部 fetch buffer ready 时，`s2_pop=1`。
- S3 组合直通：同拍将 128-bit `data` 拆成 4 条 `fetch_entry_t`，用 mask 标记 entry valid。
- 若 S2 记录了 `fetch_access_fault`，S3 对本组有效 lane 设置 `fetch_access_fault=1`。

### Fetch Buffer 周期级行为

周期 N 组合阶段：
- 根据 `count_q` 计算剩余空间。
- `enq_ready_o` 表示至少可接收一个完整 IFU enqueue window。
- `icache_req_allowed_o` 表示剩余空间达到当前 ICache request 安全阈值。
- 只要队列非空，出队端 `deq_valid_o=1`，并从 head 开始输出最多 `DEQ_WIDTH` 条 entry；不足的 lane 输出 `valid=0`。

周期 N 上升沿：
- 若 `flush_i=1`，清空 head/tail/count。
- 若入队 fire，按 lane 顺序只写入有效 entry，tail 前进有效条数。
- 若出队 fire，head 前进实际出队条数。
- count 同时加上入队条数并减去出队条数。

周期 N+1：
- IFU 看到更新后的 `enq_ready_o` 和 `icache_req_allowed_o`。
- 后端方向看到更新后的队头 fetch group。

## Branch Redirect Contract（第一版）

本章节冻结第一版 branch mispredict redirect 的 packet 定义、职责边界与已知限制，供后续 Task 2+ 的 flush/recovery 实现使用。字段名与职责描述与后端文档 [`doc/CISLC_O3.md`](doc/CISLC_O3.md) 保持一致。

### Redirect Packet 字段定义
frontend 从 core 层接收 backend 生成的 `branch_redirect_t`，字段与 `rtl/common/o3_pkg.sv` 保持一致：

| 字段 | 宽度 | 语义 |
|------|------|------|
| `valid` | 1 | 本拍 redirect 是否有效 |
| `ftq_idx` | `FTQ_INDEX_WIDTH` | 触发 redirect 的分支所在 FTQ entry 编号 |
| `branch_pc` | `PC_WIDTH` | 该分支指令自身的 PC |
| `redirect_pc` | `PC_WIDTH` | 分支实际目标地址（actual taken 时的跳转目标） |
| `actual_taken` | 1 | 分支实际方向为 taken（当前版本固定为 1） |
| `fallthrough_pc` | `PC_WIDTH` | 分支不跳转时的顺序下一条 PC |

`fallthrough_pc` 当前未参与核心恢复逻辑，但保留在 packet 中供 FTQ 修复 younger window 时参考，也为后续支持 pred-taken / actual not-taken 场景预留字段。

### 职责边界
- **backend / branch execute unit**：负责检测 conditional branch 的方向 mispredict。当发现 pred=not-taken、actual=taken 时，在 branch 执行完成拍生成 valid redirect packet。
- **o3_core**：负责把 backend 生成的 redirect 从后端传送到前端，不做任何解释或修改，只充当 transport。
- **frontend（顶层）**：负责消费 redirect，将其分发给内部 BPU、FTQ、IFU、Fetch Buffer 等子模块。
- **FTQ**：收到 redirect 后，用 `ftq_idx` 定位该 branch 所在的 FTQ entry，将该 entry 及所有 younger entry（更高 `ftq_idx`，按 FTQ 循环语义）标记为无效，并视需要修复该 entry 的 `end_pc` / `fallthrough_pc`。
- **BPU**：收到 redirect 后，用 `redirect_pc` 重新播种内部 `pred_pc_q`，从目标地址开始重新生成预测流。BPU 不负责修复或清除历史 FTQ entry，仅重置自身 `pred_pc_q`。
- **IFU**：收到 redirect 后精确清除所有在飞请求（S1/S2/S3），并从 `redirect_pc` 重新开始取指。
- **Fetch Buffer**：收到 redirect 后精确清除已缓冲但尚未被 backend 消费的 fetch entry。

### 当前限制（第一版）
- **只支持 conditional branch**：当前 redirect 仅由 conditional branch（BEQ/BNE/BLT/BGE/BLTU/BGEU）触发。JAL/JALR/RET 等 unconditional control transfer 不在第一版范围内。
- **只支持 pred not-taken / actual taken**：BPU 当前固定 `pred_taken=0`，因此唯一可能的 mispredict 场景是"预测不跳转、实际跳转"。pred taken / actual not-taken 的 redirect 路径不在第一版范围内。
- **不处理 generalized exception / multi-cause rollback**：第一版 redirect 仅服务于 branch mispredict，不扩展为通用 exception / interrupt / trap 的 flush 与精确恢复机制。后续 Task 2+ 再在此基础上扩展。
- **不做 backend 侧 checkpoint / map / ROB rollback**：第一版只要求 frontend 重新取指，不要求 backend 的 rename map、free list、ROB 做精确 rollback。backend 侧 flush 逻辑留到后续 Task。

## 当前开发约束
- 当前阶段已经有前端 smoke/regression；修改前端后应保持 `sim/frontend/frontend_basic` 可运行。
- 前端代码约束与后端一致：模块头注释、关键逻辑注释、逐周期说明都必须补齐。
- 如果后续修改影响前端接口、PC 选择、预测表、队列、握手或周期级行为，必须同步更新本文件。
- 如果后续修改同时影响协作规则、文档分工或通用执行边界，再同步更新 [`agent.md`](/home/chen/work/CISLC-O3/agent.md)。
