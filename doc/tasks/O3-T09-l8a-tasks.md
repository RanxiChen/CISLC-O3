# O3-T09：L8a 任务书（RTL 一次写完，测试 M1～M6 逐层加入）

唯一实施依据：[L8a spec](../spec/l8a-nonblocking-mem-spec.md)（已冻结，X1～X10）。本文只规定执行顺序、停止条件与报告格式，不新增任何行为。

## 共同规则

- **参考源码**：Breeze `/home/chen/leisure/flow`，提交 `a304cc2`（分支 `feat/pcie-fase-20260920`）。
  - `docs/coherence-l2-rtl-spec.md`、`docs/l1d-rtl-spec.md`
  - `design/src/main/scala/{coherence,l1d,l1i,l2}/*.scala`
  - 测试思路：`design/src/test/scala/memsys/`（`MemAgents`、`MemCoherenceMonitor`、`MemHarness`、`L1DL2SystemSpec`）

  复用的是机制，不逐行翻译（B50/B51）。spec 写了“按 O3 修改”的地方不照搬 Breeze，尤其是：不用 `s2Hold`，MSHR 不保存原请求，一拍整行，L1I 不进目录。
- **spec 未覆盖的实现细节**（信号编码、struct 字段顺序、文件内组织、测试脚本写法）：自行决定，写进报告的“自行决定”一节。每条写清问题、决定、依据和涉及文件。
  **需要改变 spec 的行为或 `doc/design/` 的 Bxx/Dxx 时**：停下来问，不改 spec 和 design。
- **允许改动的文件**：只限 spec 第 0 节列出的。
- **仿真主机**：按 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md` 选择，**每次运行前重新读取该文件**，地址、环境路径和规则以文件当前内容为准，不在本任务书里抄写，也不沿用以前记住的值。
  - 先预检首选主机（当前为 `cloud_chen`，O3 用该文件中的 `o3_environment`）：用 `BatchMode=yes` 加连接超时确认免密 SSH，激活环境，检查 Verilator、cocotb 版本以及磁盘和内存。需要外网时先验证反向代理。
  - 首选主机的连接、环境或资源不可用时，改用备用主机 Alan，做同样的预检。两台都不可用就报告具体原因，**不在本地跑仿真**。
  - 预检通过后，同步本任务的准确 SHA，在所选主机 `workspace_root` 下建独立运行目录 `<日期>-t09-<sha>/` 执行。
  - **测试失败不算主机不可用**：保留失败证据并定位，不能靠换主机或改期望值掩盖。
  - GitHub 访问走该文件规定的反向代理，禁止 Git bundle。不跑 Spike、ACT4、litmus，不综合。
- **测试纪律**：
  - 失败就修 RTL。不得放宽断言、黄金值、用例规模或种子数，也不得删除已有用例。
  - 修 RTL 之后，已通过的下层测试要重跑。
  - 开发时只重跑受影响的套件；每层提交前，把本层和所有下层完整跑一遍。

## 执行顺序

### 第 1 步：RTL 一次写完（spec 12.1）

- 写完 spec 第 2～11 节的全部 RTL，删除 `l2_cache`、`l2_recall_ctrl`、`dma_line_coord`，同步 `rtl/rtl.f`。
- 门禁：
  - 整核与新模块能 elaborate；
  - 第 2 节调试开关的每种取值（`mem_pipes` 1/2、`mshrs` 1/4、`rfo_enable` 0/1）都能 elaborate；
  - `scripts/lint.sh` 0 errors。
- 通过后提交：`feat(memsys): implement L8a non-blocking memory RTL (untested)`。
- 这时整核回归失败是预期的，不需要修。

### 第 2 步：测试逐层加入（spec 12.2～12.7）

按 M1 → M2 → M3 → M4 → M5 → M6 的顺序。每层测试全部通过后提交，提交信息写 `test(memsys): L8a test layer Mk pass`；本层修 RTL 的提交单独写 `fix(...)`。

| 层 | 范围（详见 spec 第 12 节表格） | 调试建议 |
| --- | --- | --- |
| M1 | `l2_home` 单模块：定向测试 + 随机测试 | 先跑定向，再跑随机 |
| M2 | `dcache` 单模块，接行为 L2 | 先 `mshrs=1` 跑通，再跑 4 |
| M3 | `memsys`：L1D + L2 + AXI RAM 随机 | 按 spec 规定的组合顺序：MSHR 1→4，压力几何→默认几何，RFO 0→1 |
| M4 | LSU 侧模块套件更新，加新的 LQ 等待/唤醒用例 | |
| M5 | 整核 `mem_pipes=1`：九项回归 + `run-l10-ad` + 三个 dcache/unified 目标 | 失败时先在 M3 里用同样的访问序列复现 |
| M6 | 整核默认配置 + `run-l8a-mem` | 失败时先退回 `mem_pipes=1` 或 `rfo_enable=0` 缩小范围 |

### 停止条件

- **需要改 spec 或 design 时**：停下问。
- **某层的正确性用例修不好**：不提交这一层的测试通过声明。报告里写清失败用例、首个失败点、复现命令和已经尝试过的修复，然后停下。不得跳到上层继续。
- **`run-l10-vm`**：保持 T08 的已知问题，不要求通过，只记录首个失败点有没有变化，不因它停下。
- **终点**：M6 通过；在最终 SHA 上重跑总门禁（spec 12.8）；`doc/LOOP.md` 的 L8 行与相关模块行更新；报告写完并推送后停下。不开始 L8b。

## 报告：`doc/tasks/O3-T09-report.md`

报告包括以下内容：

- 每次运行的实际主机、预检结果（若退回 Alan，写明首选主机失败的原因）、工具版本。
- 第 1 步与每一层的提交号、命令、exit code、用例数，整核目标再加周期数和退休数，以及日志目录。
- 失败与修复记录：失败现象 → 根因 → 修了哪个文件 → 回归结果。
- 自行决定一节。
- M5 → M6 各回归程序的周期数对比，以及 `run-l8a-mem` 打印的 MSHR 平均占用、RFO 发出/有用次数、bank 冲突重放次数。
- 已知问题与证据边界：哪些没有验证，例如 DMA、AMO、MMIO、litmus、综合。
- 最终 SHA 上的同 SHA 总门禁结果。

---

## 交给 Codex 的提示（复制使用）

```
在 /home/chen/work/CISLC-O3（分支 feat/L1-closure）实施 L8a 非阻塞访存底座。

唯一依据：doc/spec/l8a-nonblocking-mem-spec.md（已冻结）。执行顺序与规则：doc/tasks/O3-T09-l8a-tasks.md。
动手之前，先完整读这两份文件、spec 第 1 节列出的源码位置，以及任务书列出的 Breeze 参考
（/home/chen/leisure/flow @ a304cc2 的 coherence-l2-rtl-spec.md、l1d-rtl-spec.md 和 l1d/l2/coherence/l1i 的 Scala 源码）。

要求：
1. 先一次写完全部 RTL：elaborate 通过（含所有调试开关取值），lint 0 errors，然后提交。此时整核回归失败是预期的。
2. 然后按 M1→M6 逐层加测试，每层通过后提交。失败就修 RTL，不放宽断言、黄金值、规模和种子；修 RTL 后重跑已通过的下层。
3. Breeze 只复用机制，不逐行翻译；spec 写了按 O3 修改的地方不照搬。实现细节自行决定，写进报告；需要改 spec 或 doc/design 时停下问我。
4. 只改 spec 第 0 节允许的文件。仿真主机：每次运行前重新读 /home/chen/leisure/flow/docs/cross-project/simulation-host.md，
   先预检首选的 cloud_chen，不可用再退回 Alan；两台都不行就报告原因，不在本地跑。测试失败不算主机不可用。
   报告写明实际用的主机。不跑 Spike/ACT4/litmus，不综合。
5. 某层的正确性用例修不好：停下，报告失败用例、首个失败点和复现命令。run-l10-vm 保持已知问题，只记录首个失败点是否变化。
6. M6 通过后，在最终 SHA 上重跑总门禁；更新 doc/LOOP.md 的 L8 行和相关模块行；写 doc/tasks/O3-T09-report.md 并推送，然后停下，不开始 L8b。
```
