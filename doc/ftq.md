# FTQ 字段说明

## 文档定位
- 本文记录 `rtl/frontend/ftq.sv` 中第一版 FTQ 类型定义。
- 当前即将实现 `ftq` 模块主体的第一阶段：只实现 IFU 消费端。
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
  - BPU 后续写入新 block 的位置。
  - 当前阶段暂不实现 BPU 写入端。
- `ifu_head_q`
  - IFU 下一次消费 entry 的位置。
  - 当前阶段先实现该指针。
- `release_head_q`
  - 后续 commit、安全回收或其它释放机制真正释放 entry 的位置。
  - 当前阶段暂不实现 release 端。
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
6. flush 或 redirect 可以清掉错误路径上的 `entry.valid`，并修正相关指针。

## 当前阶段实现范围
当前阶段只实现 IFU 消费端，不实现写入、释放、失效和 flush。

### Reset 预置 Entry
由于 BPU 写入端暂时不存在，reset 时 FTQ 会预置 `FTQ_DEPTH` 个有效 entry，便于 IFU 消费端先形成可运行的时序骨架。

第 `i` 个预置 entry 的字段约定：

- `allocated_q[i] = 1`
- `consumed_q[i] = 0`
- `valid = 1`
- `start_pc = i * FTQ_BLOCK_BYTES`
- `end_pc = start_pc + FTQ_BLOCK_BYTES`
- `has_branch = 0`
- `branch_pc = 0`
- `branch_slot = 0`
- `branch_type = FTQ_BRANCH_NONE`
- `pred_taken = 0`
- `target_pc = 0`
- `fallthrough_pc = end_pc`
- `next_pc = end_pc`
- `exception = 0`
- `exception_cause = 0`

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

### 当前未实现
- 尚未实现 BPU 写入端。
- 尚未实现 `alloc_tail_q` 的真实推进。
- 尚未实现 release 端。
- 尚未实现按 `ftq_idx` 失效。
- 尚未实现 flush 和 redirect。
- 尚未实现后端或 branch execute 的 FTQ 回查端口。
