# O3-T07 L9 RTL 与基础功能验证记录

日期：2026-10-07。分支 `feat/L1-closure`，RTL 实施轮次起始/交付时 HEAD
`97e8d2903b7765005ef4e0ce38bb7191e4a5703b`。实现留在工作树，未 commit/push。
以下为先前 RTL 交付轮次的历史记录；本次测试与最新结论见末尾“基础功能测试”。

依据 `doc/spec/l9-fpu-spec.md` 与 `doc/tasks/O3-T07-l9-tasks.md`；二者和设计基线未修改。

用户本轮先要求“实现 RTL，测试下一次做”，再明确选择“本次写完 T07a 和 T07b 的 RTL，
阶段验收均留到下次”。据此本次只实施源码、初始化固定依赖、核对来源与整理状态；
不运行 lint/编译/cocotb/整核/Spike/ACT4/综合。任务书的阶段门禁没有作为通过记录，
T07a 与 T07b 均未验收。测试代码/测试 harness 适配留到下次。

## 实现范围

- 完整 F/D 译码：三源 FMA、DIVSQRT、MISC、转换/MOVE、FP load/store；整型读写字段
  填 INT 域。FP→x0 保留 INT 目的域，只关目的写入；f0 恒可写。
- FS Off/动态保留 frm 检查放在 rename_entry_gate 之前；原异常 cause/tval 保留，
  新异常用 raw_instruction（含原始 RVC 16 位）作 tval。所有异常项撤销源/目的域、
  FU/CSR/系统/访存/分支/融合语义，只占 ROB/RDQ，并截断年轻入口。
- 两域 RAT/free-list/ready/PRF 接入，按域预算与提交回收；FP f0/p0 的常量零特例移除。
  RAT 增加 src3 读口，域掩码由 backend 生成；RAW/WAW 只在该域内部匹配。
  两域共享 checkpoint tag，误预测快照与全局 committed 恢复同时进行。
- 一个 12 项 FP IQ，三源与域就绪跟踪，最多双发射。FU 选择按 FMA0/FMA1/DIVSQRT/
  MISC/CONV 五个 RegRead 输入槽容量，从老到新扫描，每个 FU 每拍最多一条。
  每拍最多一个 INT-source FP 候选，未取得共享 INT PRF 读授权不删除；另一纯 FP lane
  可独立接受。FP PRF 7R：两个 lane 各三读、port6 专供 store。
- 每个 FU 一个弹性 RegRead 槽，保存完整控制、操作数与身份；IQ 握手锁存到该槽，
  FU 握手才分配侧表并交付一次请求。支持同拍出旧入新，取消当拍禁止被取消请求进入 FU。
- 拆分五个 CVFPU opgroup 实例：FMA×2、DIVSQRT、MISC、CONV/MOVE。
  各 FU 8 项在途身份侧表；只有请求握手分配槽号。错误路径标 killed，直到迟到结果
  最终丢弃才释放；普通恢复不复位 CVFPU，也不提前复用槽号。
- 每 FU 一个共同稳定结果保持槽，仅捕获 CVFPU out_valid/out_ready 握手的结果。
  同拍取消过滤原出口与保持项；保持项通过槽号查询更新后的身份。FMV 不走算术 NaN 替换，
  有独立一拍旁路槽，与 CVFPU 活出口在保持槽处轮转；killed 输出可直接丢弃。
- FP 两写口按 ROB 年龄选六个源；MISC/CONV 的整数结果走 INT extra2/3。
  两种仲裁显式过滤全局 flush 和同拍误预测；x0 的 FP 整数结果仍完成并保留 flags。
- ROB 增加两个 FP grant 完成口，复用 t_fflags 输入，索引/有效/数据/flags 同拍对应；
  分配 meta 清 flags，退休保存真实 FP 写域/写使能。retire_info 只抑制 FP rd_write_en。
- LSU pending/replay/result 携带目的域；FLW 返回 NaN boxing，FLD 原样，FSW/FSD 数据
  从 FP port6 获取。现有 DCache/LQ/SQ 数据通路和提交/drain 机制未改。
- CSR fflags/frm/fcsr、mstatus.FS/SD、复位 Off/RNE/0、任意 frm 照存、FS Off CSR 非法、
  合法软件写置 Dirty；真实退休 OR flags，并对写 FPR 或非零 flags 置 Dirty。
  两条断言合同合成一个检查：fp_retire 有 flags 或 Dirty 时不得与 CSR 请求/trap 更新同拍。
- 浮点 RVC 四条，C.FLDSP 允许 f0；C.LUI 的 nzimm 检查排除 rd 位。
  最终采用 T07b misa=`0x800000000000112c`，FMA/DIVSQRT 译码已放开。

## 实现细节选择

| 项 | 选择与理由 |
|---|---|
| 在途槽 | 每 FU 8 项（原默认 4→8），包括流水、FMV 与保持槽；满时回压。未证明持续一拍一条吞吐 |
| 请求身份 | 3 位槽号，槽一直保留到最终写回/丢弃；无代际位，遵循 W6 寿命不变量 |
| 共同包装组织 | `o3_fpu_opgroup` 定义在允许列表内的 `fpu_fma_fu.sv`，四个具名 FU 薄包装选择 GROUP；文件清单先编译此文件 |
| 整数格式 | 项目内 `fp_int_fmt_e` 一位 IFMT_W/IFMT_L；包装内映射到 fpnew INT32/INT64 |
| 第三源 | RAT 新增 rs3 端口，rename_stage 接 src3_preg 并写 rext，IQ 独立存 src3 ready |
| FP 写回完成 | 仲裁按两个实际写口输出 complete/index/data/fflags，ROB 完成宽度由 NUM_ALUS+10 增为 NUM_ALUS+12 |
| flags | INT extra 与 FP arb 各自输出真实 flags，backend 按同一完成索引接 ROB 的 t_fflags |
| FMV 仲裁 | 局部轮转初始优先 CVFPU；每次交付活结果后让下一次冲突优先另一路；无冲突时直接交付 |
| FP 提前唤醒 | 按 W5/B33 推迟到性能优化，真实目的域 PRF grant 才广播 FP FU 写回 |
| 编译豁免 | `scripts/cvfpu.vlt` 在 `rtl/rtl.f` 引入，所以 scripts/lint.sh 与任何使用此 filelist 的入口共享同一豁免，无需改变 lint 命令 |

## 来源与命令记录

cwd 均为 `/home/chen/work/CISLC-O3`（`git -C` 命令的目标另标明）。没有 Alan 运行目录，
没有功能日志、用例数或测试 PASS。只核对源码和 Git 元数据。

| 命令/动作 | exit code | 结果 |
|---|---|---|
| `git status --short`、`git branch --show-current`、`git rev-parse HEAD` | 0 | 起始分支/HEAD 与 spec 快照一致；原未跟踪 spec/task 和仿真产物保留 |
| `git submodule add --reference /home/chen/leisure/flow/third_party/cvfpu https://github.com/RanxiChen/cvfpu.git third_party/cvfpu` | 0 | Git clone，使用只读本地对象库加速；不是复制源码或 Git bundle |
| `git -C third_party/cvfpu checkout --detach 1b220f3bc89df99e246b72e3574a3a533cf87653` | 0 | CVFPU 固定版本 |
| `git -C third_party/cvfpu submodule update --init --reference /home/chen/leisure/flow/third_party/cvfpu/src/common_cells src/common_cells` | 0 | common_cells 固定版本 `6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea` |
| `git -C /home/chen/leisure/flow show 7dfa75c4eca1bd68cd82780508cc8eb84659e835:<path>` | 0 | 读取固定 Flow wrapper/manifest/译码/操作数/RVC/豁免；Flow 未修改 |
| `git add .gitmodules third_party/cvfpu` | 首次 128；授权后 0 | 只读 .git 阻止首次索引写入；重试后 staged gitlink 固定到指定版本；没有提交 |
| `git submodule status`、子模块 `git status --short` | 0 | 指定 gitlink；两个子模块源码工作树干净 |
| `git diff --check` | 首次发现一处行尾空格；修复后 0 | 仅文本格式检查，不是 RTL lint 或功能证明 |
| `scripts/lint.sh` | 未运行 | 下次 Alan |
| cocotb、sim/o3 | 未运行 | harness/新用例均下次补齐，不统计 PASS |
| Spike/ACT4、综合/PPA、FPGA | 未运行 | 不在本次范围 |

本次只 staged `.gitmodules` 与 CVFPU gitlink（submodule add 的索引记录，固定版本后更新）；
RTL 与状态报告保留为未提交修改。首次导入应按任务书在 lint 通过后做单独依赖提交，
其后 RTL 提交/push 与精确 SHA 的验收在下一次会话进行。

## 下一次验证待办

1. 先核实工作树与固定子模块，按任务书同步允许的源码到独立 Alan 开发目录运行 lint。
2. 适配现有 cocotb harness 的新类型宽度/端口：RAT 的 rs3、rename 的 FP free count/src3、
   dispatch 的 FP lane/capacity、IQ 的 FP ready/wake/FU capacity、RR 的 INT-source FP 候选、
   INT WB 的 flush/flags、ROB 的 flags 口；保持原断言/期望，整数测试输入填 INT 域。
3. 新增 FP FU/FP WB、CSR FP 状态、两域 rename/free/PRF/ready、双发射和取消/迟到结果的
   最少定向合同测试；按 spec 第 12 节补齐 backend 入口与 RegRead 检查。
4. 编写 `sim/o3/tests/l9_fp.S` 和 `run-l9-fp`，使用当前 T07b 的完整程序/misa 期望。
   本次没有独立 T07a RTL SHA，不用 T07A 程序冒充阶段验证，也不通过宏裁剪 RTL。
5. lint 通过后按任务书组织开发提交/push；最终候选 SHA 在独立 Alan 目录跑定向模块、
   L7a/L7b 和受影响非访存回归、完整 l9_fp 与已有整核回归，记录 SHA/cwd/命令/exit/log。
6. 正确性未通过前不记 L9 完成；保留失败证据，不削弱 golden/断言，不跑禁止的后级门禁。

当前结论仅为 **T07a/T07b RTL 已实现到工作树，尚无解析或功能验收证据**。


## 基础功能测试（2026-10-07，本轮）

用户本轮明确要求少量基本测试证明能执行；更广测试留到完整 SoC 后。
因此本轮范围为 FU、CSR、RVC 的三个小套件，顺序整核浮点 smoke 和已有整核回归。
不执行原任务书全部单模块门禁，不宣称 spec 第 12 节完整验收，也不把缺失的 T07a
独立阶段 SHA 补成通过。冻结 spec/设计基线与 RTL 行为本轮未修改。

### 测试改动

- `sim/cocotb/fpu_fu`：两个测试，四类 split FU 的运算/MOVE/转换、NV/DZ、身份、
  结果背压保持、分支/全局取消、迟到丢弃和终结后身份复用；32 组固定种子整数值加法。
- `sim/cocotb/csr_file`：增加 FP 退休事件 harness 输入和状态输出；新增 FS Off/复位、
  CSR 别名、frm=5 照存、读不置 Dirty、写/退休 Dirty、flags OR、SD、FS 变化保留 fcsr。
  原随机 WARL 检查按新 FS/SD/misa 合同更新，保留原检查逻辑。
- `sim/cocotb/rvc_expander`：四条 FP RVC 的显式展开值、f0 与 C.LUI nzimm=0 保留编码。
  原本应非法的 FP 编码按 L9 已实现的合法合同调整，整数用例保留。
- `run-l9-fp-smoke`：独立顺序功能程序。CSR 读取作为既有串行边界分隔访存块，
  验证 FLD/FSD、FLW/FSW boxing、F/D 算术、MISC/CONV、DZ、Dirty、四条 FP RVC、
  50 次三源 FMA RAW/WAW 循环；整数结果/位模式自查，tohost=1 才成功。
- `run-l9-fp`：较长程序，含 FS Off 精确 trap、更多 FMA/MISC/转换、fflags=0x19、
  动态舍入、无串行边界的 FP 访存与依赖/恢复循环。保留失败，未删用例或改期望。

### 代码与环境

- 依赖提交：`c1bef1e`；原 RTL 与基础测试提交：`2e9fc3a`；顺序 smoke 提交：
  **`50ff873817305dc2696de1f7457fda1b80c337dd`**，已推送 `feat/L1-closure`。
- 最终验证 cwd/证据根：`/home/chen/FUN/CISLC-O3-runs/20261007-l9-basic-50ff873/`；
  日志位于其 `evidence/`，轨迹和 ELF 位于 `sim/o3/build/`。独立目录从 Git checkout
  完整 SHA 重建，未把开发目录的结果拼成最终证据。
- Alan `cislc-o3` 环境；Python CLI 3.12.14、cocotb 日志嵌入解释器 3.12.12；Verilator 5.050、cocotb 2.1.0。精确解释器/路径、SHA、无 tracked 修改的
  起始工作树（仅新建 evidence 目录）、依赖 SHA 见 `evidence/provenance.log`。
- CVFPU/common_cells 分别为 `1b220f3bc89df99e246b72e3574a3a533cf87653` /
  `6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea`。首次 GitHub 直连 clone TLS 失败，
  按 agent.md 使用已确认可连接的本地代理 7897，经 SSH 反向端口 18797 初始化依赖。
  缺依赖导致的首轮 lint 错误是基础设施失败；初始化后 lint 为 0 errors。

下列命令 cwd 全为上述最终验证目录；均不带 `--spike`。完整命令记录见
`evidence/commands.tsv`，表内日志名均相对 `evidence/`。

| 命令 | exit | 结果 | 日志 |
|---|---:|---|---|
| `scripts/lint.sh` | 0 | 0 errors / 361 warnings；未做 warning 清理 | `lint.log` |
| `make -C sim/cocotb/fpu_fu -j8 TEST_SEED=1` | 0 | 2/2 PASS | `fpu.log` |
| `make -C sim/cocotb/csr_file -j8 TEST_SEED=1` | 0 | 4/4 PASS | `csr.log` |
| `make -C sim/cocotb/rvc_expander -j8` | 0 | 3/3 PASS | `rvc.log` |
| `make -C sim/o3 build VERILATOR="verilator -j 8"` | 0 | 从源码独立重建 | `build.log` |
| `make -C sim/o3 run-l9-fp-smoke` | 0 | tohost=1；890 cycles / 267 retires | `fp-smoke.log` |
| `make -C sim/o3 run-smoke SPIKE_ARGS=+L7_CHECK` | 0 | 38 cycles / 4 retires；固定轨迹检查通过 | `smoke.log` |
| `make -C sim/o3 run-rv64i-instructions SPIKE_ARGS=+L7_CHECK` | 0 | 70 cycles / 14 retires；固定轨迹检查通过 | `rv64i.log` |
| `make -C sim/o3 run-l3-branch-dense SPIKE_ARGS=+L7_CHECK` | 0 | 1966 cycles / 365 retires；固定轨迹检查通过 | `branch-dense.log` |
| `make -C sim/o3 run-l7-predict` | 0 | A/B 自查、layout 和跨组正确性检查 PASS | `l7-predict.log` |
| `make -C sim/o3 run-l7b-rvc` | 0 | tohost=1；5673 cycles / 2216 retires | `l7b-rvc.log` |
| `make -C sim/o3 run-l9-fp` | 2 | **FAIL**：10760 cycles / 237 events 后超时，模拟器 exit 3 | `fp-replay-known-failure.log` |

最终二进制 SHA256：`c6e006c7164f41f85b56d53c0f279592e1289bb3df4ffc691a840b6673553305`。
复核时 `git diff --exit-code` 为 0，两个依赖源码工作树无修改。

**本轮结论：基本功能门禁通过（9/9 模块测试 + 顺序 FP 自查 + 5 项既有整核回归）；
完整 L9 验收未完成，较长整核用例仍 FAIL。** 报告/LOOP 的后续纯文档提交只记录本 SHA
证据，不把文档 SHA 作为重新运行过的 RTL/测试 SHA。

### 保留问题：单槽 replay 等待环

开发目录未修改 RTL 的整核 `run-l9-fp`：exit 2（模拟器 exit 3），
10760 cycles / 237 个观察事件后无退休进展；tohost 未写入。

1. `0x80000380` 的 C.FLD f8,0(s0) 在地址源未就绪时留在 Memory IQ。
2. `0x80000382` 的 C.FSD f8,16(s1) 等待该 load 的 f8 数据。
3. 更年轻 `0x80000384` 的 LD t0,16(a1) 地址已就绪，先发射；因更老 store
   未完成地址/数据进入单槽 replay。cycle 753 capture，754 recheck 仍被 SQ 阻塞。
4. replay 占用令 `allow_load_i=0`，随后已就绪的较老 C.FLD 也不能发射，形成等待环。
   SQ 没有变化时 replay 睡眠；地址/展开/算术结果本身没有报错。

关键合同：`backend.sv` 的 Memory IQ `allow_load_i`，`backend_issue_queue.sv`
的 load 抑制条件，`load_store_unit.sv` 的单槽 replay 与事件唤醒。此组合需要访存调度
决策，当前不擅自修改为多槽、放开旧 load 或改变 IQ 顺序。

纯整数临时复现同样停滞：DIV 产生地址 → 老 LD → 依赖其数据的 SD → 年轻 LD。
最终 SHA 上也重跑此纯整数复现：10060 cycles / 6 个观察事件后超时（模拟器 exit 3），
不使用 F/D 或 RVC。最终证据保留 `evidence/replay-integer.S` / `replay-integer.log`、
`sim/o3/build/replay-integer.elf` / `.jsonl`。汇编源码 SHA256：
`111375f110010d0d64016b2205e2f357679f0aa72ce4d4bbf1cba854fbded876`。
复现命令（相同 cwd / 环境）：

```sh
riscv64-unknown-elf-gcc -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -static -Tsim/o3/tests/l7_predict.ld evidence/replay-integer.S -o sim/o3/build/replay-integer.elf
sim/o3/build/Vo3_tandem_top +L7_CHECK --image sim/o3/build/replay-integer.elf --trace sim/o3/build/replay-integer.jsonl --tohost-address 0x801ff000 --max-cycles 20000 --max-retires 1000
```

原开发目录保留 `l9-replay-integer.S`、`l9-integer-replay.log`、`l9-diagnostic3.log`；
该诊断仅增加 C++ 观察输出，原 main.cpp 已恢复。没有重跑历史旧 SHA，故不宣称
已证明该问题在某个历史版本就存在。顺序 smoke 的 PASS 不覆盖此等待环。

### 未做项

完整 IEEE/ISA 边界、双 FMA/双写回的全部交错、所有新端口的单独模块 harness、
全套 L7/受影响非访存 cocotb、Spike/ACT4、MRET、综合/PPA/FPGA/SoC 均未运行。

## 单槽 replay 等待环修复（2026-10-07）

本节更新上述“保留问题”的结论，历史失败证据继续保留。
用户明确决定采用 L3 闭环简化：Memory IQ 的 load 按程序顺序发射；store 选择规则及
`allow_load_i` 门控保持不变，L8 换成 Breeze 访存时整体替换。不改 spec、设计基线或 LSU。

- 指定基线：`0ef54395a8b2ea71ba25cf5f8e9d71c5f11970e7`。实际起始 HEAD 为
  `00646b8bb767a98f9ae44f67bb32a10326b6adb5`；两者间仅有已有文档改动，RTL/测试相同。
- 已推送代码/测试提交：`f0f410640a27abe4f62f3cf728f387ab8b6bde6e`。
  后续报告/LOOP 纯文档提交对应此代码 SHA，不作为重新执行过门禁的 SHA。
- RTL 仅改 `rtl/backend/backend_issue_queue.sv` 的 `KIND==IQ_MEM` 选择条件与头注释。
  扫描所有有效 load，用现有 ROB 环形距离算法比较年龄；参照压紧后队列最老项
  `queue_q[0].rob_idx`。不以源就绪或握手状态排除旧 load，保证未就绪/被回压的旧 load
  仍挡住年轻 load。有效项始终按程序顺序压紧，故该参照也适用于 ROB 索引回绕。
  INT/BR/FP 选择与队列更新、恢复逻辑未改。头注释明确偏离 B04 的原因与 L8 替换安排。
- 原 Memory IQ 用例及其全部期望保留；新增一条定向用例，覆盖旧 load 未就绪、年轻
  load 就绪仍不发射，store 在 replay 占用时仍能越过，唤醒后旧 load 先发、年轻 load
  后发，以及握手回压与 ROB 回绕。固定种子为 1。
  harness 补 `ext.rs1_dom=RD_INT`：原 `rs1_read_en` 的等待源保留 `RD_NONE`，
  在分域 ready 逻辑中会被视为就绪；这是输入适配，未削弱原断言。
- 整数复现取自 `20261007-l9-basic-50ff873/evidence/replay-integer.S`，原始 SHA256
  为 `111375f110010d0d64016b2205e2f357679f0aa72ce4d4bbf1cba854fbded876`。
  收入 `sim/o3/tests/replay-integer.S`，保留 DIV→LD→依赖 SD→年轻 LD 序列，追加
  两次 load 的数据比对；tohost=1 表示通过，3 表示失败。新增 `run-replay-order`。

### Alan 运行与来源

开发目录：`/home/chen/FUN/CISLC-O3-runs/20261007-t07-replay-dev/`，checkout `0ef5439`，
按允许列表经 `rsync -aR` 同步上述 RTL、harness、测试、Makefile 和汇编；来源文件
SHA256 记录在 `evidence/provenance.log`。开发 lint 为 0 errors / 361 warnings，
Memory IQ 2/2 PASS，命令均 exit 0；通过后本地提交并 push。

最终验证 cwd：`/home/chen/FUN/CISLC-O3-runs/20261007-t07-replay-f0f4106/`。
独立 Git clone/checkout 精确代码 SHA，从源码重建，不使用开发二进制。所有命令
先 `source /home/chen/miniforge3/bin/activate cislc-o3`；Verilator 5.050、cocotb 2.1.0、
Python CLI 3.12.14。未改 Alan 原开发树或已有证据目录。

GitHub 经已验证的本地代理 `127.0.0.1:7897`，SSH 反向转发到 Alan `18798`；
clone/submodule 命令带 `-c http.proxy=http://127.0.0.1:18798`。独立目录按 gitlink 执行
`git submodule update --init third_party/cvfpu`，再在该子模块执行
`git submodule update --init src/common_cells`，均 exit 0；最终 clone 使用开发目录
的 Git 对象库作为 `--reference`，没有复制源码或使用 Git bundle。
CVFPU/common_cells 仍为 `1b220f3bc89df99e246b72e3574a3a533cf87653` /
`6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea`，源码工作树无修改。

完整命令、exit code 与日志位于 `evidence/commands.tsv`；来源见
`evidence/provenance.log`。ELF/整核轨迹位于 `sim/o3/build/`，固定回归轨迹位于 `sim/o3/`。

首次开发 checkout `00646b8` exit 128：该已有纯文档提交当时尚未推送，GitHub clone
没有其对象；改为 checkout RTL/测试相同的指定基线 `0ef5439`，exit 0。
此准备失败不计作功能失败或最终门禁证据。

### 精确 SHA 验收结果

下表 cwd 均为上述最终验证目录，日志名相对 `evidence/`。全部 exit 0。
周期数取驱动输出；退休数按 JSONL 的 `type=retire` 统计，排除 metadata 和 trap。

| 命令 | exit code | 周期 / 退休数及结果 | 日志 |
|---|---:|---|---|
| `scripts/lint.sh` | 0 | 0 errors / 361 warnings | `lint.log` |
| `make -C sim/cocotb/backend_issue_queue -j8 TEST_SEED=1` | 0 | 原用例 + 新定向用例 2/2 PASS | `memory-iq.log` |
| `make -C sim/o3 build VERILATOR="verilator -j 8"` | 0 | 从源码独立重建，141.069 s | `build.log` |
| `make -C sim/o3 run-replay-order` | 0 | 121 / 20；tohost=1，load_replays=1 | `replay-order.log` |
| `make -C sim/o3 run-l9-fp` | 0 | 1860 / 616；另有 1 次预期 FS Off trap，驱动显示 617 events；tohost=1，load_replays=2 | `l9-fp.log` |
| `make -C sim/o3 run-l9-fp-smoke` | 0 | 890 / 267；tohost=1 | `fp-smoke.log` |
| `make -C sim/o3 run-smoke SPIKE_ARGS=+L7_CHECK` | 0 | 38 / 4；固定轨迹 PASS | `smoke.log` |
| `make -C sim/o3 run-rv64i-instructions SPIKE_ARGS=+L7_CHECK` | 0 | 70 / 14；固定轨迹 PASS | `rv64i.log` |
| `make -C sim/o3 run-l3-branch-dense SPIKE_ARGS=+L7_CHECK` | 0 | 1966 / 365；固定轨迹 PASS，load_replays=10 | `branch-dense.log` |
| `make -C sim/o3 run-l7-predict` | 0 | A：43787 / 19396；B：43838 / 19447；两组 tohost=1，layout/跨组正确性与三段性能检查 PASS | `l7-predict.log` |
| `make -C sim/o3 run-l7b-rvc` | 0 | 5673 / 2216；tohost=1 | `l7b-rvc.log` |

计数复核保存在 `evidence/metrics.jsonl`。最终二进制 SHA256：
`2ab6752953c4a2941a29c9fcf4841ef159970a004cca557fadd3dfa719f181fd`，
见 `evidence/binary.sha256`。最终父仓库及两个依赖 `git diff --exit-code` 均为 0；
无断言、fatal/inclusion、timeout 或失败标记。只保留运行脚本、日志与轨迹等生成物。

**结论：单槽 replay 等待环已修复，本次指定门禁全部通过。** 整数复现仍实际触发 replay，
完整 `l9_fp.S` 也触发 2 次 replay 并完成，不是以消除 replay 或裁剪 FP 程序换取通过。
原 FP 用例、watchdog、golden、期望、断言、槽数与 LSU 访存设计均未修改。
全套 L9 spec 合同/独立模块验收仍未完成；本次未运行 Spike、ACT4、访存类 cocotb、
综合/PPA/FPGA/SoC，不将本轮通过扩大为这些项目的证明。
