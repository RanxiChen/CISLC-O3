# CISLC_O3 Long-Term Notes

## 文档定位
- 本文件保留为“当前实现状态 + 代码索引 + 时序入口”文档。
- 面向后续 agent / 协作者的执行规则、注释规范、阶段边界，已拆分到 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md)。
- 前端当前实现状态、代码索引和时序入口，已拆分到 [`doc/CISLC_O3_frontend.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3_frontend.md)。
- 使用顺序建议：
  1. 先按任务方向选择主文档：后端任务读本文件，前端任务读 [`doc/CISLC_O3_frontend.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3_frontend.md)。
  2. 再读相关 RTL。
  3. 最后按 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md) 中的规则落修改。

## 当前实现状态
- `backend` 已经具备一个最小 fetch-entry buffer，可以承接 frontend 输入。
- `backend` 已经把整数最小主链路拆成 `fetch/decode -> decoded uop queue -> rename/ROB alloc -> issue queue wakeup/select -> issue reg -> regread -> execute -> execute result reg -> writeback/ROB complete -> 3-wide retire/free-list release`。
- `backend` 在 `O3_SIM` 宏下已支持逐周期文本调试，按 cycle 把 `DECODE/RENAME/WAKEUP/ISSUE/REGREAD/EXECUTE/WRITEBACK/RETIRE` 各级组织成一个日志块输出。
- `backend` 已新增 `retired_inst_count_q` 计数器，从 reset 开始按每拍真实退休条数累加，表示系统累计已退休的指令数。
- `backend` 已新增内部 `instruction_id` 体系：每条被 backend 接收的指令都会分配一个 64 位调试编号，高位表示“第几批被接收的 fetch group”，低位表示“该批内的 lane 编号”；当 `MACHINE_WIDTH=6` 时，低 3 位表示 lane id。
- 当前后端并行宽度命名统一使用 `machine width` / `MACHINE_WIDTH`，表示每周期并行处理的 lane 数。
- `decoder` 已经能提取 `rs1/rs2/rd`，并对 RV64I 的整数 R/I 算术指令给出 `rs1_read_en/rs2_read_en/rd_write_en/use_imm/imm_type/imm_raw/int_alu_op/is_int_uop`。
- `o3_pkg` 已新增统一的 `int_alu_op_t` 与 `imm_type_t`，用于对齐 `decoder` 和 `int_execute_unit`。
- `uop_queue` 已新增，作为 decode 后、rename 前的成组缓冲。
- `free_list` 已经支持“按本拍真实请求数”分配空闲物理寄存器。
- `rename_map_table` 已新增，负责维护架构寄存器到当前物理寄存器的映射。
- `backend` 已新增最小 `preg_ready` 表，用于跟踪每个物理寄存器是否已经持有可读值；当前写回结果在下一拍才对 issue queue 的 wakeup 可见。
- `rob` 已新增，负责在 rename 阶段按真实有效 uop 数量分配最小 ROB entry 编号，存储 `instruction_id/exception/old_dst_preg/complete` 元信息，并支持从队头连续退休最多 3 条。
- `issue_queue` 已新增，负责把 rename 完成后的整数 uop 按 lane 顺序压入单一整数 issue 队列，并基于 `preg_ready` 做真实 ready/wakeup、按年龄选择和压缩补位。
- `physical_regfile` 已接入 backend 主链路，当前支持整数 regread 和多路整数写回；其中 `p0` 固定为零物理寄存器，读恒为 0、写忽略。
- `int_execute_unit` 已接入 backend 主链路，当前用于整数 R/I 算术指令执行。
- `mul_execute_unit` 已新增，提供独立的 RV64M 乘法单元，当前采用“预计算结果 + 固定拍数返回”的简化骨架。
- `div_execute_unit` 已新增，提供独立的 RV64M 除法/取余单元，当前采用“预计算结果 + 固定拍数返回”的简化骨架。
- `backend_testharness` 已更新为当前后端主链路对应的 Verilator 仿真入口；当前通过 DPI-C 伪造 6-lane 虚拟前端，从 `pc=0` 开始按组向 backend 提供固定的 RV64I 整形运算指令，并在最后一组 fetch 被接收后继续保留固定排空窗口，便于观察 `decode/rename/issue/regread/execute` 多拍日志。

## 当前后端数据流
- 当前数据流是：`frontend -> fetch_entry buffer -> decoder -> decoded uop queue -> free_list + rename_map_table + rob -> integer issue queue -> ALU issue reg -> regread -> execute -> execute result reg -> physical regfile writeback + ROB complete -> ROB retire + free_list release`
- `backend` 在 `fetch_fire` 时为整组指令生成 `instruction_id`，随后该编号随 `decoded_uop -> rename_uop -> issue_queue_entry -> ALU 流水寄存器` 一路传递，供 `O3_SIM` 和后续调试使用。
- `decoder` 先产生最小 decoded uop 语义。
- `backend` 基于队头 uop 的 `rd_write_en && rd != 0` 生成 `alloc_req`。
- `backend` 基于队头 uop 的 `valid` 生成 `rob_req`，并把 uop 中的 `exception` 一起送入 ROB。
- `backend` 固定采用 `x0 -> p0` 的零寄存器语义；`rd==0` 的指令不会申请新物理寄存器，也不会形成真实目的写回。
- `free_list` 按 lane 顺序给真正需要写回的指令分配新物理寄存器。
- `rename_map_table` 组合读出 `src1_preg/src2_preg/old_dst_preg`，并在 `rename_fire` 时更新 `rd` 的映射。
- `rob` 按 lane 顺序给真正有效的 uop 分配 ROB entry 编号，并在分配成功的同拍写入 `exception/old_dst_preg`，在写回时更新 `complete` 位。
- rename 完成后的整数 uop 当前会直接进入一个单一 `issue_queue`。
- `issue_queue` 当前根据 `preg_ready` 判断源操作数是否真的 ready；本拍写回结果要到下一拍才会体现在 wakeup 上。
- 被选中的整数 uop 会进入 3 路 ALU 流水寄存器，随后完成 regread、立即数扩展和 execute。
- `alu_result_q` 中保存的执行结果会在下一拍作为统一整数 writeback 源，驱动 physical regfile 写回和 ROB complete。
- `rob` 当前会从队头连续退休最多 3 条已经 complete 且无异常的指令，并把 `old_dst_preg` 返还给 free list。
- 当前还没有异常恢复、store 提交和更复杂的 commit/flush 链路。

## 模块说明
### backend
- 职责：承接 frontend 指令组，驱动 decode queue 与基础 rename 流程。
- 当前实现：fetch buffer + 解码 + decoded uop queue + 物理寄存器分配请求 + rename map 更新 + 最小 ROB 分配/存储/complete/retire + preg ready 跟踪 + rename 后整数 uop 入 issue queue + issue/select + regread + execute + result reg + writeback + free-list release。
- 调试能力：当定义 `O3_SIM` 时，backend 固定按周期块输出 `DECODE/RENAME/WAKEUP/ISSUE/REGREAD/EXECUTE/WRITEBACK/RETIRE/RETIRE_COUNT`；其中 `RENAME` 行可通过 DPI-C 调用 RV64I 反汇编 helper 显示汇编字符串。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期并行进入 rename 数据流的 lane 数。
- 当前未做：真实写回广播、写回 physical regfile、提交、异常恢复，以及非整数 issue/dispatch 数据流。

### backend_testharness
- 职责：作为后端专用仿真顶层，实例化 `backend` 并用 DPI-C 虚拟前端驱动它。
- 当前实现：
  - 固定把 `MACHINE_WIDTH=6`、`NUM_INT_ALUS=3`，对齐当前 backend 的主链路参数。
  - 每次向 backend 提供 6 条彼此无关、主要只读 `x0` 的 RV64I 整形运算指令，避免在尚未接入真实写回网络时制造额外相关性。
  - 所有 fetch group 被 backend 接收后，再额外等待固定 `DRAIN_CYCLES=16` 拍，给 `decode/rename/issue/regread/execute` 多拍日志留出排空时间。
- 当前未做：
  - 不接真实 frontend / icache / 内存，不做执行结果校验，不做更复杂的处理器行为建模。
  - done 条件还不是“backend 内部真实全空”，只是“最后一组 fetch 被接收后再等待固定拍数”的最小排空策略。

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
  - `x0~x31 -> p0~p31`
  - `p0` 固定作为零物理寄存器，不从 free list 重新分配
  - 空闲池从 `p32` 开始
- 当前实现补充：支持在 retire 阶段把最多 3 个 `old_dst_preg` 追加回 free list 队尾；这些释放结果从下一拍起参与分配。
- 当前未做：checkpoint、rollback、flush 恢复。

### rename_map_table
- 职责：维护架构寄存器到当前物理寄存器的映射。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期并行读取/更新映射的 lane 数。
- reset 约定：
  - `x0~x31 -> p0~p31`
  - 其中 `x0` 固定视为 `p0`
- 当前未做：commit map、checkpoint map、lane 间依赖和覆盖处理。

### rob
- 职责：在 rename 阶段为真实有效的 uop 分配 ROB entry 编号，并存储最小提交前元信息。
- 当前实现：按 lane 顺序给出连续编号；当前 ROB 表项写入 `instruction_id`、`exception`、`old_dst_preg`，并在整数写回时按 `rob_idx` 标记 `complete`；同时从队头连续退休最多 3 条已经 complete 且无异常的指令。
- 当前未做：store/branch/异常恢复约束下的完整 commit、flush/rollback，以及 `pc/结果值/提交状态` 等更完整的 ROB 元信息。

### issue_queue
- 职责：作为 rename 后、整数执行前的单一 issue 队列骨架。
- 当前实现：
  - 每个表项保存 1 条 rename 完成后的整数 uop。
  - 支持一拍从多个 lane 原子入队到同一个队列。
  - 同拍多个 lane 入队时，按 `lane0 -> lane1 -> ...` 的顺序压紧写入，保持组内隐式程序顺序。
  - 当前对“上一拍已经在队列中的有效表项”按 `preg_ready` 做真实唤醒。
  - 当前按队列从前往后扫描，把最靠前的 ready 表项优先分配给编号更小的 ALU。
  - 被发射表项会在同拍从队列删除，后续表项向前补位，始终保持压缩式队列。
- 当前表项字段：
  - `valid`
  - `instruction_id`
  - `src1_preg/src2_preg`
  - `src1_valid/src2_valid`
  - `src1_ready/src2_ready`
  - `rob_idx`
  - `dst_preg/dst_write_en`
  - `imm_raw/imm_valid/imm_type`
  - `int_alu_op`
- 当前 ready 位策略：
  - `backend` 当前已经维护最小物理寄存器 ready table。
  - rename 入队时：不需要读取的源操作数视为 ready；立即数形式的第二操作数视为 ready；`x0/p0` 源固定视为 ready；真正依赖寄存器结果的源操作数根据当前 `preg_ready` 初始化。
  - 进入 queue 以后，每拍只根据 `preg_ready` 更新旧表项；本拍写回结果下一拍才可见，不做同拍旁路。
- 当前未做：同拍广播旁路、flush/rollback 恢复、跨功能单元的更复杂选择仲裁。

### physical_regfile
- 职责：提供物理寄存器存储体。
- 当前实现：已接入 backend 的 regread 和 writeback 阶段，支持多读端口、多写端口和同拍写后读旁路；当前 reset 后所有物理寄存器清零。
- 当前特殊约定：`p0` 固定为零物理寄存器，读恒为 0，写请求被忽略。
- 当前未做：更复杂的物理实现优化与跨功能单元写回仲裁。

### int_execute_unit
- 职责：提供 RV64I 整数算术、逻辑、移位、比较类运算的数据通路。
- 当前实现：单拍组合执行，当前和 `o3_pkg::int_alu_op_t` 对齐，支持 `ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND`，并支持 64 位与 32 位 word 结果语义。
- 当前未做：不接分支/访存/回写控制。

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
- `rtl/backend/issue_queue.sv`
  - 负责把 rename 完成后的整数 uop 按 lane 顺序压入单一 issue 队列，并在队列内完成默认唤醒、选择和压缩补位。
- `rtl/backend/physical_regfile.sv`
  - 物理寄存器文件实现，当前已接入 backend 的 regread 阶段。
- `rtl/backend/int_execute_unit.sv`
  - 独立的整数执行单元，当前已接入 backend 的整数执行阶段。
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
  - 后端专用仿真顶层，实例化 `backend` 并通过 DPI-C 虚拟前端产生 6-lane fetch group；同时在最后一个 fetch group 被接收后再等待固定排空窗口。
- `sim/backend_testharness/`
  - 后端 Verilator 仿真目录，包含 `main.cpp`、固定指令流 DPI-C 实现、本地说明文档，以及当前 backend 主链路所需的 Verilator 构建入口。

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
- `backend` 组合把 `rename_uop_head` 中 `is_int_uop=1` 的 lane 转成 `issue_queue_entry`，并按 lane 顺序统计本拍整数 issue 入队需求。
- `backend` 当前对 `rd!=0` 的真实目的写生成 `alloc_req`，对 `x0/p0` 源直接视为零寄存器 ready。
- 若 `issue_queue` 剩余空间足够，则 `issueq_enq_ready=1`，rename 才允许和 free list / rob 一起握手成功。
- `issue_queue` 对旧表项组合地产生基于 `preg_ready` 的 wakeup 后视图，并按队列顺序把最靠前的 ready 表项分配给编号更小的 ALU issue 端口。
- `alu_issue_q` 当前持有的物理寄存器编号直接驱动 `physical_regfile` 读端口。
- `alu_regread_q` 当前持有的真实操作数值直接驱动 `int_execute_unit`。
- `alu_result_q` 当前持有的上一拍执行结果会在本拍组合地形成 writeback 请求，驱动 physical regfile 写口和 ROB complete 端口。
- `rob` 当前会从队头开始连续检查最多 3 项，只退休队头连续 `complete=1 && exception=0` 的前缀。

周期 N 上升沿：
- 如果 `decode_fire=1`，则当前 fetch 组完成 decode 并进入 `uop_queue`。
- 如果 `rename_fire=1`，则当前 `uop_queue` 队头这组 uop 完成本版 rename；其中所有整数 uop 会按 lane 从小到大连续写入 `issue_queue`，而且所有 `rd!=0` 的新目的 preg 会被清成 not-ready。
- `issue_queue` 会把上一拍已经在队列中的未 ready 表项按 `preg_ready` 结果更新，并删除本拍已经被接受发射的表项。
- 本拍被选中的整数 uop 会进入 `alu_issue_q`。
- 上一拍 `alu_issue_q` 中的 uop 会完成 regread 和立即数扩展，并进入 `alu_regread_q`。
- 上一拍 `alu_regread_q` 中的 uop 会经过 `int_execute_unit` 计算，并进入 `alu_result_q`。
- 当前 `alu_result_q` 中所有 `valid` 的整数结果会在本拍写回时把对应 ROB 项标记为 complete；其中 `dst_write_en=1` 的结果还会写回 PRF，并把目标 preg 置为 ready。
- 当前从 ROB 队头退休的指令会在本拍把 `old_dst_preg` 返还给 free list；这些被释放的寄存器会从下一拍起重新出现在 rename 分配候选中。
- `backend` 会在本拍把真实退休条数累加到 `retired_inst_count_q`。
- 如果 `fetch_fire=1`，则 frontend 新的一组指令写入 buffer，并按“group 序号 + lane id”生成新的 `instruction_id`。
- 如果同拍既 `decode_fire=1` 又 `fetch_fire=1`，表示旧的 fetch 组被消费完成 decode，同时新的一组顶上来。
- 当定义 `O3_SIM` 时，本拍会输出一个 lane0 日志块：
  - `DECODE` 行显示当前 fetch buffer 中 lane0 指令。
  - `RENAME` 行显示当前 rename 队头 lane0 指令及其重命名结果。
  - `WAKEUP` 行显示本拍因 `preg_ready` 变化而被唤醒的 queue 内指令 id。
  - `ISSUE` 多行显示哪些 `instruction_id` 被送进 `alu0/alu1/alu2`。
  - `REGREAD` 多行显示各 ALU 当前读到的物理寄存器值，或立即数原始编码扩展得到的 64 位值。
  - `EXECUTE` 多行显示各 ALU 当前处理的 `instruction_id`、操作数值、运算类型和结果。
  - `WRITEBACK` 多行显示各 ALU 当前从 `alu_result_q` 发起的写回信息。
  - `RETIRE` 行显示本拍从 ROB 队头按序退休的指令 id、rob idx 和被释放的 `old_dst_preg`。
  - `RETIRE_COUNT` 行显示本拍退休条数，以及从 reset 开始累计的总退休条数。
  - 日志块首尾各打印一条分割线，便于把同一个 cycle 的信息组织在一起。

周期 N+1：
- 看到更新后的 `uop_queue`、free list、rename map、rob、`issue_queue` 和 3 级 ALU 流水寄存器状态。
- 看到刚刚被写回的目标物理寄存器在 `preg_ready` 中变为 ready。
- 看到刚刚退休并释放的旧物理寄存器重新回到 free list 可见范围。
- 看到新 buffer 中的下一组指令，以及新的 rename 队头。
- 当定义 `O3_SIM` 时，日志中可看到不同 `instruction_id` 在各级继续向后流动。

### backend_testharness 周期级行为
周期 N 组合阶段：
- `backend_testharness` 根据 `fetch_group_idx_q` 调用 DPI-C，组合生成 1 组 `MACHINE_WIDTH=6` 的 `fetch_entry`。
- 若该组在硬编码指令流范围内且所有 lane 都有效，则 `fetch_valid=1`。
- `backend` 同拍组合给出 `fetch_ready_o`。
- 若所有 fetch group 都已被 backend 接收，则 testharness 组合地根据 `drain_counter_q` 判断 `done_o` 是否拉高。

周期 N 上升沿：
- 若 `fetch_valid && fetch_ready`，当前 6 条指令被 backend 接收，`fetch_group_idx_q` 与 `accepted_group_count_q` 同拍递增。
- 同一个 `fetch_fire` 上升沿，testharness 会按 lane 逐条调用 DPI-C 日志函数，打印本拍被接收的 group 内容。
- 若已经没有新的 fetch group 可送，则 `drain_counter_q` 每拍递增，直到达到固定排空窗口上限。

周期 N+1：
- 若还有剩余 group，则对外看到下一组 6-lane 固定指令。
- 若所有 group 都已送完，则不再产生新的 fetch，只保留固定排空窗口，等待后端内部多拍流水和日志继续向后推进。

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

### issue_queue 周期级行为
周期 N 组合阶段：
- `backend` 把当前 rename 队头里属于整数计算的 lane 组装成 `issue_queue_entry`。
- `issue_queue` 对上一拍已经在队列中的未 ready 表项按 `preg_ready` 检查是否可以唤醒。
- `issue_queue` 从前往后扫描 wakeup 后的队列，把最靠前的 ready 表项优先分配给编号更小的 ALU issue 端口。
- `issue_queue` 根据“本拍将会被发射删除的条数”和“本拍想入队的整数 uop 数”共同判断 `enq_ready_o`；若空间不足，则整批等待，不做部分入队。

周期 N 上升沿：
- 若本拍有被接受发射的表项，则这些表项从队列中删除，后续表项向前补位。
- 若 `enq_valid_i && enq_ready_o`，则本拍所有有效整数 uop 按 `lane0 -> lane1 -> ...` 顺序连续追加到压缩后队尾。
- 若同拍既有发射又有入队，则最终看到的是“先删除发射表项、再在队尾追加新表项”的压缩结果。

周期 N+1：
- 对外看到更新后的压缩式队列内容，以及下一拍可继续参与 wakeup/select 的整数 issue entry。

### integer ALU 流水寄存器周期级行为
周期 N 组合阶段：
- `alu_issue_q` 直接驱动 `physical_regfile` 读端口地址。
- `physical_regfile` 组合读出 `src1/src2` 值。
- `backend` 在 regread 阶段把 `imm_raw/imm_type` 扩展成 64 位立即数，并根据 `imm_valid/src2_valid` 生成真正的 `src2_value`。
- `alu_regread_q` 直接驱动 `int_execute_unit` 的输入。
- `int_execute_unit` 组合地产生执行结果。

周期 N 上升沿：
- 本拍新选择出来的 issue uop 进入 `alu_issue_q`。
- 上一拍 `alu_issue_q` 中的 uop 进入 `alu_regread_q`。
- 上一拍 `alu_regread_q` 中的 uop 执行结果进入 `alu_result_q`。

周期 N+1：
- 同一条整数指令会在日志中向后移动到下一拍的下一级寄存器。

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
- `tail_q`、`head_q` 和 `free_count_q` 在上升沿更新。
- 同拍把 `alloc_exception_i` 和 `alloc_old_dst_preg_i` 写入新分配到的 ROB entry，并清掉该 entry 的 `complete` 位。
- 若本拍有执行结果写回，则按 `complete_idx_i` 把对应 ROB entry 的 `complete` 位置 1。
- 若本拍有退休，则把对应队头 entry 的 `valid` 清 0，并把 `head_q` 前移退休条数。

周期 N+1 组合阶段：
- 对外看到新的 ROB 队头位置、下一批候选 entry 编号，以及新写入的最小 ROB 元信息。

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
