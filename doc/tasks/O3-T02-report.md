# O3-T02 阶段一报告

## 1. 交付状态与提交

2026-10-05，分支 `feat/L1-closure`。**阶段一文档已交付；spec 未冻结，阶段二未开始。**
本轮仅新增任务书、规格和本报告，没有修改执行代码或 Spike 源码。

| 项目 | 提交/标识 |
|---|---|
| 本轮开始时 HEAD（O3-T01 完成） | `5d684c5` |
| 第 0 步：只提交新任务书，已 push | `26c8a5d606a3034cbf86ec28116806ef3c00a24f`；提交信息 `Add O3-T02 Spike lockstep task` |
| 阶段一规格提交 | `0cc75cbe1b9d0338107263991fac8909c0776470`；`docs(o3): draft O3-T02 Spike lockstep phase-one spec` |
| 阶段一报告提交 | 包含本报告的后续提交；push 后在最终回复给出完整 SHA。可用 `git log -1 --format=%H -- doc/tasks/O3-T02-report.md` 提取，避免在提交内容中自引用尚未生成的 SHA |
| 仓库源码审查锚点 | `26c8a5d606a3034cbf86ec28116806ef3c00a24f`；与开始时执行代码相同 |
| Spike 源码审查固定提交 | `609dbe0b9994154833039209fa37151e7c05e9d4`，官方 `riscv-software-src/riscv-isa-sim`；实际安装采用此版本仍待 Q1 冻结 |

交付文件：[spike-lockstep-spec.md](../spec/spike-lockstep-spec.md)。
规格包含任务书阶段一要求的全部七项：固定版本/构建/API 审查、退休字段来源表、
比较与结束规则、随机生成器草案、门禁 CLI 草案、比对器自测计划、未决问题。
草案中的具体参数和接口选择均未被当作已定机制。

## 2. 阅读与源代码审查

已完整阅读 `agent.md`、`doc/O3-v1-plan.md`（含 §2.2 和 L5 行）、
`doc/design/CISLC-O3-BACKEND-DESIGN-BASELINE.md` §36.4 B45、任务书，
以及现有 `sim/o3/main.cpp:1–429`、`sim/o3/o3_tandem_top.sv:1–299`、
`sim/o3/check_trace.py:1–47`、`sim/o3/Makefile:1–113`、README 与环境描述。
另外阅读 `doc/LOOP.md` 和 O3-T01 规格相关合同，核对 ROB/WB/LSU/退休连线、
ACT4 现有构建/运行配置与固定程序输入。所有规格中代码现状描述都有文件/行号，
Spike 引用绑定完整提交，不以浮动 master 为证据。

审查发现的关键缺口（不是新发现的 DUT 功能错误）：

- `retire_info_t` 当前定义在 `rtl/common/o3_pkg.sv:450–462`，没有访存记录；
  任务书范围点名 `o3_types_pkg.sv`，需 Q3 明确类型落点/修改范围。
- Spike load log 仅记录 `(original_addr,0,len)`，不携带实际 load 数据
  （[Spike mmu.cc:309–310](https://github.com/riscv-software-src/riscv-isa-sim/blob/609dbe0b9994154833039209fa37151e7c05e9d4/riscv/mmu.cc#L309-L310)）。
  规格列出 RAM 重读或写回日志低位取值等不改 Spike 的替代方案；采用方式、x0 load
  和未来 MMIO 边界待 Q4。
- Spike 的 `sim_t::step()` 是 private，`processor_t::step()` 可调用
  （`S:riscv/sim.h:83,107–108`、`S:riscv/processor.h:236,251`）。
  上游 C++ 内部接口不作稳定公共 API 承诺（`S:README.md:99–102`）；
  规格没有将内部 commit log 宣称为稳定公共 API。
- 当前驱动没有 `--tohost-address`，也没有 tohost 结束路径
  （`sim/o3/main.cpp:233–261,386–405`），ACT4 runner 却传入该参数
  （`verification/act4/scripts/run_one.py:36–48`）。ACT4 链接图仍采用旧地址
  （`verification/act4/config/cislc-o3-rv64i/link.ld:2–18`），需 Q6 解决迁移和范围。
- `unified_memory` 包含旧代码/软件内存地址与不自然对齐访问
  （`sim/o3/tests/unified_memory.hex:2–20,22–32`），与当前 AXI RAM 范围
  （`sim/o3/o3_tandem_top.sv:194,207–209`）及本任务自然对齐要求冲突，待 Q7。

这里 `S:` 与规格相同，统一指上述固定提交的 Spike 源码。
未运行程序；没有确认新的 DUT 错误，也没有宣称 ACT4/Spike 当前可用。

## 3. 命令、结果与日志

| 命令/操作 | 本轮结果 | 日志/证据位置 |
|---|---|---|
| `git status --short --branch`、`git log -1 --oneline` | 初始分支正确，仅任务书未跟踪，HEAD=`5d684c5` | 本轮工具输出 |
| `git add -- doc/tasks/O3-T02-spike-lockstep.md`；`git commit -m 'Add O3-T02 Spike lockstep task'`；`git push` | 成功；只提交1个任务书文件，远端 `5d684c5..26c8a5d` | git 历史与本轮工具输出 |
| `git ls-remote https://github.com/riscv-software-src/riscv-isa-sim.git HEAD` | 沙箱内连接失败；按权限流程重试后成功，读取上述 SHA | 本轮工具输出 |
| `git clone --depth 1 https://github.com/riscv-software-src/riscv-isa-sim.git /tmp/o3-t02-spike-source` | 成功；仅供阅读，HEAD 与固定 SHA 相符 | `/tmp/o3-t02-spike-source`；`/tmp/o3-t02-phase1/spike-source.log` |
| `git -C /tmp/o3-t02-spike-source rev-parse HEAD`、`git -C /tmp/o3-t02-spike-source status --porcelain` | 固定 SHA 符合；源码工作树干净 | 同上 |
| `scripts/lint.sh` | **本地 lint PASS**，0 errors、101 warnings；未启用 strict，不代表功能正确 | `/tmp/o3-t02-phase1/lint.log` |
| Python stdin 静态检查文档中的路径/行号区间 | PASS；检查实际源文件存在、引用区间合法，不等同于语义/运行验证 | `/tmp/o3-t02-phase1/reference-check.log` |
| `git diff --check`、暂存区检查、提交文件清单检查 | PASS；本轮差异仅三个 Markdown 文件 | `/tmp/o3-t02-phase1/scope-check.log`；git 历史 |
| Spike configure/build/install、最小适配器链接/单步 | **未运行**；只写未来命令草案 | 无 |
| Alan cocotb、O3-T01 回归、ACT4、Spike 固定/随机/注入自测 | **未运行**；阶段一没有实现这些测试/门禁 | 无 |

本地 lint 输出：

```text
[lint] verilator : Verilator 5.050 2026-07-01 rev conda-forge build 0
[lint] filelist  : rtl/rtl.f
[lint] top       : o3_core
[lint] errors=0 warnings=101
[lint] PASS —— RTL 解析通过（不代表功能正确）
```

阶段一为文档任务，没有新增模块行为，故没有新增/运行 cocotb，未改变模块状态或
闭环进度，未改 `doc/LOOP.md`。不得把本报告当作 L5 闭环、Spike 0 差异、
随机400000条通过或 ACT4 51项复验的证据。

## 4. 偏离、未决问题与停止点

与阶段一任务范围的偏离：**无**。没有修改任何 `.sv`、`.cpp`、`.py`、Makefile，
也没有修改 Spike 源码。没有安装/构建 Spike、实现随机生成器或进行阶段二操作。

完整问题及可审阅选项见规格 §8，编号保持一致：

| ID | 未决问题 |
|---|---|
| Q1 | 实际采用的 Spike SHA、构建依赖/ABI、链接方式及 build 入口 |
| Q2 | 固定版本内部接口依赖、参考初始化及单步失败/异常诊断 |
| Q3 | 退休类型落点与允许文件范围、访存观测来源、ROB 身份及同拍更新合同 |
| Q4 | 两侧 load 数据取值（含 x0）、store/mask 和地址规范化 |
| Q5 | JSON schema、FP/CSR/异常预留以及差异报告/退出码 |
| Q6 | ACT4 51项清单、旧图迁移、tohost 协议与 `verification/act4/` 修改范围 |
| Q7 | legacy unified_memory 纳入全部固定门禁的处理方式 |
| Q8 | 随机分布、窗口、PRNG/种子、长度计数和默认 CLI 参数 |
| Q9 | 终止同拍 lane 消费、fatal/差异优先级及周期/无退休/宿主超时 |
| Q10 | 自测注入接口与正式门禁隔离 |

本报告提交并 push 后停止，等待用户审阅与冻结；未决问题不在本轮自行决定。


## 5. 阶段二交付记录（2026-10-06）

用户以 `b37a896` 冻结 §8 Q1–Q10，并授权发现 DUT 真 bug 后跑完全部种子再汇总。
阶段二实现已完成，**零差异验收未通过**；保留所有现有期望、测试和断言，未修执行 RTL。
任务分支仍为 `feat/L1-closure`。

| 提交 | 内容 |
|---|---|
| `db8b083053a93863a32146db4e9e4984428cc3fe` | 进程内 Spike、退休访存观测、JSONL v2、生成器、ACT4 SD/AXI 迁移、超时/注入 |
| `b227994cbafea38b6b765dc9cea2164eb48e7667` | ACT4 数据容量/邮箱布局修正；随机生成器独立 Spike 预跑 |
| `857442d` | 同步迁移 Sail RAM PMA；完整重新生成 51 项 |
| 本阶段收尾提交 | `git log -1 --format=%H --grep='close O3-T02 phase-two failure evidence'` 可查询；提交自身 SHA 不在内容中自引用 |

### 5.1 实现选择与范围

Q3 选择 backend 内 ROB-indexed 旁路表，不改变 ROB complete/valid/退休控制。
分配清槽；store 在 SQ execute 时采样；load 在真实 WB 消费时采样。
LSU 新增仅观测的 pending/result 地址与大小寄存器，随转发、replay、迟到响应与
Result 背压保留；M 时不采样 killed load，存活老 load 照常记录。
类型定义保持原 `o3_pkg.sv` 位置；访存类型 0/1/2=none/load/store，大小在 RTL
存 log2(bytes)，JSON 输出 1/2/4/8。地址保存完整 64 位以检出非法高位，正常比较
56 位物理地址；store 数据按大小截断，load 数据为格式化 WB 值，x0 load 不比较数据。
FP/CSR/异常 valid tie-off 为 0，JSON 六个预留字段 null。本阶段没有修改 Dxx/Bxx。

参考端：固定原版 Spike，sim_t 无 DTB，单 hart RV64I/M/Bare、PMP=0、trigger=0。
共用初始 loader bytes，运行时内存独立；每 lane 单步一次，minstret 必须增长 1。
PC/编码独立预取；整数事件取 commit log；load 地址取 log，再读参考 RAM 并独立
符号/零扩展。日志文本写 `/dev/null`，结构日志仍开启。首差异不重同步，退出 2；
fatal 优先；周期/10000 周期无退休超时退出 3。SD tohost 非零退休后仍比较同拍所有 lane。

测试 RAM 扩为 2 MiB以覆盖 Q8 数据窗口；未改 DUT cache/执行机制。
生成器 nominal template 权重 45/15/5/20/15；loop/control setup 会改变动态分布。
x1–x3 保留，访存使用窗口内自然对齐 offset；每种子目标恰好 3000 动态退休，
同拍 younger lane 可增加最终比较数量。默认种子 1–200，batch 保留每项失败并继续。
独立 `--spike-reference-only` 先证明生成程序合法和动态计数；200 项均为 3000。
正式 gate 清 `O3_INJECT`，仅五类自测显式设置记录副本扰动。

Q6 实际镜像图：code=0x80000000，data=0x80100000/256 KiB，tohost=0x801ff000。
初次 60 KiB data 不足，修正为原有 256 KiB；第二次 Sail 仍用旧 RAM PMA，随后
同步地址迁移。均为基础设施问题，已解决，不删除生成项、不放宽测试。
ACT4 upstream 保持 `dfa582359db885ae4c6ed1fa82faef60874e212c`，最终完整生成 51 ELF；
构建输出 `255 succeeded` 为各构建步骤数，不是 255 个测试。

### 5.2 Spike 构建与环境证据

Alan 源码 `/tmp/cislc-o3-spike-src` 完整 SHA
`609dbe0b9994154833039209fa37151e7c05e9d4`，原版工作树干净。
源码从阶段一已核对副本同步；默认 configure/make/install，日志
`/tmp/cislc-o3-spike-build/{configure,build,install}.log`。命令完整写入
`sim/o3/README.md`。安装前缀 `/home/chen/miniforge3/envs/cislc-o3`。

| 项目 | 实测 |
|---|---|
| Spike 编译器 | system GCC 13.3.0，默认 -g -O2 -std=c++2a，make -j4 |
| Simulator 编译器 | conda GCC 16.2.0，C++20；pkg-config -lriscv + prefix rpath |
| Python/cocotb/Verilator | 3.12.14 / 2.1.0 / 5.050 |
| libriscv.so SHA256 | `09fc861e8860bc4b8e000b422ab39312dfe082e69c4e085fb0e5dd9f6ca748e6` |
| 实际动态库 | ldd 指向 conda prefix 的 libriscv.so；无需独立 -lfesvr |
| 依赖 | DTC、pkg-config、Boost system/regex、pthread；FESVR/FDT/disasm/softfloat 按默认 Spike 构建 |

Alan 工作目录 `/home/chen/FUN/CISLC-O3-o3t02` 是隔离 worktree。
GitHub push 成功；Alan 原有 17897 代理失效，通过已 push 的 Git bundle 精确 fetch
提交，再用明确 SHA checkout；未修改共享代理、原 checkout 或 Flow 文件。
开发阶段有一次 FETCH_HEAD 在主 worktree 获取、子 worktree 不能解析，改为明确 SHA；
该轮 `trial` 只作开发日志，不作最终同 SHA 证据。

本地每个实现提交前 `scripts/lint.sh` PASS：0 errors / 101 warnings；日志
`/tmp/o3-t02-{lint,followup-lint,act4map-lint}.log`。收尾提交前另跑 lint。
AST 静态解析通过，不能替代 Alan 执行结果。

### 5.3 开发验收结果与最终提交复验

Alan 总证据目录：`/home/chen/FUN/CISLC-O3-runs/20261005-o3t02/`。

| 验收 | 开发轮次实际结果 | 日志 |
|---|---|---|
| make -C sim/o3 build | PASS，db8b083 / b227994 两次重建成功 | trial/build.log、trial/build-b227994.log |
| make -C sim/o3 run-spike-all | 5 个既有程序均 0 差异，固定 checker 全 PASS，共 396 条 | trial/spike-gates.log |
| make -C sim/o3 run-spike-selftest | 5/5 检出且字段、退休序号正确 | trial/selftest/summary.json，五类 .log |
| make -C sim/o3 run-spike-random SEEDS=1-200 | 200 项全跑完；1 PASS、199 FAIL，全部首差异 PC；匹配前缀 114412 条 | trial-b227994/random/summary.json，每种子 log/jsonl/hex/meta/reference.log |
| 独立 Spike 随机预跑 | 200/200 合法；每项 3000，共 600000 条 | 同上 reference.log |
| ACT4 全量生成及 run-spike-act4 | 51 项全生成/执行；15 PASS、36 FAIL、0 INFRA_ERROR | trial/act4-857442d.log、trial/act4-run-857442d.log、trial-857442d/act4/summary.json |
| O3-T01 全部 60 条命令 | 收尾提交后的完整复验逐项保存，不以之前 O3-T01 的旧 PASS 替代 | final/commands.tsv、final/summary.json |

随机通过的是 seed 120，共比较 3001 条（含 tohost 同拍年轻 lane）。其余 199 项
首个失败前成功匹配条数各自保存在 summary；匹配合计 114412，包含失败当前条的
DUT 观测记录合计 114611，不能把这些当作 200 项各 >=2000 且 0 差异的通过证据。

**同一最终 SHA 复验**：本收尾提交 push 后，在 Alan 原样执行 O3-T01 final/commands.tsv
中的全部 60 条命令，再执行 fixed/selftest/random/ACT4 build/run 和历史 unified。
使用 `/tmp/o3t02_acceptance.py`，相同 make 目录串行，不同目录最多三个同时运行；
断言、测试、seed、停止条件完全不改。全部命令即使失败也继续。
最终目录 `final/` 的 `sha.txt`/`sha-end.txt` 必须相同且等于本收尾提交；
`commands.tsv` 逐项记录命令、退出码和日志，`summary.json` 保存 O3-T01 60 项汇总，
`random/summary.json`、`selftest/summary.json`、`act4/summary.json` 保存全量结果。
最终 ACT4 ELF manifest/sha256 和工具/动态库指纹保存于同目录。最终回报以该目录
实际结果为准，本表中的开发轮次不能替代它。

### 5.4 确认的 DUT bug 与缩减复现

最小复现随机种子为 1。原差异：cycle=3911、retire_idx=1022、lane=0，
DUT PC=0x80000ea4，Spike PC=0x80000e84；之前退休的 BNE
PC=0x80000e8c、x2=3，参考应回到 0x80000e84 继续有界循环。
双方完整记录和此前 32 条在 `trial-b227994/random/seed-1.log`。

独立缩减为 `sim/o3/repros/branch_loop.hex`，12 个静态指令、循环仅 2 次：
PC=0x8000001c 的 BNE 退休时 x2=1，正确后继应是 0x80000014；
DUT 下一条却到 0x8000002c。差异如下（完整版在 minimize/loop-pad1-n2.log）：

```text
MISMATCH field=pc cycle=60 retire_idx=8 lane=0
DUT   pc=0x008000002c instruction=0x0000006f rd_write=false
SPIKE pc=0x0080000014 instruction=0x00120213 rd=4 rd_wdata=0x2
```

Alan O3-T01 已验证的旧二进制（SHA `5d684c5726cc6f75d023d8b74311bcd91f58f60b`）
运行同一镜像、max-retires=9，也在 order=8 退休 PC=0x8000002c；原 JSON v1
轨迹在 `trial-b227994/minimize/old-dut.jsonl`。证明 bug 在退休观测新增之前已存在。
64 个 loop alignment/count 激励中 pad=1/5、iterations>=2 稳定出现同类差异。
本阶段不定位到未经证实的具体模块/拍，不修 RTL；用户随后已直接授权 O3-T02-fix。

### 5.5 ACT4 manifest（全部 51 项）

下表记录迁移后实际生成的完整集合；对应最终生成 ELF/hash 见 final/act4-manifest.sha256。
每项均执行，36 FAIL 的具体首差异保留在独立日志；不以 mailbox PASS 替代逐条比对。

| ELF | 初次完整 Spike 结果 |
|---|---|
| `I-add-00.elf` | FAIL |
| `I-addi-00.elf` | FAIL |
| `I-addiw-00.elf` | FAIL |
| `I-addw-00.elf` | FAIL |
| `I-and-00.elf` | FAIL |
| `I-andi-00.elf` | FAIL |
| `I-auipc-00.elf` | PASS |
| `I-beq-00.elf` | FAIL |
| `I-bge-00.elf` | FAIL |
| `I-bgeu-00.elf` | FAIL |
| `I-blt-00.elf` | FAIL |
| `I-bltu-00.elf` | FAIL |
| `I-bne-00.elf` | FAIL |
| `I-fence-00.elf` | PASS |
| `I-jal-00.elf` | PASS |
| `I-jalr-00.elf` | FAIL |
| `I-lb-00.elf` | PASS |
| `I-lbu-00.elf` | FAIL |
| `I-ld-00.elf` | PASS |
| `I-lh-00.elf` | PASS |
| `I-lhu-00.elf` | PASS |
| `I-lui-00.elf` | PASS |
| `I-lw-00.elf` | PASS |
| `I-lwu-00.elf` | PASS |
| `I-nop-00.elf` | PASS |
| `I-or-00.elf` | FAIL |
| `I-ori-00.elf` | FAIL |
| `I-sb-00.elf` | PASS |
| `I-sd-00.elf` | PASS |
| `I-sh-00.elf` | PASS |
| `I-sll-00.elf` | FAIL |
| `I-slli-00.elf` | FAIL |
| `I-slliw-00.elf` | FAIL |
| `I-sllw-00.elf` | FAIL |
| `I-slt-00.elf` | FAIL |
| `I-slti-00.elf` | FAIL |
| `I-sltiu-00.elf` | FAIL |
| `I-sltu-00.elf` | FAIL |
| `I-sra-00.elf` | FAIL |
| `I-srai-00.elf` | FAIL |
| `I-sraiw-00.elf` | FAIL |
| `I-sraw-00.elf` | FAIL |
| `I-srl-00.elf` | FAIL |
| `I-srli-00.elf` | FAIL |
| `I-srliw-00.elf` | FAIL |
| `I-srlw-00.elf` | FAIL |
| `I-sub-00.elf` | FAIL |
| `I-subw-00.elf` | FAIL |
| `I-sw-00.elf` | PASS |
| `I-xor-00.elf` | FAIL |
| `I-xori-00.elf` | FAIL |

### 5.6 偏离和交接

Q1–Q10 未改变；原任务书“发现真 bug 停下”已由本轮用户明确替换为跑完其余种子。
验收事实：随机及 ACT4 零差异目标未达成，不宣称 L5 闭环通过。
本任务保留原程序/期望/checker/断言；unified 按 Q7 标为历史。
按 2026-10-06 用户指令，收尾复验结束后直接执行 O3-T02-fix，无阶段一：逐 bug
缩减、定位模块/拍/条件、对照 Dxx/Bxx、补固定门禁和 cocotb、每 bug 单独提交，
最终同 SHA 全量复验；只有必须改变设计决策时才停。

## 6. 修复记录（O3-T02-fix）

### 6.1 Bug 1：busy 恢复丢弃更老执行重定向

根因模块 `rtl/frontend/redirect_arbiter.sv`，原 `accept_exec` 无条件要求
`!recover_busy_q`。单 BRU 可因操作数等待而先解析年轻 JAL，再解析更老 BNE；
因此单 BRU 不保证解析按程序顺序。复现为 `sim/o3/tests/branch_loop.hex` 的
12 条静态指令（阶段二原件仍在 repros/，不删除证据）。

原 RTL 周期 45：JAL PC=0x8000002c 在 Result，触发恢复到自身；BNE
PC=0x8000001c 在 RegRead，x2=1，正确目标 0x80000014。周期 46：BNE
Result 有效且 mispredict=1，backend 接受更老 checkpoint 恢复；前端 busy=1
却拒绝该请求。周期 47 继续从 JAL 目标分配，周期 60 的 order=8 退休
PC=0x8000002c，Spike 要求 PC=0x80000014、x4=2。逐拍日志保留在 Alan
`/home/chen/FUN/CISLC-O3-runs/20261006-o3t02-fix/loop-before.log`。

D24 已明确规定恢复期间更老有效请求应替换当前恢复，并防止旧完成覆盖新状态；
本次无需改变 Dxx/Bxx。修改仅在此模块按相对 FTQ head 的环形年龄、同一动态
FTQ 身份内的 slot 判断更老，接受后整份请求替换，重新发起快照读取和 kill；
保持替换优先于当拍旧 done，及原有 RAS done 身份校验。

新增 cocotb `older_exec_replaces_busy_recovery` 覆盖跨块、同块、环形回绕、
旧 done 同拍/后拍及年轻请求拒绝。原 RTL `fff0cd3` 加新测试在 21ns 必然
FAIL：older redirect valid=0；相同测试及全部原有分支恢复测试在独立临时修复
构建中 4/4 PASS。日志 `arbiter-before.log`、`arbiter-after-trial.log`；此为
对照证据，不能替代提交 SHA 上的最终验收。新增 `run-spike-branch-loop`
并纳入 `run-spike-all`，保留五个既有固定程序及其期望/checker/断言不变。
本地 lint 0 errors / 101 warnings，PASS；提交后继续 ACT4/随机全量迭代。
