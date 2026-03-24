# CISLC_O3 Long-Term Notes

## 当前实现状态
- `backend` 已经具备一个最小 fetch-entry buffer，可以承接 frontend 输入。
- `backend` 已经实例化 `decoder`，并将 decode 结果送入基础 rename 数据流。
- `decoder` 已经能提取 `rs1/rs2/rd`，并给出基础 RVI 的 `rs1_read_en/rs2_read_en/rd_write_en`。
- `free_list` 已经支持“按本拍真实请求数”分配空闲物理寄存器。
- `rename_map_table` 已新增，负责维护架构寄存器到当前物理寄存器的映射。
- `physical_regfile` 已存在并可参数化配置，但本次没有继续扩展它的功能。

## 当前后端数据流
- 当前数据流是：`frontend -> fetch_entry buffer -> decoder -> free_list + rename_map_table`
- `decoder` 先产生最小重命名语义。
- `backend` 基于 `rd_write_en && rd != 0` 生成 `alloc_req`。
- `free_list` 按 lane 顺序给真正需要写回的指令分配新物理寄存器。
- `rename_map_table` 组合读出 `src1_preg/src2_preg/old_dst_preg`，并在 `rename_fire` 时更新 `rd` 的映射。

## 模块说明
### backend
- 职责：承接 frontend 指令组，驱动基础 rename 流程。
- 当前实现：单级 buffer + 解码 + 物理寄存器分配请求 + rename map 更新。
- 当前未做：ROB、调度、执行、回写、提交、异常恢复。

### decoder
- 职责：从 32 位指令中提取寄存器字段，并判断是否读 `rs1/rs2`、是否写 `rd`。
- 当前覆盖：基础 RVI 中 `LUI/AUIPC/JAL/JALR/BRANCH/LOAD/STORE/OP-IMM/OP/FENCE/SYSTEM(保守处理)`。
- 当前未做：立即数、功能单元类型、CSR 详细行为、trap 语义。

### free_list
- 职责：维护空闲物理寄存器池，为 rename 提供新物理寄存器。
- reset 约定：
  - `x1~x31 -> p0~p30`
  - 空闲池从 `p31` 开始
- 当前未做：释放旧物理寄存器、checkpoint、rollback、flush 恢复。

### rename_map_table
- 职责：维护架构寄存器到当前物理寄存器的映射。
- reset 约定：
  - `x0` 固定视为 `p0`
  - `x1~x31 -> p0~p30`
- 当前未做：commit map、checkpoint map、lane 间依赖和覆盖处理。

### physical_regfile
- 职责：提供物理寄存器存储体。
- 当前状态：模块已存在，本次未修改其行为规划。

## 关键时序行为
### backend 周期级行为
周期 N 组合阶段：
- `fetch_entry_q` 中保存当前待 rename 的指令组。
- `decoder` 组合输出 `rs1/rs2/rd` 和读写语义。
- `free_list` 组合输出本拍候选 `new_dst_preg`。
- `rename_map_table` 组合输出 `src1_preg/src2_preg/old_dst_preg`。

周期 N 上升沿：
- 如果 `rename_fire=1`，则当前 buffer 中这组指令完成本版 rename。
- 如果 `fetch_fire=1`，则 frontend 新的一组指令写入 buffer。
- 如果同拍既 `rename_fire=1` 又 `fetch_fire=1`，表示旧的一组被消费，同时新的一组顶上来。

周期 N+1：
- 看到更新后的 free list 和 rename map 状态。
- 看到新 buffer 中的下一组指令。

### rename_map_table 周期级行为
周期 N 组合阶段：
- 输入当前 lane 的 `rs1/rs2/rd`。
- 直接读取 map table，得到 `src1_preg/src2_preg/old_dst_preg`。
- 若该 lane 需要写 `rd`，backend 同拍还会拿到对应 `new_dst_preg`。

周期 N 上升沿：
- 若 `rename_fire=1 && rd_write_en=1 && rd!=0`，则更新 `map_table[rd] = new_dst_preg`。

周期 N+1 组合阶段：
- 若再次读取同一个 `rd`，会看到更新后的物理寄存器编号。

### free_list 周期级行为
周期 N 组合阶段：
- 统计本拍所有 lane 的 `alloc_req_i` 请求数。
- 若剩余空闲寄存器数足够，则 `alloc_valid_o=1`。
- 对请求为 1 的 lane，按 lane 顺序给出连续的候选新物理寄存器。

周期 N 上升沿：
- 若 `alloc_valid_o=1 && alloc_ready_i=1`，则真正消耗本拍请求数个物理寄存器。
- `head_q` 和 `count_q` 在上升沿更新。

周期 N+1 组合阶段：
- 对外看到新的队头位置和下一批候选物理寄存器。

## 已知限制
- 当前多发射只是“并行 lane”，同拍 lane 之间按彼此无关处理。
- 当前不处理组内 RAW/WAW/WAR。
- 当前不处理同拍多个 lane 写同一个 `rd` 的精确定义。
- 当前不做 commit、旧物理寄存器释放、checkpoint、rollback、flush。
- 当前 `SYSTEM` 指令先按保守方式处理，不纳入 CSR 重命名细节。
- 当前不要求任何测试代码。
- 当前不要求任何仿真代码。
- 当前不做完整代码检测闭环，统一留到后续数据流更完整后再补。

## 后续扩展入口
- 组内依赖处理：优先在 `backend` 的 lane 间旁路逻辑或 `rename_map_table` 前级仲裁逻辑中接入。
- 提交与旧物理寄存器释放：在 `rename_map_table` 已输出的 `old_dst_preg` 基础上向 ROB / commit 级联。
- checkpoint / rollback：在 `rename_map_table` 上扩展 speculative map 管理。
- 分支恢复：在 rename 状态与 free list 状态上同时增加可恢复快照。

## 开发约定
- 当前阶段只要求把 RTL 功能链路搭起来。
- 当前阶段不写测试代码，不写仿真代码。
- 当前阶段不做完整代码检测闭环。
- 等后续 backend 数据流更完整后，再统一补验证、联调和仿真。

## 注释规范
- 以后每次新增或修改 RTL，都必须在模块头注释写清楚：
  - 已经实现什么功能
  - 当前没有实现什么功能
  - 未来准备从哪里扩展
- 涉及状态寄存器、队列、映射表、握手的逻辑，必须说明：
  - 组合输出是什么
  - 上升沿更新什么状态
  - 下一拍会看到什么
- 对复杂时序模块，优先补逐周期说明，不再使用字符串画波形。
- 如果当前阶段没有做测试或仿真，也要在代码注释和本文档里明确写出来。
