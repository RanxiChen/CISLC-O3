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
- `backend` 已经把前两拍拆成 `fetch/decode -> decoded uop queue -> rename/ROB alloc`。
- `backend` 在 `O3_SIM` 宏下已支持逐周期文本调试，按 cycle 把 lane0 的 `DECODE` 与 `RENAME` 两级组织成一个日志块输出；其中 `RENAME` 行可通过 DPI-C 调用 RV64I 反汇编 helper 显示汇编字符串。
- `backend` 已新增内部 `instruction_id` 体系：每条被 backend 接收的指令都会分配一个 64 位调试编号，高位表示“第几批被接收的 fetch group”，低位表示“该批内的 lane 编号”；当 `MACHINE_WIDTH=6` 时，低 3 位表示 lane id。
- 当前后端并行宽度命名统一使用 `machine width` / `MACHINE_WIDTH`，表示每周期并行处理的 lane 数。
- `decoder` 已经能提取 `rs1/rs2/rd`，并对 RV64I 的整数 R/I 算术指令给出 `rs1_read_en/rs2_read_en/rd_write_en/use_imm/imm_type/imm_raw/int_alu_op/is_int_uop`。
- `o3_pkg` 已新增统一的 `int_alu_op_t` 与 `imm_type_t`，用于对齐 `decoder` 和 `int_execute_unit`。
- `uop_queue` 已新增，作为 decode 后、rename 前的成组缓冲。
- `free_list` 已经支持“按本拍真实请求数”分配空闲物理寄存器。
- `rename_map_table` 已新增，负责维护架构寄存器到当前物理寄存器的映射。
- `rob` 已新增，负责在 rename 阶段按真实有效 uop 数量分配最小 ROB entry 编号，并把 frontend 带来的 `exception` 信息写入 ROB 表项。
- `physical_regfile` 已存在并可参数化配置，但本次没有继续扩展它的功能。
- `int_execute_unit` 已新增，提供独立的 RV64I 整数执行数据通路，但尚未接入 backend 主链路。
- `mul_execute_unit` 已新增，提供独立的 RV64M 乘法单元，当前采用“预计算结果 + 固定拍数返回”的简化骨架。
- `div_execute_unit` 已新增，提供独立的 RV64M 除法/取余单元，当前采用“预计算结果 + 固定拍数返回”的简化骨架。
- `backend_testharness` 已新增，提供一个后端专用的 Verilator 仿真入口；当前通过 DPI-C 伪造 4-lane 虚拟前端，从 `pc=0` 开始按组向 backend 提供固定的 RV64I 整形运算指令。

## 当前后端数据流
- 当前数据流是：`frontend -> fetch_entry buffer -> decoder -> decoded uop queue -> free_list + rename_map_table + rob`
- `backend` 在 `fetch_fire` 时为整组指令生成 `instruction_id`，随后该编号随 `decoded_uop -> rename_uop -> renamed_uop_q` 一路传递，供 `O3_SIM` 和后续调试使用。
- `decoder` 先产生最小 decoded uop 语义。
- `backend` 基于队头 uop 的 `rd_write_en && rd != 0` 生成 `alloc_req`。
- `backend` 基于队头 uop 的 `valid` 生成 `rob_req`，并把 uop 中的 `exception` 一起送入 ROB。
- `free_list` 按 lane 顺序给真正需要写回的指令分配新物理寄存器。
- `rename_map_table` 组合读出 `src1_preg/src2_preg/old_dst_preg`，并在 `rename_fire` 时更新 `rd` 的映射。
- `rob` 按 lane 顺序给真正有效的 uop 分配 ROB entry 编号，并在分配成功的同拍写入 exception 位。
- rename 完成后的 uop 当前先暂存在 backend 内部，还没有插入 issue / dispatch / execute 数据流。

## 模块说明
### backend
- 职责：承接 frontend 指令组，驱动 decode queue 与基础 rename 流程。
- 当前实现：fetch buffer + 解码 + decoded uop queue + 物理寄存器分配请求 + rename map 更新 + 最小 ROB 分配/存储。
- 调试能力：当定义 `O3_SIM` 时，backend 固定输出 lane0 的逐周期阶段视图；每个 cycle 固定打印 `DECODE` 与 `RENAME` 两行，若该阶段当前有有效指令，则 `DECODE` 显示 `instruction_id/pc/instruction`，`RENAME` 显示 `instruction_id/RV64I 汇编字符串`，并附带逻辑寄存器到物理寄存器的映射、旧/新目标物理寄存器和 ROB 编号。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期并行进入 rename 数据流的 lane 数。
- 当前未做：ROB、调度、执行、回写、提交、异常恢复。

### backend_testharness
- 职责：作为后端专用仿真顶层，实例化 `backend` 并用 DPI-C 虚拟前端驱动它。
- 当前实现：固定把 `MACHINE_WIDTH=4`，每次向 backend 提供 4 条彼此无关的 RV64I 整形运算指令。
- 当前未做：不接真实 frontend / icache / 内存，不做执行结果校验，不做更复杂的处理器行为建模。

### decoder
- 职责：从 32 位指令中提取寄存器字段、原始立即数编码和基础整数 ALU uop 语义。
- 当前覆盖：RV64I 中直接走整数 ALU 的 R/I 算术指令。
  - R-type：`ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND`
  - I-type：`ADDI/SLLI/SLTI/SLTIU/XORI/SRLI/SRAI/ORI/ANDI`
- 当前输出形态：输出 `decode_out_t`，包含 `rs1/rs2/rd`、`rs1_read_en/rs2_read_en/rd_write_en`、`use_imm`、`imm_type`、`imm_raw[11:0]`、`int_alu_op`、`is_int_uop`。
- 当前各类指令解码结果：
  - R-type 算术：读 `rs1/rs2`、写 `rd`，`use_imm=0`，`imm_type=IMM_TYPE_NONE`
  - I-type 算术：读 `rs1`、写 `rd`，`use_imm=1`，`imm_type=IMM_TYPE_I`，`imm_raw=instruction[31:20]`
  - 其它 opcode 或未识别的 `funct3/funct7`：保守输出全 0，不触发 rename 侧寄存器分配
- 当前未做：branch/load/store/jump/system 的完整控制语义、RV64I word 指令、更细的功能单元类型、CSR 详细行为、trap 语义。

### uop_queue
- 职责：作为 decode 后、rename 前的成组 uop 缓冲。
- 当前实现：按 `MACHINE_WIDTH` 整组入队/出队，支持对 decode 和 rename 两侧背压。
- 当前未做：不做 lane 级部分推进、不做 wakeup/select、不做 flush 恢复。

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

### rob
- 职责：在 rename 阶段为真实有效的 uop 分配 ROB entry 编号，并存储每个 entry 的 exception 位。
- 当前实现：按 lane 顺序给出连续编号；当前 ROB 表项只写入 `exception`，不实现提交和释放。
- 当前未做：完成/提交/恢复/回收，以及 `pc/dst_preg/完成状态` 等更完整的 ROB 元信息。

### physical_regfile
- 职责：提供物理寄存器存储体。
- 当前状态：模块已存在，本次未修改其行为规划。

### int_execute_unit
- 职责：提供 RV64I 整数算术、逻辑、移位、比较类运算的数据通路。
- 当前实现：单拍组合执行，当前和 `o3_pkg::int_alu_op_t` 对齐，支持 `ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND`，并支持 64 位与 32 位 word 结果语义。
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
  - 负责把 32 位指令变成 decoded uop 阶段所需的最小语义。
- `rtl/backend/uop_queue.sv`
  - 负责在 decode 与 rename 之间缓存一整组 decoded uop。
- `rtl/backend/free_list.sv`
  - 负责按真实请求数分配新物理寄存器。
- `rtl/backend/rename_map_table.sv`
  - 负责维护架构寄存器到物理寄存器的当前映射。
- `rtl/backend/rob.sv`
  - 负责按真实有效 uop 数量分配最小 ROB entry 编号，并存储 exception 位。
- `rtl/backend/physical_regfile.sv`
  - 物理寄存器文件实现，当前仍是独立能力模块，尚未接入完整后端数据流。
- `rtl/backend/int_execute_unit.sv`
  - 独立的整数执行单元，负责 RV64I 的基础整数计算。
- `rtl/backend/mul_execute_unit.sv`
  - 独立的乘法执行单元，负责 RV64M 的乘法类指令。
- `rtl/backend/div_execute_unit.sv`
  - 独立的除法执行单元，负责 RV64M 的除法/取余类指令。
- `rtl/common/o3_pkg.sv`
  - 定义 `fetch_entry_t`、`decode_in_t`、`decode_out_t`、`int_alu_op_t`、`imm_type_t` 等跨模块接口类型，以及 `decoded_uop/renamed_uop` 使用的 `instruction_id` 字段。
- `rtl/frontend/frontend.sv`
  - frontend 侧实现入口，和 backend 对接时需要一起看接口约束。
- `rtl/O3.sv`
  - O3 核心顶层连接入口。
- `rtl/Tile.sv`
  - 更上层系统封装入口。
- `tb/backend_testharness.sv`
  - 后端专用仿真顶层，实例化 `backend` 并通过 DPI-C 虚拟前端产生 4-lane fetch group。
- `sim/backend_testharness/`
  - 后端 Verilator 仿真目录，包含 `main.cpp`、固定指令流 DPI-C 实现和本地说明文档。

## 关键时序行为
### backend 周期级行为
周期 N 组合阶段：
- `fetch_entry_q` 中保存当前待 decode 的指令组。
- `fetch_instruction_id_q` 中保存当前 fetch buffer 这组指令对应的调试编号；编号的低位是 lane id，高位是被 backend 接收时的 group 序号。
- `decoder` 组合输出 `rs1/rs2/rd`、`rs1_read_en/rs2_read_en/rd_write_en`、`use_imm`、`imm_type`、`imm_raw`、`int_alu_op` 和 `is_int_uop`。
- 若 `uop_queue` 可接收，则当前 fetch 组在本拍以 `decoded_uop` 形式入队。
- `uop_queue` 队头保存当前待 rename 的一组 uop。
- `free_list` 组合输出本拍候选 `new_dst_preg`。
- `rename_map_table` 组合输出 `src1_preg/src2_preg/old_dst_preg`。
- `rob` 组合输出本拍候选 `rob_idx`。

周期 N 上升沿：
- 如果 `decode_fire=1`，则当前 fetch 组完成 decode 并进入 `uop_queue`。
- 如果 `rename_fire=1`，则当前 `uop_queue` 队头这组 uop 完成本版 rename。
- 如果 `fetch_fire=1`，则 frontend 新的一组指令写入 buffer，并按“group 序号 + lane id”生成新的 `instruction_id`。
- 如果同拍既 `decode_fire=1` 又 `fetch_fire=1`，表示旧的 fetch 组被消费完成 decode，同时新的一组顶上来。
- 当定义 `O3_SIM` 时，本拍会输出一个 lane0 日志块：
  - 第一行固定是 `DECODE`，显示当前 fetch buffer 中 lane0 这条指令的 `instruction_id/pc/instruction`；若该级为空则显示 `empty`。
  - 第二行固定是 `RENAME`，显示当前 decode queue 队头 lane0 这条指令的 `instruction_id` 与通过 DPI-C 反汇编得到的 RV64I 汇编字符串；若该级有效，还会显示 `rs1/rs2` 映射到的物理寄存器、`rd` 的 `old/new dst preg` 和 `rob idx`；若该级为空则显示 `empty`。
  - 日志块首尾各打印一条分割线，便于把同一个 cycle 的信息组织在一起。

周期 N+1：
- 看到更新后的 `uop_queue`、free list、rename map 和 rob 状态。
- 看到新 buffer 中的下一组指令，以及新的 rename 队头。
- 当定义 `O3_SIM` 时，日志中可看到 lane0 跟踪对象是否已切换到下一条被接收的指令。

### uop_queue 周期级行为
周期 N 组合阶段：
- 若队列非空，则队头这一组 `decoded_uop` 直接对 rename 级可见。
- 若队列未满，则 `enq_ready_o=1`，decode 级可在本拍把一整组 uop 压入队列。

周期 N 上升沿：
- 若 `enq_valid_i && enq_ready_o`，则一整组 decoded uop 写入队尾。
- 若 `deq_valid_o && deq_ready_i`，则当前队头这一组 uop 被 rename 级消费。
- 若入队和出队同拍发生，则队列深度不变，只移动头尾指针。

周期 N+1：
- 对外看到更新后的队头、队尾和空满状态。

### backend_testharness 周期级行为
周期 N 组合阶段：
- testharness 根据当前 `fetch_group_idx_q` 调用 DPI-C，组合地产生 4 个 lane 的 `fetch_entry`。
- 每个 lane 的 `pc` 按 `group_base + lane*4` 递增，其中 `group_base = fetch_group_idx_q * 16`。
- 若当前 group 仍在固定指令流范围内，则 `fetch_valid=1`；backend 同拍组合返回 `fetch_ready_o`。

周期 N 上升沿：
- 若 `fetch_valid && fetch_ready_o`，说明 backend 在本拍接收了这一整组 4 条指令。
- testharness 在该拍把 `fetch_group_idx_q` 与 `accepted_group_count_q` 同拍加 1。
- 同时调用 DPI-C 日志函数，记录本拍真正被 backend 接收的 4-lane 指令组。

周期 N+1：
- 若仍有剩余 group，则对外看到下一组固定 RV64I 指令。
- 若全部 group 都已经被 backend 接收，则 `done_o` 拉高，供 Verilator 主循环退出。

### rename_map_table 周期级行为
周期 N 组合阶段：
- 输入当前 lane 的 `rs1/rs2/rd`。
- 直接读取 map table，得到 `src1_preg/src2_preg/old_dst_preg`。
- 若该 lane 需要写 `rd`，backend 同拍还会拿到对应 `new_dst_preg`。

### 当前解码输出到 uop 的样子
- `decoder` 的直接输出是 `decode_out_t`，字段为：
  - `rs1/rs2/rd`
  - `rs1_read_en/rs2_read_en/rd_write_en`
  - `use_imm`
  - `imm_type`
  - `imm_raw`
  - `int_alu_op`
  - `is_int_uop`
- `backend` 会把 frontend 带来的原始信息与这些解码字段拼成 `decoded_uop_t` 后再入 `uop_queue`。
- 当前 `decoded_uop_t` 的内容是：
  - frontend 原样透传：`valid/instruction_id/pc/instruction/exception`
  - decoder 新产生：`rs1/rs2/rd`、`rs1_read_en/rs2_read_en/rd_write_en`、`use_imm`、`imm_type`、`imm_raw`、`int_alu_op`、`is_int_uop`
- 也就是说，当前 decode 级产出的不是“完整执行控制词”，而是“原始指令 + 最小 rename/整数 ALU 语义”的一组 uop。
- 当前 decode 不再输出 XLEN 展开的 `imm_value`；立即数的符号扩展计划留到后续寄存器读阶段完成。

周期 N 上升沿：
- 若 `rename_fire=1 && rd_write_en=1 && rd!=0`，则更新 `map_table[rd] = new_dst_preg`。

周期 N+1 组合阶段：
- 若再次读取同一个 `rd`，会看到更新后的物理寄存器编号。

### rob 周期级行为
周期 N 组合阶段：
- 统计本拍所有真实有效 uop 的 `alloc_req_i` 请求数。
- 若剩余 ROB 空位足够，则 `alloc_valid_o=1`。
- 对请求为 1 的 lane，按 lane 顺序给出连续的候选 ROB entry 编号。

周期 N 上升沿：
- 若 `alloc_valid_o=1 && alloc_ready_i=1`，则真正消耗本拍请求数个 ROB entry。
- `head_q` 和 `free_count_q` 在上升沿更新。
- 同拍把 `alloc_exception_i` 写入新分配到的 ROB entry。

周期 N+1 组合阶段：
- 对外看到新的 ROB 队头位置、下一批候选 entry 编号，以及新写入的 exception 表项。

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
- 当前不做 commit、ROB entry 释放、旧物理寄存器释放、checkpoint、rollback、flush。
- 当前 ROB 只存 exception 位，还没有存 pc、目标寄存器、完成状态等完整表项信息。
- 当前 `SYSTEM` 指令先按保守方式处理，不纳入 CSR 重命名细节。
- 当前整数/乘法/除法执行单元还没有接入 backend 主链路。
- 当前 renamed uop 只是先暂存在 backend 内部，还没有接真正的 issue queue。
- 当前 `mul_execute_unit/div_execute_unit` 只是固定拍数骨架，不代表最终工业级实现。
- 当前不处理乘法高低位融合、除法商余融合，也不处理多请求并发执行。
- 当前不要求任何测试代码。
- 当前虽然已经有专用仿真入口，但仍未建立完整验证闭环；现有 `backend_testharness` 只用于驱动后端最小 rename 数据流。
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
