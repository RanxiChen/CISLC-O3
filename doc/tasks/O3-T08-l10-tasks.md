# O3-T08：L10 分步任务书（T08a～T08c）

唯一实施依据：[L10 spec](../spec/l10-priv-mmu-spec.md)（X1～X16）。本文只规定分步顺序与每步测试范围，不新增任何行为。

## 共同规则（每一步都适用）

- spec 未覆盖或有歧义的行为：**停下提问**，不自行补设计；不改 spec 与 `doc/design/`。spec 允许自选的实现细节自行决定并在报告写明（agent.md 1.2）。
- 只改 spec 第 0 节允许的文件；不跑 Spike、ACT4、特权测试套件、访存类 cocotb（spec 第 12 节）；不综合。
- 参考源码：Breeze `~/flow-mem`（`02e3f6f`）`design/src/main/scala/mmu/sv39/*.scala`、`docs/breeze-mmu-rtl-spec.md`、
  `design/src/test/scala/mmu/sv39/*.scala`（用例来源）、`design/src/main/scala/core/RegFile.scala`（CSR 语义）、
  `design/src/main/scala/mmu/BreezeMmu.scala`（旧 MMU 的 Svadu A/D 参考）。spec 标“修正”的地方不照搬 Breeze。
- 测试在 Alan 上运行（`source /home/chen/miniforge3/bin/activate cislc-o3`，Verilator 5.050、cocotb 2.1.0），
  独立运行目录 `/home/chen/FUN/CISLC-O3-runs/<日期>-t08<x>-<sha>/`。GitHub 访问按 agent.md 3.1 走反向代理，禁止 Git bundle。
- 门禁：本步列出的 cocotb、L7a/L7b/L9 全部 cocotb 与受影响的非访存 cocotb、spec 13.3 的全部回归目标、`scripts/lint.sh` 0 errors。
  正确性项修不好：不提交 RTL，停下报告失败用例与复现命令。
- **T08a → T08b → T08c 连续执行**：每步门禁通过、提交后直接进入下一步；只有正确性项修不好、或遇到 spec 未覆盖的行为时才停下。
  三步合写一份报告 `doc/tasks/O3-T08-report.md`。
- 精简流程：开发时只重跑受影响的套件；提交前跑一次完整门禁。报告只需提交号、命令、exit code、用例数/周期/退休数、日志目录、失败与修复记录、自选细节、未做项。
- 提交信息：`feat(system|frontend|lsu|backend): ...`，可多次提交。

## T08a：特权、CSR、中断、WFI、计数器、time/Sstc、PMP（satp 仍只接受 Bare）

内容：spec 第 2、3 节全部；第 9 节 PMP 与 PMA（取指、数据两处；PTW 处在 T08b）；6.3 PMP 写同步；第 7 节中 PMP kind；
`o3_core.mtime_i` 与 13.2 testbench 改动；第 10、11 节中相关部分。本步 `satp` 写 MODE=8 视为非法 MODE（写入忽略），翻译保持直通。

测试：spec 13.1 的 `csr_file`、`hpm_counters`、`pmp_checker`、`commit_ctrl`（不含 SFENCE 与 needs_D 部分）、`frontend_sync_ctrl`（PMP kind）；
`run-l10-priv` 全部；`run-l10-vm` 中的 PMP 项可先以 Bare 形式单独放进 `run-l10-priv`；全部回归。

## T08b：Sv39 MMU（Svade 模式）

内容：第 4 节全部（A/D 先按 8.4 的 ADUE=0 行为：A=0 或 store D=0 报 page fault）；第 5 节全部；6.1 SFENCE、6.2 satp；
第 7 节 SFENCE/SATP kind；PTW 读的 PMP/PMA；DCache PTW 读口（5.4）；`satp` 放开 MODE=8。

测试：spec 13.1 `mmu` 中除 A 更新以外的全部用例；`commit_ctrl` 的 SFENCE 序列与 satp needs_refetch；
`run-l10-vm` 中除硬件 A/D 以外的项（页表预置 A=D=1，另加一例 ADUE=0 下 A=0 报 page fault）；T08a 全部用例；全部回归。

## T08c：硬件 A/D（Svadu）

内容：第 8 节全部：DCache `pte_ad` 原子比较置位口、PTW 的 A 更新、store `needs_D` 与队头 D 更新、年轻 load 排序、epoch 隔离；ADUE 复位 1。
更新 `doc/LOOP.md`：L10 一行与相关模块行（含 X2 非阻塞、X8 等待 PTW idle 等闭环简化说明）。

测试：`mmu` 的 A 更新与比较失败重遍历用例；`commit_ctrl` 的 needs_D；完整 `run-l10-vm`；T08a/T08b 全部用例；全部回归。

---

## 交给 Codex 的提示（复制使用）

```
在 /home/chen/work/CISLC-O3（分支 feat/L1-closure，基线 L10 spec 冻结提交）实施 L10 S/U 特权与 Sv39 MMU。

唯一依据：doc/spec/l10-priv-mmu-spec.md（已冻结，X1～X16）。分步与门禁：doc/tasks/O3-T08-l10-tasks.md。
先完整读这两份文件、spec 第 1 节列出的源码位置，以及任务书“共同规则”列出的 Breeze 参考源码，再动手。

要求：
1. 按 T08a → T08b → T08c 顺序做，连续执行；每步门禁通过后提交，再进入下一步。
2. spec 没写或有歧义的行为：停下问我，不自己补设计；不改 doc/spec、doc/design。spec 标“修正”处不照搬 Breeze。
3. 只改 spec 第 0 节允许的文件。
4. 测试在 Alan 的独立运行目录跑，不跑 Spike/ACT4/特权测试套件/访存类 cocotb，不综合。
5. 正确性门禁修不好就不提交 RTL，停下报告失败用例和复现命令。整核程序若卡在 L5 已知的 MRET 问题，报告首个失败点并停下。
6. 最后写 doc/tasks/O3-T08-report.md：提交号、每条命令与 exit code、用例数/周期/退休数、日志目录、失败与修复记录、
   自选的实现细节、未做项。同时更新 doc/LOOP.md 中 L10 一行和相关模块行的状态。
```
