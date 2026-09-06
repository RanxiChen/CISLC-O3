# CISLC_O3 Long-Term Notes

## 文档定位
- 本文件保留为“当前实现状态 + 代码索引 + 时序入口”文档。
- 面向后续 agent / 协作者的执行规则、注释规范、阶段边界，已拆分到 [`agent.md`](/home/chen/work/CISLC-O3/agent.md)。
- 前端当前实现状态、代码索引和时序入口，已拆分到 [`doc/CISLC_O3_frontend.md`](/home/chen/work/CISLC-O3/doc/CISLC_O3_frontend.md)。
- 使用顺序建议：
  1. 先按任务方向选择主文档：后端任务读本文件，前端任务读 [`doc/CISLC_O3_frontend.md`](/home/chen/work/CISLC-O3/doc/CISLC_O3_frontend.md)。
  2. 再读相关 RTL。
  3. 最后按 [`agent.md`](/home/chen/work/CISLC-O3/agent.md) 中的规则落修改。

## 当前实现状态
- `backend` 已经具备一组 Decode Input Register，可以承接 frontend 输入；公共 `fetch_entry_t` 包含 lane 级 `valid/pc/raw_instruction/instruction/inst_len/is_rvc` 和统一的 `exception_valid/exception_cause/exception_tval`。
- 当前重构数据流已经推进到 `fetch/decode -> Decode Queue -> variable-prefix Rename -> Rename/Dispatch Queue -> variable-prefix Dispatch -> Integer/Memory/Branch IQ`；三类IQ已经分别闭环到ALU、LSU和单发射BRU。
- `backend` 在 `O3_SIM` 宏下已支持逐周期文本调试，按 cycle 把 `DECODE/RENAME/WAKEUP/ISSUE/REGREAD/EXECUTE/WRITEBACK/RETIRE` 各级组织成一个日志块输出。
- `backend` 在 `O3_SIM_SINGLE_INST_TRACE` 宏下会关闭普通逐周期文本块，只追踪第一条进入 backend 的有效指令，从 `ACCEPT` 打到 `RETIRE`，并通过 `single_inst_retired_o` 给 core 单指令仿真提供结束条件。
- `backend` / `o3_core` 在 `ENABLE_RETIRE_INFO` 宏下透出 `retire_info_o[BACKEND_NUM_INT_ALUS]`，每个 valid entry 描述一条已经从 ROB head 提交的指令；当前字段覆盖 `rob_idx/instruction_id/pc/instruction/rd/rd_write_en/rd_wdata`，用于仿真 monitor 和 C++ 断言。
- `backend` 已新增 `retired_inst_count_q` 计数器，从 reset 开始按每拍真实退休条数累加，表示系统累计已退休的指令数。
- `backend` 已新增内部 `instruction_id` 体系：每条被 backend 接收的指令都会分配一个 64 位调试编号，高位表示“第几批被接收的 fetch group”，低位表示“该批内的 lane 编号”；当前 core 集成默认 `MACHINE_WIDTH=4`，低 2 位表示 lane id。
- 当前后端并行宽度命名统一使用 `machine width` / `MACHINE_WIDTH`，表示每周期并行处理的 lane 数。
- 当前 core/backend 固定配置集中在 `rtl/common/o3_pkg.sv` 的 `CORE_FETCH_WIDTH` 与 `BACKEND_*` 参数中；当前版本 `CORE_FETCH_WIDTH=4`，`BACKEND_MACHINE_WIDTH=4`。
- 物理寄存器默认配置为96项，编号宽度7位。复位时`p0~p31`承担初始架构映射、`p32~p95`空闲；后续被提交新映射覆盖的`p1~p31`也可进入Free List，只有`p0`永久保留。
- `decoder` 已经能提取 `rs1/rs2/rd`，并覆盖RV64I的`LUI/AUIPC`、整数R/I算术、九条word算术、Load/Store、六种条件分支、`JAL/JALR`及`FENCE`；`src1_is_pc`让AUIPC选择PC，`is_word_op`控制低32位结果符号扩展。
- `o3_pkg` 已新增统一的 `int_alu_op_t` 与 `imm_type_t`，用于对齐 `decoder` 和 `int_execute_unit`。
- `uop_queue` 已重构为默认 16-entry 的单-uop 队列：4-wide 配置下采用 4 bank，压紧写入，并从队头展示最多 4 条最老 uop；原始 fetch/decode bundle 边界不进入队列语义。
- `rename_stage` 已按lane0最老的顺序联合检查ROB、Free List、LQ、SQ、branch checkpoint和Rename/Dispatch Queue容量，每拍接受0～4条连续前缀；任一指令资源不足时停止该指令及所有年轻lane。
- `free_list` 已改为96位物理寄存器空闲位图，并为每个未决分支维护allocation mask；误预测时一拍返还错误路径分配的preg。
- `rename_map_table` 同时维护speculative map、committed map和每分支完整speculative map快照。
- `rename_map_table` 已支持同一 packed rename bundle 内的顺序映射旁路：年轻 lane 的 `rs1/rs2` 会看到最近的年老 lane 刚分配的目的 preg，同批 WAW 的 `old_dst_preg` 也会指向最近的旧版本。
- 后端已新增4槽branch checkpoint file、8-entry Load Queue、8-entry Store Queue和16-entry Rename/Dispatch Queue。
- 单发射BRU已经产生内部`branch_resolution`广播；正确解析释放checkpoint并清branch bit，误预测恢复Map/Free List/ROB/LQ/SQ、清空Decode侧并向Frontend输出redirect。
- `backend` 保留最小 `preg_ready` 表；三个IQ依据该表维护源ready，只有真正获得PRF写口的ALU/Load结果才写表并广播，下一拍参与Select。
- 同批依赖的年轻 uop 在 IQ 入队时会强制把相应源标为 not-ready，不会误读 Free List 中该 preg 分配前的 ready 状态。
- `rob`在Rename阶段按真实uop数分配entry，保存`instruction_id/exception/new/old preg/complete`等元信息，并支持从队头连续退休最多4条。
- `dispatch_stage`按队头年龄计算0～4条连续前缀，并在前缀内部把uop并行分流到16-entry Integer IQ、8-entry Memory IQ和4-entry Branch IQ。
- `backend_issue_queue`是三个IQ共用的存储与调度骨架：压紧入队、容量反压、源ready更新、最老ready候选和branch-mask恢复均已实现。
- Integer、Memory与Branch IQ按ROB年龄共同竞争逻辑8个PRF读口，一条uop所需读口原子授权；Branch一次最多发射一条。
- 4个ALU结果、1个Load结果与JAL/JALR链接值按ROB年龄竞争4个PRF写口；未获grant的结果留在各自结果寄存器并逐级反压，grant周期原子执行PRF写入、wakeup和ROB complete。
- LSU已经连接AGU、LQ/SQ依赖查询、单个更老Store完整覆盖转发、256KiB DTCM和范围外memory口；committed Store优先使用统一请求口。
- Store在AGU把地址/数据/mask写入SQ后complete，ROB顺序退休只把SQ entry变为committed，DTCM或外部memory真正接受后才释放SQ容量。
- Memory IQ在当前无replay、单请求LSU下只发射物理队头，避免年轻Load占住执行槽并等待尚未执行的老Store；Integer和Branch IQ仍按最老ready项选择。
- Issue Queue的`use_imm`只选择执行单元输入，不再绕过真实`rs2`依赖；Branch可同时等待B型立即数和Load产生的`rs2`。
- RV64I `OP-IMM`计算指令与R型共用该整数闭环：IQ只等待`rs1`，RegRead分别保存`src1`和符号扩展立即数，ALU由`use_imm`显式选择第二操作数。
- `mul_execute_unit` 已新增，提供独立的 RV64M 乘法单元，当前采用“预计算结果 + 固定拍数返回”的简化骨架。
- `div_execute_unit` 已新增，提供独立的 RV64M 除法/取余单元，当前采用“预计算结果 + 固定拍数返回”的简化骨架。
- `rtl/core/o3_core.sv` 已经把真实 frontend 和真实 backend 接通；frontend 内部已有 fetch buffer，core 层不再额外实例化 fetch buffer。
- `sim/o3` 是当前唯一的完整core Verilator入口：C++驱动真实Frontend/Backend和ICache refill，仿真顶层展开`retire_info_o`并输出有序JSONL Tandem记录；当前不运行Spike，也不输出微架构事件。

## 当前后端数据流
- 当前数据流是：`frontend -> Decode Input Register -> decoder -> 16-entry Decode Queue -> prefix Rename planner -> Map + Free List + ROB + checkpoint + LQ/SQ原子分配 -> 16-entry Rename/Dispatch Queue -> prefix Dispatch planner -> Integer/Memory/Branch IQ`。
- `backend` 在 `fetch_fire` 时为整组指令生成 `instruction_id`，随后该编号随 `decoded_uop -> rename_uop -> issue_queue_entry -> ALU 流水寄存器` 一路传递，供 `O3_SIM` 和后续调试使用。
- `fetch_entry_t.valid` 决定该 lane 是否形成真实 decoded uop；前端异常元数据原样进入 decoded uop，Decoder 未识别的编码形成 illegal-instruction 异常。
- `decoder` 并行产生最多 `MACHINE_WIDTH` 条最小 decoded uop 语义；异常 uop 保留顺序和异常元数据，但关闭寄存器与整数执行副作用。
- `backend` 基于队头 uop 的 `rd_write_en && rd != 0` 生成 `alloc_req`。
- `backend` 基于队头 uop 的 `valid` 生成 `rob_req`，并把 uop 中的 `exception` 一起送入 ROB。
- `backend` 固定采用 `x0 -> p0` 的零寄存器语义；`rd==0` 的指令不会申请新物理寄存器，也不会形成真实目的写回。
- `free_list` 按 lane 顺序给真正需要写回的指令分配新物理寄存器。
- `rename_map_table` 组合读出 `src1_preg/src2_preg/old_dst_preg`，并在 `rename_fire` 时更新 `rd` 的映射。
- `rob` 按 lane 顺序给真正有效的 uop 分配 ROB entry 编号，并在分配成功的同拍写入 `exception/old_dst_preg`，在写回时更新 `complete` 位。
- 在 `ENABLE_RETIRE_INFO` 下，ROB allocate 同拍还会记录 `pc/instruction/rd/rd_write_en`；ALU writeback complete 同拍按 `rob_idx` 记录 `rd_wdata`；retire 组合口从 ROB head 输出对应 `retire_info_o`。
- rename结果先进入独立Rename/Dispatch Queue；Dispatch根据三个IQ空位接受最大队头连续前缀，并在该前缀内部按类型分流。
- 三个IQ根据`preg_ready`和四路Writeback广播维护源状态；Integer/Memory/Branch ready候选共同进入共享8读口仲裁。
- `alu_result_q`、`load_result_q`与Branch链接结果是可保持的写回源；共享仲裁每拍选择最多4个最老结果写PRF并complete ROB。
- Load经AGU后检查更老SQ entry：未知或部分重叠时等待，完整覆盖时从最年轻匹配Store转发，否则按地址请求DTCM或core外部memory；LQ generation tag丢弃flush或复用后的迟到响应。
- Store退休时不会释放SQ；SQ队头最老committed Store完成DTCM或外部memory请求握手后才释放。
- `rob`从队头连续退休最多4条已经complete且无异常的指令，并提交映射、返还`old_dst_preg`。
- Branch IQ经共享读口进入Branch RegRead和BRU；Branch Result下一周期广播resolution，redirect不等待JAL/JALR链接值写回。Commit按`ftq_last`产生FTQ释放计数并已在core连接Frontend。

## 当前核心集成状态
- `rtl/core/o3_core.sv` 是当前真实 frontend + backend 的 core 级连接入口。
- core 顶层透出 `reset_pc_i`、ICache refill、TCM初始化、LSU外部memory request/response、backend `done_o` 和 `retired_inst_count_o`；在 `ENABLE_RETIRE_INFO` 下额外透出 `retire_info_o`。
- frontend 输出 4-lane `fetch_entry_t` group；backend 当前通过 `BACKEND_MACHINE_WIDTH=4` 对齐该宽度。
- frontend 端口是 unpacked array，backend 端口是 packed aggregate，core 内部用逐 lane bridge 做形状转换；该 bridge 不改变 lane 顺序、不压缩 bubble、不做协议转换。
- `fetch_valid_o/fetch_ready_i` 与 `fetch_valid_i/fetch_ready_o` 是 group 级 ready/valid；后端不能单独 ready 某个 lane。
- ICache范围外refill和LSU范围外请求仍需要testbench或后续存储系统驱动；当前整核仿真由一份共享C++稀疏内存响应。
- FTQ已经由Backend Commit按`ftq_last`顺序释放；mispredict时Backend resolution同时驱动Frontend恢复。
- `rtl/O3.sv` 与 `rtl/Tile.sv` 仍是 LED 占位系统入口，尚未包住 `o3_core`。

## 模块说明
### backend
- 职责：承接 frontend 指令组，驱动 decode queue 与基础 rename 流程。
- 当前实现：Decode Input Register + Decode Queue + 可变前缀Rename + Map/Free List/checkpoint/ROB/LQ/SQ原子分配 + Rename/Dispatch Queue + 三路Dispatch/IQ；Integer闭合到4路ALU，Memory闭合到单发射LSU，Branch闭合到单发射BRU和Frontend恢复。
- 调试能力：
  - 当只定义 `O3_SIM` 时，backend 按周期块输出 `DECODE/RENAME/WAKEUP/ISSUE/REGREAD/EXECUTE/WRITEBACK/RETIRE/RETIRE_COUNT`；其中 `RENAME` 行可通过 DPI-C 调用 RV64I 反汇编 helper 显示汇编字符串。
  - 当定义 `O3_SIM_KANATA` 时，backend 输出 Kanata 格式文件。
  - 当定义 `O3_SIM_SINGLE_INST_TRACE` 时，backend 不输出普通整周期文本块，只追踪第一条进入 backend 的有效指令，并在目标指令退休后拉高 `single_inst_retired_o`。
  - 当定义 `ENABLE_RETIRE_INFO` 时，backend 输出 retire-time observation record，供外部 testbench/scoreboard 判断 commit 指令的架构效果。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期并行进入 rename 数据流的 lane 数。
- 当前未做：BTB/BHT/RAS训练表、精确异常恢复、DCache/MMU/PMA、Load replay、内存访问异常和完整内存序模型。

### o3_core
- 职责：作为当前 core 级最小集成入口，实例化真实 frontend 和真实 backend。
- 当前实现：
  - 连接 frontend 已有 fetch buffer 出队口到 backend fetch 输入口。
  - 透出 ICache refill request/response，供 testbench 或后续存储系统驱动。
  - 在 `ENABLE_RETIRE_INFO` 下透出 `retire_info_o`。
  - 在 `O3_SIM_SINGLE_INST_TRACE` 下透出 `single_inst_retired_o`。
- 当前未做：不接外部data cache/总线，不生成refill response，不做精确异常恢复，不定义真实程序结束条件。

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
- 当前覆盖：RV64I 中直接走整数 ALU 的U/R/I算术和word指令。
  - U-type：`LUI/AUIPC`
  - R-type：`ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND`
  - I-type：`ADDI/SLLI/SLTI/SLTIU/XORI/SRLI/SRAI/ORI/ANDI`
  - Word：`ADDIW/SLLIW/SRLIW/SRAIW/ADDW/SUBW/SLLW/SRLW/SRAW`
- 当前输出形态：输出 `decode_out_t`，包含 `rs1/rs2/rd`、`rs1_read_en/rs2_read_en/rd_write_en`、`use_imm`、`imm_type`、`imm_raw[11:0]`、`int_alu_op`、`is_int_uop`。
- 当前各类指令解码结果：
  - R-type 算术：读 `rs1/rs2`、写 `rd`，`use_imm=0`，`imm_type=IMM_TYPE_NONE`
  - I-type 算术：读 `rs1`、写 `rd`，`use_imm=1`，`imm_type=IMM_TYPE_I`，`imm_raw=instruction[31:20]`
  - RV64移位立即数使用6位`shamt[5:0]`；`SLLI/SRLI/SRAI`合法性检查`instruction[31:26]`，允许移位量32～63
  - Load/Store：生成寄存器副作用、立即数、LQ/SQ分类、访问宽度和Load signed/unsigned语义
  - Branch/JAL/JALR：生成Rename/checkpoint所需分类
  - 其它 opcode 或未识别的 `funct3/funct7`：保守输出全 0，不触发 rename 侧寄存器分配
- 当前已接通BEQ/BNE/BLT/BGE/BLTU/BGEU和JAL/JALR执行、恢复与redirect；仍未实现system/fence、CSR和trap执行语义。

### uop_queue
- 职责：作为 decode 后、rename 前按单条 uop 计数的顺序缓冲，消除不同输入批次留下的容量碎片。
- 当前实现：默认深度为 16 entries；存储按 `MACHINE_WIDTH` 个 bank 组织。每拍接收一个已经压紧的有效前缀，并从队头展示最多 `MACHINE_WIDTH` 条最老 uop。
- 出队合同：`deq_count_o` 表示当前展示条数，Rename用`deq_accept_count_i`回报本拍真正原子获得全部资源的最老前缀长度0～4。
- 背压合同：只有当前空位可容纳本拍全部 Decode 输出时才允许入队，不借用同拍即将出队的空间，因此 Rename 的资源判断不会形成直达 Decode 的组合路径。
- 当前未做：不计算Rename资源、不做指令融合或wakeup/select；mispredict时只按合同整体清空。

### free_list
- 职责：维护空闲物理寄存器池，为 rename 提供新物理寄存器。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期最多并行服务的分配请求 lane 数。
- reset 约定：
  - `x0~x31 -> p0~p31`
  - `p0` 固定作为零物理寄存器，不从 free list 重新分配
  - 空闲池从 `p32` 开始
- 当前实现补充：使用空闲位图做最多4路优先分配；commit释放旧preg；每个branch tag保存96位allocation mask，mispredict时一拍合并返还。

### rename_map_table
- 职责：维护架构寄存器到当前物理寄存器的映射。
- 宽度语义：使用 `MACHINE_WIDTH` 表示每周期并行读取/更新映射的 lane 数。
- reset 约定：
  - `x0~x31 -> p0~p31`
  - 其中 `x0` 固定视为 `p0`
- 当前实现：speculative map服务Rename，committed map随ROB退休更新；每个分支保存完整32×7位Map快照并支持一拍恢复。

### rename_stage / branch_checkpoint_file
- `rename_stage`是无状态前缀规划器，从最老lane开始累计资源消耗，输出0～4条接受前缀及完整`renamed_uop_t`。
- 每条指令必须同时取得它需要的ROB、preg、LQ/SQ、checkpoint和Rename/Dispatch Queue位置；不存在部分分配。
- `branch_checkpoint_file`管理4个branch tag、当前active branch mask以及每个分支的ROB/LQ/SQ恢复tail。
- 分支自己的uop不携带自己的branch bit；同拍更年轻lane立即携带该bit。

### load_queue / store_queue
- 当前默认各8项，在Rename阶段按真实Load/Store数量分配索引并保存ROB年龄和branch mask。
- LQ保存AGU地址和outstanding状态，每次复用翻转generation；Load响应只有tag仍匹配有效entry时才可进入写回，ROB退休时释放最老Load。
- SQ保存地址、数据、byte mask和committed状态；ROB退休不释放Store，只置committed，队头Store被DTCM或外部memory接受后才释放。
- 分支恢复删除错误路径SQ项时，同拍已握手且不受该分支控制的老Store execute、commit和drain事件仍然生效。
- Load查询全部更老Store；支持从单个最年轻完整覆盖Store转发，未知地址/数据或部分重叠保守阻塞。
- mispredict按branch mask删除未提交年轻entry并恢复checkpoint tail；committed Store不可被flush。

### rename_dispatch_queue
- 默认16项，按单条renamed uop压紧存储，隔离Rename和后续Dispatch背压。
- 正确分支解析清除branch bit；误预测删除所有携带目标bit的年轻uop。
- 入队宽度和出队Dispatch宽度独立参数化；当前分别为4和4。

### dispatch_stage / backend_issue_queue
- `dispatch_stage`只接受RDQ队头0～4条最大连续前缀，不允许年轻uop绕过被阻塞的老uop。
- 接受前缀内部按`is_int_uop`、`is_load/is_store`、`is_branch/is_jal/is_jalr`分别进入Integer、Memory和Branch IQ。
- 任一lane所需目标IQ无空位时，该lane及全部年轻lane留在RDQ；已经Dispatch的更老前缀同拍从RDQ删除。
- 三个`backend_issue_queue`保存完整renamed uop，分别维护容量、源ready、最老ready候选和分支恢复。
- Integer IQ最多提供4个候选，Memory和Branch IQ各提供1个候选；全局按ROB年龄和8个PRF读口做原子grant，未获读口或FU槽位的候选留在IQ。

### rob
- 职责：在 rename 阶段为真实有效的 uop 分配 ROB entry 编号，并存储最小提交前元信息。
- 当前实现：按lane顺序给出连续编号并保存`ftq_idx/ftq_last`；ALU/Load/Branch链接值写回、B型resolution与Store AGU按`rob_idx`标记`complete`；从队头连续退休最多4条已经complete且无异常的指令。
- `ENABLE_RETIRE_INFO` 调试路径：allocate 时额外保存 `pc/instruction/rd/rd_write_en`，ALU complete 时保存 `rd_wdata`，retire 时输出 `retire_info_o`。
- 当前未做：branch/异常恢复约束下的完整commit，以及CSR、访存异常cause等更完整ROB元信息。

### legacy issue_queue
- 旧`issue_queue.sv`仍保留在仓库中供后续迁移参考，但backend当前不再实例化它。
- 当前正式路径使用三个`backend_issue_queue`实例；不能再把旧单一整数IQ的周期行为当作现行Dispatch合同。

### physical_regfile
- 职责：提供物理寄存器存储体。
- 当前实现：已接入 backend 的 regread 和 writeback 阶段，支持多读端口、多写端口和同拍写后读旁路；当前 reset 后所有物理寄存器清零。
- 当前特殊约定：`p0` 固定为零物理寄存器，读恒为 0，写请求被忽略。
- 当前backend已在PRF外实现8读口与4写口仲裁；PRF本体尚未做bank、真实宏单元映射或端口冲突物理优化。

### branch_execute_unit
- 单发射BRU组合计算B型方向、JAL/JALR目标、实际下一PC和链接值。
- Branch Result寄存器把resolution广播与PRF写回分开；预测错误立即redirect，JAL/JALR链接值未获写口时继续保持。
- 所有resolution都会释放checkpoint或清branch mask；只有mispredict触发前后端恢复。resolution周期冻结新Rename/checkpoint分配。

### load_store_unit / simple_data_sram / writeback_arbiter
- `load_store_unit`接收一条已经读出操作数的Memory uop，组合执行AGU和SQ依赖判断；Store写SQ并complete，Load转发或建立单个memory outstanding请求。完整访问位于`0x11000000..0x1103ffff`时选择DTCM，否则整笔选择外部memory口。
- `simple_data_sram`是后端私有256KiB DTCM字节数组，使用绝对物理地址和初始化写口；Store握手上升沿修改数据，Load握手后一拍产生可反压响应。
- 外部memory口允许可变响应延迟，当前仍只允许一个Load outstanding；Store只有请求握手，没有返回包。仿真入口让取指与数据端共享同一份C++稀疏内存。
- `writeback_arbiter`在4个ALU result、1个Load result和JAL/JALR链接结果之间按ROB年龄分配4个写口；未获grant的生产者保持，grant与PRF写、wakeup、ROB complete原子对应。

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

### 独立访存框架（尚未接入 core）

- `rtl/memory/axi_master.sv`
  - 将简单的单请求/单响应接口转换为 AXI4 五通道。
  - 当前只允许一个 outstanding、单 beat 访问；不实现 burst、乱序返回或原子操作。
- `rtl/memory/axi_memory_smoke_top.sv`
  - 仅用于 LiteX 仿真，依次验证初始化读取、写入和读回。
  - 不属于 `o3_core`，未来 FPGA 顶层也不应使用这个 smoke driver。
- `config/o3_platform.json`
  - 保存当前采用的 Rocket/Flow 风格地址布局；main RAM 位于 `0x80000000`。

当前边界：这套AXI访存框架仍未接入core。`o3_core`已经透出简单的单请求外部memory
接口，整核仿真用软件模型响应；它还没有转换成AXI或真实DCache协议。

- `rtl/backend/backend.sv`
  - 当前 rename 最小闭环的总装模块。
  - 串起 fetch-entry buffer、decoder、free_list、rename_map_table。
- `rtl/backend/decoder.sv`
  - 负责把 32 位指令变成 decoded uop 阶段所需的最小语义。
- `rtl/backend/uop_queue.sv`
  - 负责在 decode 与 rename 之间缓存 16 条按程序顺序连续排列的 decoded uop，并提供最多 `MACHINE_WIDTH` 条的队头前缀。
- `rtl/backend/free_list.sv`
  - 负责按真实请求数分配新物理寄存器。
- `rtl/backend/rename_map_table.sv`
  - 负责speculative/committed映射、同拍旁路和完整分支Map快照恢复。
- `rtl/backend/rename_stage.sv`
  - 负责0～4条最老前缀的联合资源判断和renamed uop组装。
- `rtl/backend/branch_checkpoint_file.sv`
  - 负责branch tag、active mask和ROB/LQ/SQ恢复tail。
- `rtl/backend/load_queue.sv` / `rtl/backend/store_queue.sv`
  - 负责Rename位置预留、AGU状态、Load generation、Store commit buffer、转发查询和分支恢复。
- `rtl/backend/load_store_unit.sv`
  - 负责单发射Memory RegRead之后的AGU、Load依赖判断、SRAM仲裁和Load结果保持。
- `rtl/backend/branch_execute_unit.sv`
  - 负责单发射Branch RegRead之后的条件比较、目标、实际下一PC和链接值计算。
- `rtl/backend/writeback_arbiter.sv`
  - 负责4个ALU结果与1个Load结果到4个PRF写口的最老优先仲裁。
- `rtl/memory/simple_data_sram.sv`
  - 后端私有256KiB DTCM，单端口、字节寻址并带绝对地址初始化口；当前不连接AXI。
- `rtl/backend/rename_dispatch_queue.sv`
  - 负责缓存renamed uop并执行branch mask清除/删除。
- `rtl/backend/rob.sv`
  - 负责按真实有效 uop 数量分配最小 ROB entry 编号，并存储 exception 位。
- `rtl/backend/backend_issue_queue.sv`
  - 三类IQ共用的压紧存储、wakeup、最老ready候选和分支恢复骨架；candidate输出与ready删除逻辑分离，允许外部资源仲裁安全回送ready。
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
  - 当前也集中定义 `CORE_FETCH_WIDTH` 与 `BACKEND_*` 固定配置参数。
  - `fetch_entry_t` 是前后端共同认可的单 lane 指令包，除指令和异常字段外携带`ftq_idx/ftq_last/predicted_next_pc`。
- `rtl/frontend/frontend.sv`
  - frontend 侧实现入口，和 backend 对接时需要一起看接口约束。
- `rtl/core/o3_core.sv`
  - 当前真实 frontend + backend 的 core 级连接入口。
- `rtl/O3.sv`
  - 旧系统级入口；当前仍是 LED 占位逻辑，尚未包住 `o3_core`。
- `rtl/Tile.sv`
  - 更上层系统封装入口；当前仍包住占位 `o3`，真实 core 集成后需要同步更新。
- `sim/o3/`
  - 当前唯一的完整core Verilator入口；包含统一RTL清单、ICache refill驱动、最小指令镜像和JSONL Tandem退休轨迹生产器。
  - 当前只生成退休记录，不启动Spike，不进行差分判断，也不生成Kanata微架构轨迹。

## 关键时序行为
### backend 周期级行为
周期 N 组合阶段：
- `fetch_entry_q` 中保存当前待 decode 的指令组。
- `fetch_instruction_id_q` 中保存当前 fetch buffer 这组指令对应的调试编号；编号的低位是 lane id，高位是被 backend 接收时的 group 序号。
- `fetch_entry_q[lane].valid` 决定该 lane 的 `decoded_uop.valid`；统一的前端异常元数据或 Decoder 的非法指令判定形成 `decoded_uop.exception_*`。
- `decoder` 组合输出 `rs1/rs2/rd`、`rs1_read_en/rs2_read_en/rd_write_en`、`use_imm`、`imm_type`、`imm_raw`、`int_alu_op`、`is_int_uop` 和 `illegal_instruction`。
- 若 `uop_queue` 可接收，则当前 fetch 组在本拍以 `decoded_uop` 形式入队。
- `uop_queue` 从队头展示当前最老的最多 `MACHINE_WIDTH` 条 uop，输出 lane 始终是无洞的有效前缀。
- `free_list` 组合输出本拍候选 `new_dst_preg`。
- `rename_map_table` 组合输出 `src1_preg/src2_preg/old_dst_preg`。
- `rob` 组合输出本拍候选 `rob_idx`。
- `rename_stage`从lane0开始累计检查ROB、preg、LQ、SQ、checkpoint和Rename/Dispatch Queue空位，得到最大可接受前缀。
- Map、Free List、ROB、LQ/SQ组合给出该前缀的候选编号；同拍更年轻lane看到更老lane的新映射。
- Rename/Dispatch Queue隔离IQ背压，因此IQ不直接决定同拍Rename数量。
- `dispatch_stage`按Integer/Memory/Branch IQ拍初空位接受RDQ队头最大连续前缀；前缀内部可以三路并行分流。
- 三个IQ组合更新源ready视图并输出最老ready候选；Integer、Memory和Branch候选按ROB年龄参与8读口/FU槽位联合仲裁。
- 读仲裁按候选实际需要的0/1/2个源原子分配PRF端口，无法完整满足时不向IQ回送ready。
- `alu_regread_q` 当前持有的真实操作数值直接驱动 `int_execute_unit`。
- 4个`alu_result_q`、1个Load结果槽和JAL/JALR链接结果按ROB年龄竞争4个写口；只有grant形成PRF写、wakeup和ROB complete。
- LSU对当前Memory uop组合产生AGU地址，查询SQ后选择Store forwarding、DTCM或外部memory；committed Store优先请求统一端口。
- `rob`从队头开始连续检查最多4项，只退休队头连续`complete=1 && exception=0`的前缀。

周期 N 上升沿：
- 如果 `decode_fire=1`，则当前 fetch 组完成 decode 并进入 `uop_queue`。
- 如果`rename_accept_count`非零，前缀中的每条指令在同一上升沿原子更新Map/Free List/ROB/LQ/SQ/checkpoint并进入Rename/Dispatch Queue；Decode Queue删除相同条数。
- 如果内部`branch_resolution.valid && mispredict`，恢复优先于正常Rename：Decode侧清空，Map/Free List/ROB/LQ/SQ恢复，后端队列和流水删除目标分支之后的uop。
- 三个IQ分别压紧写入本拍Dispatch给自己的uop，并把旧表项按`preg_ready`结果更新；只有获得全部读口与FU槽位的候选被删除。
- grant的Integer/Memory/Branch候选在该上升沿锁存PRF读值和扩展立即数；Branch下一拍由BRU计算并进入结果保持寄存器。
- 上一拍 `alu_regread_q` 中的 uop 会经过 `int_execute_unit` 计算，并进入 `alu_result_q`。
- 写口grant的ALU/Load结果写PRF、置目标preg ready、广播并complete ROB；未grant结果保持，逐级阻塞对应RegRead和IQ端口。
- Store AGU把地址/数据/mask写入SQ并complete ROB；Load建立DTCM/外部memory请求或把转发值写入Load结果槽。
- ROB退休的Load释放LQ；退休的Store只把SQ entry置committed，随后由最老Store drain写SRAM并在请求握手后释放。
- 当前从 ROB 队头退休的指令会在本拍把 `old_dst_preg` 返还给 free list；这些被释放的寄存器会从下一拍起重新出现在 rename 分配候选中。
- `backend` 会在本拍把真实退休条数累加到 `retired_inst_count_q`。
- 如果 `fetch_fire=1`，则 frontend 新的一组指令写入 buffer，并按“group 序号 + lane id”生成新的 `instruction_id`。
- 如果同拍既 `decode_fire=1` 又 `fetch_fire=1`，表示旧的 fetch 组被消费完成 decode，同时新的一组顶上来。
- 当只定义 `O3_SIM`、未定义 `O3_SIM_KANATA` 和 `O3_SIM_SINGLE_INST_TRACE` 时，本拍会输出一个 lane0 日志块：
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
- 看到更新后的`uop_queue`、free list、rename map、ROB、三个IQ及可反压ALU/LSU流水状态。
- 看到刚刚被写回的目标物理寄存器在 `preg_ready` 中变为 ready。
- 看到刚刚退休并释放的旧物理寄存器重新回到 free list 可见范围。
- 看到新 buffer 中的下一组指令，以及新的 rename 队头。
- 当只定义普通 `O3_SIM` 文本日志时，日志中可看到不同 `instruction_id` 在各级继续向后流动；当定义 `O3_SIM_SINGLE_INST_TRACE` 时，只会打印第一条进入 backend 的有效指令。

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
- 统计 Decode 输入无洞有效前缀的条数；只有当前空位足以容纳整个前缀时，`enq_ready_o=1`。
- 从 `head_q` 开始读取最多 `MACHINE_WIDTH` 条最老 uop，压紧放在输出 lane0 起始的有效前缀中，并通过 `deq_count_o` 给出条数。

周期 N 上升沿：
- 若入队握手成立，则从 `tail_q` 起连续写入本拍真实有效的 decoded uop；每个逻辑位置按照模 `MACHINE_WIDTH` 映射到一个 bank。
- 删除 `deq_accept_count_i` 指定数量的最老 uop；该数只能是当前展示前缀的长度以内。
- 入队和出队可同拍发生，`head_q/tail_q/count_q` 按各自真实数量原子更新。

周期 N+1：
- 对外看到更新后的队头、队尾和空满状态。

### dispatch_stage / backend_issue_queue 周期级行为
周期 N 组合阶段：
- `dispatch_stage`从RDQ lane0开始累计三个IQ的拍初空位，形成0～4条最大连续接受前缀。
- 接受前缀中的Integer、Load/Store和Branch/Jump分别形成三个无洞的逻辑入队集合。
- 每个`backend_issue_queue`根据`preg_ready`更新旧表项ready视图；Integer和Branch选择最老ready候选，Memory在当前单请求LSU下只允许物理队头成为候选。
- Integer、Memory与Branch IQ候选按ROB年龄参加8读口和对应FU容量仲裁。

周期 N 上升沿：
- RDQ删除Dispatch接受的最老前缀；三个IQ分别按原lane年龄压紧追加属于自己的uop。
- IQ旧表项写回更新后的源ready状态；获得全部资源的候选按各自ready握手删除，未grant候选保持。
- 分支恢复拍禁止Dispatch：正确解析清branch bit，误预测删除携带目标bit的错误路径表项并压紧。

周期 N+1：
- 对外看到RDQ新队头、三个IQ的新容量和各自新的最老ready候选。

### integer ALU 流水寄存器周期级行为
周期 N 组合阶段：
- 全局读仲裁从Integer/Memory IQ候选中按ROB年龄贪心选择，组合驱动8个`physical_regfile`读地址。
- `physical_regfile`组合读出grant候选需要的`src1/src2`值。
- `backend`在RegRead阶段把`imm_raw/imm_type`扩展成64位`imm_value`，同时独立保存寄存器`src2_value`；`int_execute_unit`根据`imm_valid`选择第二操作数。
- `alu_regread_q` 直接驱动 `int_execute_unit` 的输入。
- `int_execute_unit` 组合地产生执行结果。

周期 N 上升沿：
- 本拍获得读口的Integer候选及其操作数进入`alu_regread_q`；`alu_issue_q`只保留现有日志观察副本。
- 上一拍 `alu_regread_q` 中的 uop 执行结果进入 `alu_result_q`。
- 若旧`alu_result_q`未获写口，则它和对应`alu_regread_q`保持，本拍该ALU不接受新IQ候选。

周期 N+1：
- 同一条整数指令会在日志中向后移动到下一拍的下一级寄存器。

### LSU、SQ commit buffer与统一memory周期级行为
周期 N 组合阶段：
- `mem_execute_q`组合产生有效地址和访问byte mask，Load同时查询全部更老SQ entry。
- 更老Store地址/数据未知或部分重叠时，Load保持；单个最年轻Store完整覆盖时形成转发结果；否则按完整访问范围选择DTCM或外部memory。
- SQ队头若为地址/数据齐全的committed Store，则优先于Load占用统一请求口。
- DTCM或外部Load响应只有LQ `{generation,lq_idx}`仍存活且Load结果槽可接收时才握手。

周期 N 上升沿：
- Store把地址、数据和mask写入Rename时分配的SQ entry，并向ROB报告complete。
- 若本拍同时发生分支误预测恢复，不携带该分支tag的更老Store execute/commit/drain事件仍原子生效，恢复只删除错误路径项。
- Load请求锁存唯一pending元数据和目标类型；DTCM固定一拍返回，外部memory可以在任意后续周期返回，返回数据或Store转发值进入可保持Load结果槽。
- ROB退休Store只设置对应SQ entry的`committed`；目标memory接受队头Store写请求才推进SQ head并释放容量。
- 获得共享写口的Load结果写PRF、广播wakeup并complete ROB；未获写口时结果保持并阻塞新的Load结果。

周期 N+1：
- DTCM响应或外部握手、SQ committed状态、LQ outstanding状态和释放后的容量对外可见。
- flush后迟到的Load响应因generation或branch mask失配被消费但不产生写回。

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
- 读取speculative map，并按lane0到lane3让更老lane的新目的映射覆盖年轻lane的源和old-destination读值。

### 当前解码输出到 uop 的样子
- `decoder` 的直接输出是 `decode_out_t`，字段为：
  - `rs1/rs2/rd`
  - `rs1_read_en/rs2_read_en/rd_write_en`
  - `use_imm`
  - `imm_type`
  - `imm_raw`
  - `int_alu_op`
  - `is_int_uop`
  - `illegal_instruction`
- `backend` 会把 frontend 带来的原始信息与这些解码字段拼成 `decoded_uop_t` 后再入 `uop_queue`。
- 当前 `decoded_uop_t` 的内容是：
  - frontend/Backend 输入寄存器透传：`valid/instruction_id/pc/raw_instruction/instruction/inst_len/is_rvc/exception_valid/exception_cause/exception_tval`
  - decoder 新产生：`rs1/rs2/rd`、`rs1_read_en/rs2_read_en/rd_write_en`、`use_imm`、`imm_type`、`imm_raw`、`int_alu_op`、`is_int_uop`
- 也就是说，当前 decode 级产出的不是“完整执行控制词”，而是“原始指令 + 最小 rename/整数 ALU 语义”的一组 uop。
- 当前 decode 不再输出 XLEN 展开的 `imm_value`；立即数的符号扩展计划留到后续寄存器读阶段完成。

周期 N 上升沿：
- 正常Rename时更新接受前缀的目的映射；遇到分支lane时保存包含该lane自身修改、但不包含更年轻lane的完整Map快照。
- ROB顺序退休时同步更新committed map。
- mispredict时恢复优先，一拍把目标checkpoint复制回speculative map。

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
- 统计96位free bitmap，并从lane0开始为真实目的写逐级优先选择不同的候选preg。

周期 N 上升沿：
- 正常Rename原子清除接受前缀分配的preg位，并把每个新preg记入它所依赖的所有活动分支allocation mask。
- Commit释放的old preg重新置为空闲。
- mispredict时禁止新分配，将目标分支allocation mask与commit释放集合合并回free bitmap。

周期 N+1 组合阶段：
- 对外看到正常分配或恢复后的空闲集合；被放弃preg中的PRF数据不会清零。

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
- 当前重构边界已经推进到Integer/Memory/Branch IQ、ALU/LSU/BRU、ITCM/DTCM与外部memory、共享8R4W仲裁、Store commit buffer和Frontend redirect。
- 单发射BRU已经接通；预测器仍固定not-taken，不含BTB/BHT/RAS或训练表。
- Load只支持单个更老Store完整覆盖转发；未知地址/数据及部分重叠保守等待，不实现violation检测或replay。
- 当前地址图包含64KiB ITCM和256KiB DTCM；范围外由简单外部memory接口处理，仿真中对应共享软件稀疏内存。
- 当前最多一个Load outstanding；committed Store固定优先，持续Store drain可能推迟Load。
- TCM跨边界请求整笔走外部memory；数据端写ITCM或指令端访问DTCM只更新/读取软件后备副本，不提供运行时双端口一致性，因此不支持自修改代码。
- Branch/Jump已有完整静态链路；定向整核测试覆盖taken BEQ、JAL、错误路径清除和链接值退休，ACT4-I覆盖六种分支、JAL与JALR生成用例。
- `FENCE`编码当前作为无寄存器副作用uop完成，但不会阻止年轻访存提前执行或等待SQ排空；屏障状态机仍未实现。
- 当前 `SYSTEM` 指令先按保守方式处理，不纳入 CSR 重命名细节。
- `alu_issue_q`当前只保留日志观察副本，真实grant候选的操作数直接锁存到`alu_regread_q`；后续做时序收敛时可重新切分Select/RegRead边界。
- 乘除单元尚未接入新Issue/写回仲裁接口。
- 当前 `mul_execute_unit/div_execute_unit` 只是固定拍数骨架，不代表最终工业级实现。
- 当前不处理乘法高低位融合、除法商余融合，也不处理多请求并发执行。
- 当前整核仿真支持ELF64 PT_LOAD、带绝对地址的hex、TCM初始化、范围外软件memory及`tohost`结束协议；固定ACT4版本生成的非特权RV64I-I共51项已形成整核回归并全部通过。该集合不含ECALL/EBREAK语义和FENCE内存序；Spike差分、特权态、异常与中断仍未进入该闭环。

## 后续扩展入口
- Branch预测扩展：在现有BRU/redirect闭环上增加BTB/BHT/RAS和训练消费。
- LSU扩展：加入多Load outstanding、Load violation检测/replay、多个Store字节合并转发和真实DCache接口。
- PRF扩展：在逻辑8R4W合同稳定后加入bank映射、bank conflict replay或固定延迟FU的未来写回槽预订。
- 执行单元扩展：U/R/I/word、Memory和Branch路径已经闭合；后续接入Mul/Div并纳入共享读写口仲裁。
- 乘法器扩展：在保持当前固定拍数接口不变的前提下，将内部实现替换为 DSP 优化、Booth 或华莱士树结构。
- 除法器扩展：在保持当前固定拍数接口不变的前提下，将内部实现替换为迭代式除法器，并视需要扩展可取消与融合能力。

## 文档分工建议
更适合放到 [`agent.md`](/home/chen/work/CISLC-O3/agent.md) 的内容：
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
