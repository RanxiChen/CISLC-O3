# O3-T01 阶段一报告

日期：2026-10-05。分支：`feat/L1-closure`。**阶段一文档已编写，spec 待用户冻结；阶段二未开始。**

## 1. 提交与交付

| 项目 | 提交/状态 |
| --- | --- |
| 进入任务时 HEAD | `9ec5591ecd9e8b6e25428c48d78c60d78c33870c` |
| 第 0 步采纳提交 | `711c762ba7ac2621ea4936d3177411f998ef538d`，已 push 至 `origin/feat/L1-closure` |
| 第 0 步文件 | 仅 `agent.md`、`doc/LOOP.md`、`doc/design/CISLC-O3-BACKEND-DESIGN-BASELINE.md`、`doc/design/README.md`、`doc/O3-v1-plan.md`、`doc/tasks/O3-T01-l3-closure.md` |
| 第 0 步提交信息 | `Adopt O3 v1 plan: 4-wide (B42), B43-B47, L3-L11 ladder, O3-T01 task` |
| 阶段一交付 | [l3-closure-spec.md](../spec/l3-closure-spec.md) 和本报告；同一文档提交，提交号在最终回报中给出 |

为避免把提交号写进自身内容造成自引用，包含本报告的阶段一提交可用下列只读命令确定；本报告的所有源码行号和审计结论固定对应 `711c762`。

```sh
git log -1 --format='%H %s' -- doc/tasks/O3-T01-report.md
```

完整阅读了任务指定的五份文档，包括后端基线第 15 节和第 36 节。spec 交付包含宽度消费者清单、空壳实例/filelist/tie-off 清单、各级停顿方程、旧/新项 mask 清位时机、同拍优先级、缺口 2 核实、定向/随机测试与整核门禁计划，以及六项未决问题。没有更改用户维护的设计基线来代替冻结。

## 2. 核实结论

- 四宽修改会影响正在工作的旧数据流，`BACKEND_MACHINE_WIDTH` 已直接取 rename 配置（`rtl/common/o3_pkg.sv:33`）。Decode Queue 由 6 bank 变 4 bank 后，当前深度 18 不满足整除约束（`rtl/common/o3_cfg_pkg.sv:346`；`rtl/backend/uop_queue.sv:50`、`:68`、`:191–192`），容量待 U1 冻结。
- 缺口 1 还存在：总装 Decode/read/rename/dispatch 仍以全部解析阻塞（`rtl/backend/backend.sv:558–561`、`:641`、`:724`、`:906`）；IQ 内部也阻塞所有解析拍的选择和入队（`rtl/backend/backend_issue_queue.sv:110`、`:173`）；ROB 退休使用 `!resolution_valid_i`（`rtl/backend/rob.sv:270`）。spec 已列出以误预测 M 替换阻塞条件、继续广播 R 清 mask 的完整合同，没有修 RTL。
- 正确解析与新 checkpoint create 同拍需要合并更新；当前代码用解析分支跳过 create（`rtl/backend/branch_checkpoint_file.sv:100–119`）。仅修改总装门控不足以完成任务。
- 缺口 2 的 independent RegRead kill 在源码中已存在（`rtl/backend/alu_pipe.sv:94–119`）；现有测试也已经有旧 Result 背压/年轻 RegRead/误预测的定向序列（`sim/cocotb/branch_recovery/test_branch_recovery.py:133–158`）。总装的缺口说明过期（`rtl/backend/backend.sv:35`）。本轮没有重新运行该测试，不能报告当前 SHA 动态 PASS；阶段二需新增具名定向与真实 DUT 随机/总装仲裁交错测试。
- DCache 是实际 L3 路径，不删除其实例（`rtl/backend/backend.sv:1809–1833`）；FP 域的共享模块只删未连接实例，保留 INT 路径所用文件（INT 连接位置 `rtl/backend/backend.sv:753`、`:827`、`:918–950`、`:1016`、`:1038`）。
- FTQ 提交通知只接到 commit_ctrl 空壳（`rtl/backend/backend.sv:1862`；空壳正文 `rtl/system/commit_ctrl.sv:124`），当前长程序回收能力未确认。删除空壳后的最小通知合同见 U3，没有擅自将它写成已完成的 L3 功能。

## 3. 实际执行与证据

| 命令/检查 | 结果 | 日志/证据位置 |
| --- | --- | --- |
| `git status --short`、`git branch --show-current`、`git rev-parse HEAD` | 分支匹配；初始仅指定 6 个文档改动 | 本报告 §1；会话工具输出 |
| `cat`/分段 `sed` 阅读指定文档；`rg -n`/`nl -ba` 阅读 RTL 和现有测试 | 完成源码审计；行号随 spec 留存 | spec §2～§7；未生成仿真证据 |
| `git diff --check`（第 0 步） | PASS，退出码 0 | 会话工具输出 |
| `scripts/lint.sh`（第 0 步提交前，本地） | PASS，0 errors、211 warnings；Verilator 5.050 | `/tmp/o3-t01-phase1-lint-20261005.log`，输出副本；原输出见下文 |
| 第 0 步 `git add`/`git commit` | 首次沙箱失败：`.git/index.lock` 为只读；随后权限提升成功，仅提交 6 个文件 | 会话工具输出；`git show --stat 711c762` 可复核 |
| `git push origin feat/L1-closure`（第 0 步） | 成功，远端 `9ec5591..711c762` | 会话工具输出 |
| `python3` 标准输入内联文档检查（未创建 `.py` 文件） | PASS；六项内容齐全，176 个显式源码区间存在且行号有效，原有 RTL/测试/Makefile 未变，相对文档链接有效，第 0 步文件范围正确 | `/tmp/o3-t01-phase1-doc-check-20261005.log`；区间检查不证明文字语义或未来行为已实现 |
| `git diff --cached --check`、`--stat`、`--name-only`（阶段一提交前） | PASS，退出码 0；暂存区仅两份阶段一文档 | 会话工具输出 |
| Alan lint / cocotb / 整核门禁 | **未运行**；本轮不做阶段二验证 | 没有 Alan 日志 |
| 新分支密集门禁与周期前后比较 | **未实现、未运行**；仅交付测试计划 | 没有性能数据；计划见 spec §6.3 |
| 综合/时序/FPGA/Linux/Spike | **未运行**，不在阶段一 | 没有相应证据 |

本地已执行 lint 的实际输出：

```text
[lint] verilator : Verilator 5.050 2026-07-01 rev conda-forge build 0
[lint] filelist  : rtl/rtl.f
[lint] top       : o3_core
[lint] errors=0 warnings=211
[lint] PASS —— RTL 解析通过（不代表功能正确）
```

上述 lint 在文档采纳提交前执行，阶段一仅新增 Markdown，没有更改 RTL 或 filelist。未重复运行功能测试；LOOP 的历史 Alan 结果没有转记为本次提交的结果。

## 4. 与 spec 的偏离

阶段一交付内容无偏离。spec 未冻结，不存在阶段二实现；没有修改任何 `.sv`、`.py` 或 Makefile，未移除实例，未改变配置数值，未新增仿真程序。冻结前需明确的选择没有写入实现。

## 5. 未决问题

详细证据与影响见 [spec 第 7 节](../spec/l3-closure-spec.md#7-未决问题冻结前需要决定)。

1. **U1**：四 bank Decode Queue 的深度；当前 18 不能直接沿用，未选择 16/20 或其他组织。
2. **U2**：正确解析刚释放的 checkpoint tag 是否允许同拍复用，以及同 tag create/release/mask 的优先级。
3. **U3**：移除 commit_ctrl 后，L3 是否补最小 ROB→FTQ 提交通知；若补，冻结身份、slot、region_last 来源；当前长程序回收未确认。
4. **U4**：移除 CSRFile 后，前端/数据侧 CSR 与 PMP 静态占位状态的具体合同。
5. **U5**：R1/buffer 的按综合触发记账，以及数据 stride 预取、硬件性能计数空壳的确切后续归属。
6. **U6**：阶段二是否授权共享包/模块必要的注释或行为修改，以及未实例化 L2/DMA 的 filelist 清理；不扩大到前端/核心整体重构。

其他尚未动态确认的控制接缝只列为测试核实项，见 spec §7 末尾，不擅自转换成新的设计决定。

## 6. 停止点

阶段一文档提交并 push 后停止，等待用户宣布 spec 冻结。没有进入阶段二；L3 收尾不能记为闭环通过。
