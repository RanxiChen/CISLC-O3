# CISLC_O3 Frontend Notes

## 当前边界

前端当前形成第一版顺序预测与恢复闭环：

```text
sequential BPU -> FTQ -> serial IFU -> ICache -> Fetch Buffer -> Backend
       ^                                                       |
       +---------- branch resolution / redirect ---------------+
```

- BPU只生成最大32B的预测取指块，当前没有BTB/BHT/RAS，固定按not-taken顺序推进。
- FTQ是16项预测块环形队列，不是一级流水寄存器。IFU消费与Commit释放使用独立指针。
- IFU暂时采用单块、单ICache请求状态机，不实现多请求并发。
- ICache内部包含`0x10000000`起始的64KiB ITCM；完整16B窗口位于该范围时固定一拍
  返回，范围外继续走blocking Cache refill，由仿真器的软件后备内存响应。
- Fetch Buffer继续作为前后端交接的紧凑指令队列。
- Backend提交某块最后一条存活指令时，按序释放对应FTQ entry。
- 分支误预测时，Frontend保留包含该分支的FTQ entry，截断所有年轻entry，并从
  `redirect_pc`重新生成预测块。
- FTQ能够记录分支实际方向和目标并在释放时形成训练观察值；当前BPU不使用训练数据。

统一内存定向测试已经覆盖ITCM初始化取指和范围外软件内存refill。RVC、真实预测算法、
TLB/PMP、跨页取指、异常恢复和并发ICache请求仍未实现。

## 预测块与FTQ合同

`ftq_entry_t`保存：

- `[start_pc,end_pc)`预测取指范围；当前最大32B。
- 预测控制流位置、类型、方向、目标、fallthrough和`next_pc`。
- 分支执行后回填的实际分支PC、类型、方向和目标。
- 取指异常占位字段。

当前BPU始终生成无已知分支的完整32B块：`has_branch=0`、`pred_taken=0`、
`next_pc=end_pc`。未来预测器命中块内控制流时，可以缩短有效块边界并改变`next_pc`，
而不改变FTQ到IFU的接口。

FTQ维护：

- `alloc_tail_q`：BPU下一次分配位置。
- `ifu_head_q`：IFU下一次消费位置。
- `release_head_q`：Commit下一次释放位置。
- `allocated_count_q`：已分配但尚未提交释放的块数。

IFU消费只推进`ifu_head_q`，不回收容量。Commit输出本拍跨过的`ftq_last`数量，FTQ从
`release_head_q`连续释放相同数量的entry。

## 串行IFU状态机

`rtl/frontend/ifu.sv`当前有四个状态：

- `IFU_IDLE`：等待并接收一条FTQ entry。
- `IFU_REQ`：保持一个16B对齐请求，直到ICache ready/valid握手。
- `IFU_WAIT`：等待该请求唯一对应的ICache返回。
- `IFU_OUT`：把128位返回拆成最多4条32位指令，保持到Fetch Buffer接受。

一个32B预测块通常依次产生两个16B请求。只有第一组返回已经进入Fetch Buffer后，IFU
才发第二组请求；当前故意不重叠请求、返回和块处理。

每条`fetch_entry_t`携带：

- 原始和规范32位指令、PC、长度和统一异常字段。
- `ftq_idx`：所属预测块。
- `ftq_last`：该指令是不是块内最后一条有效指令。
- `predicted_next_pc`：该指令当初预测的下一PC；无预测控制流时为`pc+4`。

当前没有RVC解压，正常指令固定`inst_len=4/is_rvc=0`。地址不满足4字节对齐时直接生成
`EXCEPTION_CAUSE_INST_ADDR_MISALIGNED`；ICache错误转换为统一取指访问异常。

## Redirect与ICache

分支错误解析到达Frontend时：

1. BPU在上升沿把预测PC改为`redirect_pc`。
2. FTQ删除出错块之后的所有entry，`alloc_tail/ifu_head`恢复到该块之后。
3. IFU清除当前块、请求和返回保持状态。
4. Fetch Buffer整体清空；其中所有指令都比分支年轻。
5. ICache杀死查找/replay并丢弃旧miss的迟到refill。

Branch redirect不会清空ICache有效数据。`icache.flush`保留给reset级维护语义，redirect使用
独立`kill`输入，仅处理错误路径的在飞控制状态。

ITCM使用绝对物理地址初始化口。完整16B窗口命中ITCM时不查询tag、不分配Cache line；
窗口跨越ITCM末端时整笔按范围外请求处理。flush和redirect都不擦除ITCM内容。当前数据端
写ITCM不会同步修改该阵列，因此不支持自修改代码。

第一版只有一个请求在飞，因此IFU被清空后可以直接忽略迟到返回；ICache在discard miss
完成前保持blocking，不会把旧返回误配给新请求。未来增加多个outstanding后，需要epoch或
请求tag。

## 分支恢复与训练时序

- BRU结果先进入Backend Branch Result寄存器。
- 下一周期`branch_resolution.valid`广播实际方向、目标、FTQ/ROB/checkpoint身份。
- 正确预测只更新FTQ实际结果并释放后端checkpoint，不清前端。
- 错误预测同时触发后端checkpoint恢复和上述Frontend redirect。
- 默认not-taken可能在32B块中部遇到真实taken分支；ROB会把该分支改记为`ftq_last`，使
  被杀掉的原块尾指令不会阻止FTQ最终释放。
- 该FTQ块提交时产生训练观察值并释放。当前训练输出未连接预测表。

## 文件索引

- `rtl/frontend/bpu.sv`：顺序预测块生成与redirect PC恢复。
- `rtl/frontend/ftq.sv`：预测块存储、IFU消费、Commit释放、误预测截断和训练观察。
- `rtl/frontend/ifu.sv`：单块单请求取指状态机。
- `rtl/frontend/icache.sv`：64KiB ITCM、blocking ICache、refill以及redirect kill。
- `rtl/frontend/fetch_buffer.sv`：前后端交接的紧凑指令队列。
- `rtl/frontend/frontend.sv`：上述模块总装和恢复信号分发。
- `rtl/core/o3_core.sv`：Backend resolution/release到Frontend的闭环连接。

## 后续顺序位置

当前前端只具备固定not-taken预测结构。下一步若继续前端，应先讨论BTB记录的块边界、
条件分支方向表和训练端口吞吐；在此之前不引入RAS、GHR恢复或多bank ICache优化。
