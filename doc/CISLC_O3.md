# CISLC_O3 Long-Term Notes

## 文档定位
- 本文件保留为“当前实现状态 + 代码索引 + 时序入口”文档。
- 面向后续 agent / 协作者的执行规则、注释规范、阶段边界，已拆分到 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md)。
- 使用顺序建议：
  1. 先读本文件，确认当前实现边界与受影响模块。
  2. 再读相关 RTL。
  3. 最后按 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md) 中的规则落修改。

## 当前实现状态
- `backend` 已经具备一个最小 fetch-entry buffer，可以承接 frontend 输入。
- `backend` 已经实例化 `decoder`，并将 decode 结果送入基础 rename 数据流。
- 当前后端并行宽度命名统一使用 `machine width` / `MACHINE_WIDTH`，表示每周期并行处理的 lane 数。
- `decoder` 已经能提取 `rs1/rs2/rd`，并给出基础 RVI 的 `rs1_read_en/rs2_read_en/rd_write_en`。
- `free_list` 已经支持“按本拍真实请求数”分配空闲物理寄存器。
- `rename_map_table` 已新增，负责维护架构寄存器到当前物理寄存器的映射。
- `physical_regfile` 已存在并可参数化配置，但本次没有继续扩展它的功能。
- `int_execute_unit` 已新增，提供独立的 RV64I 整数执行数据通路，但尚未接入 backend 主链路。
- `mul_execute_unit` 已新增，提供独立的 RV64M 乘法单元，当前采用“预计算结果 + 固定拍数返回”的简化骨架。
- `div_execute_unit` 已新增，提供独立的 RV64M 除法/取余单元，当前采用“预计算结果 + 固定拍数返回”的简化骨架。

## 当前后端数据流
- 当前数据流是：`frontend -> fetch_entry buffer -> decoder -> free_list + rename_map_table`
- `decoder` 先产生最小重命名语义。
- `backend` 基于 `rd_write_en && rd != 0` 生成 `alloc_req`。
- `free_list` 按 lane 顺序给真正需要写回的指令分配新物理寄存器。
- `rename_map_table` 组合读出 `src1_preg/src2_preg/old_dst_preg`，并在 `rename_fire` 时更新 `rd` 的映射。
- 当前执行单元已经独立存在，但还没有插入到 rename 之后的 issue / dispatch / execute 数据流中。

## 模块说明
### backend
- 职责：承接 frontend 指令组，驱动基础 rename 流程。
- 当前实现：单级 buffer + 解码 + 物理寄存器分配请求 + rename map 更新。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期并行进入 rename 数据流的 lane 数。
- 当前未做：ROB、调度、执行、回写、提交、异常恢复。

### decoder
- 职责：从 32 位指令中提取寄存器字段，并判断是否读 `rs1/rs2`、是否写 `rd`。
- 当前覆盖：基础 RVI 中 `LUI/AUIPC/JAL/JALR/BRANCH/LOAD/STORE/OP-IMM/OP/FENCE/SYSTEM(保守处理)`。
- 当前未做：立即数、功能单元类型、CSR 详细行为、trap 语义。

### free_list
- 职责：维护空闲物理寄存器池，为 rename 提供新物理寄存器。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期最多并行服务的分配请求 lane 数。
- reset 约定：
  - `x1~x31 -> p0~p30`
  - 空闲池从 `p31` 开始
- 当前未做：释放旧物理寄存器、checkpoint、rollback、flush 恢复。

### rename_map_table
- 职责：维护架构寄存器到当前物理寄存器的映射。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期并行读取/更新映射的 lane 数。
- reset 约定：
  - `x0` 固定视为 `p0`
  - `x1~x31 -> p0~p30`
- 当前未做：commit map、checkpoint map、lane 间依赖和覆盖处理。

### physical_regfile
- 职责：提供物理寄存器存储体。
- 当前状态：模块已存在，本次未修改其行为规划。

### int_execute_unit
- 职责：提供 RV64I 整数算术、逻辑、移位、比较类运算的数据通路。
- 当前实现：单拍组合执行，支持 64 位与 32 位 word 结果语义。
- 当前未做：不接指令解码、不接 issue/dispatch、不接分支/访存/回写控制。

### mul_execute_unit
- 职责：提供 RV64M 乘法类指令的独立执行单元。
- 当前实现：单请求在飞；请求进入时预计算结果，再按固定 `MUL_LATENCY` 延迟返回。
- 当前未做：不做乘法高低位融合、不做多请求并发、不做工业级乘法器结构。

### div_execute_unit
- 职责：提供 RV64M 除法与取余类指令的独立执行单元。
- 当前实现：单请求在飞；请求进入时预计算商/余数，再按固定 `DIV_LATENCY` 延迟返回。
- 当前未做：不做商余融合、不做多请求并发、不做工业级迭代除法器结构。

## 代码索引
- `rtl/backend/backend.sv`
  - 当前 rename 最小闭环的总装模块。
  - 串起 fetch-entry buffer、decoder、free_list、rename_map_table。
- `rtl/backend/decoder.sv`
  - 负责把 32 位指令变成 rename 阶段所需的最小寄存器语义。
- `rtl/backend/free_list.sv`
  - 负责按真实请求数分配新物理寄存器。
- `rtl/backend/rename_map_table.sv`
  - 负责维护架构寄存器到物理寄存器的当前映射。
- `rtl/backend/physical_regfile.sv`
  - 物理寄存器文件实现，当前仍是独立能力模块，尚未接入完整后端数据流。
- `rtl/backend/int_execute_unit.sv`
  - 独立的整数执行单元，负责 RV64I 的基础整数计算。
- `rtl/backend/mul_execute_unit.sv`
  - 独立的乘法执行单元，负责 RV64M 的乘法类指令。
- `rtl/backend/div_execute_unit.sv`
  - 独立的除法执行单元，负责 RV64M 的除法/取余类指令。
- `rtl/common/o3_pkg.sv`
  - 定义 `fetch_entry_t`、`decode_in_t`、`decode_out_t` 等跨模块接口类型。
- `rtl/frontend/frontend.sv`
  - frontend 侧实现入口，和 backend 对接时需要一起看接口约束。
- `rtl/O3.sv`
  - O3 核心顶层连接入口。
- `rtl/Tile.sv`
  - 更上层系统封装入口。

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

### int_execute_unit 周期级行为
周期 N 组合阶段：
- 根据 `valid_i/op_i` 以及输入操作数，组合地产生 `result_o/cmp_true_o`。
- 若 `use_imm_i=1`，则第二操作数取 `imm_value_i`；否则取 `src2_value_i`。
- 若 `is_word_op_i=1`，则结果按 RV64 的 word 语义做 32 位截断后符号扩展。

周期 N 上升沿：
- 模块没有内部状态，不更新任何寄存器。

周期 N+1：
- 输出继续由新的输入组合决定。

### mul_execute_unit 周期级行为
周期 N 组合阶段：
- 当 `busy_o=0` 时，`req_ready_o=1`，表示本拍可接受一个新的乘法请求。
- `resp_valid_o` 反映上一拍时序逻辑是否已经把该请求完成。

周期 N 上升沿：
- 若 `req_valid_i && req_ready_o`，则锁存本次乘法请求的结果，并装载固定拍数计数器。
- 若模块处于 busy，则每拍递减一次剩余拍数。
- 当剩余拍数耗尽时，本拍上升沿拉起 `resp_valid_o` 对应的状态，并清除 busy。

周期 N+1：
- 对外看到本拍更新后的 `busy_o/resp_valid_o/result_o`。
- 若上一拍刚完成，则这一拍 `resp_valid_o=1`，随后单元回到可接收状态。

### div_execute_unit 周期级行为
周期 N 组合阶段：
- 当 `busy_o=0` 时，`req_ready_o=1`，表示本拍可接受一个新的除法/取余请求。
- `resp_valid_o` 反映上一拍时序逻辑是否已经把该请求完成。

周期 N 上升沿：
- 若 `req_valid_i && req_ready_o`，则锁存本次除法/取余请求的结果，并装载固定拍数计数器。
- 若模块处于 busy，则每拍递减一次剩余拍数。
- 当剩余拍数耗尽时，本拍上升沿拉起 `resp_valid_o` 对应的状态，并清除 busy。

周期 N+1：
- 对外看到本拍更新后的 `busy_o/resp_valid_o/result_o`。
- 若上一拍刚完成，则这一拍 `resp_valid_o=1`，随后单元回到可接收状态。

## 已知限制
- 当前多发射只是“并行 lane”，同拍 lane 之间按彼此无关处理。
- 当前不处理组内 RAW/WAW/WAR。
- 当前不处理同拍多个 lane 写同一个 `rd` 的精确定义。
- 当前不做 commit、旧物理寄存器释放、checkpoint、rollback、flush。
- 当前 `SYSTEM` 指令先按保守方式处理，不纳入 CSR 重命名细节。
- 当前整数/乘法/除法执行单元还没有接入 backend 主链路。
- 当前 `mul_execute_unit/div_execute_unit` 只是固定拍数骨架，不代表最终工业级实现。
- 当前不处理乘法高低位融合、除法商余融合，也不处理多请求并发执行。
- 当前不要求任何测试代码。
- 当前不要求任何仿真代码。
- 当前不做完整代码检测闭环，统一留到后续数据流更完整后再补。

## 后续扩展入口
- 组内依赖处理：优先在 `backend` 的 lane 间旁路逻辑或 `rename_map_table` 前级仲裁逻辑中接入。
- 提交与旧物理寄存器释放：在 `rename_map_table` 已输出的 `old_dst_preg` 基础上向 ROB / commit 级联。
- checkpoint / rollback：在 `rename_map_table` 上扩展 speculative map 管理。
- 分支恢复：在 rename 状态与 free list 状态上同时增加可恢复快照。
- 执行单元接入：在 rename 之后新增 issue / dispatch 输入定义，把 `int_execute_unit`、`mul_execute_unit`、`div_execute_unit` 串入真正的执行与回写链路。
- 乘法器扩展：在保持当前固定拍数接口不变的前提下，将内部实现替换为 DSP 优化、Booth 或华莱士树结构。
- 除法器扩展：在保持当前固定拍数接口不变的前提下，将内部实现替换为迭代式除法器，并视需要扩展可取消与融合能力。

## 文档分工建议
更适合放到 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md) 的内容：
- 开发流程约定。
- 当前阶段“不写测试/不写仿真/先搭功能”的工作边界。
- 每次修改 RTL 时的注释规范。
- 修改前后自检项。

应继续保留在本文件中的内容：
- 当前实现状态。
- 模块职责与边界。
- 周期级行为。
- 已知限制。
- 后续扩展入口。
- 代码索引。
