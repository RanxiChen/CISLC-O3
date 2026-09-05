# FTQ 字段与生命周期

FTQ是16项预测块环形队列。它保存预测控制记录，不保存ICache返回的指令数据；IFU消费
entry以后也不会立即释放，必须等待对应块在Backend提交。

## 块参数

- `FTQ_BLOCK_BYTES=32`：当前预测块最大范围。
- `FTQ_FETCH_WINDOW_BYTES=16`：串行IFU一次ICache请求宽度。
- `FTQ_INDEX_WIDTH=4`：16项FTQ索引宽度。

预测块使用`[start_pc,end_pc)`表示有效范围。未来预测到块内taken控制流时，块可以在
该控制流指令后提前结束；当前BPU没有预测表，始终生成完整32B顺序块。

## Entry内容

预测阶段写入：

- `start_pc/end_pc`
- `has_branch/branch_pc/branch_slot/branch_type`
- `pred_taken/target_pc/fallthrough_pc/next_pc`
- 块级取指异常占位

BRU解析后回填：

- `actual_valid`
- `actual_branch_pc/actual_branch_type`
- `actual_taken/actual_target`

回填内容在Commit释放entry的同拍形成训练观察输出；当前BPU不消费它。

## 三指针

- `alloc_tail_q`：BPU写新预测块的位置。
- `ifu_head_q`：IFU消费最老未取指块的位置。
- `release_head_q`：Commit释放最老已完成块的位置。
- `allocated_count_q`：已分配但尚未释放的entry数量，用于反压BPU。

周期N的BPU ready/valid握手写入`alloc_tail`；IFU ready/valid握手只标记entry已消费并
推进`ifu_head`。Backend本拍提交的`ftq_last`数量作为`release_count`，上升沿从
`release_head`连续清除对应数量的entry。三种动作在无恢复时可以同拍发生，count按
“分配数减释放数”原子更新。

## 指令身份

IFU从FTQ取得块时，把下列字段写入每条`fetch_entry_t`：

- `ftq_idx`：所属FTQ entry。
- `ftq_last`：块内最后一条有效指令。
- `predicted_next_pc`：该指令当初预测的下一PC。

这些字段经过Decode/Rename进入ROB。ROB从队头提交带`ftq_last`的指令时产生FTQ释放。

## Mispredict恢复

BRU的`branch_resolution`携带`ftq_idx`、branch checkpoint tag、实际方向、实际目标和
正确下一PC。误预测时FTQ：

1. 保留包含出错分支的entry并回填实际结果。
2. 删除该entry之后、`alloc_tail`之前的所有年轻entry。
3. 把`alloc_tail`和`ifu_head`恢复到出错entry的下一个位置。
4. 保持`release_head`不变，出错entry仍等待非推测提交。

如果默认not-taken在块中部遇到真实taken分支，原块尾指令会被后端杀掉。ROB同时把
该分支标记成新的`ftq_last`，保证它提交时仍能释放这个FTQ entry。

外部flush清空全部FTQ状态；普通正确分支解析只回填实际结果，不改变三个指针。

## 当前限制

- 训练观察没有接BTB/BHT/RAS。
- 一个FTQ entry只保存一组实际控制流训练记录。
- 没有BPU到IFU同拍bypass。
- 没有多线程、复杂历史恢复或多路预测器更新仲裁。
- 本阶段没有更新或运行测试，只做RTL静态检查。
