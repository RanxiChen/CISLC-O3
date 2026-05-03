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
- `rtl/frontend/ftq.sv` 已实现 IFU 消费端。
- Reset 时预置 16 个 32B 顺序 block，供 IFU 消费。
- 消费后只标记 `consumed_q`，不清 entry。
- 尚未实现 BPU 写入端、release 端、flush、redirect。

### Frontend Top
- `rtl/frontend/frontend.sv` 已实例化并连接 `ftq`、`ifu`、`ICache` 和 `fetch_buffer`。
- 当前顶层数据流是 `FTQ -> IFU -> fetch_buffer -> frontend output`，其中 IFU 通过 ICache 完成取指数据访问。
- fetch buffer 出队口暂时直接作为 frontend 顶层输出：`fetch_valid_o` 表示本拍有 fetch group，`fetch_valid_mask_o` 由每个 `fetch_entry_t.valid` 生成。
- ICache refill request/response 当前从 frontend 顶层透出，后续可接 L2、总线或测试内存模型。
- ICache line 大小当前由 `o3_pkg::ICACHE_LINE_BYTES` 统一定义，frontend 实例化点不单独覆盖。
- `flush_i` 当前接到 ICache 和 fetch buffer；尚未实现 FTQ/IFU 的 redirect 精确清除。

### 尚未实现
- 不接 backend；fetch buffer 出队口还没有连入后端 decode 入口。
- 未实现分支预测、BPU、BTB、BHT、RAS。
- 未实现 redirect、异常恢复和跨模块精确清除。
- `rtl/O3.sv` 和 `rtl/Tile.sv` 仍是占位顶层，未接入真实 IFU/FTQ/icache 链路。
- 未写测试和仿真。

## 当前前端数据流

```
frontend
  FTQ ──ready/valid──> IFU S0 ──ready/valid──> IFU S1 ──ready/valid──> ICache s0
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
- 当前实现：IFU 消费端 + reset 预置 entry。
- 当前未做：BPU 写入端、release 端、回查端口。

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
- `rtl/frontend/ftq.sv`
  - FTQ 模块，当前只实现 IFU 消费端。
- `rtl/frontend/icache.sv`
  - ICache 模块，IFU S1 向其发请求，S2 接收其返回。
- `rtl/frontend/frontend.sv`
  - 前端顶层，实例化并连接 FTQ、IFU、ICache 和 fetch buffer。
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

## 当前开发约束
- 当前阶段只搭前端 RTL 功能骨架，不写测试代码，不写仿真代码。
- 前端代码约束与后端一致：模块头注释、关键逻辑注释、逐周期说明都必须补齐。
- 如果后续修改影响前端接口、PC 选择、预测表、队列、握手或周期级行为，必须同步更新本文件。
- 如果后续修改同时影响协作规则、文档分工或通用执行边界，再同步更新 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md)。
