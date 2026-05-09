# FTQ 字段说明

## 文档定位
- 本文记录 `rtl/frontend/ftq.sv` 中第一版 FTQ 类型定义。
- 当前 `ftq` 模块已经实现 BPU 入队、IFU 消费和三指针骨架。
- 当前 FTQ 面向按 block 进行分支预测的前端，用来保存每个 fetch block 的预测边界、控制流信息和后续恢复所需元信息。

## 基础常量
- `FTQ_DEPTH`
  - 后续 FTQ 环形队列的表项数量。
  - 当前先固定为 16。
- `FTQ_BLOCK_BYTES`
  - 一个 FTQ block 覆盖的字节数。
  - 当前先固定为 32B。
- `FTQ_FETCH_WINDOW_BYTES`
  - IFU 一次取指窗口的字节数。
  - 当前先固定为 16B，只作为 FTQ 与 IFU 边界说明；实际窗口拆分和 lane mask 由 IFU 管理。
- `FTQ_BRANCH_SLOT_WIDTH`
  - `branch_slot` 的宽度。
  - 用于表示分支指令在当前 fetch block 的第几个 lane。
  - 当前 32B block 最多包含 8 条 32 位指令，因此该宽度先固定为 3。
- `FTQ_INDEX_WIDTH`
  - `ftq_idx_t` 的宽度。
  - 后续分支执行或 redirect 回查 FTQ 时使用。
- `FTQ_EXCEPTION_CAUSE_WIDTH`
  - `exception_cause` 的宽度。
  - 当前先保留 8 位，具体 cause 编码后续再统一。

## 分支类型
- `FTQ_BRANCH_NONE`
  - 当前 block 没有控制流指令。
- `FTQ_BRANCH_COND`
  - 条件分支。
- `FTQ_BRANCH_JAL`
  - RISC-V `JAL` 直接跳转。
- `FTQ_BRANCH_JALR`
  - RISC-V `JALR` 间接跳转。
- `FTQ_BRANCH_CALL`
  - 调用类跳转，后续可用于 RAS push。
- `FTQ_BRANCH_RET`
  - 返回类跳转，后续可用于 RAS pop。

## FTQ Entry 字段
- `valid`
  - 当前 FTQ entry 是否有效。
  - 后续让一个 block 失效时，预期只清这个字段，不立即搬移其它 entry。
- `start_pc`
  - 当前 fetch block 的起始 PC。
- `end_pc`
  - 当前 fetch block 的开区间结束 PC。
  - 含义是顺序取指下第一条不属于本 block 的指令地址。
- `has_branch`
  - 当前 block 内是否包含分支、跳转、调用或返回类控制流指令。
- `branch_pc`
  - 当前 block 内控制流指令的 PC。
  - 当 `has_branch=0` 时该字段无效。
- `branch_slot`
  - 控制流指令在当前 fetch block 内的 lane 编号。
  - 相比只保存 `branch_pc`，该字段更方便做 block 内 lane 级对账。
- `branch_type`
  - 当前控制流指令的类型。
- `pred_taken`
  - 前端对当前控制流指令的预测方向。
  - 当 `has_branch=0` 时通常为 0。
- `target_pc`
  - 如果预测或实际结果为 taken，控制流跳转到的目标 PC。
- `fallthrough_pc`
  - 如果预测或实际结果为 not-taken，顺序执行应该到达的 PC。
- `next_pc`
  - 前端当时实际选择的下一个 fetch PC。
  - 通常等于 `pred_taken ? target_pc : fallthrough_pc`，但保留成独立字段便于 debug 和后续复杂预测器对账。
- `exception`
  - 当前 fetch block 是否携带取指异常。
- `exception_cause`
  - 取指异常原因。
  - 当前只保留字段，具体编码后续统一。

## 不属于 FTQ Entry 的信息
- `fetch_mask` 不放在 FTQ entry 中。
- 原因是 FTQ 描述的是 block 级预测结果，而 IFU 的实际取指窗口当前是 16B，小于当前 FTQ block 的 32B。
- 一个 FTQ block 后续可能由 IFU 分多拍取完，每拍哪些 lane 有效应由 IFU 根据取指窗口、PC 对齐、ICache 返回、跨 line、跨页和异常情况自行生成。

## 目标结构
FTQ 后续不按普通 FIFO 实现。普通 FIFO 在消费后会释放队头 entry，但 FTQ entry 在被 IFU 消费后仍需要保留，供后端分支解析、redirect 恢复和后续调试回查使用。

目标结构是多指针环形窗口：

- `entries_q[FTQ_DEPTH]`
  - 保存所有 `ftq_entry_t`。
- `allocated_q[FTQ_DEPTH]`
  - 表示对应槽位是否已经被 FTQ 分配。
  - 分配表示该槽位属于当前 FTQ 窗口，不等于该 block 一定仍在正确路径上。
- `consumed_q[FTQ_DEPTH]`
  - 表示对应 entry 是否已经提供给 IFU 消费过。
  - IFU 消费只设置该位，不清 entry 内容，也不清 `entry.valid`。
- `alloc_tail_q`
  - BPU 写入新 block 的位置。
  - 当前阶段已经由 BPU 入队端推进。
- `ifu_head_q`
  - IFU 下一次消费 entry 的位置。
  - 当前阶段已经由 IFU 消费端推进。
- `release_head_q`
  - 后续 commit、安全回收或其它释放机制真正释放 entry 的位置。
  - 当前阶段只 reset，不推进。
- `allocated_count_q`
  - 当前已经分配但尚未 release 的 entry 数量。
  - 用于判断 FTQ 是否已满，决定是否对 BPU 拉高 `bpu_ready_o`。
- `entry.valid`
  - 表示该 block 是否仍属于当前有效路径。
  - 失效某个 block 时清 `entry.valid`，但不等价于释放该槽位。

## Entry 生命周期
目标生命周期如下：

1. BPU 产生一个预测 block，在 `alloc_tail_q` 分配 FTQ entry。
2. IFU 从 `ifu_head_q` 消费该 entry，拿到 block 级 PC 边界和预测信息。
3. IFU 消费后只标记 `consumed_q`，entry 继续保留。
4. 后端分支执行、redirect 或调试逻辑仍可通过 `ftq_idx` 回查这个 entry。
5. 当 commit 或其它安全回收机制确认该 entry 不再需要时，才由 `release_head_q` 真正释放槽位。
6. flush 或 redirect 可以清掉错误路径上的 entry，并修正相关指针。

## 当前阶段实现范围
当前阶段实现 BPU 入队端、IFU 消费端和 FTQ 本地 redirect repair/rewind；保留 release 指针但不实现 release/commit 回收。

### Reset 行为
Reset 后 FTQ 为空，不再预置顺序 block：

- `entries_q = 0`
- `allocated_q = 0`
- `consumed_q = 0`
- `alloc_tail_q = 0`
- `ifu_head_q = 0`
- `release_head_q = 0`
- `allocated_count_q = 0`

reset 释放后，BPU 从 `frontend.reset_pc_i` 开始生成第一个 `ftq_entry_t`，FTQ 在未满时接收该 entry。

### BPU 入队端握手
FTQ 从 BPU 接收 block 级预测结果：

- `bpu_valid_i`
  - BPU 当前有一个 `ftq_entry_t` 可以写入 FTQ。
- `bpu_ready_o`
  - FTQ 未满时为 1。
  - 当前定义为 `allocated_count_q < FTQ_DEPTH`。
- `bpu_entry_i`
  - BPU 生成的 fetch block。

当 `bpu_valid_i && bpu_ready_o` 成立时：

- `entries_q[alloc_tail_q] <= bpu_entry_i`。
- `allocated_q[alloc_tail_q] <= 1`。
- `consumed_q[alloc_tail_q] <= 0`。
- `alloc_tail_q` 前进到下一个 entry。
- `allocated_count_q` 加 1。

如果 `allocated_count_q == FTQ_DEPTH`：

- `bpu_ready_o = 0`。
- 即使 IFU 同拍消费 entry，也不会释放容量。
- 只有未来 release/commit 回收逻辑才能让 FTQ 再次接收 BPU entry。

### IFU 消费端握手
FTQ 向 IFU 提供 ready/valid 风格接口：

- `ifu_valid_o`
  - 当前 `ifu_head_q` 指向的 entry 已分配、有效且尚未被 IFU 消费时为 1。
- `ifu_ready_i`
  - IFU 表示本拍接受当前 entry。
- `ifu_entry_o`
  - 当前提供给 IFU 的 FTQ entry。
- `ifu_ftq_idx_o`
  - 当前 entry 对应的 FTQ index。

当 `ifu_valid_o && ifu_ready_i` 成立时：

- `consumed_q[ifu_head_q]` 置 1。
- `ifu_head_q` 前进到下一个 entry。
- 不清 `entries_q[ifu_head_q]`。
- 不清 `entries_q[ifu_head_q].valid`。
- 不清 `allocated_q[ifu_head_q]`。
- 不减少 `allocated_count_q`。

### 当前容量限制
当前 FTQ 已经是三指针骨架，但 release 端尚未实现。因此：

1. BPU 最多可以向 FTQ 分配 `FTQ_DEPTH` 个 entry。
2. IFU 可以按顺序消费这些 entry。
3. IFU 消费后 entry 仍然保留，容量不会释放。
4. 当 `allocated_count_q == FTQ_DEPTH` 后，`bpu_ready_o=0`，BPU 停在当前 PC。
5. IFU 消费完所有已分配 entry 后，`ifu_valid_o=0`，前端停止继续向后产生新 fetch block。

### 当前未实现
- 尚未实现 release 端。
- 已实现 FTQ 本地 redirect repair：
  - younger wrong-path entries 被清空并从当前窗口移除；
  - branch entry 会被截断到 `branch_pc + 4`，并改写 `next_pc=redirect_pc`；
  - `alloc_tail_q` / `ifu_head_q` 会回到 branch entry 的下一槽位；
  - `allocated_count_q` 会收缩到保留窗口大小。
- redirect rewind 只作用于 FTQ 当前窗口，不代表 commit-time release：
  - `release_head_q` 不前进；
  - older-than-branch 的已分配 entry 仍保留，供后续后端回查或未来 commit/release 使用。
- 尚未实现 frontend 顶层的 redirect 接线、IFU flush 和 fetch buffer flush。
- 尚未实现后端或 branch execute 的 FTQ 回查端口。

## Redirect Repair / Rewind 语义

本节是当前短期 FTQ redirect 语义的单点说明。后续 agent 若要继续 Task 4/5/6，应优先以本节为准，而不是反向从 RTL 推导行为。

### 输入字段
- `redirect_valid_i`
  - redirect repair 有效，优先级高于普通 enqueue / consume。
- `redirect_ftq_idx_i`
  - backend 指向 branch 所在的 FTQ entry。
- `redirect_branch_pc_i`
  - branch 指令的真实 PC。
- `redirect_redirect_pc_i`
  - branch 实际 taken 后应跳转到的 redirect 目标。
- `redirect_actual_taken_i`
  - 当前短期实现里只期待 taken mispredict 路径，但字段保留为显式方向信息。

### Branch / Younger / Older 的处理规则
- branch entry：
  - 保留该 entry。
  - `end_pc` 改成 `branch_pc + 4`。
  - `next_pc` 改成 `redirect_pc`。
  - `pred_taken/target_pc/fallthrough_pc` 同步改写到实际结果。
- younger entries：
  - 指 `redirect_ftq_idx_i` 之后、旧 `alloc_tail_q` 之前仍属于当前 allocated window 的槽位。
  - 这些槽位会被清空 `entry/allocated/consumed`，立即从当前 FTQ window 中移除。
- older entries：
  - 完全保持不变。
  - 既不改 entry 内容，也不改 allocated 状态。

### 当前明确不做的事
- 不做 commit-time release。
- 不做 generalized recovery 或多异常源统一回滚。
- 不做 backend 驱动的 FTQ walkback / release-head 推进。
- 不做 IFU / fetch_buffer / ICache 的跨模块 flush；这些属于后续 Task 4。
- 不做 frontend top 到 backend 的完整 redirect 闭环；这些属于后续 Task 5/6。

### Pointer / Count Policy
- `alloc_tail_q`
  - redirect 后回到 `next_ptr(redirect_ftq_idx_i)`。
  - 这样后续 BPU block 会从 branch 后第一槽位重新覆盖旧 wrong-path window。
- `ifu_head_q`
  - redirect 后也回到 `next_ptr(redirect_ftq_idx_i)`。
  - 目的不是重放 branch，而是保证 IFU 不会跳过 redirect 后重新分配到 branch 后槽位的新 block。
- `allocated_count_q`
  - 收缩为 `[release_head_q, next_ptr(redirect_ftq_idx_i))` 这段保留窗口的大小。
  - 这样 FTQ 不会继续把已失效的 wrong-path slot 计入“已分配未 release”容量。
- `release_head_q`
  - redirect 时保持不变。
  - commit-time release 仍是后续独立机制，不与 wrong-path rewind 混用。
