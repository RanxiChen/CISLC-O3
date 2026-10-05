# O3-T02 Spike lockstep 规格（阶段一，未冻结）

## 1. 范围、状态与引用约定

2026-10-05；分支 `feat/L1-closure`；仓库源码审查锚点为任务书提交
`26c8a5d`（完整 SHA 见阶段一报告）。本文件只交付设计审查材料，未实现比对器，
未建立 L5/Spike 通过证据。阶段二必须等用户宣布冻结。

依据：`doc/O3-v1-plan.md:23–34,47`、后端基线
`doc/design/CISLC-O3-BACKEND-DESIGN-BASELINE.md:687–691`、
`doc/tasks/O3-T02-spike-lockstep.md:9–19,25–37,43–60`。
已定：进程内链接 `libriscv`；每条 DUT 退休对应一条 Spike 指令；按退休 lane
顺序比较；首个差异停止；保留固定期望 checker；前 32 条历史；随机验收至少
200 个种子、每种子至少 2000 条退休。本任务不实现新执行行为、CSR、异常、中断、
M/A/F/D、RVC 或 MMU。

以下区分三类：**现状**均有源码行号；**合同要求**来自任务书；**待确认草案**
只用于展示可审阅的具体选项，不是已定实现。所有没有被既有设计覆盖的选择统一
列入 §8；阶段二不得将草案直接当作授权。未实测的构建、链接和运行能力均为“未确认”。

`S:` 表示官方 Spike 源码，全部固定在
[`609dbe0b9994154833039209fa37151e7c05e9d4`](https://github.com/riscv-software-src/riscv-isa-sim/tree/609dbe0b9994154833039209fa37151e7c05e9d4)。
例如 `S:riscv/processor.h:251` 指该提交中的源文件行号；不引用浮动 master。
本轮只下载到 `/tmp/o3-t02-spike-source` 并阅读，未修改 Spike 源码，也未编译安装。

## 2. Spike 版本、构建和 API 审查

### 2.1 固定版本与 Alan 构建草案（Q1）

源码审查已固定到上述完整 SHA；是否将它冻结为实际链接版本，**未确认**。
官方声明 C++ 内部接口不属于稳定公共 API（
[S:README.md:99–102](https://github.com/riscv-software-src/riscv-isa-sim/blob/609dbe0b9994154833039209fa37151e7c05e9d4/README.md#L99-L102)）。
下文“可调用”指头文件中 C++ `public` 接口，不代表上游稳定性承诺。

任务书指定安装到 Alan `cislc-o3` conda 前缀；仓库记录为
`/home/chen/miniforge3/envs/cislc-o3`（`sim/o3/README.md:5–14`）。
拟采用原版源码、默认小端构建，configure 仅给 `--prefix`，运行时配置 RV64I；
原版默认 C++ 标准为 `-std=c++2a`（`S:Makefile.in:96–97`），
需要 DTC（`S:configure.ac:59–65`）；依赖说明见 `S:README.md:110–115`。
具体宿主编译器、Boost/DTC/pkg-config 是否已在 Alan 环境中可用，**未确认**。

以下是冻结后在 Alan 执行的命令草案，阶段一**未运行**：

```sh
source /home/chen/miniforge3/etc/profile.d/conda.sh
conda activate cislc-o3
O3_SPIKE_SHA=609dbe0b9994154833039209fa37151e7c05e9d4
O3_SPIKE_SRC=/tmp/cislc-o3-spike-src
O3_SPIKE_BUILD=/tmp/cislc-o3-spike-build
git clone https://github.com/riscv-software-src/riscv-isa-sim.git "$O3_SPIKE_SRC"
git -C "$O3_SPIKE_SRC" checkout --detach "$O3_SPIKE_SHA"
test "$(git -C "$O3_SPIKE_SRC" rev-parse HEAD)" = "$O3_SPIKE_SHA"
test -z "$(git -C "$O3_SPIKE_SRC" status --porcelain)"
mkdir -p "$O3_SPIKE_BUILD"
cd "$O3_SPIKE_BUILD"
"$O3_SPIKE_SRC/configure" --prefix=/home/chen/miniforge3/envs/cislc-o3
make -j2
make install
```

拟按原版默认优化选项构建，不凭旧版本经验添加 `--enable-commitlog`；该提交
的日志由 `enable_log_commits()` 开启（`S:riscv/processor.cc:148–152`）。
上述构建是否成功、实际库依赖、安装文件及 ABI，均待 Alan 实证。
阶段二应将完整 SHA、宿主版本、实际 configure/编译命令、依赖清单、库 SHA256
记录到任务书允许的 `sim/o3/README.md` 或 `sim/alan-env.yml`。

### 2.2 链接草案（Q1）

当前 Verilator 命令只编译 top 与 `main.cpp`，开启 `ENABLE_RETIRE_INFO`，
尚未链接 Spike（`sim/o3/Makefile:9–24`）。
原版安装 `sim.h`、`processor.h`、`devices.h` 等头文件和共享库
（`S:riscv/riscv.mk.in:4–14,18–49`）；共享库构建带上子项目归档依赖
（`S:Makefile.in:247–255`）。`riscv-riscv.pc` 提供 include、`-lriscv` 和 rpath
（`S:riscv-riscv.pc.in:1–10`）。

待确认草案：用 conda 前缀的 pkg-config 元数据向 Verilator `-CFLAGS` 传入
`-std=c++20` 与 include，向 `-LDFLAGS` 传入该库的链接与 rpath；如果适配器直接
引用 FESVR 符号，核验并补充对应库依赖。必须保证最终二进制加载的是固定 SHA
生成的库，不能从系统目录意外加载另一版本。准确 flags、是否需要额外 `-lfesvr`
以及环境可重建性，**未确认**；先做 Alan 最小链接/单步自测，再建整核门禁。

### 2.3 对象创建、加载与单步可调用接口（Q1、Q2）

| 动作 | 源码已确认的接口/行为 | lockstep 使用草案及限制 |
|---|---|---|
| 配置 | `cfg_t` 提供 `isa/priv/endianness/mem_layout/start_pc/hartids`（`S:riscv/cfg.h:77–100`）；`start_pc.set_global()`（`S:riscv/cfg.cc:53–56`） | 单 hart 0、`isa="rv64i"`、小端、起始 PC 与 DUT 相同；保持已定 M/Bare（`doc/spec/l3-closure-spec.md:260`），用户指令集不等于切换到 U 特权态；参考端 PMP/trigger 的具体初始化接口与配置待 Q2 |
| 创建内存 | `mem_t(size)`、`store(offset,len,bytes)`、`load(offset,len,bytes)`（`S:riscv/devices.h:56–65`）；地址按区内 offset 处理并检查边界（`S:riscv/devices.cc:116–134`） | AXI 区 `(base=0x80000000,size=0x100000)`；初始化 bytes 与 DUT 同源，运行后 Spike 内存独立维护；legacy 区域待 Q6/Q7 |
| 创建模拟器 | `sim_t` 完整签名（`S:riscv/sim.h:33–42`） | 传入 cfg、未 halt、memory pairs、空插件、禁用 DTB discovery/DTB/socket、无命令文件/指令限额的参数草案；cfg、内存、日志生命周期覆盖模拟器 |
| 创建处理器 | 无 DTB 分支内部 `new processor_t(...)`、添加内存、设置起始 PC（`S:riscv/sim.cc:105–121`）；独立构造签名（`S:riscv/processor.h:237–240`） | 由 `sim_t` 创建，取 `get_core(0)`（`S:riscv/sim.h:61`）；不额外创建重复 hart；模拟器析构删除其 procs（`S:riscv/sim.cc:345–350`） |
| 装入 ELF/HEX | DUT 已有 ELF64 PT_LOAD/BSS 和 HEX loader（`sim/o3/main.cpp:131–216`）；Spike `htif_t::load_program()` 为 protected（`S:fesvr/htif.h:55–67`），public `start()` 会加载并 reset（`S:fesvr/htif.cc:94–109`） | 推荐共用现有 loader 的规范化 bytes，调用所持 `mem_t::store(addr-base,...)` 预装；拟以 `args={"none"}` 避免 HTIF 自动装载。是否采用此方式或 HTIF start 路径待 Q2；不能假设 `sim_t` 构造即已加载程序 |
| 单步 | `processor_t::step(size_t)` 可调用（`S:riscv/processor.h:251`）；`sim_t::step` 是 private（`S:riscv/sim.h:83,107–108`） | 每条退休使用 `sim.get_core(0)->step(1)`，禁止调用 private 接口、改访问控制或修改 Spike |
| PC、指令 | `get_state()->pc`（`S:riscv/processor.h:258,85`）；`get_mmu()->load_insn(pc).insn`（`S:riscv/processor.h:257`、`S:riscv/mmu.h:355–357`） | 单步前取 Spike 自己的 PC/编码，不能拿 DUT 指令填参考侧。此预取会进入 Spike 取指路径；仅限本任务无副作用 RAM 场景，采用方式待 Q2 |
| 整数寄存器 | `state_t::XPR`（`S:riscv/processor.h:85–87`），`operator[]` 和 x0 禁写（`S:riscv/decode.h:226–245`） | 单步后读 XPR；写回事件还需 commit log，不能仅靠前后寄存器值变化判断是否写回（同值写回也必须检测） |
| 日志开关 | public `enable_log_commits()`（`S:riscv/processor.h:248`）或 `sim.configure_log(false,true)`（`S:riscv/sim.h:50–54`、`S:riscv/sim.cc:406–415`） | 调用后读取内部日志；默认不开日志（`S:riscv/processor.cc:37–40`）。日志文件路径可传构造函数；空路径会写 stderr（`S:riscv/log_file.h:10–31`），不能假设仅收集结构而不输出文本 |

单步不是“每次调用必定成功退休”的保证：`step()` 内部处理 trap 并返回，WFI
也可提前返回（`S:riscv/execute.cc:277–284,317–320`）。拟检查单步前后
`minstret` 增量为 1，并独立保存单步前 PC/编码；计数更新见
`S:riscv/execute.cc:355–361`，读取接口见 `S:riscv/processor.h:254–255`。
参考侧异常不能被当作退休继续比较；如何报告当前调用中的异常及诊断字段待 Q2。
本任务的异常诊断不构成 DUT 异常比对实现。

### 2.4 本条访存与写回日志：能力和缺口（Q2、Q4）

日志类型为寄存器 map 和 `(addr,value,size)` vector
（`S:riscv/processor.h:72–76,218–220`）。每条 logged 执行前清空
（`S:riscv/execute.cc:10–15,164–178`），因此必须在下一次单步前复制出本条日志。
整数写回 key 为 `rd<<4`，低四位域标签 0，数据为 `freg_t` 的整数成员 `v[0]`
（`S:riscv/decode.h:19–21`、`S:softfloat/softfloat_types.h:55`）；
整数/FP/CSR 域编码见 `S:riscv/decode_macros.h:27–41`，打印解释见
`S:riscv/execute.cc:82–135`。写 x0 的日志可能存在，实际 XPR x0 不改变
（`S:riscv/decode_macros.h:33–37`、`S:riscv/decode.h:230–237`）。

**不能把 load 日志的 value 当读数据**：
[`S:riscv/mmu.cc:309–310`](https://github.com/riscv-software-src/riscv-isa-sim/blob/609dbe0b9994154833039209fa37151e7c05e9d4/riscv/mmu.cc#L309-L310)
实际压入 `(original_addr,0,len)`；store 日志才压入实际 bytes 转换后的数据
（`S:riscv/mmu.cc:401–405`）。开日志会 flush TLB 并避免 TLB 快路径缓存
（`S:riscv/processor.cc:148–152`、`S:riscv/mmu.cc:447–450`），需自测连续
load 命中场景确保每条记录都存在，不能只测首次 miss。

替代方案供 Q4 决策，全部不改 Spike 源码：

1. 普通 RAM、单 hart、无外部写入时，取 log 的地址/大小，直接从独立 Spike
   `mem_t::load(addr-base,size,bytes)` 读低位 bytes，作为该 load 的原始数据。
   load 不修改 RAM，故该限制下单步后重读等价于本条读到的 bytes；这是**推导**，
   不是 log 已携带读值。对 rd=x0 仍成立。不能推广到 MMIO、副作用设备或 DMA。
2. 对 rd≠x0 的普通整数 load，可从本条写回日志低 `8*size` 位恢复原始 bytes，
   同时保留完整 XLEN 扩展结果供 rd 比较；LB/LBU 路径见
   `S:riscv/insns/lb.h:1`、`S:riscv/insns/lbu.h:1`。若选择此路，x0 load
   不能通过读 XPR[0] 获得数据，必须另有方案；禁止无声取消该数据比较。

`memtracer_t::trace(addr,bytes,type)` 没有数据参数（`S:riscv/memtracer.h:22–24`），
不能单靠它得到 load 数据。源码有编译期 `MMU_OBSERVE_*` 宏，默认为空
（`S:riscv/mmu.h:26–39,118`），它不是现成运行时 getter；本任务不自行采用
宏覆写、重新包装 Spike 编译或打补丁。稳定公共 API 所需信息不足，内部结构依赖与
load 替代方式必须列为未决问题。后续 MMIO/中断事件需要扩展同步合同，不由本任务补定。

## 3. 退休观测记录

### 3.1 已有字段的完整来源

**现状更正**：`retire_info_t` 当前属于 `rtl/common/o3_pkg.sv:450–462`，
并非 `o3_types_pkg.sv`。任务书允许后者相关字段改动，但没有点名前者，见 Q3。
已有流向是 ROB → backend → core → scalar top → C++，连线见
`rtl/backend/backend.sv:816–819`、`rtl/core/o3_core.sv:191–194`、
`sim/o3/o3_tandem_top.sv:104–112`、`sim/o3/main.cpp:308–332`。

位宽依据：`rtl/common/o3_isa_pkg.sv:14–20`（XLEN=64、ILEN=32、rd=5）；
`rtl/common/o3_cfg_pkg.sv:275–279`（VA=64、PA=56、commit=4）；
派生位宽见 `rtl/common/o3_pkg.sv:27`、`rtl/common/o3_types_pkg.sv:32`。

| 字段 | 当前位宽、有效条件 | ROB 存储与写入级、输出来源 |
|---|---|---|
| `valid` | 1；本条真退休 | ROB 拍初完成的非异常连续前缀；M 拍不退休（`rtl/backend/rob.sv:261–275`） |
| `pc` | PC_WIDTH=64；valid | rename head（`rtl/backend/backend.sv:530`）在分配沿写 `entry_pc_q`（`rtl/backend/rob.sv:380–383`），退休输出（同文件 `253`） |
| `instruction` | ILEN=32；valid | rename head（`rtl/backend/backend.sv:531`）→ `entry_instruction_q`（`rtl/backend/rob.sv:380–383`）→ 输出（同文件 `254`） |
| `rd` | 5；架构写回时用于 Spike 比较 | `rename_rd_addr`（`rtl/backend/backend.sv:515,771`）→ `entry_rd_q`（`rtl/backend/rob.sv:367`）→ 输出（同文件 `255`）；无写回时原始字段仍保留 |
| `rd_write_en` | 1；valid | ROB 分配实际接 `alloc_req`（`rtl/backend/backend.sv:772`），保存（`rtl/backend/rob.sv:368`），输出（同文件 `256`）；x0 不分配 preg 的逻辑见 `rtl/backend/rename_stage.sv:88,128` |
| `rd_wdata` | XLEN=64；valid 且 rd_write_en | WB 数据网络（`rtl/backend/backend.sv:1018–1029`）→ 完成沿 `entry_rd_wdata_q`（`rtl/backend/rob.sv:336–340,388–393`）→ 输出（同文件 `257`）；不在退休时从 PRF 再读 |
| `rob_idx`、`instruction_id` | 派生宽度；valid；诊断身份 | 定义（`rtl/common/o3_pkg.sv:455–456`）；指令 ID 分配保存（`rtl/backend/rob.sv:379`），退休（同文件 `251–252`）；不和 Spike 的内部序号比较 |
| `slot`、`order`、`cycle` | 当前 C++ 整数；valid；诊断字段 | slot=退休 lane，order 单调累加，cycle 为驱动周期（`sim/o3/main.cpp:308–331,386–394`）；并非已有 ROB 存储字段 |

### 3.2 新字段语义草案与来源缺口（Q3、Q4、Q5）

以下字段尚不存在于当前退休类型（`rtl/common/o3_pkg.sv:450–462`）。
宽度/编码是可审阅草案，未冻结；表中既有信号只是候选来源，不能把“可读到信号”
写成“ROB 已保存该字段”。所有新元数据必须按 ROB 身份存储、随原项恢复/取消，
只能在该项退休时输出，不能用执行顺序或 AXI 事务顺序代替。

| 拟字段 | 位宽/编码草案与有效条件 | 候选来源、写入级与未确认部分 |
|---|---|---|
| `lane` | `$clog2(commit_width)`=2；valid；JSON 保留 `slot` 名 | 退休端口索引；来源 `rtl/backend/rob.sv:229–234`、`sim/o3/o3_tandem_top.sv:104`；是否加入 struct 待 Q3 |
| `mem_valid`、`mem_kind` | 1 + 2；NONE/LOAD/STORE 编码待 Q3；valid | 已有 `entry_is_load_q/entry_is_store_q` 在 rename 分配沿保存（`rtl/backend/rob.sv:163–164,369–370`），输出目前是独立端口（同文件 `239–240`） |
| `mem_addr` | 建议 XLEN=64；mem_valid；本任务 Bare VA=PA | load 候选 `lq_execute_addr`，store `sq_execute_addr`（`rtl/backend/backend.sv:952–958`）；地址在 LSU AGU/replay 计算（`rtl/backend/load_store_unit.sv:240–258,314–321`）。ROB 当前没有地址存储；接收成功的 load 身份/握手 tap 和精确写入沿待 Q3 |
| `mem_size` | 建议 2 位 log2(bytes)，取 0/1/2/3；mem_valid | rename/dispatch 指令已携带 mem_size（`rtl/common/o3_pkg.sv:193,237`）；执行槽复制（`rtl/backend/backend.sv:1582–1591`）；建议 ROB 分配时保存，未确认 |
| `mem_data`：load | 建议 64 位、低 size 字节有效、高位规范化为 0；LOAD | 现有 WB 已保留 `load_result.result`（`rtl/backend/writeback_arbiter.sv:91–95,137–141`）；它经过符号/零扩展（`rtl/backend/load_store_unit.sv:207–224,433–463`）。可用 ROB `entry_rd_wdata_q` 低位恢复 bytes，或新增原始数据路径，选择待 Q4；即使 rd=x0，访存数据也必须有效 |
| `mem_data`：store | 建议 64 位、低 size 字节有效、高位清零；STORE | SQ 接收的未左移 `sq_execute_data` 与完成 ROB idx（`rtl/backend/backend.sv:956–970`；`rtl/backend/load_store_unit.sv:314–321`）；建议在 Store complete 沿按 idx 保存，当前 ROB 完成数据只是 0（`rtl/backend/backend.sv:1026–1029`），不能拿它作 store 数据 |
| `mem_mask` | 建议 8 位、相对 `mem_addr` 的连续低位字节掩码；mem_valid | 现有 size_mask 为 01/03/0f/ff，Store 数据不按对齐总线地址左移（`rtl/backend/load_store_unit.sv:198–205,317–319`）；是否统一用于 load/store、高位如何规范化待 Q4；不是 AXI beat wstrb |
| FP 预留 | 建议 `fp_valid:1,fp_rd:5,fp_data:64`；本任务 valid=0 | 现有目标 FP 写回类型参考 `rtl/common/o3_types_pkg.sv:740–746`；本任务不接通 FP，预留 schema 待 Q5 |
| CSR 预留 | 建议 `csr_valid:1,csr_addr:12,csr_wdata:64`；本任务 valid=0 | ISA 地址宽度来源 `rtl/common/o3_isa_pkg.sv:20`；当前退休 struct 无 CSR 字段，来源/写入级由 O3-T03 定义；一次指令多 CSR 写入是否需要列表待 Q5 |
| 异常预留 | 建议 `exc_valid:1,cause:64,tval:64`；本任务 valid=0 | 已有 `exc_info_t` 见 `rtl/common/o3_types_pkg.sv:781–785`，trap 请求另见同文件 `999–1008`，ISA 同步 cause 类型只有 6 位（`rtl/common/o3_isa_pkg.sv:22–33`）；最终 cause 编码/异常记录与正常退休关系待 Q5/O3-T03 |

自然对齐访问的表示例（**草案**）：SB 到 A+3 时 `mem_addr=A+3,size=0,mask=01`，
`mem_data[7:0]` 为所写 byte；SW 到 A+4 时 `size=2,mask=0f`，数据位于低 32 位。
LB 读到 0x80 时 mem_data=0x80、rd_wdata=0xffffffffffffff80；LBU 对同一 byte
的 rd_wdata=0x80。data/符号扩展必须分别比较，不能直接把两种记录的 64 位值混比。

### 3.3 生命周期与同拍边界要求

元数据必须初始化为无效，分配时清除前一代，成功完成后保存直到退休；分支 kill
不得让取消的访存进入记录；replay 只能更新本条仍存活的同一身份，不得生成第二条
退休。当前 ROB 清理/恢复/分配/完成的顺序见 `rtl/backend/rob.sv:289–406`，
LSU replay/pending/result 身份见 `rtl/backend/load_store_unit.sv:385–463`。

拟时序：周期 N 组合看到执行/完成观测；N 沿保存到原 ROB 项；N+1 及以后拍初
该项进入可退休前缀时输出保存值。现状前缀判断读拍初 `entry_complete_q`
（`rtl/backend/rob.sv:268–275`），驱动在上升沿之前采样记录
（`sim/o3/main.cpp:386–394`）。新观测不得改变执行握手、恢复优先级或退休许可。
同拍 M + 存活老 load/store 观测、完成与重分配同 idx、迟到响应/回绕的精确
身份保护与新字段更新优先级，尚未有新增字段合同，必须由 Q3 冻结并用局部测试证明。

Store 在 SQ 接受 AGU 结果时 complete，之后按 ROB 顺序退休，不能拿 drain 或
cache writeback 时间当退休访存发生时间（`rtl/backend/load_store_unit.sv:308–321`；
ROB 类型输出 `rtl/backend/rob.sv:239–242`）。最终 AXI RAM 值可能仍在脏 cache 中，
不能在结束时随意要求它与 Spike RAM 完全相同；本任务比较架构 store 记录。

## 4. 比较、停止与诊断合同

### 4.1 逐条比较

同拍先固定 DUT 退休向量，按 lane0→lane3 的有效项逐条处理，每处理一项 Spike
单步一次；执行/WB/DCache/AXI 事件不触发 Spike 单步。当前 lane 扫描见
`sim/o3/main.cpp:312–331`，严格前缀来自 `rtl/backend/rob.sv:261–275`。

| 内容 | 比较条件和要求 |
|---|---|
| PC/指令 | 每条有效退休都比较单步前 Spike PC 与 32 位编码；以数值比较，不能因为字符串补零不同而认为语义差异 |
| 整数写回事件 | 从参考自身指令/本条日志得出是否写非 x0；必须与 DUT rd_write_en 一致，不能让 DUT valid 决定跳过参考写回 |
| rd/value | 两侧都有非 x0 架构写回时比较 rd 号及完整 64 位结果，包括同值写回、RV64 word 符号扩展 |
| x0 | 不存在架构写回；日志中 key=0 的计算结果不等于 XPR[0]；要求 x0 为 0。x0 load 的地址/大小/数据照常比较 |
| 无写回 | 分支/store 等不比较 rd_wdata；语义上的 rd 不适用。旧记录原始 rd bits 保留供固定 checker，不把它改成 0 |
| 访存 | 两侧独立得出类型/存在性；本任务正常对齐标量 load/store 每条对应一次数据访问；比较 address、size、有效 bytes、mask 表示；意外 0/多笔访问不能跳过，报协议错误 |
| store | 比较 commit log 实际 store 地址/大小/低位数据与 DUT 保存的架构 store；不给 store 伪造整数写回，不等待 cache 写回 |
| FP/CSR/异常 | 本任务预留输出无效；遇到超范围指令/参考异常不能因为字段无效而算 PASS，报超范围或参考端错误 |
| lane/cycle/ROB ID | DUT 诊断身份；按 lane 确定先后，不与 Spike 时序/内部 ROB 作相等比较；不比较时序 |

无写回 rd bits 的现状见 `rtl/backend/rob.sv:255–257`；旧 checker 仍会比较
原始 rd、rd_write，并在有效写回时比较 rd_wdata
（`sim/o3/check_trace.py:21–40`）。Spike checker 的规范化不得破坏旧 JSONL 字段、
原始固定期望或 checker 行为。新增访存字段的 JSON 命名/version 与高位规则待 Q4/Q5。

本任务不要求 committed_next_pc：下一条退休 PC 可发现多数控制流差异，但程序
最后一条分支的 next-PC 未由本任务独立覆盖；它属于计划 L5 后续机制
（`doc/O3-v1-plan.md:47`），不得把本任务报告成完整控制流/精确异常验证。

### 4.2 结束和超时（Q6、Q7、Q9）

固定程序目前通过指定退休数停止，存在同拍批量输出可能越过阈值的边界
（`sim/o3/main.cpp:308–332,386–405`）；不得私改预期数量来适配新比对器。
固定 gate 的记录数量、程序与终点保持既有合同，计数终点那条也必须完成 Spike 比较。
随机和 ACT4 要以 `tohost` 结束，`max-retires` 只能作为上限保护，不能冒充 PASS。

当前驱动参数解析没有 `--tohost-address`，循环也不使用 done/tohost
（`sim/o3/main.cpp:233–261,386–405`）。ACT4 旧 runner 却传入该参数并要求
`[o3-tohost] value=0x1 status=PASS`（`verification/act4/scripts/run_one.py:36–48`）。
因此当前 SHA 的 ACT4 51 项能否跑通 **未确认**，不得引用旧历史说明宣称已兼容。

待确认草案：在两侧均比较成功的退休 store 处维护相同的 byte-addressed tohost
邮箱影子；支持 SW/SD 与 mask，只在完整规定值可见时判定；1=成功，非零其他值=失败，
初始值为 0。当前 ACT4 宏用 SW 写 1/3（`verification/act4/config/cislc-o3-rv64i/rvmodel_macros.h:14–24`）。
选择退休记录检测还是等待后台 drain、tohost 地址/宽度、是否停止于终止 store
或处理同拍其余退休，均待 Q6/Q9。不得自动运行 Spike `run()`/HTIF 循环，因为它自行
执行并清除邮箱（`S:riscv/sim.cc:352–361`、`S:fesvr/htif.cc:284–315`），破坏驱动逐条同步。

要求：两侧终止条件一致、首个不一致优先报错；超时/无退休/超过退休上限/参考侧
单步未退休/fatal/inclusion 错误均返回失败；超时不能输出 PASS。
cycles 上限、无退休 watchdog、Spike 单步的宿主超时以及终止同拍取样优先级待 Q9。
当前 fatal 检查位于记录输出后（`sim/o3/main.cpp:386–394`），其相对新 comparator
的优先级需要明确，不能漏掉错误状态。

### 4.3 差异输出

任务书要求字段必须齐全；以下格式为待确认草案（Q5）。写 stderr 并保存结构化记录，
首个差异退出非零，禁止自动重同步、跳过/覆盖参考结果。历史缓冲只含此前成功比较
的至多 32 条，当前失败条单列；复位开始的差异不足 32 条时输出实际数量。

```text
SPIKE_LOCKSTEP_FAIL field=mem.data cycle=<N> order=<K> lane=<L>
provenance: rtl_sha=<...> spike_sha=<...> image_sha256=<...> seed=<...>
dut:   pc=<...> insn=<...> rd_write=<...> rd=<...> value=<...>
       mem={kind:<...>,addr:<...>,size:<...>,mask:<...>,data:<...>}
spike: pc=<...> insn=<...> rd_write=<...> rd=<...> value=<...>
       mem={kind:<...>,addr:<...>,size:<...>,mask:<...>,data:<...>}
history: <earlier records, oldest first, at most 32>
```

lane 内第二条失败时必须包含同拍第一条的已比较历史。报告还需区分
`DUT_MISMATCH`、`REFERENCE_ERROR`、`RECORD_PROTOCOL_ERROR`、`TIMEOUT`、
`INFRA_ERROR`、`TEST_FAIL`；具体枚举与退出码待 Q5。一旦发现真实 DUT 错误，按任务书
停止，保存最小复现种子/程序/命令/输出，不在本任务修 RTL，不删除失败种子。

## 5. 随机生成器规格草案（Q8、Q9）

仓库内新增 Python 生成器是任务书已定要求（`doc/tasks/O3-T02-spike-lockstep.md:18`）；
阶段一没有新增生成器。以下可执行语义供冻结，所有具体分布/窗口/种子编号待 Q8。

| 项目 | 待确认草案 |
|---|---|
| 默认规模 | 200 个种子、每个 payload 2000 条动态退休；这满足任务书下限。种子候选 `0..199`；初始化、循环控制、tohost 尾声是否计入 2000 待确认，统计必须同时报告实际总退休数 |
| 指令分布 | ALU/比较 40%，移位 15%，六种分支 15%，JAL 5%，load 15%，store 10%；ALU 含 RV64 word 与 U-type；比例按静态生成模板抽样，另报告动态直方图，不能把控制模板的额外指令隐去 |
| 依赖 | 候选 60% 选择近期结果形成 RAW/WAW 链，40% 独立操作；包含 load→ALU→store、store→load、同地址不同访问大小、分支错路可杀副作用；基址/循环计数/结束寄存器不能被随机部分覆盖 |
| RAM 窗口 | 候选数据 `[0x80080000,0x80090000)`，code 在 `[0x80000000,0x80080000)`；tohost 候选 `0x800ff000`；互不重叠、均在现有 1 MiB AXI RAM 内（`sim/o3/o3_tandem_top.sv:153,194,207–209`） |
| 地址与大小 | LB/LBU/LH/LHU/LW/LWU/LD、SB/SH/SW/SD；每笔自然对齐，`addr+size` 不越窗口或溢出；代码/终止区禁止普通数据写入；以 AUIPC 等构造真实 64 位 RAM 地址，不能误用 LUI 的符号扩展地址 |
| 前向控制流 | 标签落在已生成 code 的 4 字节边界、分支/JAL immediate 可编码；两臂模板使用已知退休成本，跳过的死代码不计动态长度；禁止跳入数据/指令中间 |
| 后向循环 | 单入口、显式计数且每轮单调减至退出；候选循环上限 16、无任意嵌套/跨回边跳转；普通生成指令不改计数器、回边不由任意随机数据控制；JAL 不生成无界自环 |
| 长度 | 先构造控制图并计算各模板动态成本，再分配预算，最后补合法 ALU，确保规定 payload 长度固定；不能仅生成 2000 个静态 word 就声称 2000 退休；具体预算算法和计数口径待 Q8 |
| 可重放性 | 同 seed、生成器版本、长度、配置得到相同镜像/清单 SHA256；明确 PRNG 算法与版本，不靠无版本全局随机状态；保留 seed/参数/镜像/hash、反汇编、Spike 预检记录 |
| 结束 | 固定尾声以成功值写 tohost；候选 SW 写 1 后自环，停止边界按 Q6/Q9。循环/终止错误必须失败，不能提前计数 PASS |

合法性要求：仅白名单 RV64I 普通指令，不生成 CSR/ECALL/EBREAK/非法编码、
FENCE/FENCE.I、JALR、M/A/F/D/RVC；JALR 的整核当前范围记录在
`doc/LOOP.md:110,117`，计划为 L6（`doc/O3-v1-plan.md:48`）。
基址、loop 和 tohost 寄存器初始化；一般寄存器/数据均有可重放初值；所有运行路径
地址/跳转合法、不自修改代码。不要为了规避 DUT 缺陷删除合法输入或改变种子。

每个镜像在驱动 DUT 前，先由**同一固定 Spike** 独立跑 legality preflight，确认
无异常、所有数据访问符合窗口、循环有界、payload 退休数符合要求并以 tohost 成功。
随后重建/复位一个全新参考实例执行 lockstep，不能复用预检后的状态。
预检失败是生成器/基础设施问题；lockstep 发现 DUT 差异按任务书停止。不得用预检
生成的轨迹替代进程内单步比较，或用 DUT 输出反写随机程序的期望。

## 6. 固定程序集合与门禁命令

### 6.1 输入清单和兼容缺口（Q6、Q7）

| 程序 | 已有入口/停止条件的源码证据 | 阶段二约束 |
|---|---|---|
| smoke | `sim/o3/Makefile:28–40`，4 退休、1000 cycles、require refill；输入 `sim/o3/tests/smoke.hex:1–5` | 保留固定 checker 与 refill 要求；smoke.expected/icache_smoke.expected 的关系不能任意改 |
| rv64i_instructions | `sim/o3/Makefile:42–55`，14 退休、5000 cycles；`sim/o3/tests/rv64i_instructions.hex:1–17` | 保留 taken BEQ/JAL 和排除错路期望 |
| dcache_data | `sim/o3/Makefile:57–70`，7 退休、5000 cycles；`sim/o3/tests/dcache_data.hex:1–13` | 保留 store/load 和固定期望 |
| dcache_replay | `sim/o3/Makefile:72–85`，6 退休、5000 cycles、require replay；`sim/o3/tests/dcache_replay.hex:1–12` | Spike 不比较 replay 时序；原 replay 门禁照常成立 |
| l3_branch_dense | `sim/o3/Makefile:107–113`，365 退休、30000 cycles、require replay | 固定输入与 oracle 不变；Spike 独立比较 |
| unified_memory | `sim/o3/Makefile:87–100`，18 退休；`sim/o3/tests/unified_memory.hex:2–20,22–32` | code=0x10000000，数据含 0x12000000 和不自然对齐访问；与当前 AXI map/本任务对齐范围冲突，如何处理待 Q7，不能静默跳过 |
| ACT4 RV64I-I 51 项 | `verification/act4/ACT4_REV:1–3` 固定 `dfa582359db885ae4c6ed1fa82faef60874e212c`；构建 `verification/act4/scripts/build_tests.sh:10–42`；旧 51 项历史描述 `doc/CISLC_O3.md:662` | 当下 manifest/51 ELF 身份和可运行性未确认，不能把旧 PASS 当本 SHA 证据；需要固定生成配置、工具链、ELF hash 和确切 51 项名单 |

ACT4 链接图在 `verification/act4/config/cislc-o3-rv64i/link.ld:2–18` 仍为
code=0x10000000、data=0x11000000、tohost=0x12000000；当前 loader 只初始化
DTCM 与 0x80000000 AXI RAM（`sim/o3/main.cpp:346–347,369–381`），AXI RAM
只接受自己的窗口（`sim/o3/o3_tandem_top.sv:194,207–209,220–221`）。
不能仅给 Spike 添加旧地址 RAM 就声称 DUT 可执行 ACT4。是否重新链接 ACT4 到 AXI RAM、
是否保留 DTCM，以及改 `verification/act4/` 所需范围授权，必须在 Q6 明确。

### 6.2 门禁 CLI 草案（尚不存在，尚未运行）

当前 Makefile 的目标表没有以下 Spike targets（`sim/o3/Makefile:19`）。
冻结后拟提供：

```sh
make -C sim/o3 build-spike
make -C sim/o3 run-spike-all
make -C sim/o3 run-spike-act4
make -C sim/o3 run-spike-random
make -C sim/o3 run-spike-random SEEDS="0 1 7 29" LENGTH=2000
make -C sim/o3 test-spike-comparator
```

`run-spike-all` 必须有明确完整 manifest，覆盖现有固定程序（含 dense/legacy 待 Q7），
每个程序同时通过 Spike 和原固定 checker。`run-spike-act4` 要求完整 51 项的原
PASS 结束判据与 Spike 0 差异，缺少程序、跳过项目、空集合都失败。
ACT4 当前以自身程序结果检查，尚无逐条 expected.json 的统一接口
（`verification/act4/scripts/run_one.py:36–58`）；不伪造固定期望 checker 结果。

随机默认要求 200 种子/每种子≥2000 退休，具体 SEEDS/length 口径待 Q8；少量覆盖
只算调试，不能算完整随机验收。`test-spike-comparator` 只跑注入自测，不进入正式门禁。
目标名称/参数、build-spike 是否与原 build 共用二进制、默认是否启用 Spike 待 Q1/Q8。
所有 O3-T01 gate 仍须在同一最终 SHA 验收，完整清单沿用
`doc/spec/l3-closure-spec.md:218–264`，不能用新增 targets 替代局部恢复/kill 测试。

## 7. 测试计划（阶段二，全部未运行）

| 测试层 | 需要证明的行为 |
|---|---|
| Spike 适配器 | 固定 SHA 可链接；同镜像/entry/BSS/HEX bytes；连续命中 load 的日志不丢；同值写 rd、x0 写/读、x0 load；LB/LBU/LH/LHU/LW/LWU/LD 和不同大小 store；trap 时单步不被当成功；重建参考实例无状态泄漏 |
| ROB/观测路径局部 cocotb | 正常分配→完成→退休；metadata 有效条件；M 取消年轻、存活老完成不丢；replay 后只一次退休；full/回绕/迟到响应；lane0..3 顺序；reset 清 metadata；x0 load/store；固定种子随机事务。新增字段同拍合同由 Q3 冻结 |
| Comparator 成功自测 | 0/1/多 lane，0..31/32/超过32条历史，连续同 rd 写回，store 后 load，多 seed 隔离；DUT 不写回却参考写回和相反情况；相同数值不同文本表示；不以类型字段无效跳过错误 |
| Comparator 失败注入 | 必测 PC、整数值、load 数据、store 地址、store 数据五类（任务书 `doc/tasks/O3-T02-spike-lockstep.md:54`）；建议再测 instruction、rd 号、写回 valid、访存 size/mask/kind、丢失/重复记录、参考异常/超时 |
| 定位断言 | 单条/同拍中间 lane/历史已回绕处各注入；断言首错 cycle/order/lane/字段、双方值、此前32条顺序、非零退出，且没有继续单步后续 lane；预期位置独立写定，不能只搜 FAIL 字样 |
| 正式门禁 | 原固定程序 checker + Spike；ACT4 完整51项自身结果 + Spike；随机≥200种子×≥2000退休，0差异，报告总退休数；O3-T01 局部/整核回归保持通过 |

注入放在比对器自测的数据拷贝/测试入口中，一次只扰动一项。源轨迹、固定 expected、
原程序、Spike 状态及执行 RTL 不改。注入开关只由自测入口使用，正式门禁禁止启用；
注入具体位置/接口待 Q10。每类都要有“未注入 PASS、注入恰好命中独立预期位置”的
成对测试；不允许修改断言以接受漏检。自测包括 load rd=x0，避免只测寄存器写回
能发现的 load 差异。

日志应留在 Alan 独立输出目录，保存实际 DUT SHA/Spike SHA/conda 与工具版本、
输入/种子/hash/参数、命令退出码、实际退休总数、差异及最小复现；生成物不提交。
本地 lint 只证明 RTL 解析，最终功能结论只来自 Alan
（`agent.md:103–137,180–183`）。

## 8. 决定（2026-10-05，已冻结）

本文已冻结。下表取代原未决问题；表中没写到的实现细节由实现者自行决定，在报告中写明选择即可，不需要停下来问。

| ID | 决定 |
|---|---|
| Q1 | 用审查的 Spike SHA `609dbe0b`，原版默认 configure/make，安装到 conda 环境前缀；`sim/o3` 通过 pkg-config 或直接 `-I/-L` 链接 `libriscv`。构建命令写进 `sim/o3/README.md`。编译/链接问题自行解决。 |
| Q2 | 接受依赖该固定 SHA 的内部 C++ 接口（`get_state()`、commit log）。初始化：共用 ELF/hex loader，不用 DTB，M 模式、Bare、PMP 关闭或全放行、无 trigger；Spike 单步未退休或报异常时立即报错停止。 |
| Q3 | 允许修改 `o3_pkg.sv`、`o3_types_pkg.sv`、`rob.sv`、`backend.sv`、`load_store_unit.sv`、`load_queue.sv`、`store_queue.sv`、`writeback_arbiter.sv`、`o3_core.sv`，**只加观测字段，不改执行行为**。访存信息在 LSU 产生结果/SQ 执行时写入 ROB 项（或旁路记录表，二选一自定）。 |
| Q4 | load 比较**格式化后的写回值**（符号/零扩展后 64 位）；Spike 侧从 commit log 取地址，从 Spike 的内存模型重读该地址取值后按同样规则格式化。x0 的 load 只比地址和大小。地址比较 56 位物理地址（Bare 下等于 VA 低位，高位须为 0）。store 比较地址、大小和按大小截取的数据，mask 由大小与地址低位推出，不单独比较。 |
| Q5 | JSONL 每条加 `"v":2`；预留字段 `fp_rd/fp_wdata/csr_addr/csr_wdata/exc_cause/exc_tval`，本任务输出 `null`。差异报告：一行 `MISMATCH field=...` + 双方完整记录 + 前 32 条，退出码 2；超时退出码 3。 |
| Q6 | 允许修改 `verification/act4/` 的 linker 脚本与 runner，迁移到 AXI RAM `0x8000_0000`，`tohost` 放在镜像内固定符号，SD 写入非零即结束。重新生成 51 项，manifest 写进报告。若生成后少于 51 项，报告实际数量与原因，不作为停止条件。 |
| Q7 | `unified_memory` 旧门禁**排除**在 Spike 比对之外，在 `LOOP.md` 标为历史门禁；它原有的 checker 门禁若仍可运行则保留，否则也标为历史。 |
| Q8 | 生成器：ALU/移位 45%、分支 15%（后向分支只用计数寄存器保证有界循环，最多 8 次）、JAL 5%、load 20%、store 15%；访存窗口 `0x8010_0000`–`0x8010_ffff`，自然对齐；x1–x3 保留作基址与循环计数；Python `random.Random(seed)`；种子 1–200；长度按**动态退休数**计，目标 3000，下限 2000；默认 `SEEDS=1-200`。 |
| Q9 | `tohost` store 退休即结束：同拍更年轻 lane 的记录照常比较；不等 SQ drain。fatal 优先于记录比较报告。超时：`max-cycles` 默认 = 退休目标 × 50；连续 10000 周期无退休即判超时。 |
| Q10 | 注入只在 C++ 驱动中通过环境变量 `O3_INJECT=<kind>:<retire_idx>` 扰动 DUT 一侧的记录拷贝；正式门禁的 Makefile 目标在启动时清除该变量。自测目标 `run-spike-selftest` 对五类各注入一次，断言报告的字段与退休序号正确。 |
