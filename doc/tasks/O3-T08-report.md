# O3-T08：L10 实施与 Alan 验证报告

实施依据：冻结 spec `0b812d6`，Q1～Q8 已纳入；分支 `feat/L1-closure`。

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
同 SHA 交付门禁在本步代码提交后运行，结果补在收尾报告。

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

## 已知问题（收尾时按最终 SHA 更新）

- T08b `run-l10-vm`：首个失败 `rtl/backend/backend.sv` 的 `decode_ready == uopq_enq_ready` 断言。
  最后退休前缀 cycle 15839、PC `0x80000154`；未经同 SHA 诊断前不把它归因为 MRET 或 MMU。
  复现：Alan 对应代码目录 `make -C sim/o3 run-l10-vm SPIKE_ARGS=+L7_CHECK VM_AD=0`。
  按 2026-10-07 修订继续 T08c；不删除断言、失败程序或自查期望。
