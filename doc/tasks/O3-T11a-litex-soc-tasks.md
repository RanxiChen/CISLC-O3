# O3-T11a：L11a 任务书（LiteX 接入、平台 PMA、KCU105 首次上板）

唯一实施依据：[L11a spec](../spec/l11a-litex-soc-spec.md)（已冻结，Z1～Z10）。L8b spec 与 T10 的已批准解释继续有效。本文只规定执行顺序、停止条件与报告格式，不新增任何行为。

## 2026-10-09 用户修订

首版一次接齐 DDR、CLINT/PLIC/UART 和 SD/一致性 DMA。用户授权先实现代码、稍后补充测试；本轮执行范围以 spec 第 15 节为准，原分层门禁保留供后续验证。当前含 L7c 的 HEAD 派生 `feat/l11a-litex-soc`，既有未提交修改保留。

## 历史开工条件（本轮代码阶段由上述用户修订取代）

- T10 已在最终 SHA 通过 L8b 12.8 总门禁并推送 origin。开工前 `git log` 确认 T10 报告的最终提交在当前分支中；不满足则停下报告。
- 在 `feat/L1-closure` 上开新分支 `feat/l11a-litex-soc` 工作；完成后由用户决定合并。

## 共同规则

- **参考源码**：Breeze `/home/chen/leisure/flow` 提交 `ec899c7`（spec 开头列出的文件）。复制进 O3 仓库的文件在文件头注明来源路径与 SHA；改动处保持最小，并在报告“自行决定”中列出。
- **spec 未覆盖的实现细节**（生成脚本格式、LiteX 参数、包装端口命名、测试脚本写法）：自行决定，写进报告“自行决定”一节。**需要改变 spec 的行为或 `doc/design/` 的 Bxx 时**：停下问。
- **允许改动的文件**：只限 spec 第 0 节列出的。
- **主机**：
  - 仿真、Verilator、LiteX 生成：每次运行前重新读取 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`，先预检 cloud_chen，不可用再 Alan；两边都不可用就报告原因，不在本地跑。
  - Vivado 只在 Alan。
  - LiteX 环境按 spec 第 6 节最后一条；报告写明两套环境的版本。
  - 测试失败不算主机不可用。
- **证据规则**（同 T10 加速修订）：
  - 开发中只跑受影响的套件。
  - 每层提交时只需一张表：SHA、主机、命令、exit、用例数，外加失败 → 根因 → 修复文件。
  - 完整同 SHA 审计只在 spec 12.5 总门禁做一次。中间层不生成审计 JSON、逐文件哈希或快照包。
- **可自行决定、不停**：
  - 测试代码自身错误（以冻结 spec 为准修正）；
  - tb wiring 与 tie-off、Makefile 筛选、只读调试日志；
  - spec 第 11 节预先批准的 IO 测试地址迁移（逐条列出）。
- **仍须停下问**：改冻结 spec 或 design；改黄金值；放宽断言；减少规模、种子或用例；其他旧测试与冻结 spec 冲突。
- **核内问题**：冒烟或构建中暴露的核内 bug 按 spec 第 7 节最后一条处理：保存证据，单独提交 `fix(...)`，修后重跑受影响套件与 L8b N5 冒烟。不在 SoC 侧绕开。

## 执行顺序

| 层 | 内容 | 提交 |
| --- | --- | --- |
| P1 | spec 12.1：平台表、生成包、PMA/ICache/PTW/dcache/DMA 判定，定向测试与回归 | `feat(pma): ...` + `test(pma): L11a layer P1 pass` |
| P2 | spec 12.2：LiteX 包装、CPU 类、路由、CLINT/PLIC/UART，elaborate 与 `main_ram` 主设备检查 | `feat(soc): ...` |
| P3 | spec 12.3：冒烟 S1～S3 | `test(soc): L11a layer P3 pass` |
| P4 | spec 12.4：Alan 上生产版与调试版 bitstream | `docs(t11a): FPGA build results` |
| 总门禁 | spec 12.5，最终 SHA | `docs(t11a): L11a final gate` |

### 停止条件

- 需要改 spec 或 design 时。
- 旧测试冲突（预先批准范围以外）时。
- 某层正确性用例修不好：报告失败用例、首个失败点、复现命令和已尝试的修复，不跳到上层。
- Vivado 综合或实现崩溃、超过 3 小时未完成：保留日志后报告，不调参重试超过一次。
- **终点**：两份 bitstream 产出且总门禁通过，`doc/LOOP.md` 的 L11 行更新，报告写完后停下。不推送 origin（等用户上板确认），不开始 L11b。

## 报告：`doc/tasks/O3-T11a-report.md`

- 每次运行的主机、预检、工具与环境版本（O3 环境、LiteX 环境、Vivado）。
- 每层的提交号、命令、exit、用例数；冒烟的仿真周期数与墙钟。
- 平台表 → 生成包 → LiteX 的一致性证据；`main_ram` 主设备列表。
- 迁移的 IO 测试地址清单（旧地址 → 新地址、文件:行）。
- 失败与修复记录。
- FPGA：WNS/TNS/WHS、利用率、最差 10 条路径起止点及归属（核内/胶合），bitstream 与 `.ltx` 路径；与 `ooc/mem-preview` 报告的路径族对照（如已有）。
- 自行决定一节；已知问题与证据边界（未上板、未跑 OpenSBI/Linux、SD 未接）。

---

## 交给 Codex 的提示（复制使用）

```
在 /home/chen/work/CISLC-O3 实施 L11a：O3 接入 LiteX、平台 PMA 精确化、KCU105 首次上板 bitstream。

唯一依据：doc/spec/l11a-litex-soc-spec.md（已冻结，Z1～Z10）。执行顺序与规则：doc/tasks/O3-T11a-litex-soc-tasks.md。
动手之前，先完整读这两份文件、L8b spec 第 6、8 节，以及 spec 开头列出的 Breeze 参考文件（/home/chen/leisure/flow @ ec899c7），
尤其 docs/cluster-soc-rtl-spec.md、litex_wrapper/flow/{core.py,axi_router.py}、fpga/kcu105/target.py、config/breeze_mcu_platform.json。

要求：
1. 先确认 T10 已推送、最终提交在 feat/L1-closure 中，然后从它开新分支 feat/l11a-litex-soc。否则停下报告。
2. 按 P1→P2→P3→P4 推进，每层通过后提交。失败就修，不放宽断言、黄金值和规模；核内 bug 单独 fix 提交，并重跑 L8b N5 冒烟。
3. 地址只能有一个来源：config/o3_platform.json → 生成 rtl/common/o3_platform_pkg.sv，LiteX 侧也只读这个 JSON。
4. 只改 spec 第 0 节允许的文件。需要改 spec 或 doc/design 时停下问我。spec 第 11 节的 IO 测试地址迁移已预先批准，其余旧测试冲突停下问。
5. 主机：仿真、LiteX 每次运行前重新读 simulation-host.md，先预检 cloud_chen，不行再用 Alan；Vivado 只在 Alan。都不可用就报告原因，不在本地跑。
6. 证据按任务书的轻量规则；完整同 SHA 审计只在 spec 12.5 做一次。
7. 两份 bitstream 产出、总门禁通过后：更新 doc/LOOP.md 的 L11 行，写 doc/tasks/O3-T11a-report.md，然后停下。
   不推送 origin，不开始 L11b。上板由我本人进行。
```
