# O3-T08：L10 实施与 Alan 验证报告

实施依据：冻结 spec `0b812d6`，Q1～Q8 已纳入；分支 `feat/L1-closure`。
本轮从 GitHub 拉取并确认 `bc4a62d`，按任务书顶部 2026-10-07 用户修订连续执行 T08b→T08c。
收尾：**L10 带已知问题收口**。T08b `2e5333b`、T08c `1d0d6f8`；Alan 同 SHA
分别 126/126、132/132 模块通过，八项既有整核回归与 T08a 全通过；完整 VM 的旧分支断言
失败保留。全部自行决定与已知问题见下文；L8/L11 未开始。

## T08a

状态：**T08a 实现与指定门禁通过**；Sv39/硬件 A/D 尚未实现，不宣称完整 L10 完成。
代码 SHA：`8610b9a3d0dd5695c0a5ef651b4a567e81403d6f`。

范围：M/S/U CSR 与 trap/xRET；委托与指令边界中断；WFI；counteren、Sscofpmf、time/Sstc；
16 项 G=2 PMP 与 PMA 的取指/数据检查；PMP 与 ADUE 有效变化同步。satp 本步只接受 Bare。
`fetch_return_queue` 未修改；TLB/PTW/硬件 A/D 在 T08b/c 才实现。

实现细节：

- 保留 `VPN_W=52`，Sv39 的 27 位 VPN 留 T08b 添加专用常量。
- PMP 原始 54 位 pmpaddr 存储与架构读视图分开；TOR 两端屏蔽低两位，NAPOT bit 0 强制为 1。
  cfg 请求 NA4 时只保留原 A 字段，其余可写字段照常归一；最低编号的部分覆盖仍失败。
- ADUE 有效变化复用 `SYS_SATP` 的 frontend sync/refetch；STCE 单独变化不推进 epoch。
- HPM 本拍按旧事件/过滤配置计数；OF 基准取本拍软件写值，硬件溢出置位最后合并；
  显式写计数器抑制该计数器本拍增量和溢出。LCOFIP 的硬件置位优先于软件清。
- 取指使用既有 S2 候选/S3 优先级路径，检查整块 16B；故障不发 L2 请求，缓存命中重新检查权限。
- 四个平台中断支持 `+irq_m_ext_at`、`+irq_m_timer_at`、`+irq_m_soft_at`、`+irq_s_ext_at`，
  从指定 mtime 周期起保持置位，默认关闭；mtime 每拍递增。
- 只读 whole-core 事件监测器保留 producer 聚合与逐拍计数断言，参考模型扩展为特权过滤/OF。

### 开发检查与修复

Alan 开发目录：`/home/chen/FUN/CISLC-O3-runs/20261007-t08a-0b812d6-work/`。
它由早先 T08a 独立目录创建，HEAD 为 `5f12346`，本地 `0b812d6` 工作区允许范围的文件通过
rsync 同步；此目录为未提交开发快照，不作为最终 SHA 验收。
环境：`source /home/chen/miniforge3/bin/activate cislc-o3`，Verilator 5.050、cocotb 2.1.0，
Python CLI 3.12.14 / cocotb 嵌入解释器 3.12.12。
命令、退出码、stdout/stderr 分别在 `evidence/<轮次>/commands.jsonl` 与同名 `.log`。

| 轮次 | 命令 | exit | 结果 |
| --- | --- | --- | --- |
| dev01 | `bash scripts/lint.sh`；`make -C sim/cocotb/<模块> -j8 SIM=verilator TEST_SEED=1`（csr_file、hpm_counters、pmp_checker、commit_ctrl、frontend_sync_ctrl、wfi_ctrl、decoder、icache） | 全 0 | 新机制定向用例通过 |
| core01 | `make -C sim/o3 build 'VERILATOR=verilator -j 8'`；`make -C sim/o3 <目标> SPIKE_ARGS=+L7_CHECK` | build 及前七个目标 0；run-l9-fp 2 | L9 程序仍使用旧 misa 精确期望，按 Q4 修正；run-replay-order 本轮未执行 |
| core02 | 同上，run-l10-priv 加八项 13.3 回归 | 全 0 | tohost 与既有 golden 轨迹检查通过 |
| gate01 | 全套 L7a/L7b/L9 及受影响非访存 cocotb | backend 2，其前各套件 0 | backend 旧 L3 预测统计期望与 L7 实际预测器不匹配，逐条退休 golden 完全通过 |
| gate02 | backend、backend_control、backend_issue_queue、free_list、rename_entry_gate、rename_map_table、rename_stage、rob、prf_read_arbiter、fu_completion_fifo、wb_alu_kill、trap_ctrl，另 FTQ harness | 全 0 | 开发检查通过 |

修复记录：

1. 按 Q4 将 `l9_fp.S` 的 misa 精确期望改成 `0x800000000014112C`；没有裁剪 FP 自查。
2. backend/backend_control 的旧 Makefile 仅收集 `rtl/` 文件，漏掉 L9 CVFPU 文件，backend
   也缺 monitor include 根路径。改为从唯一 `rtl/rtl.f` 收集完整源码，沿用既有 CVFPU waiver
   和 include 路径；不新增 waiver、不改 CVFPU 源码。
3. backend 分支密集用例的 40 correct / 80 mispredict 来自 L3 顺序预测器。先核实未改动 RTL
   的 pre-L10 `f0f410640a27abe4f62f3cf728f387ab8b6bde6e` Alan 证据：
   `/home/chen/FUN/CISLC-O3-runs/20261007-t07-replay-f0f4106/evidence/branch-dense.log`
   已为精确 80 / 40。本级同一 golden 程序同为 80 / 40，据此修正旧统计期望，仍保留
   精确统计、所有 PC/指令/rd/rd_wdata/写使能 golden 检查和 replay 检查。
4. 开发时检查并修复 frontend_sync_ctrl fixture 的 kind 初始化插入导致的缩进问题；
   原 FENCE.I 完整等待/失效确认路径与 200 事务随机用例继续执行。

### 未做项

T08b/c、Spike、ACT4、特权测试套件、独立访存类 cocotb、formal、综合/时序/PPA、FPGA/SoC：未运行。
报告与 LOOP 的后续提交仅包含文档；验收绑定下列代码 SHA，文档提交不冒充重跑代码门禁。


### 最终代码 SHA 门禁

代码 SHA：`8610b9a3d0dd5695c0a5ef651b4a567e81403d6f`（GitHub branch HEAD 已核对）。
Alan cwd：`/home/chen/FUN/CISLC-O3-runs/20261007-t08a-8610b9a/`。
经本地代理 `127.0.0.1:7897` 和 SSH 反向端口 `18808` 从 GitHub clone 精确分支 HEAD；
CVFPU/common_cells 分别从 GitHub 按 gitlink 初始化到 `1b220f3` / `6aeee85`，未修改源码。
测试前后 tracked diff 均为空。工具版本、SHA、依赖、运行 cwd 在 `evidence/final/provenance.log`。

- 模块门禁：`make -C sim/cocotb/<模块> -j8 SIM=verilator TEST_SEED=1`。
- FTQ 另用 `make -C sim/cocotb/bpu -j8 SIM=verilator TEST_SEED=1 COCOTB_TOPLEVEL=ftq_training_tb_top COCOTB_TEST_MODULES=test_ftq`。
- lint：`bash scripts/lint.sh`，exit 0；**0 errors / 364 warnings**（非 strict 门禁）。
- 整核构建：`make -C sim/o3 build 'VERILATOR=verilator -j 8'`，exit 0；从本目录源码重新构建。
- 整核目标：`make -C sim/o3 <目标> SPIKE_ARGS=+L7_CHECK`，不含 `--spike`。
- 每条命令与 exit：`evidence/final/commands.jsonl`、`evidence/final-core/commands.jsonl`；
  各命令 stdout/stderr 为对应 `<模块或目标>.log`，汇总为 `evidence/final/summary.json`。

| 模块 / harness | exit | 用例 |
| --- | --- | --- |
| `ubtb` | 0 | 3/3 PASS |
| `main_btb` | 0 | 2/2 PASS |
| `tage` | 0 | 2/2 PASS |
| `ras` | 0 | 2/2 PASS |
| `branch_recovery` | 0 | 4/4 PASS |
| `fetch_buffer` | 0 | 2/2 PASS |
| `fetch_return_queue` | 0 | 3/3 PASS |
| `bpu_slow_check` | 0 | 1/1 PASS |
| `redirect_arbiter` | 0 | 2/2 PASS |
| `bpu` | 0 | 5/5 PASS |
| `rvc_expander` | 0 | 3/3 PASS |
| `ifu_f0` | 0 | 6/6 PASS |
| `ifu_f1` | 0 | 18/18 PASS |
| `l7_recovery` | 0 | 2/2 PASS |
| `hpm_counters` | 0 | 19/19 PASS |
| `csr_file` | 0 | 9/9 PASS |
| `fpu_fu` | 0 | 2/2 PASS |
| `pmp_checker` | 0 | 2/2 PASS |
| `wfi_ctrl` | 0 | 1/1 PASS |
| `decoder` | 0 | 1/1 PASS |
| `commit_ctrl` | 0 | 3/3 PASS |
| `frontend_sync_ctrl` | 0 | 2/2 PASS |
| `icache` | 0 | 4/4 PASS |
| `backend` | 0 | 2/2 PASS |
| `backend_control` | 0 | 1/1 PASS |
| `backend_issue_queue` | 0 | 2/2 PASS |
| `free_list` | 0 | 2/2 PASS |
| `rename_entry_gate` | 0 | 1/1 PASS |
| `rename_map_table` | 0 | 2/2 PASS |
| `rename_stage` | 0 | 1/1 PASS |
| `rob` | 0 | 3/3 PASS |
| `prf_read_arbiter` | 0 | 1/1 PASS |
| `fu_completion_fifo` | 0 | 1/1 PASS |
| `wb_alu_kill` | 0 | 1/1 PASS |
| `trap_ctrl` | 0 | 1/1 PASS |
| `ftq` | 0 | 3/3 PASS |

共 36 个套件，**119/119 PASS**，FAIL=0、SKIP=0。固定种子为 1。

| 整核目标 | exit | 周期 / 退休与 trap |
| --- | --- | --- |
| `run-l10-priv` | 0 | 3493 / 422 退休 + 17 trap（439 events）；tohost=1 |
| `run-smoke` | 0 | 38 / 4；既有自查/轨迹检查 PASS |
| `run-rv64i-instructions` | 0 | 70 / 14；既有自查/轨迹检查 PASS |
| `run-l3-branch-dense` | 0 | 1966 / 365；既有自查/轨迹检查 PASS |
| `run-l7-predict` | 0 | A：43787 / 19396；B：43838 / 19447；两组 tohost、布局、跨组正确性/性能检查 PASS |
| `run-l7b-rvc` | 0 | 5673 / 2216；既有自查/轨迹检查 PASS |
| `run-l9-fp-smoke` | 0 | 890 / 267；既有自查/轨迹检查 PASS |
| `run-l9-fp` | 0 | 1860 / 616 退休 + 1 trap（617 events）；tohost=1 |
| `run-replay-order` | 0 | 121 / 20；既有自查/轨迹检查 PASS |

`run-l10-priv` 的 17 次 trap 为 12 次 M 入口（5 次非法、5 次 S ECALL、2 次 PMP）和
5 次 S 入口（2 次 U ECALL、SSI/STI/LCOFI 各 1）；程序的 s3=12 计的是 M handler，
s4=7 记录三种 S 中断。CSR 用例另验证中断 cause 的最高位与委托/全局使能。
`l7_predict_summary.json` 的三个窗口 EXEC=5/2/2、CMT_REGION=2003/2502/4003，两组与既有基线一致。
B49 的跨行拆分、L8 L1D clean、MMIO/平台中断器件未扩展；独立 LSU/访存 cocotb 按 spec 未运行。
Q7 的 TLB 不缓存 A=0、ADUE=0 时由 PTW 交付一次 pending page fault，将由 T08b/c 接入；
本步没有 TLB 回填路径，不能把上述 CSR 同步测试作为该性质的证明。

## T08b（2026-10-07 用户修订）

实现 Sv39 ITLB/DTLB（8×4 + 4 大页、树 PLRU）、共享单 PTW 与轮转仲裁、
1×4/2×4 walk cache、路径累计 G、四种精确 SFENCE、satp.MODE=8、epoch 隔离，
以及 ICache 物理 tag/PA、LSU 翻译请求与单槽 TLB-miss replay、SQ 保存 PA、共享 DCache PTW 物理读口。
本步 PTW 按 Svade 判 A/D；不做硬件写 PTE。

开发目录：Alan `/home/chen/FUN/CISLC-O3-runs/20261007-t08b-bc4a62d-work/`。
开发快照基于 T08a clone，允许范围文件 rsync；开发证据不冒充同 SHA 验收。
`evidence/t08b-gate02/commands.jsonl` 记录全部命令/cwd/exit；37 个模块套件共 126/126 PASS；
八项整核回归与 T08a `run-l10-priv` 全通过；`scripts/lint.sh` 0 errors。
`run-l10-vm VM_AD=0` exit 2，首个失败为 backend 的正确分支推进断言；保留断言并追加诊断上下文。
同 SHA 交付门禁已完成：代码 `2e5333bf62201cd428a73481b2401d7b1c3c29bc`，
Alan cwd `/home/chen/FUN/CISLC-O3-runs/20261007-t08b-final/`，GitHub clone + 原 gitlink 子模块初始化。
`python3 sim/o3/tests/run_t08_gates.py evidence/final --build --core`，逐项命令与 exit 在
`evidence/final/commands.jsonl`；37 套件 **126/126 PASS**（FAIL/SKIP=0），八项整核回归、
T08a `run-l10-priv`、build、lint exit 0；完整 VM_AD=0 exit 2。
测试前后 tracked diff 为空，SHA 与状态记录在 `evidence/sha.txt`、`evidence/status-{before,after}.txt`。

开发失败与修复：

- ICache 接入时误移除 Bare 同物理行未决回压，既有用例失败；恢复该回压，4/4 PASS。
- 新 PTW 性能源接入后，whole-core 参考聚合遗漏该源；扩展只读参考聚合的源数组，保留全部断言。
- 复制来的旧生成目录引用错误 cocotb 路径；采用每轮独立 `SIM_BUILD`，不修改 RTL/期望来绕过构建失败。

## 自行决定（T08b；T08c 追加）

| 问题 | 决定 | 依据 | 涉及文件 |
| --- | --- | --- | --- |
| MMU 内部 VPN 宽度与存储 | 保留外部 `VPN_W=52`，内部 `sv39_vpn_t=27`；TLB 用寄存器，组织固定 X4 并断言 cfg 一致 | spec 4.2/4.3 允许实现自选；B49 | o3_types_pkg、itlb、dtlb、walk_cache |
| 请求身份/上下文 | PTW 请求快照 root/ASID/epoch/有效特权/访问类型/SUM/MXR/ADUE；pending fault 只给相同上下文的重试 | RISC-V Sv39 访问权限与 satp 上下文；X7、D27 | o3_types_pkg、itlb、ptw |
| 多命中优先级 | 4K 项优先大页，各阵列选最低编号；同键 walk-cache 重遍历覆盖原项 | spec 4.1 不允许多命中断言；规范允许软件重叠映射 | itlb、walk_cache |
| DTLB 请求口 | 现有 LSU 只使用端口 0；额外 AGU 口显式 tie-off 留 L8；miss 入已有 replay 槽，不占 DCache MSHR | L3 单发射简化，X2/X16；不扩展 L8 | dtlb、load_store_unit |
| 取指慢路径 | S1 翻译 miss 保留该请求并重查；缓存阵列 S0 并行读，S2 使用翻译 PA；最近行键为 PA+epoch+priv | spec 5.1；D27 | icache |
| SFENCE 源操作数/epoch | ROB 保存第二源 preg；队头借用两个 PRF 读口；数据侧发一次范围失效、CSR epoch++，再同步前端 ITLB | spec 6.1；B22/B24、D26 | rob、backend、commit_ctrl、csr_file、frontend_sync_ctrl |
| PTW 取消 | drain 已接受物理读，返回旧 epoch 身份仅供 owner 释放；TLB 不回填/不交付旧结果 | spec 4.5、D27；PTW 读不被 kill | ptw、itlb |

规范依据：[RISC-V Supervisor ISA 1.13 的 Sv39/翻译算法与 SFENCE](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)。

## T08c：硬件 A/D 与 L10 收口

实现 DCache 完整 64 位 PTE CAS（命中与 refill 后均比较）、PTW 的投机 A 更新与比较失败重遍历、
ROB `needs_d` 元信息及退休前缀阻挡、队头 D 重遍历、LSU 单个 D-store 身份保存与年轻访存等待。
D 成功后精确失效该 VA 的本地 DTLB 项，重新翻译、更新 SQ PA 并进行原只读目标 probe；
最终成功才清 ROB needs_D，错误保留原 store VA/cause。ADUE 复位仍为 1。
原 L3 单发射/单 pending/replay、B04 顺序 load 简化保留，跨 line/跨页拆分与 LR/SC 留 L8。

新增/扩展 MMU 六组用例、真实 DCache PTE 入口两组用例、commit_ctrl needs_D 和 ROB 退休前缀用例；
保留全部既有用例/断言/golden。`run-l10-ad` 是额外的正向 A/D 整核程序，完整 `run-l10-vm` 原样保留。
只读事件聚合增加 AD 源，继续逐拍检查 producer 聚合、HPM 与已有 L7 检查。

开发 cwd：`/home/chen/FUN/CISLC-O3-runs/20261007-t08c-2e5333b-work/`。
该目录为 rsync 开发快照，最终代码 SHA 门禁另外从 GitHub clone。

| 轮次 | 命令与范围 | exit / 结果 |
| --- | --- | --- |
| dev01 | `bash scripts/lint.sh` | 0 errors，exit 0 |
| dev02 | runner `--modules mmu commit_ctrl --build --core` | MMU 6/6、commit 5/5；八项整核回归与特权自查通过；VM exit 2，无进展超时 |
| dev03 | runner `--modules rob mmu_pte`；`make -C sim/o3 run-l10-ad SPIKE_ARGS=+L7_CHECK` | ROB 4/4；PTE harness 编译枚举类型错误；AD 正向程序 PASS 15892 周期/6252 退休 |
| dev04 | runner `--modules mmu_pte` | harness 显式初始化 amo_op 后 2/2 PASS；lint exit 0 |
| gate01 | runner `--build --core` | 38套件/132 用例，HPM 1个旧事件边界刺激失败；八项回归、priv、AD通过；VM超时 |
| hpm-fix | runner `--modules hpm_counters` | 19/19 PASS，包含新四个事件精确计数 |
| dev05 | runner `--modules mmu --build`，VM 二进制 `+L7_CHECK +L10_DEBUG` | MMU新增 D mismatch/权限/PMP 拒绝后 6/6 PASS；VM 诊断出 replay 等待环 |
| dev06 | runner `--modules backend backend_control backend_issue_queue --build --core` | 5/5模块通过；八项回归、priv、AD通过；VM 推进至 cause 15 旧分支断言 |

开发修复：真实 DCache harness 的 struct pattern 必须显式初始化 enum `amo_op`，修正 fixture；
runner 不再将构建失败前的旧 XML 误计为本轮结果，只解析本次命令之后生成的 XML。
这些修复不修改 DUT 行为或降低检查强度。
完整 gate01 的 HPM 旧“越界 BE event”刺激硬编码 0x26，在 T08c 已成为有效 DTLB 事件；
原不计数断言仍为精确 0，越界刺激改为 DUT 暴露的 BE_PERF_NUM，并新增 0x26～0x29
每个 selector 的完整计数检查（3×4=12）。这修正事件边界刺激，不屏蔽合法事件或放宽期望。

## 自行决定（T08c）

| 问题 | 决定 | 依据 | 涉及文件 |
| --- | --- | --- | --- |
| 原子口仲裁/所有权 | AD > PTW > 原 CPU 仲裁，复用 cache 两级/单 MSHR；命中与 refill 都比较完整 64 位 PTE，成功才写脏 | spec 5.4/8.1、B36；普通访问不增加流水级 | dcache |
| D owner 保存/回压 | LSU 只保存一个 needs_D store 的完整 uop/SQ/ROB/VA；第二个 D=0 store 与年轻访存回压，年轻 load 入已有 replay | X2/X16、spec 8.3、B49；L3 资源不扩展为 L8 | load_store_unit |
| ROB 完成和退休分离 | 首次只读 probe 仍置 complete，但 needs_D 阻止任何包含此项的退休前缀；队头只发一次更新请求，完成前禁止中断越过 | spec 8.3、精确异常、B36/B37 | rob、commit_ctrl、backend |
| 比较失败之后的 SQ 地址 | D 重遍历可发现新 PPN；成功后本地精确 DTLB 失效并重翻译/替换 SQ PA/重新 probe，最终完成才清 needs_D | 完整 PTE 比较与重遍历；不能使用过期 PA 写 store，B49 | ptw、load_store_unit |
| CAS 重试上限 | 无固定次数/超时软件 trap；mismatch 从 walk-cache lookup 重走并重新检查权限/PMP | spec 8.2/8.3、B49 | ptw |
| 取消/epoch 边界 | 已接受物理 CAS 可 drain；尚未接受的旧 epoch 请求不写。旧结果只释放 owner，不回填/退休；冲突通知只在实际成功写时发出 | spec 8.5、D27、B36；原子事务所有权 | pte_ad_updater、dcache、ptw |
| D 重遍历优先级 | 队头 DCOMMIT 先于 I/D miss；普通 I/D 仍 RR，D 重遍历不修改 RR 历史 | spec 8.3 与 single-walker 前进需求 | ptw、pte_ad_updater |
| 性能事件口径 | BE 0x26 DTLB miss 响应次数（包含重试），0x27/0x28 实际 A/D 0→1 写次数，0x29 SFENCE 发起；既有 PTW 0x12/WC 0x13；FE 0x28 ITLB miss | spec 10 的自由事件编码；不是软件 perf/PMU 平台证明 | o3_types_pkg、dtlb、pte_ad_updater、commit_ctrl、backend、l10_event_checks |
| replay 与寄存器内 store 仲裁 | 单 replay 比寄存器内更年轻访存优先；更老 store 仍可越过解除未知 SQ 地址依赖；被旁侧 preempt 的输入不应答 ready | X2/X16、B04/L3 简化、B49 硬件处理；修复新 VM 的硬件等待环 | load_store_unit |
| 测试组织 | PTE cache harness 放在 mmu/，只覆盖 L10 CAS 合同；另加完整 A/D 正向整核程序补完整 VM 失败之后的路径 | 用户修订允许新增 L10 已知失败继续；不运行推迟的通用访存 suite | sim/cocotb/mmu、sim/o3/tests/l10_ad.S、Makefile |

跨模块合同：PTW 请求携带上下文和 DCOMMIT src；响应携带 PTE 地址/值；ROB 增加 needs_D，
LSU→ROB mark/clear/idx 与 LSU→updater VA/SQ、updater→LSU done/exception；commit 单发请求，
PTW/updater/DCache 共享 CAS 身份。修改均在允许文件范围内，没有改 doc/design Bxx/Dxx 或 doc/spec。

## 已知问题

1. **T08b 完整 VM**：首个失败是 `backend.sv` 的正确分支推进断言
   `decode_ready == uopq_enq_ready`。同 SHA 诊断为 `decode_ready=0 enq_ready=1 block=1 flush=1
   trap=1 cause=13 head_pc=0x80000180`：程序预期的 SUM=0 load page fault 与正确分支解析同拍。
   MRET、4K/2M 前缀已推进；最后退休 cycle 15839、PC `0x80000154`。不删断言或故障程序。
   复现 cwd `/home/chen/FUN/CISLC-O3-runs/20261007-t08b-final/`：
   `make -C sim/o3 run-l10-vm SPIKE_ARGS=+L7_CHECK VM_AD=0`（exit 2）；日志 `evidence/final/run-l10-vm.log`。
2. **T08c 完整 VM**：开发 dev02 的 10000 拍无退休超时（cycle 25818、6237 events）已修复：
   老 SUM=0 load（PC `0x80000184`）在 replay，年轻错误路径 tohost store 占 RegRead；
   replay 仲裁按 ROB 年龄优先老项并保持被 preempt 输入不 ready，更老 store 仍可解除 SQ 依赖。
   dev06 已越过该点、完成 SUM=0/SUM=1 路径；首个剩余失败是同一旧正确分支推进断言，
   `decode_ready=0 enq_ready=1 block=1 flush=1 trap=1 cause=15 head_pc=0x800001c4`，
   对应程序预期的只读页 store page fault 与正确分支解析同拍。
   保留原断言，按用户修订作为已知问题；最终 SHA 复现与日志见下节。

以上按任务书 2026-10-07 用户修订带已知问题收口，不宣称完整 Sv39 整核 VM 通过。
完整 VM 的 RO fault 之后 NX、ADUE=0、ASID/SFENCE/PMP 整核链没有完整通过证据；
MMU 权限/ASID/精确 fence/PMP/A/D 模块通过与独立 AD 正向程序通过不能替代它。
D 重遍历的 PTE 替换/权限/PMP 失败在 MMU harness 覆盖；LSU 重新写 SQ PA 的并发映射改变
及 D 失败的精确 store trap 尚无独立整核覆盖，不能从固定映射 AD 正向程序推断这些集成路径已验证。
历史 L5 的随机差异/旧 MRET 等问题仍按 [T03 报告](O3-T03-report.md) 保留；本轮没有重跑或宣称修复。

未做：L8/L11、通用访存类 cocotb、Spike、ACT4、formal、综合/时序/PPA、FPGA/SoC：**未运行**。

## T08c 最终代码 SHA 门禁

代码 SHA：`1d0d6f8369fa69476d07538157be234a88db08bf`（已推 GitHub）。
Alan cwd：`/home/chen/FUN/CISLC-O3-runs/20261007-t08c-1d0d6f8/`，从 GitHub 独立 clone，
按原 gitlink 初始化 CVFPU/common_cells 及其余子模块，不复用开发生成目录。
环境：`source /home/chen/miniforge3/bin/activate cislc-o3`。

完整门禁：`python3 sim/o3/tests/run_t08_gates.py evidence/final --build --core`。
该 runner 记录每条命令/cwd/exit 并继续到后续目标，进程返回 0 不代表全门禁通过；
以 `evidence/final/commands.jsonl` 与 `summary.json` 的每条 exit/test fail 为准。
原始 stdout/stderr 为 `evidence/final/<套件或目标>.log`；构建目录每轮/每模块独立。
工具版本/代码 SHA/gitlink/cwd：`evidence/final/provenance.log`；
tracked diff 与完整状态：`tracked-{before,after}.diff`、`status-{before,after}.txt`。

实际命令模式：

- `make -C sim/o3 build 'VERILATOR=verilator -j 8'`。
- `make -C sim/cocotb/<模块> -j8 SIM=verilator TEST_SEED=1 SIM_BUILD=<evidence/final/build-模块>`。
- FTQ：bpu 目录加 `COCOTB_TOPLEVEL=ftq_training_tb_top COCOTB_TEST_MODULES=test_ftq`。
- PTE 原子入口：mmu 目录加 `-f Makefile.pte`。
- `bash scripts/lint.sh`。
- `make -C sim/o3 <目标> SPIKE_ARGS=+L7_CHECK VM_AD=1`（不带 `--spike`）。

最终结果：**38 套件，132/132 PASS，FAIL=0、SKIP=0**。包含全部 T08a/T08b 与
L7a/L7b/L9 既有用例；HPM 原越界刺激按实际事件上界修正，新增四事件精确计数保留。
整核构建与 lint 均 exit 0；lint **0 errors / 364 warnings**（非 strict 门禁）。
测试前后 tracked diff 均为 0 字节；未跟踪项为 evidence 与生成的 XML/JSONL/pycache。
51 条命令中仅 `run-l10-vm` exit 2，其他全部 exit 0，原始统计另在 `evidence/final/facts.json`。
文档收尾提交只更新报告/LOOP，验收绑定以上代码 SHA，不冒充再次运行代码门禁。

| 套件 / harness | T08b 2e5333b | T08c 1d0d6f8 | 两步 exit |
| --- | --- | --- | --- |
| `ubtb` | 3/3 | 3/3 PASS | 0 / 0 |
| `main_btb` | 2/2 | 2/2 PASS | 0 / 0 |
| `tage` | 2/2 | 2/2 PASS | 0 / 0 |
| `ras` | 2/2 | 2/2 PASS | 0 / 0 |
| `branch_recovery` | 4/4 | 4/4 PASS | 0 / 0 |
| `fetch_buffer` | 2/2 | 2/2 PASS | 0 / 0 |
| `fetch_return_queue` | 3/3 | 3/3 PASS | 0 / 0 |
| `bpu_slow_check` | 1/1 | 1/1 PASS | 0 / 0 |
| `redirect_arbiter` | 2/2 | 2/2 PASS | 0 / 0 |
| `bpu` | 5/5 | 5/5 PASS | 0 / 0 |
| `rvc_expander` | 3/3 | 3/3 PASS | 0 / 0 |
| `ifu_f0` | 6/6 | 6/6 PASS | 0 / 0 |
| `ifu_f1` | 18/18 | 18/18 PASS | 0 / 0 |
| `l7_recovery` | 2/2 | 2/2 PASS | 0 / 0 |
| `hpm_counters` | 19/19 | 19/19 PASS | 0 / 0 |
| `csr_file` | 10/10 | 10/10 PASS | 0 / 0 |
| `fpu_fu` | 2/2 | 2/2 PASS | 0 / 0 |
| `pmp_checker` | 2/2 | 2/2 PASS | 0 / 0 |
| `wfi_ctrl` | 1/1 | 1/1 PASS | 0 / 0 |
| `decoder` | 1/1 | 1/1 PASS | 0 / 0 |
| `commit_ctrl` | 4/4 | 5/5 PASS | 0 / 0 |
| `frontend_sync_ctrl` | 3/3 | 3/3 PASS | 0 / 0 |
| `icache` | 4/4 | 4/4 PASS | 0 / 0 |
| `backend` | 2/2 | 2/2 PASS | 0 / 0 |
| `backend_control` | 1/1 | 1/1 PASS | 0 / 0 |
| `backend_issue_queue` | 2/2 | 2/2 PASS | 0 / 0 |
| `free_list` | 2/2 | 2/2 PASS | 0 / 0 |
| `rename_entry_gate` | 1/1 | 1/1 PASS | 0 / 0 |
| `rename_map_table` | 2/2 | 2/2 PASS | 0 / 0 |
| `rename_stage` | 1/1 | 1/1 PASS | 0 / 0 |
| `rob` | 3/3 | 4/4 PASS | 0 / 0 |
| `prf_read_arbiter` | 1/1 | 1/1 PASS | 0 / 0 |
| `fu_completion_fifo` | 1/1 | 1/1 PASS | 0 / 0 |
| `wb_alu_kill` | 1/1 | 1/1 PASS | 0 / 0 |
| `trap_ctrl` | 1/1 | 1/1 PASS | 0 / 0 |
| `mmu` | 4/4 | 6/6 PASS | 0 / 0 |
| `ftq` | 3/3 | 3/3 PASS | 0 / 0 |
| `mmu_pte` | 未运行 | 2/2 PASS | — / 0 |

| 整核目标 | exit | 最终周期 / 退休与 trap |
| --- | --- | --- |
| `run-smoke` | 0 | 38 / 4；既有自查/轨迹检查 PASS |
| `run-rv64i-instructions` | 0 | 70 / 14；既有自查/轨迹检查 PASS |
| `run-l3-branch-dense` | 0 | 1966 / 365；既有自查/轨迹检查 PASS |
| `run-l7-predict` | 0 | A：43807 / 19396；B：43861 / 19447；既有自查/轨迹检查 PASS |
| `run-l7b-rvc` | 0 | 5873 / 2216；既有自查/轨迹检查 PASS |
| `run-l9-fp-smoke` | 0 | 890 / 267；既有自查/轨迹检查 PASS |
| `run-l9-fp` | 0 | 1844 / 615 events（614 退休 + 1 trap），tohost=1 |
| `run-replay-order` | 0 | 121 / 20；既有自查/轨迹检查 PASS |
| `run-l10-priv` | 0 | 3499 / 439 events（422 退休 + 17 trap），tohost=1 |
| `run-l10-vm` | 2 | cause 15 / head PC 0x800001c4 的旧正确分支推进断言；未到 tohost |
| `run-l10-ad` | 0 | 15891 / 6252；tohost=1，A-only→队头D→年轻load/SQ转发→PTE读回均自查通过 |

完整 VM 最终 SHA 首个失败为 `rtl/backend/backend.sv:2257`：

```text
correct-branch progress: decode_ready=0 enq_ready=1 block=1 flush=1 sys=0
trap=1 cause=15 head_pc=00000000800001c4
```

复现（Alan 已激活 cislc-o3）：

```bash
cd /home/chen/FUN/CISLC-O3-runs/20261007-t08c-1d0d6f8
make -C sim/o3 run-l10-vm SPIKE_ARGS=+L7_CHECK VM_AD=1
```

make exit 2；首个失败日志 `evidence/final/run-l10-vm.log`，中止前轨迹 `sim/o3/build/l10_vm.jsonl`。
开发等待环诊断另保留 `20261007-t08c-2e5333b-work/evidence/t08c-vm-debug-direct.log` 与
`evidence/l10-vm-debug.jsonl`；`+L10_DEBUG` 是只读观察，不修改 ready/valid/断言。
原正确分支断言、VM 故障自查、八项回归 golden 均保留。

交付状态：T08b/T08c 代码与报告已推送；LOOP L10 行与相关模块行更新；
L10 按用户修订带已知问题收口，到此停止，**L8/L11 未开始**。
