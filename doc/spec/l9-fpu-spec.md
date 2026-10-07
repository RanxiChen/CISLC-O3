# O3-T07：L9 F/D 浮点 RTL spec（审核修订版）

日期：2026-10-07。分支：`feat/L1-closure`。审计快照：`97e8d29`（L7b 收口后）。行号均指该快照。

依据：[v1 计划](../O3-v1-plan.md) 第 3 节 L9；[后端基线](../design/CISLC-O3-BACKEND-DESIGN-BASELINE.md) B14（§17）、B15（§18）、B22（§25）、B33（§35.2）、B40（§35.9）；
[L7b spec](l7b-rvc-spec.md) 2.2（浮点 RVC 推迟到 L9）。

**验证原则（用户 2026-10-06）：先完成后完美。** 每个新行为一个简单定向用例；Spike、ACT4 RV64GC 推迟到 FPGA；L11 前不综合。
访存只做到 FLW/FLD/FSW/FSD 功能可用，接在现有 L3 LSU 上（2026-10-06 顺序调整）。

**状态：2026-10-07 审核修订版。** 用户指定 W1 使用 git submodule，并授权落实审核结论；W1～W12 的最终取舍见第 13 节。本轮只修订 spec 与任务书，不开始 RTL、不运行仿真、不提交。本文供后续实施使用。

---

## 0. 任务书

```
目标：L9 —— RV64FD（M 模式）：独立 FP 重命名域（32→64）、FP IQ、拆分 CVFPU 的五个 FU
      （FMA×2、DIVSQRT、MISC、CONV/MOVE）、FP 写回、FLW/FLD/FSW/FSD、
      fflags/frm/fcsr 与 mstatus.FS/SD、退休合并 fflags 与置 Dirty（B40）、浮点 RVC。
涉及模块（允许改动）：
  rtl/common/{o3_cfg_pkg,o3_types_pkg,o3_pkg}.sv
  rtl/backend/{decoder,rename_stage,rename_map_table,free_list,preg_ready_table,
               dispatch_stage,rename_dispatch_queue,backend_issue_queue,prf_read_arbiter,
               physical_regfile,writeback_arbiter,fp_writeback_arbiter,rob,load_store_unit,backend}.sv
  rtl/backend/fpu/fpu_{fma,divsqrt,misc,conv}_fu.sv（由空壳实现）
  rtl/system/{commit_ctrl,csr_file}.sv；rtl/frontend/rvc_expander.sv
  .gitmodules；third_party/cvfpu（git submodule，W1）；third_party/CVFPU.md（来源与依赖记录）
  rtl/rtl.f；scripts/lint.sh 与 Verilator 豁免文件
  对应 sim/cocotb/*；sim/o3/tests 新程序与 sim/o3/Makefile 目标
  doc/LOOP.md；doc/tasks/O3-T07-report.md
不做：第 11 节
验收：第 12 节
```

## 1. 现状（`97e8d29` 源码核实）

| 位置 | 现状 | L9 要做 |
| --- | --- | --- |
| `o3_cfg_pkg.sv:354,366,372,373,378,382` | `fp_phys_regs=64`、`fp_iq_depth=12`、FP PRF 6R/2W、`num_fma=2` 等已定义，`fpu_inflight_slots=4`；只有未接入的空壳使用 | 接入；`fp_prf_read_ports` 改 7（W4），槽数见 6.1 |
| `o3_types_pkg.sv:636-856,1099-1123` | `reg_domain_e`、FP `fu_class_e`、`fp_op_e`、`uop_ext_t.{rs3,*_dom,fp_op,fp_fmt,rm}`、`rename_ext_t.src3_preg`、`fpu_req_t/resp_t`、`wb_req_t.fflags`、`fp_retire_evt_t`、`rob_commit_t.{rd_dom,fflags}` 已有 | 使用；按需补字段（第 10 节） |
| `decoder.sv:142,443` | 默认 illegal；0x07/0x27/0x43/0x47/0x4B/0x4F/0x53 均落入 default → 非法 | 第 3 节 |
| `decoder.sv:122` | `ext='0`，所有域为 `RD_NONE` | 整数指令填 `RD_INT`，FP 按第 3 节 |
| `rename_map_table.sv:90-169`、`free_list.sv:88-151`、`rename_stage.sv:89,129`、`physical_regfile.sv:88` | 有 `DOMAIN` 参数与 `HAS_ZERO_REG`，但 x0 判断写死、`HAS_ZERO_REG` 未使用；map table 无 rs3 读口；`rename_stage` 只有一个 preg 预算 | 第 4 节 |
| `backend.sv:949,1032,1232,1264` | 只有 `RD_INT` 实例 | 增加 FP 实例 |
| `backend_issue_queue.sv:83-94,170-199` | 只跟踪 src1/src2；唤醒只比 preg 号、不比域 | 第 5 节 |
| `dispatch_stage.sv:72-80` | 按 `is_load/is_store/is_branch/is_int_uop` 分 MEM/BR/INT | 增加 FP |
| `writeback_arbiter.sv:31-58` | 6 个 extra 源：0 MUL、1 DIV、2 FMISC→INT、3 FCONV→INT、4 CSR、5 AMO；后四个接 0 | 2、3 接入（7.2） |
| `fp_writeback_arbiter.sv:13,24-26` | 空壳，`NUM_SRC=6`（FMA×2、DIVSQRT、MISC、CONV、FP load） | 实现（7.1） |
| `rtl/backend/fpu/*.sv` | 四个空壳，只有分支解析口；头注释建议槽+代际侧表、结果保持、不用原生 flush | 第 6 节；补全局 flush 口，按槽寿命决定身份编码 |
| `rob.sv:319` | `rd_dom` 写死 `RD_INT`；`t_fflags_*` 端口存在但未读、未连 | 7.3 |
| `commit_ctrl.sv:188`、`backend.sv:229,245` | `fp_retire_o='0` 且悬空；`csr_file.fp_retire_i('0)`、`frm_o/fs_o` 悬空 | 2.4 |
| `csr_file.sv:79,91,112,133` | MISA=RV64IMC；mstatus 读值 `0x1800\|MPIE\|MIE`、写掩码 `0x88`，无 FS/SD；无 0x001～0x003；`frm_o=fs_o=0` | 第 2 节 |
| `load_store_unit.sv:247-264,359-361`、`backend.sv:1864-1886` | `format_load` 符号/零扩展；`base/store_value` 都取自整数 PRF；`dst_write_en` 要求 `rd!=0` | 第 8 节 |
| `rvc_expander.sv:41-111` | C.FLD/C.FSD/C.FLDSP/C.FSDSP 走 default → 非法；C.LUI 合法性用 `\|c[12:2]`（含 rd 位，nzimm=0 的保留编码被接受） | 第 9 节 |
| Flow `~/leisure/flow` `7dfa75c`，CVFPU 子模块 `1b220f3`（fork RanxiChen/cvfpu，含 `cdb4c70`/`1b220f3` 两处 100 MHz 切分） | `design/src/main/resources/vsrc/fpnew/FlowFpnewWrapper.sv:37-58` 配置；文件清单 `cvfpu-files.f`；Breeze 译码映射 `fpu/BreezeFp.scala:74-227`，操作数排列 `backend/BreezeBackend.scala:341-350` | 第 6 节复用 |

Breeze 的两处行为，O3 **不沿用**：FLD/FLW/FMV.W.X 不置 FS Dirty（`core/RegFile.scala:469-495`，不满足 B40）；写 frm 时把 5～7 钳成 0（`RegFile.scala:489,494`，与本项目 W8 的照存合同不同）。W8 的规范边界见 2.1；不把保留舍入模式的异常处理误写成现行规范唯一强制行为。

现有 `rename_dep_r1` 与 `rename_stage_buffer` 仍未接入；L9 沿用 B42 允许的单拍重命名与 map table 组内旁路，不在本级补做 R1/R2 两拍拆分。

## 2. CSR 与浮点架构状态

### 2.1 新增 CSR（`csr_file.sv`）

| 地址 | 名称 | 读 | 写 |
| --- | --- | --- | --- |
| 0x001 | fflags | `{59'b0, fflags_q}` | `fflags_q ← wdata[4:0]` |
| 0x002 | frm | `{61'b0, frm_q}` | `frm_q ← wdata[2:0]`，**任意值照存**（W8） |
| 0x003 | fcsr | `{56'b0, frm_q, fflags_q}` | `frm_q ← wdata[7:5]`，`fflags_q ← wdata[4:0]` |

- 三个 CSR 在 `FS == Off` 时访问非法（读写都算），沿用现有 `resp_o.illegal` 路径（`backend.sv:206-208`）。
- 合法写这三个 CSR 时置 `FS=Dirty`（B40“软件写浮点 CSR 时，在既定串行更新点置 Dirty”）。
- 读写抑制沿用 Zicsr：CSRRS/CSRRC 的 rs1=x0、立即数形式 zimm=0 不写，因此单纯读取不置 Dirty。非法访问不修改任何浮点状态。高位未实现字段写入忽略、读取为 0。
- 读 fflags 不需要额外等待：CSR 指令 `block_younger`，到达队头时更老指令都已退休、fflags 已合并（B22）。
- **W8 的规范边界**：本项目允许 frm 的 3 位任意值照存；带架构 rm 的指令使用保留静态 rm（5、6）或保留动态 frm（5～7）时，选择报非法指令。现行规范将保留舍入模式的执行行为定义为 reserved，非法指令异常是允许的实现选择；较早版本曾强制动态保留值报异常。依据：[RISC-V 官方 F 规范，Floating-Point Control and Status Register](https://github.com/riscv/riscv-isa-manual/blob/main/src/unpriv/f-st-ext.adoc)。

### 2.2 mstatus 与 misa

- mstatus 增加 `FS[14:13]`（WARL，可写 0～3）与只读 `SD[63] = (FS == 2'b11)`。写掩码 `0x88 → 0x6088`；读值 `0x1800 | FS<<13 | MPIE<<7 | MIE<<3 | SD<<63`。
- **复位 FS = Off、frm = RNE（0）、fflags = 0**（W9）。这是本项目复位合同。测试程序须先 `csrs mstatus, (1<<13)` 打开浮点；改变 FS 不清除 FPR 或 fcsr 的内容。
- **T07a**：MISA 保持 `64'h8000000000001104`（RV64IMC），浮点子集只作为内部开发过渡，不声明完整 F/D 支持。
- **T07b**：FMA、DIVSQRT 与浮点 RVC 接通后，在同一实现版本中加 F（bit 5）与 D（bit 3）：`64'h8000000000001104 | 64'h28 = 64'h800000000000112C`（RV64IMFDC）。写 misa 不改变本项目的固定支持集合。
- 输出 `frm_o = frm_q`，`fs_o = FS`。

### 2.3 FS Off 与动态舍入的检查点（W7）

- 检查在 **Rename 入口**，使用 `csr_file` 的当前 `fs_o/frm_o`；不在前端译码时锁存 CSR 值。组合预处理放在 `rename_entry_gate` 输入前，使新发现的异常也参与前缀截断；只有 entry gate 放行且 `rename_stage` 实际接受的 lane 才锁存检查结果和解析后的 rm。被 gate 阻塞的年轻指令留在 Decode Queue，后续重新检查：
  - 任意 FP 指令（第 3 节表中所有指令，含 FLW/FLD/FSW/FSD 与 FP RVC 展开结果）在 `FS == Off` 时 → 非法指令异常。
  - **仅 `uses_arch_rm=1`** 且 `rm == 3'b111`（DYN）的指令：`frm_q ∈ {5,6,7}` → 非法指令异常；否则把 `ext.rm` 替换为 `frm_q`，此后一直携带已解析的 rm（B15“随请求锁存”）。SGNJ/MINMAX/CMP 的子操作编码、FCLASS、FMV 与访存不查 DYN。
  - 静态 `rm ∈ {5,6}` 在译码阶段已判非法（第 3 节）。
- 正确性依据：FS 从 Off 变化、frm 变化只能由 CSR 写产生，而 CSR 指令 `block_younger`，年轻指令在它退休前不会通过 entry gate（B22）；退休置 Dirty 不改变“是否 Off”。因此 rename 入口看到的就是程序顺序正确的值。
- 若 uop 已带取指或译码异常，保留它的 cause/tval，不能被 FS/rm 检查覆盖。新异常为 `exception_valid=1`、`cause=ILLEGAL_INSTRUCTION`、`tval=原始指令`（RVC 为 16 位编码零扩展），保留 PC、真实长度与 FTQ 身份。
- 任一异常项都撤销执行语义：清 `rd_write_en`、全部源读使能（含 rs3）、全部源/目的域、`is_int_uop/is_load/is_store/is_branch/is_jal/is_jalr`、`needs_checkpoint`；`fu_class=FU_NONE`，清 CSR/系统执行及融合标记，置 `block_younger=1`。只消耗 ROB/RDQ，不分配 INT/FP preg、LQ/SQ/checkpoint，不进任何 IQ；ROB 分配即 complete，由队首 trap 路径处理。
- 例：FS=Off 时 `fld f0,0(x1)` 必须以原指令报非法；不能因为遗留 `is_load` 而分配 LQ 或向 LSU 发请求。entry gate 的阻塞位由 trap/global flush 清除，沿用已有异常路径。

### 2.4 退休合并（B40）

- `commit_ctrl` 生成 `fp_retire_o`（`fp_retire_evt_t`）：本拍实际退休的 lane 中，`fflags` 取 OR；`fs_dirty` = 任一退休项 `rd_dom == RD_FP && rd_write_en`，或任一退休项 `fflags != 0`。`valid` = 本拍有退休。
- `csr_file` 在 `fp_retire_i.valid` 时：`fflags_q |= fflags`；`fs_dirty` 时 `FS ← 2'b11`。
- 互斥：trap 拍无退休（`commit_ctrl.sv:153-156`）；CSR 写那拍的队头 CSR 指令 `block_younger`，其后没有年轻项、更老项都已退休，所以 CSR 写与非零 fp_retire 不会同拍。加断言 `!(fp_retire_i.valid && |fp_retire_i.fflags && (req_valid_i || trap_update_valid_i))`，`fs_dirty` 同理。
- **FLD/FLW/FMV.W.X/FCVT.fmt.X 等任何写 FPR 的退休都置 Dirty**（不沿用 Breeze 的缺口）。

## 3. 译码（`decoder.sv`）

### 3.1 指令表

具有 `fmt` 字段的 OP-FP（0x53）与四种 FMA opcode，`inst[26:25]` 只接受 `00`（S）和 `01`（D），其余非法。FLW/FLD/FSW/FSD 没有该字段，这些位属于立即数，不做 fmt 检查。静态 rm 字段（`inst[14:12]`，仅 `uses_arch_rm=1` 的指令）为 5 或 6 时非法；7 为 DYN，留给 2.3。

| 指令 | opcode / 关键字段 | rs1 域 | rs2 域 | rs3 | rd 域 | fu_class | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| FLW / FLD | 0x07，funct3 010 / 011 | INT | – | – | FP | LDST | 其余 funct3 非法；`mem_size` 4/8B |
| FSW / FSD | 0x27，funct3 010 / 011 | INT | FP | – | – | LDST | 同上 |
| FMADD/FMSUB/FNMSUB/FNMADD | 0x43/0x47/0x4B/0x4F | FP | FP | FP（`inst[31:27]`） | FP | FMA | 带 rm |
| FADD/FSUB/FMUL | 0x53，funct5 00000/00001/00010 | FP | FP | – | FP | FMA | 带 rm |
| FDIV | funct5 00011 | FP | FP | – | FP | FDIVSQRT | 带 rm |
| FSQRT | funct5 01011，rs2 必须为 0 | FP | – | – | FP | FDIVSQRT | 带 rm |
| FSGNJ/FSGNJN/FSGNJX | funct5 00100，funct3 0/1/2 | FP | FP | – | FP | FMISC | 其余 funct3 非法；无 rm |
| FMIN/FMAX | funct5 00101，funct3 0/1 | FP | FP | – | FP | FMISC | 无 rm |
| FEQ/FLT/FLE | funct5 10100，funct3 2/1/0 | FP | FP | – | INT | FMISC | 无 rm |
| FCLASS | funct5 11100，funct3 1，rs2=0 | FP | – | – | INT | FMISC | |
| FMV.X.W / FMV.X.D | funct5 11100，funct3 0，rs2=0，fmt S/D | FP | – | – | INT | FCONV | 位搬运（6.3） |
| FMV.W.X / FMV.D.X | funct5 11110，funct3 0，rs2=0 | INT | – | – | FP | FCONV | 位搬运 |
| FCVT.S.D / FCVT.D.S | funct5 01000，rs2 = 1 / 0（且 ≠ fmt） | FP | – | – | FP | FCONV | 带 rm |
| FCVT.{W,WU,L,LU}.fmt | funct5 11000，rs2 0～3 | FP | – | – | INT | FCONV | 带 rm；rs2≥4 非法 |
| FCVT.fmt.{W,WU,L,LU} | funct5 11010，rs2 0～3 | INT | – | – | FP | FCONV | 带 rm；rs2≥4 非法 |

- 填 `ext.{rs1_dom,rs2_dom,rs3_dom,rd_dom,rs3,rs3_read_en,fu_class,fp_op,fp_fmt,rm}`；整数指令有读使能的源及有写使能的目的填 `RD_INT`（不再是 `RD_NONE`）。不读的源填 `RD_NONE` 且 `rs*_read_en=0`；store 等没有结果的指令目的域为 `RD_NONE`。**FP→x0 的比较/分类/转换/搬运仍带 `rd_dom=RD_INT`，只令 `rd_write_en=0`**，使结果经整数完成通路终结并携带 fflags；不能因 x0 把结果路由域清成 NONE。异常项则按 2.3 清域。
- `fp_op` 使用现有 `fp_op_e`，四种 fused 操作已齐全；包装据此产生 6.2 的 op/op_mod，不增加重复枚举。
- 补 `uses_arch_rm`、`fp_src_fmt`、`fp_int_fmt` 与 `fp_unsigned`：`fp_fmt` 保留为目的浮点格式；普通同格式操作令 `fp_src_fmt=fp_fmt`，F2F 从 rs2 编码取源格式；整数转换宽度取 rs2[1]（W/L），无符号属性取 rs2[0]。rs2 编码是转换控制信息，不能因它不是寄存器源而丢失。类型编码自行决定，不让公共类型依赖 fpnew package。
- `rd_write_en`：FP 目的恒为 1（f0 是普通寄存器）；INT 目的沿用 `rd != 0`。
- **T07a 过渡**：FMA 与 FDIVSQRT 类在 T07a 仍译为非法，T07b 接入 FU 后放开（见任务书 `doc/tasks/O3-T07-l9-tasks.md`）。

### 3.2 派发分类

- FLW/FLD/FSW/FSD 置 `is_load/is_store`，走 MEM IQ（不变）。
- `fu_class ∈ {FMA, FDIVSQRT, FMISC, FCONV}` 走新的 FP IQ（`dispatch_stage` 增加 FP 计数与 lane 输出）。
- 上述分类仅对无异常项生效；异常项只消费 RDQ 前缀，由 ROB 队首处理。

## 4. 重命名（FP 域，B15）

### 4.1 新实例

- `backend.sv` 增加 `rename_map_table #(.DOMAIN(RD_FP))`、`free_list #(.DOMAIN(RD_FP))`、`preg_ready_table #(.DOMAIN(RD_FP))`、`physical_regfile #(.DOMAIN(RD_FP))`，容量取 `fp_phys_regs=64`。
- RAT、free list 与 PRF 按 `HAS_ZERO_REG` 门控现有的 x0/p0 特殊处理（`rename_map_table` 的 `!= '0`、`free_list` 从 preg 1 起搜与跳过 p0、`physical_regfile.is_zero_preg`）。FP 实例 `HAS_ZERO_REG=0`：f0 正常重命名，p0 正常分配和读写；ready table 沿用按域取容量的通用分配/写回逻辑，不新增 p0 恒就绪特例。整数实例行为不变。
- `backend.sv` 中其他写死 x0 的地方（`:701` `rename_alloc_valid`、`:1311-1312` bypass 跳过 0、`:1874` `dst_write_en`）改为按目的域判断。

### 4.2 map table 读口与组内依赖

- 每 lane 增加 rs3 读口（FP 实例使用；整数实例可参数化去掉或接 0）。
- 组内 RAW/WAW（`rename_map_table.sv:90-120`）：只在**同域**之间比较；src3 参与 RAW；old_dst 的 WAW 也按域。跨域（例如 lane0 写 x5、lane1 读 f5）不构成依赖。
- 每个源从**自己域**的 map table 读，结果填 `src1_preg/src2_preg/rext.src3_preg`。

### 4.3 资源预算与原子分配

- `rename_stage` 分开整数与 FP 两个 free count；lane 需要哪个域的 preg 由 `rd_dom` 决定。资源前缀判定（`rename_stage.sv:72-123`）对两个域分别累计，任一域不够则从该 lane 起停住（保持现有原子前缀语义）。
- 整数指令不消耗 FP preg，反之亦然。

### 4.4 checkpoint、提交与恢复

- `branch_checkpoint_file` 不改（与域无关）。FP map table 与 FP free list 使用**同一套 checkpoint tag**创建快照/分配记录，mispredict 时同时恢复两个域。
- 提交：ROB 退休项按 `rd_dom` 更新对应域的 committed RAT，`old_preg` 归还对应域 free list（`backend.sv:795-807` 改为按域分流；FP 域不跳过 p0）。
- 全局 flush：两个域都从 committed 状态恢复。

## 5. 派发、发射与读寄存器

### 5.1 IQ 的源域（所有 IQ）

- `backend_issue_queue` 每个源记录域；唤醒总线分为整数与 FP 两组，**只匹配同域的 preg 号**；持续轮询改为查对应域的 ready table。没有该源时（`RD_NONE`）视为就绪。
- 整数 IQ/BR IQ 的源都是 INT，行为不变；MEM IQ 的 src2 在 FSW/FSD 时为 FP 域；FP IQ 的源可能是 INT（W3）或 FP。
- **必测**：FP 域源 `p5` 不能被整数域 `p5` 的写回唤醒，反之亦然。

### 5.2 FP IQ（W2）

- 一个统一 FP IQ，深度 `fp_iq_depth`（12），三源，每拍最多发射 **2** 条，按年龄从老到新选择。
- 选择时检查目标 FU 的 **RegRead 输入槽能接纳**（5.4），两个 FMA 各算一个，DIVSQRT/MISC/CONV 各一个；同一 FU 每拍最多接纳一条。FMA 类可选任一能接纳的 FMA，不能让两个发射 lane 选择同一 FU。
- 含整数源的 FP 指令（FCVT.fmt.{W,WU,L,LU}、FMV.W.X/FMV.D.X）：每拍最多发射 1 条，并须在同拍获得整数 PRF 读授权（W3）；未授权不删除（沿用现有 prf_read_arbiter 合同）。该限制不妨碍另一 lane 发射纯 FP 源指令。

### 5.3 读寄存器

- FP PRF 读口 7 个：0～2 给 FP 发射 lane 0 的 src1～3，3～5 给 lane 1，6 给 MEM 的 FSW/FSD 数据（W4）。FP 发射与 FP PRF 读口固定对应，不需要仲裁。
- 整数源：`prf_read_arbiter` 增加一个 FP IQ 候选（单源 rs1），与 INT/MEM/BR 候选按现有年龄规则竞争。
- FSW/FSD：MEM 发射时只向整数 PRF 申请 rs1；`store_value` 取 FP PRF 读口 6（`backend.sv:1882` 按 `rs2_dom` 选择）。
- RegRead 拍内的 FP 操作同样按分支掩码取消（参照 B12 缺口 2 的 ALU 处理），被取消项不进 FU。
- **唤醒（W5，B33 闭环简化）**：L9 不对 FP FU 做提前唤醒；消费者由实际目的域的 PRF 写口广播唤醒（FP→INT 也一样），依赖 `physical_regfile` 现有的同拍写读旁路。模块头注释写明“B33 提前唤醒对 FP FU 推迟，性能优化时再补”。

### 5.4 IQ → RegRead → FU 的两个接受边界

- 每个已接入 FP FU 在 `backend.sv` 有一个可保持的 RegRead 输入槽；槽保存所选 FU、完整请求控制、操作数与分支身份。槽为空，或其旧请求本拍已被 FU 接受/被取消时，可以接纳新请求；允许同拍出旧入新，以支持连续发射。T07a 仅接 MISC/CONV，FMA/DIVSQRT 无候选、无请求。
- **IQ 接受**：所需源就绪、目标 RegRead 槽能接纳、必要的整数读口已授权且本拍未取消，才从 IQ 删除；该沿同时把控制与读值锁存到目标槽。未握手的候选留在 IQ。
- **FU 接受**：RegRead 槽保持 `req_valid` 与请求数值控制，直到 `req_valid && req_ready`；这次握手才分配 6.1 的在途槽并向 CVFPU 或 FMV 通路交付一次请求。无空闲在途槽、CVFPU 不能接收或 FMV 旁路满时，输入槽继续保持。
- CVFPU `in_ready_o = in_valid_i & fmt_in_ready[dst_fmt_i]`（`fpnew_opgroup_block.sv:84`），依赖当前请求及格式。不能把它直接反馈为 IQ 选择前的通用 FU 空闲信号，也不能让 `req_valid` 等待自身 `req_ready`；由已锁存的 RegRead 请求驱动 valid/格式，ready 只决定它是否完成握手。输入容量与候选选择不得形成组合环。
- 分支正确解析更新 RegRead 的掩码；误预测命中或 `global_flush` 当拍撤销 valid 并禁止 FU 请求握手。身份掩码按解析更新；未取消、未接受期间，操作数、op、格式和 rm 保持。

例：lane 0 的 I2F 未获整数读口时留在 IQ；lane 1 的纯 FP 操作可独立接受。已进入 CONV RegRead 的请求遇到 CVFPU 背压，则保持请求，不重复从 IQ 取出、不提前分配或复用在途槽。

## 6. FP FU（B14）

### 6.1 共同结构（四个 `fpu_*_fu.sv`）

- **来源（W1，用户指定）**：以 `https://github.com/RanxiChen/cvfpu.git` 添加 git submodule `third_party/cvfpu`，父仓库 gitlink 固定 **`1b220f3bc89df99e246b72e3574a3a533cf87653`**；不复制源码，不跟踪 branch HEAD，不用 `submodule update --remote`。保留子模块及嵌套依赖的原许可证、版权声明，子模块工作树不得有源码修改。
  - 本级必需的嵌套依赖为 `src/common_cells`，其 gitlink 固定 **`6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea`**；按 CVFPU 父提交的 gitlink 初始化，不自行升级。`src/fpu_div_sqrt_mvp` 与 `tb/flexfloat` 不在 Flow 的 THMULTI 文件清单内，本级不要求初始化；以后确需它们时也只能用父提交记录的版本。
  - 在父仓库新增 `third_party/CVFPU.md`：记录来源 URL、上述完整 SHA、所用文件清单与初始化步骤。RTL 编译集合参照 Flow **`7dfa75c4eca1bd68cd82780508cc8eb84659e835`** 的 `design/src/main/resources/vsrc/fpnew/cvfpu-files.f`，加入 `rtl/rtl.f`（含 `+incdir+`）。复用包装配置或译码映射时从该固定 Flow 提交读取，不使用可能变化的工作树 HEAD。
  - Alan 在每个独立运行目录按同一 gitlink 初始化 CVFPU 和必需嵌套依赖；GitHub 访问仍按 agent.md 3.1 走反向代理。缺依赖时不能靠删文件清单或禁用 FU 通过门禁。
  - Verilator 兼容豁免仅限固定 CVFPU 的已知 `BLKANDNBLK` 及对应 `fpnew_*.sv` 路径（参照 Flow `sim/verilator/cvfpu.vlt`）；不屏蔽 O3 包装或其他错误。所有 lint/仿真编译入口加载同一豁免；`scripts/lint.sh` 仍须 0 errors。
- **例化**：每个 FU 直接例化一个 `fpnew_opgroup_block`，参数取固定 Flow 配置（`FlowFpnewWrapper.sv:37-58`）对应 opgroup 的那一行：Width 64、**EnableVectors=0**、RV64D 格式掩码（FP32/FP64）、IntFmtMask INT32/INT64、DivSqrtSel THMULTI、PipeConfig DISTRIBUTED；ADDMUL PipeRegs `{3,4,…}` PARALLEL，DIVSQRT 2 MERGED，NONCOMP 1 PARALLEL，CONV 4 MERGED。`vectorial_op_i=0`，`simd_mask_i='1`，`flush_i=0`。
- **NaN-box 输入检查**：按 `fpnew_top.sv:84-97` 在包装内计算 `is_boxed[FP32][op] = (operand[op][63:32] == 32'hFFFFFFFF)`，FP64 恒 1，送入 `is_boxed_i`。输出的 boxing/整数扩展已在 slice 内完成（`fpnew_opgroup_fmt_slice.sv:271`、`multifmt_slice.sv:437-482`），包装不再处理。
- **侧表与 tag（W6）**：每个 FU 有 `S` 个在途槽，fpnew 的 `tag` 为槽号。槽保存 `fu_tag_t`（ROB 号、目的域、目的 preg、分支掩码）与 `killed` 位。
  - **仅 FU 请求握手时分配**；选择空闲槽号作为 CVFPU/FMV 的请求 tag，无空闲槽时回压 RegRead。正确解析清对应掩码位；误预测把命中的槽标 `killed`；包装新增 `flush_all_i`，全局 flush 标记所有有效槽 killed。CVFPU 原生 `flush_i` 恒 0；系统复位另经 reset 口同时清两端，见下条。
  - 槽从请求接受起保留，直到活结果写回握手，或 killed 结果完成最终丢弃。进入结果保持槽不是释放点；误预测/全局 flush 也不能直接清空侧表或复用未返回的槽。ROB/preg 可被恢复路径复用，但旧结果只能按侧表 killed 丢弃。
  - 包装与 CVFPU 用同一系统复位清除状态；普通恢复不能只复位包装而保留 CVFPU 在途结果。依据“不提前复用、每个请求只终结一次、复位同时清两端”的不变量，本级只用槽号即可，不强制代际位；返回 tag 必须命中有效槽，不得接受重复终结。
  - `S` 取 `fpu_inflight_slots`，必须能在途多条；默认值可由实现调整并报告。容量预算含算术流水、FMV 旁路和结果保持槽；背压可降低吞吐，不能宣称仅按内部算术级数已证明整条包装每拍接收一条。
- **结果保持**：每个 FU 包装有一个共同结果保持槽，保存 `slot_id/result/fflags`。CVFPU opgroup 的格式出口仲裁未开启 `LockIn`，背压时可换候选；因此只能在 `out_valid && out_ready` 时捕获，不能将其原始出口直接当作 O3 的稳定写回候选。保持槽为空或旧项本拍终结时可接纳一个新结果；满且未终结时回压活 CVFPU 结果。killed 的原始出口结果直接握手丢弃并释放其侧表槽，无需占用共同保持槽。
- **取消优先于交付**：出口与保持槽都按 `killed_now = slot.killed || flush_all_i || br_killed(slot.br_mask, resolution_i)` 组合过滤；本拍命中立即禁止写 PRF、置 ready、广播及 ROB complete，不等下一拍 killed 寄存器更新。分支解析的掩码维护覆盖 RegRead 和所有侧表有效槽；保持槽用 `slot_id` 查询当前身份，不能永久保存未更新的分支掩码副本。同拍出旧入新时分别检查两笔身份。
- **输出**：共同保持槽的 `fpu_resp_t` 按侧表当前 `tag.dst_dom` 送 FP 写回（7.1）或整数写回 extra 槽（7.2）；数值结果、fflags 与目的身份保持到授权，分支掩码按解析更新。killed 保持项直接丢弃，不报告完成；全局 flush 还必须使所有写回仲裁在该拍禁止 grant/complete（包括 FP load）。

### 6.2 操作映射

fpnew `operation_e`、`op_mod`、格式与操作数排列沿用 Breeze（`fpu/BreezeFp.scala:131-222`，`backend/BreezeBackend.scala:341-350`）：

| 指令 | FU | op | op_mod | 操作数 A / B / C | 格式 |
| --- | --- | --- | --- | --- | --- |
| FMADD / FMSUB | FMA | FMADD | 0 / 1 | rs1 / rs2 / rs3 | src=dst=fmt |
| FNMSUB / FNMADD | FMA | FNMSUB | 0 / 1 | rs1 / rs2 / rs3 | |
| FADD / FSUB | FMA | ADD | 0 / 1 | 0 / rs1 / rs2 | |
| FMUL | FMA | MUL | 0 | rs1 / rs2 / – | |
| FDIV / FSQRT | DIVSQRT | DIV / SQRT | 0 | rs1 / rs2 | |
| FSGNJ{,N,X} | MISC | SGNJ | 0 | rs1 / rs2 | rm = funct3（0/1/2） |
| FMIN / FMAX | MISC | MINMAX | 0 | rs1 / rs2 | rm = funct3（0/1） |
| FLE / FLT / FEQ | MISC | CMP | 0 | rs1 / rs2 | rm = funct3（0/1/2），结果写整数 |
| FCLASS | MISC | CLASSIFY | 0 | rs1 | 结果写整数 |
| FCVT.S.D / D.S | CONV | F2F | 0 | rs1 | src = rs2 字段，dst = fmt |
| FCVT.{W,WU,L,LU}.fmt | CONV | F2I | rs2[0] | rs1 | int_fmt = rs2[1] ? INT64 : INT32 |
| FCVT.fmt.{W,WU,L,LU} | CONV | I2F | rs2[0] | rs1（整数） | 同上 |
| FMV.* | CONV | 不经 fpnew | | | 6.3 |

- SGNJ/MINMAX/CMP 用 rm 字段选择子操作，这些指令的 rm 不是舍入模式，不受 2.3 的 DYN 检查（它们没有 DYN 编码）。
- FCVT.W[U] 的结果在 CVFPU 内已符号扩展到 64 位（`fpnew_cast_multi.sv:528,846`）。
- `fpu_req_t` 明确携带 `src_fmt/dst_fmt/int_fmt`；由译码扩展字段沿 rename/RDQ/IQ/RegRead 传递，包装不从被当成寄存器值的 rs2 重新猜格式。`op_mod` 按本表从 fp_op 或整数转换无符号属性生成。

### 6.3 FMV（CONV/MOVE 包装内位搬运，B14）

- FMV.X.W：`{{32{src[31]}}, src[31:0]}`；FMV.X.D：原样；FMV.W.X：`{32'hFFFFFFFF, src[31:0]}`；FMV.D.X：原样。fflags=0。
- 走包装内一个可保持的 1 拍旁路槽；FMV 请求握手同时分配侧表槽、锁存原始位搬运结果与 slot_id。旁路槽满且旧项不能移出/丢弃时不接新 FMV；不经过 fpnew 的输入 NaN 替换。
- 旁路槽与 CVFPU 出口竞争 6.1 的共同结果保持槽，一拍至多接纳一个活结果。两者均有效时轮转授权，未授权者保持/回压；killed 项优先丢弃。两路及共同保持槽共享同一侧表寿命合同；这种局部轮转不改变写回端的 ROB 年龄优先规则。

### 6.4 各 FU 小结

| FU | 个数 | 内部流水配置（不含 O3 RegRead/结果保持，未在 O3 实测） | 占用 |
| --- | --- | --- | --- |
| FMA | 2 | FP32 3 拍，FP64 4 拍 | 全流水；同一 FU 内 S/D 可能乱序返回（槽号区分） |
| DIVSQRT | 1 | 2 拍 + 迭代（C910 vfdsu，拍数待测） | 一次一条 |
| MISC | 1 | 1 拍 | 全流水 |
| CONV/MOVE | 1 | 4 拍（FMV 1 拍） | 全流水 |

## 7. 写回与完成

### 7.1 FP 写回（`fp_writeback_arbiter.sv`）

- 源 6 个：FMA0、FMA1、DIVSQRT、MISC（FP 目的）、CONV（FP 目的）、FP load。写口 `fp_prf_write_ports=2`。按 ROB 年龄从老到新授权（与 `writeback_arbiter.sv:115-133` 同规则）。
- 授权那拍：写 FP PRF、置 FP ready table、广播 FP 唤醒、通知 ROB complete（带 fflags）。取消过滤与整数写回仲裁相同。
- `flush_all_i` 当拍禁止所有活结果 grant/complete；分支误预测命中的候选同拍过滤。被取消结果由生产者丢弃，不能把消费当成 ROB complete。

### 7.2 写整数的 FP 结果

- MISC 的 FEQ/FLT/FLE/FCLASS → `writeback_arbiter.extra_src_i[2]`；CONV 的 FCVT.{W..}.fmt、FMV.X.* → `extra_src_i[3]`（这两个槽已预留）。`wb_req_t.fflags` 填真实值。
- **rd = x0 时**（例如 `feq.d x0, f1, f2` 置 NV）：不写 PRF，但必须完成 ROB 项并带上 fflags。
- 整数仲裁的 extra 完成输出必须携带同笔结果的真实 fflags；无目的写入的活结果可直接终结，不等待 PRF 写口。它仍受同拍取消和全局 flush 过滤；只门控 PRF 写使能而保留旧 ROB complete 不足以保证安全。

### 7.3 ROB

- `meta_q.rd_dom` 改为 `t_alloc_ext_i[lane].rd_dom`（`rob.sv:319`）。
- 每个完成口带 5 位 fflags（非 FP 源接 0），写入该项；退休输出 `t_commit_o[].fflags`。可以复用现有 `t_fflags_*` 端口，也可以并入完成口，由实现选择。
- 结果和 fflags 的 ROB 索引、有效位及接受拍必须一致；分配新 ROB 项时 fflags 清 0。两条 FP 结果同拍完成分别记账，实际多 lane 退休才 OR 合并，不能在写回时写架构 fflags。
- 完成口宽度增加 2 个 FP 写回口；FP load 经 FP 写回完成；整数 load 仍走原 load 完成口。
- `retire_info_o`：FP 目的的退休项 `rd_write_en=0`（不把 FP 数据冒充整数写回）。`fp_valid/fp_rd/fp_wdata` 不要求填写（第 11 节）。
- 上述抑制仅作用于观察接口；`rob_commit_t.rd_write_en`、退休 RAT/free list 与 Dirty 判断仍保存真实 FP 写入，包括 f0，不能随退休轨迹一起清零。

## 8. 访存（FLW/FLD/FSW/FSD，接现有 LSU）

- `mem_execute_uop_t` 与 `load_result_t` 增加目的域（或 `is_fp` 位），并沿 LSU 的 pending 寄存器（`load_store_unit.sv:469-473`）传递。
- FLW：`format_load` 的两个调用点（`:491-493` DCache 响应、`:511-512` SQ 转发）对 FP 4B 返回 `{32'hFFFFFFFF, raw[31:0]}`；FLD 8B 原样。
- FP load 结果送 FP 写回源（7.1），不送整数 `writeback_arbiter`；`dst_write_en` 对 FP 目的恒为 1（f0 可写）。
- FSW/FSD：数据来自 FP PRF（5.3），`mem_size` 4/8B，SQ/提交/drain 不变（B15“进入既有 SQ，遵守 B05”）。FSW 只存低 32 位，不检查 boxing。
- 不改 DCache、SQ、LQ 的任何其他行为；不跑访存类 cocotb（L8 前）。

## 9. 前端：浮点 RVC 与 C.LUI

- `rvc_expander.sv` 放开 C.FLD（Q0 funct3 001）、C.FSD（Q0 101）、C.FLDSP（Q2 001）、C.FSDSP（Q2 101），展开为 FLD/FSD（立即数编码同 C.LD/C.SD、C.LDSP/C.SDSP 的 8 字节缩放；参考 Breeze `frontend/BreezeCompressedDecoder.scala:57,61,95,105`）。C.FLDSP 的 rd 可以为 0（f0 合法），与 C.LDSP 的 `rd!=0` 不同。
- FS Off 时这些展开结果在 rename 入口判非法（2.3），tval 为 16 位原编码零扩展。
- **C.LUI 合法性修正**：nzimm 判定改为 `{c[12], c[6:2]} != 0`（现为 `|c[12:2]`，含 rd 位；Flow `AirRvcDecompressor.scala:114` 原样带有此缺陷）。保留编码 nzimm=0 应非法。

## 10. 类型、端口与配置汇总

- `o3_cfg_pkg`：`fp_prf_read_ports` 6→7；`fpu_inflight_slots` 视 6.1 调整；`fp_iq_depth`、`fp_prf_write_ports` 保持；注释里的“待定”改为本 spec 决定。
- `o3_types_pkg`/`o3_pkg`：`uop_ext_t` 补 `uses_arch_rm/fp_src_fmt/fp_int_fmt/fp_unsigned`，`fp_fmt` 继续表示目的浮点格式；`fpu_req_t` 的单一 fmt 改为 `src_fmt/dst_fmt` 并增加 `int_fmt`（32/64 位）。公共整数格式枚举不依赖 fpnew package，包装负责转换为 fpnew 编码。现有 `fp_op_e` 不需重复扩展四种 fused 操作。
- `mem_execute_uop_t`、`load_result_t` 增加目的域并在 replay/pending/结果槽传递；IQ 项三源与源域；ROB 完成口 fflags。
- 新端口：`rename_map_table` rs3 读口；`rename_stage` FP free count 与 src3 映射；`dispatch_stage` FP 输出；`backend_issue_queue` 分域 ready/唤醒、三源、双发射与目标 RegRead 容量；`prf_read_arbiter` FP 整数源候选；四种 `fpu_*_fu` 增加 `flush_all_i`；两个写回仲裁显式接全局 flush，整数 extra 完成路径携带 fflags；`rob` FP 完成口；`commit_ctrl.fp_retire_o` 与 `csr_file.fp_retire_i/frm_o/fs_o` 接通。
- `backend.sv` 接 Rename 入口异常预处理、各 FP FU 的 RegRead 槽、FP PRF 和分域写回；取消覆盖 RegRead、FU 侧表及出口。类型/端口改变在实现报告与 `doc/LOOP.md` 记录。
- 设计基线未定的容量（FP IQ 组织、读写口数）由本 spec 第 5 节与 W2～W4 确定；不改 Dxx/Bxx。

## 11. 不做

- Zfh/Zfa/Zfinx、向量；FP 的 S/U 视图（sstatus.FS、SD 的 S 模式行为在 L10）。
- FP 提前唤醒（W5）；FU 内部选择性 kill；FP 性能事件（`perf_o` 不扩展）。
- `retire_info` 的 `fp_valid/fp_rd/fp_wdata` 与 Spike 的 F/D 比对（Spike ISA 串不改；FPGA 前不跑）。
- ACT4 RV64GC、riscv-tests；综合；访存类 cocotb；DCache/SQ/LQ 其他改动。
- DIVSQRT 迭代拍数优化；FMA S/D 共享数据通路。

## 12. 验收（少量定向用例）

用户原则：每个新行为一个简单定向用例，不新增大规模随机/Spike/ACT4 门禁。期望值可用主机 Python（`struct`、`fractions`）计算或取 IEEE 754 熟知值，在测试里写死并注明来源；现有测试、断言及期望不因失败而削弱或删除。

实现阶段允许 lint 通过后的开发提交与 push，以便 Alan 在精确 SHA 上验证；**正确性门禁失败阻塞本步验收及进入下一步**，不把开发提交视为已通过。已有基线失败保存原始证据、与本次新增回归区分；不擅自改任务范围修后级问题。详细提交/验收顺序见任务书“共同规则”。

| 位置 | 用例 |
| --- | --- |
| `sim/cocotb/decoder`（改） | 指令表编码/域/源读使能，四种 fused 操作现有枚举；rm 5/6 非法；F2F 源/目的格式与 W/WU/L/LU 控制字段；FP load/store 的立即数高位不受 fmt 检查；T07a 的 FMA/DIVSQRT 非法、T07b 合法 |
| `sim/cocotb/csr_file`（改） | FS/frm/fflags 复位；fflags/frm/fcsr 读写与别名；frm 写 5 读回 5；FS Off 时三个 CSR 非法且不修改状态；仅读取且写入被抑制时不置 Dirty；写浮点 CSR 置 Dirty、SD；`fp_retire` 合并 fflags 并置 Dirty；misa 按 T07a/T07b 的实现版本检查 |
| `sim/cocotb/rename_map_table`、`free_list`（改） | FP 实例：f0 正常重命名、p0 可分配；整数实例原测试保留 |
| `sim/cocotb/rename_stage`（改） | 四 lane 混合域：组内同域 RAW（含 src3）、跨域不依赖；FP preg 不足时从该 lane 停住 |
| `sim/cocotb/backend_issue_queue`、`prf_read_arbiter`（改） | 同号不同域不误唤醒；三源就绪后才发射；每拍最多一个整数源 FP 候选，读口拒绝不删除且另一纯 FP lane 可推进；目标 FU 不重复选择；T07b 两个 FMA 同拍接纳 |
| `sim/cocotb/backend_control` / `backend`（改，按合同选择 harness） | FS Off 的 FLD/FSW 不分配 preg/LQ/SQ、不入 IQ；原有异常 cause/tval 保留；CSR 写后年轻 FP 使用新 FS/frm；异常参与入口截断；RegRead 请求背压保持且只接受一次、取消当拍禁止 FU 接受；FP RAT/free list 同域恢复 |
| `sim/cocotb/physical_regfile`、`preg_ready_table`（扩展或新增） | FP p0 可写；同拍写读旁路；真实写口授权才置 ready，重新分配清 ready；整数实例原测试保留 |
| `sim/cocotb/fpu_fu`（新，参数选择 FU） | 共同结构：请求/结果背压，活结果保持稳定，结果到达同拍误预测不交付，老请求保留/年轻丢弃，全局 flush 后槽留到迟到结果终结、复位同时清两端；FMA：fadd.s boxing、未 boxing 输入按 NaN、fmadd.d 一例、连续 4 条背靠背、混合 S/D 出口背压；DIVSQRT：fdiv.d、1/0 的 DZ、sqrt(−1) 的 NV；MISC：fsgnjn、fmin 含 NaN、flt 遇 sNaN 的 NV、fclass；CONV：fcvt.w.d 负数符号扩展、fcvt.d.l、fcvt.s.d、FMV.X.W 符号扩展、FMV.W.X boxing、FMV 与转换结果同时就绪且背压 |
| `sim/cocotb/fp_writeback_arbiter`、`writeback_arbiter`、`rob`、`commit_ctrl`（扩展或新增） | 两个 FP 写口同拍 grant/complete，各自 fflags 不串项；FP→x0 不写 PRF但完成并保留 flags；全局 flush/误预测同拍禁止被取消项 grant/complete；ROB 复用清 flags；实际退休多 lane OR 合并；FP 退休观察抑制不影响真实 FP 写入/Dirty |
| `sim/cocotb/rvc_expander`（改） | C.FLD/C.FSD/C.FLDSP/C.FSDSP 各一例；C.LUI nzimm=0 非法 |
| 整核 `sim/o3/tests/l9_fp.S`（新，`-march=rv64imfdc_zicsr -mabi=lp64`，tohost 自查） | 见 12.1；Makefile 目标 `run-l9-fp`，`L9_T07A=1` 对应编译宏 `-DT07A`，默认完整 T07b；均带 `+L7_CHECK`，不带 `--spike` |
| 回归 | `run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`、`run-l7-predict`、`run-l7b-rvc`；L7a/L7b 全部 cocotb 与 `commit_ctrl`、`rob`、`mdu`、`fu_completion_fifo` 等非访存 cocotb；`scripts/lint.sh` 0 errors |

### 12.1 整核程序 `l9_fp.S`

- 统一 trap 处理：仅在“期望 trap”标志置位、`mcause == 2`、`mepc` 与 `mtval` 匹配该用例的故障 PC 和原指令时，清标志并跳到预存的续行地址；否则 fail。**不使用 MRET**（避开 [T03 报告](../tasks/O3-T03-report.md) 已知超时；本级不验证 MRET 返回路径）。
- 主体代码用 `.option norvc` 防止汇编器把 T07a 普通 FP 访存自动压成尚未实现的 C.FLD/C.FSD；仅 T07b 的显式 RVC 测试块临时启用 `.option rvc`。T07a 裁剪所有 FMA/DIVSQRT 与浮点 RVC 执行块，并检查 misa 未设 F/D；T07b 检查 F/D 已设。
- 依次：
  1. 复位后检查 FS=Off；分别执行 `fsgnj.d`、FLD、FSW → 期望非法 trap，store 地址使用哨兵值确认无写入；打开 FS（Initial），检查 mstatus.FS==1。T07b 另测一条 FP RVC 在 Off 时的原 16 位 mtval。
  2. FLD/FSD、FLW/FSW、T07b 的 C.FLD/C.FSD/C.FLDSP/C.FSDSP 往返（含 f0）；FLW 后 `fmv.x.d` 检查高 32 位全 1。**分别**先把 FS 设为 Clean，再单独执行 FLD、FLW、FMV.W.X，各自立即读 mstatus 确认 Dirty/SD；不能在多种 FP 写入之后只查一次 Dirty。
  3. FMV.X.W 符号扩展、FMV.W.X boxing、FSGNJ/FMIN/FMAX/FEQ/FLT/FLE/FCLASS、FCVT 各一例（含 W 结果负数）。
  4. **仅 T07b**：FADD/FSUB/FMUL/FMADD/FMSUB/FNMSUB/FNMADD/FDIV/FSQRT 的 S、D 各若干，比较结果位模式。
  5. fflags：**两步均测**清零后 `feq.d x0` 遇 sNaN，读回 NV=0x10，并确认无整数目的写入也能继续执行。**仅 T07b** 清零后做 1.0/3.0（NX）、1.0/0.0（DZ）、sqrt(−1)（NV），读回 0x19。T07a 不执行开方/除法，也不要求 0x19。
  6. 动态舍入：同一 DYN 运算在 frm=RTZ 与 RNE 下结果不同（T07a 可用 `fcvt.w.d` 对 2.7：RNE→3、RTZ→2）；静态 rm 指令不受 frm 影响；frm 写 5 后执行一条 DYN 指令 → 期望非法 trap。
  7. 依赖链与恢复：**T07a** 用 MISC/CONV、FLD 与依赖分支检验源域和恢复；**T07b** 增加 ≥50 次含 FMA 链、FDIV 的循环，误预测路径有 FP 运算与 FLD，校验累加结果位模式。另设小用例：先清 fflags 再把 FS 设为 Clean，错误路径的 FPR 写入与产生 NV 的操作均不得改变最终 fflags/FS；读取状态前不能插入正常路径 FPR 写入或浮点 CSR 写入掩盖结果。背压、同拍取消、全局 flush 后 ROB/preg 复用及迟到返回由第 12 节 harness 作确定性验证，不只依靠循环碰到。
- 全部通过写 tohost=1。验收结论为本阶段的定向浮点闭环；完整 F/D ISA 比对、MRET 返回、PPA/FPGA 仍为未运行。

## 13. 审核后的决定（2026-10-07）

| 编号 | 问题 | 本版采用 | 理由 / 边界 |
| --- | --- | --- | --- |
| W1 | CVFPU 怎么进仓库 | **git submodule** `third_party/cvfpu`，固定 fork URL 与完整 gitlink SHA，必需 common_cells 也按父 gitlink 初始化；源码不改 | 用户明确选择；来源、依赖、许可证保留在原子模块，版本记录见 6.1；不使用复制方案或跟踪远端 HEAD |
| W2 | FP IQ 组织与发射宽度 | 一个统一 FP IQ（12 项、三源），每拍最多 2 条 | 提供两 FMA 所需双发射带宽；单发射仍可交替使用不同 FMA，但不能同拍发两条。同一 FU 不重复接纳 |
| W3 | 整数源 FP 指令（I2F、FMV.W.X）从哪读整数源 | 留在 FP IQ，向 `prf_read_arbiter` 申请一个整数读口，每拍 ≤1 条 | 备选：给 FP IQ 专用整数读口（整数 PRF 读口变多）；或拆成两条 uop（改动更大）。这类指令少，共享仲裁够用 |
| W4 | FSW/FSD 的数据从哪读 | FP PRF 第 7 个读口专给 MEM | 备选：与 FP IQ 共享 6 口加仲裁。专口无仲裁、最简单；资源问题留到 L11 综合 |
| W5 | FP 是否做提前唤醒（B33） | 不做，按实际目的域 PRF 写回唤醒（闭环简化） | FMA 有 S/D 两种延迟且可背压，做提前唤醒需完成 FIFO 与信用；先完成后完美 |
| W6 | 取消机制 | 侧表 killed、共同结果保持槽、出口丢弃；新增包装/写回全局 flush 口，CVFPU `flush_i` 恒 0 | 同拍取消优先交付；槽留到请求终结，结果到保持槽不释放；仅槽号的安全不变量见 6.1，系统复位同时清两端 |
| W7 | FS Off 与 DYN rm 在哪检查 | Rename 入口组合预处理、异常参与 entry gate 截断；实际接受时携带解析后的 rm | B22 阻止更老 CSR 未退休时年轻 FP 进入 Rename；被阻塞项重新检查，完整撤销新异常的执行/访存资源语义 |
| W8 | frm 写入 5～7 | 照存，带架构 rm 的 DYN 指令使用时报非法；静态 5/6 也报非法 | 本项目选择现行规范允许的异常行为，不能说这是现行规范唯一强制行为；SGNJ/MINMAX/CMP 不查 DYN |
| W9 | 复位时 FS | Off；frm=RNE，fflags=0 | 明确本项目复位合同，固件负责打开；改变 FS 不清浮点数据 |
| W10 | FS Dirty 的触发 | 任何写 FPR 的退休（含 FLD/FMV.W.X）+ 非零 fflags + 写浮点 CSR | 就是 B40 原文；明确写出是因为 Breeze 漏了 load/FMV |
| W11 | C.LUI nzimm 判定缺陷 | 顺带修（T07b 改 rvc_expander 时） | 一行修改；保留编码当前被误收为 LUI |
| W12 | 任务拆分 | T07a（CSR/FS、译码、FP 重命名/PRF/IQ/写回、FLW/FLD/FSW/FSD、MISC 与 CONV FU）→ T07b（FMA×2、DIVSQRT、浮点 RVC、C.LUI、完整 `l9_fp.S`）；实施获授权后连续执行 | T07a FMA/DIVSQRT 暂译非法、misa 不宣告 F/D；NV 由 sNaN 比较测试。开发提交用于 Alan 验证，每步在最终推送 SHA 上通过门禁才验收/推进 |
