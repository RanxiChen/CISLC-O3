# O3-T10：L8b 任务书（RTL 一次写完，测试 N1～N6 逐层加入）

唯一实施依据：[L8b spec](../spec/l8b-atomic-mmio-dma-spec.md)（已冻结，Y1～Y14）。L8a spec 与 T09 的已批准解释继续有效。本文只规定执行顺序、停止条件与报告格式，不新增任何行为。

## 共同规则

- **参考源码**：Breeze `/home/chen/leisure/flow`，提交 `a304cc2`（分支 `feat/pcie-fase-20260920`）。
  - `docs/l1d-rtl-spec.md` 第 5.1、8、9、10.2、11、12 节；`docs/coherence-l2-rtl-spec.md` 第 1.1、1.4、4.4、5.2 节
  - `design/src/main/scala/l1d/{L1DCache,L1DMmio,L1DProbe}.scala`、`cache/BreezeAmoAlu.scala`
  - 测试思路：`design/src/test/scala/memsys/{L1DCacheSpec,L1DL2SystemSpec,L2HomeSpec,L1DL2MultiCoreFaultSpec}.scala`；`docs/tasks/MEM-single-core-atomics-report.md`（两个已修 bug，O3 不得重犯）
  - 6.3 节的出处：`docs/tasks/SOC-2-bram-report.md`（时序结果）与 `docs/tasks/SOC-3-timing.md` M1（修复思路；该任务尚未实施，只借思路）

  复用的是机制，不逐行翻译。spec 写了按 O3 修改的地方不照搬，尤其是：O3 没有 `s2Hold`，原子与 MMIO 在 ROB 队头由 HEU 执行；SC 成功要求同地址同大小；reservation 清除表按 spec 5.3。
- **spec 未覆盖的实现细节**（信号编码、struct 字段、HEU 内部状态划分、测试脚本写法）：自行决定，写进报告的“自行决定”一节，每条写清问题、决定、依据和涉及文件。
  **需要改变 spec 的行为或 `doc/design/` 的 Bxx/Dxx 时**：停下来问，不改 spec 和 design。
- **允许改动的文件**：只限 spec 第 0 节列出的。
- **仿真主机**：按 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md` 选择，**每次运行前重新读取该文件**，以文件当前内容为准，不沿用以前记住的地址或路径。
  - 先预检首选主机（当前为 `cloud_chen`，O3 用该文件中的 `o3_environment`）：`BatchMode=yes` 加连接超时确认免密 SSH，激活环境，检查 Verilator、cocotb 版本以及磁盘和内存。
  - 首选主机不可用时改用 Alan，做同样的预检。两台都不可用就报告具体原因，**不在本地跑仿真**。
  - 同步本任务的准确 SHA，在所选主机 `workspace_root` 下建独立运行目录 `<日期>-t10-<sha>/` 执行。
  - **测试失败不算主机不可用**：保留失败证据并定位，不能靠换主机或改期望值掩盖。
  - GitHub 访问走该文件规定的反向代理，禁止 Git bundle。不跑 Spike、ACT4、litmus，不综合。
- **测试纪律**：
  - 失败就修 RTL。不得放宽断言、黄金值、用例规模或种子数，也不得删除已有用例。
  - 旧测试与冻结 spec 冲突（旧规格遗留断言）时：停下，列出文件、行号、对应的冻结 spec 条目和建议补丁，等用户批准，不批量自行迁移。
  - 修 RTL 之后，已通过的下层测试要重跑（L8a 的 M1～M6 视为 N1 之下的既有层）。开发时只重跑受影响的套件；每层提交前，把本层和所有下层完整跑一遍。
  - 退休条数比较沿用 T09 用户批准的截止前缀解释（成功 tohost store 同拍之后的末尾自跳转不计）。
  - Y13 的一致性断言在全部仿真中开启。

## 执行顺序

### 第 1 步：RTL 一次写完（spec 12.1）

- 写完 spec 第 2～11 节的全部 RTL，删除 `clean_all_*` 与 `crossline_misalign`，同步 `rtl/rtl.f`。
- 门禁：
  - 整核与新模块能 elaborate；
  - 第 2 节调试开关的每种取值（新增 `heu_enable`、`split_enable`、`order_flush_enable` 各 0/1，以及 L8a 的 `mem_pipes` 1/2、`mshrs` 1/4、`rfo_enable` 0/1）都能 elaborate；
  - `scripts/lint.sh` 0 errors。
- 通过后提交：`feat(memsys): implement L8b atomic, MMIO, split and DMA RTL (untested)`。
- 这时整核回归失败是预期的，不需要修。

### 第 2 步：测试逐层加入（spec 12.2～12.7）

按 N1 → N2 → N3 → N4 → N5 → N6 的顺序。每层测试全部通过后提交，提交信息写 `test(memsys): L8b test layer Nk pass`；本层修 RTL 的提交单独写 `fix(...)`。

| 层 | 范围（详见 spec 第 12 节表格） | 调试建议 |
| --- | --- | --- |
| N1 | 叶模块：`l2_home` 的 DMA 用例与 `dma_write` 位、`mmio_axil_master`、`dma_line_adapter` | 先定向，再随机 DMA 代理 |
| N2 | `dcache` 单模块：权限寄存（Y13 断言）、AMO、LR/SC 与 reservation、IO 区判定、`dma_write` 广播；`run-l10-vm` 序列复现 | AMO 等 GetM 时 probe 不能被压住（Breeze `7ecb4f0` 的死锁） |
| N3 | `memsys`：随机流量加 AMO/LR/SC 与 DMA 代理 | 失败时先关 `rfo_enable`、`mshrs=1` 缩小范围 |
| N4 | LSU 侧与系统模块：现有套件更新 + decoder、SQ/LQ 新项、拆分、HEU、commit_ctrl、misa | 拆分失败时先用 `split_enable=0` 确认其余功能 |
| N5 | 整核既有回归（L8a M6 全部目标、`mem_pipes=1` 的 M5 目标）+ `run-l10-vm` 必须通过 | 失败时先在 N3 用同样的访问序列复现 |
| N6 | 整核新程序：`l8b_amo`、`l8b_mmio`、`l8b_misalign`、`l8b_dma`（含 `o3_mmio_model.sv`） | MMIO 副作用计数器每条 load 只能计 1 次，这是最重要的检查 |

### 停止条件

- **需要改 spec 或 design 时**：停下问。
- **旧测试与冻结 spec 冲突时**：按上文停下，给出建议补丁。
- **某层的正确性用例修不好**：不提交这一层的通过声明。报告里写清失败用例、首个失败点、复现命令和已经尝试过的修复，然后停下，不跳到上层。
- **`run-l10-vm` 的根因需要改 B36 合同时**：停下问。
- **终点**：N6 通过；在最终 SHA 上重跑 spec 12.8 总门禁；`doc/LOOP.md` 的 L8 行与相关模块行更新；报告写完并推送 origin 后停下。不开始 L8c。

## 报告：`doc/tasks/O3-T10-report.md`

报告包括以下内容：

- 每次运行的实际主机、预检结果（若退回 Alan，写明首选主机失败的原因）、工具版本。
- 第 1 步与每一层的提交号、命令、exit code、用例数，整核目标另加周期数、截止前缀条数与豁免尾部条数，以及日志目录。
- 失败与修复记录：失败现象 → 根因 → 修了哪个文件 → 回归结果。`run-l10-vm` 单独一节写清根因。
- 6.3 节：寄存了哪些权限位、放在哪一级；一致性论证的依据（串行与 flush 规则的 RTL 位置，尤其 ITLB 的 PTW 内部请求）；Y13 断言的位置和 `ifndef SYNTHESIS` 包裹方式。
- 自行决定一节。
- 新整核程序的周期数，以及新增性能事件的计数（AMO、LR、SC 失败、LR 窗口压住 probe 的拍数、MMIO 读写、拆分条数、load 顺序冲刷、DMA 读写）；L8a 既有回归程序的周期数相对 T09 最终 SHA 的变化（只记录）。
- 已知问题与证据边界：哪些没有验证，例如 AXI 从口 DMA、真实外设、litmus、多核、综合。
- 最终 SHA 上的同 SHA 总门禁结果。

---

## 交给 Codex 的提示（复制使用）

```
在 /home/chen/work/CISLC-O3（分支 feat/L1-closure）实施 L8b：队头执行单元（HEU）、A 扩展、MMIO、跨行拆分、一致性 DMA。

唯一依据：doc/spec/l8b-atomic-mmio-dma-spec.md（已冻结，Y1～Y14）。执行顺序与规则：doc/tasks/O3-T10-l8b-tasks.md。
动手之前，先完整读这两份文件、L8a spec（doc/spec/l8a-nonblocking-mem-spec.md）、spec 第 1 节列出的源码位置，
以及任务书列出的 Breeze 参考（/home/chen/leisure/flow @ a304cc2）。

要求：
1. 先一次写完全部 RTL：elaborate 通过（含所有调试开关取值），lint 0 errors，然后提交。此时整核回归失败是预期的。
2. 然后按 N1→N6 逐层加测试，每层通过后提交。失败就修 RTL，不放宽断言、黄金值、规模和种子；修 RTL 后重跑已通过的下层
   （L8a 的 M1～M6 视为 N1 之下的既有层）。Y13 的仿真断言全程开启。
3. run-l10-vm 在 N2/N3 复现定位，N5 起必须通过；根因需要改 B36 合同时停下问我。
4. Breeze 只复用机制，不逐行翻译；spec 写了按 O3 修改的地方不照搬。实现细节自行决定，写进报告；需要改 spec 或 doc/design 时停下问我。
5. 只改 spec 第 0 节允许的文件。仿真主机：每次运行前重新读 /home/chen/leisure/flow/docs/cross-project/simulation-host.md，
   先预检 cloud_chen，不可用再退回 Alan；两台都不行就报告原因，不在本地跑。测试失败不算主机不可用。
   报告写明实际用的主机。不跑 Spike/ACT4/litmus，不综合。
6. 旧测试与冻结 spec 冲突时，停下给出文件、行号、对应 spec 条目和建议补丁，等我批准，不批量自行迁移。
   某层的正确性用例修不好：停下，报告失败用例、首个失败点和复现命令，不跳到上层。
   退休条数比较沿用 T09 批准的截止前缀解释。
7. N6 通过后，在最终 SHA 上重跑 spec 12.8 总门禁；更新 doc/LOOP.md 的 L8 行和相关模块行；
   写 doc/tasks/O3-T10-report.md 并推送 origin，然后停下，不开始 L8c。
```
