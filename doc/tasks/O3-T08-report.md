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
