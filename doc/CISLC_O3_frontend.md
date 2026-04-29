# CISLC_O3 Frontend Notes

## 文档定位
- 本文件保留为"前端当前实现状态 + 代码索引 + 时序入口"文档。
- 面向后续 agent / 协作者的执行规则、注释规范、阶段边界，统一遵循 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md)。
- 与后端主文档 [`doc/CISLC_O3.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3.md) 的分工：
  - `doc/CISLC_O3.md` 记录后端现状和后端主链路。
  - 本文件记录前端现状和前端后续开发入口。
- 使用顺序建议：
  1. 先读本文件，确认当前前端实现边界与受影响模块。
  2. 再读相关 frontend RTL 和顶层连接文件。
  3. 最后按 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md) 中的规则落修改。

## 当前实现状态

### IFU（Instruction Fetch Unit）
- `rtl/frontend/ifu.sv` 已实现完整的取指流水线骨架，包含 S0/S1/S2/S3 + Fetch Buffer。
- **S0**：FTQ block 消费端。通过 ready/valid 从 FTQ 拉取 block，组合生成 16B 对齐的 `group_pc` 和 4-bit `mask`。
  - 零气泡设计：`block_valid_q` 在 block 用完的上升沿清 0，同拍组合逻辑 `ftq_ready_o=1`，可立即 fire 下一个 block。
  - 块内指针 `fetch_ptr_q` 跟踪当前 block 内的下一个 group 地址，每次推进 +16B。
  - `mask` 基于 `[start_pc, end_pc)` 开区间计算，标记当前 16B window 内哪些指令属于当前 block。
- **S1**：向 icache 发请求。接收 S0 输出，暂存 `group_pc`/`mask`/`ftq_idx`，驱动 icache s0 接口。
  - 支持同拍收发：S0 进新数据的同时 S1 可将旧数据发给 icache。
- **S2**：双槽移位 FIFO，暂存已发 icache 但尚未返回的请求上下文。
  - 槽位保存 `group_pc`、`mask`、`ftq_idx`，以及 icache 返回后回填的 128-bit `data`。
  - 最大深度 2，对应 icache 单流处理最多 1 个 s1 请求 + 1 个 replay 请求。
  - 弹出条件：头部数据完整（`data_valid=1`）且下游 Fetch Buffer 有空间。
- **S3**：组合直通，零状态。将 icache 返回的 128-bit 数据拆成 4×32-bit 指令。
  - 用 S2 头部槽位的 `mask` 标记每条指令的 `valid`。
  - 4 条指令的 PC 依次为 `group_pc + 0/4/8/12`。
- **Fetch Buffer**：16-entry 统一环形 buffer。
  - 只写入 `valid=1` 的指令（由 mask 决定），按顺序依次占用 slot。
  - 后端每拍可读出最多 4 条指令。
  - 提供 `fb_has_space` 信号用于 backpressure：当剩余空间 < 4 时，IFU S0 不向 FTQ ready，FTQ 被 stall。

### FTQ
- `rtl/frontend/ftq.sv` 已实现 IFU 消费端。
- Reset 时预置 16 个 32B 顺序 block，供 IFU 消费。
- 消费后只标记 `consumed_q`，不清 entry。
- 尚未实现 BPU 写入端、release 端、flush、redirect。

### 尚未实现
- `frontend.sv` 仍是旧的最小顺序取指骨架，后续会被 IFU 取代或集成。
- 未实现分支预测、BPU、BTB、BHT、RAS。
- 未实现 flush、redirect、异常恢复。
- 未实现 icache miss 时的 IFU 级 stall / replay（icache 内部已处理 refill）。
- `rtl/O3.sv` 和 `rtl/Tile.sv` 仍是占位顶层，未接入真实 IFU/FTQ/icache 链路。
- 未写测试和仿真。

## 当前前端数据流

```
FTQ ──ready/valid──> IFU S0 ──ready/valid──> IFU S1 ──ready/valid──> ICache s0
                                                           │
                                                           │ out_valid + out_data
                                                           ▼
                                                    IFU S2（双槽 FIFO）
                                                           │
                                                           │ s2_pop（data_valid && fb_has_space）
                                                           ▼
                                                    IFU S3（组合直通：128b → 4×32b）
                                                           │
                                                           │ 只写 valid=1 的指令
                                                           ▼
                                                    Fetch Buffer（16-entry 环形 buffer）
                                                           │
                                                           │ fb_deq_ready_i
                                                           ▼
                                                        后端 Decode
```

- S0 每拍输出一个 group（`group_pc` + `mask`）。
- S1 将 group 发给 icache。
- S2 等 icache 返回 128-bit 数据，匹配请求上下文。
- S3 把 128-bit 拆成 4 条指令，用 mask 标记 valid。
- Fetch Buffer 按顺序只收 valid 指令，后端按顺序读出。

## 受影响模块

### IFU（`rtl/frontend/ifu.sv`）
- 职责：前端取指主流水线，管理 FTQ block 消费、icache 请求、数据拆分、Fetch Buffer 写入。
- 当前实现：S0/S1/S2/S3 + Fetch Buffer 骨架完整。
- 当前未做：flush/redirect 传播、异常处理、预解码、与 backend 的 decode 接口收敛。

### FTQ（`rtl/frontend/ftq.sv`）
- 职责：保存 fetch block 的预测边界和元信息。
- 当前实现：IFU 消费端 + reset 预置 entry。
- 当前未做：BPU 写入端、release 端、回查端口。

### ICache（`rtl/frontend/icache.sv`）
- 职责：指令缓存，提供 hit/miss 判断和 refill。
- 当前实现：4-way set-associative，64B line，16B fetch window，带 refill FSM。
- 与 IFU 接口：S0 请求（`s0_valid/s0_ready/s0_pc`），返回（`out_valid/out_data/out_pc/out_hit`）。

### O3 / Tile
- 职责：核心顶层和系统封装。
- 当前实现：仍为占位模块，未接入真实前端链路。

## 代码索引

- `rtl/frontend/ifu.sv`
  - IFU 主模块，包含 S0/S1/S2/S3 + Fetch Buffer 的完整实现。
- `rtl/frontend/ftq.sv`
  - FTQ 模块，当前只实现 IFU 消费端。
- `rtl/frontend/icache.sv`
  - ICache 模块，IFU S1 向其发请求，S2 接收其返回。
- `rtl/frontend/frontend.sv`
  - 旧的最小顺序取指骨架，后续会被 IFU 取代。
- `rtl/O3.sv`
  - O3 核心顶层入口；真正集成前后端时需要一起修改。
- `rtl/Tile.sv`
  - 更上层系统封装入口。

## 关键时序行为

### IFU S0 周期级行为

周期 N 组合阶段：
- `active_block` = `ftq_fire ? ftq_entry_i : current_block_q`
- `active_ptr` = `ftq_fire ? ftq_entry_i.start_pc : fetch_ptr_q`
- `group_pc = {active_ptr[38:4], 4'b0}`（16B 对齐）
- `mask[3:0]` 基于 `[active_block.start_pc, active_block.end_pc)` 计算
- `block_done = (group_pc + 16 >= active_block.end_pc)`
- `ftq_ready_o = !block_valid_q`（零气泡：block 用完即 ready）
- `s1_valid_o = block_valid_q || ftq_fire`

周期 N 上升沿：
- 若 `ftq_fire`：锁存新 block，`fetch_ptr_q = group_pc + 16`，`block_valid_q = !block_done`
- 若 `s0_s1_fire && block_done`：`block_valid_q = 0`
- 若 `s0_s1_fire && !block_done`：`fetch_ptr_q = group_pc + 16`

周期 N+1：
- 若上一拍 `block_valid_q` 清 0，本拍 `ftq_ready_o=1`。若 FTQ `valid=1`，同拍 fire，S0 用 FTQ 直通输出新 block 第一组。

### IFU S1 周期级行为

周期 N：
- S1 接收 S0 的 `group_pc` + `mask` + `ftq_idx`。
- `icache_valid_o = s1_valid_q`，`icache_pc_o = s1_group_pc_q`。
- `s1_ready_i = (!s1_valid_q || icache_ready_i) && s2_has_space`。

周期 N 上升沿：
- 若 `s0_s1_fire`：锁存 S0 输出到 S1 寄存器。
- 若 `s1_icache_fire`：S1 数据发给 icache，`s1_valid_q` 保持或更新。

### IFU S2/S3 周期级行为

- S1 `fire` 时，请求上下文压入 S2 FIFO。
- `icache_out_valid` 来时，icache 数据回填 S2 头部槽位。
- 当头部 `data_valid=1` 且 Fetch Buffer 有空间时，`s2_pop=1`。
- S3 组合直通：同拍将 128-bit `data` 拆成 4×32-bit 指令，用 mask 标记 valid。
- Fetch Buffer 写入：只写入 valid=1 的指令，tail 推进相应数量。

## 当前开发约束
- 当前阶段只搭前端 RTL 功能骨架，不写测试代码，不写仿真代码。
- 前端代码约束与后端一致：模块头注释、关键逻辑注释、逐周期说明都必须补齐。
- 如果后续修改影响前端接口、PC 选择、预测表、队列、握手或周期级行为，必须同步更新本文件。
- 如果后续修改同时影响协作规则、文档分工或通用执行边界，再同步更新 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md)。
