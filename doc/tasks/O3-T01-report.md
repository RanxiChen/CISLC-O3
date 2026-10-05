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

## 7. 阶段二记录（2026-10-05：U4 代码事实不符，停止）

用户已宣布 spec 冻结，§7 U1～U6 与附加要求生效。已开始阶段二前置核对，发现下述问题后，按用户“发现 spec 有误、遗漏或与代码事实不符，停下来”的要求停止实现。没有修改设计，也没有开始 RTL、filelist 或测试改动；本次仅追加报告并更新 LOOP 状态。

### 提交与工作区

| 项目 | 核对结果 |
| --- | --- |
| 分支 | `feat/L1-closure` |
| 阶段二进入 HEAD（冻结提交） | `b48ddf3e7f8578bd30251c160ec358f3e8fc2041` |
| 审阅决定提交 | `26246a805b9a011c094ddde410a6b74682e359f0`，是冻结提交的直接父提交 |
| 进入时工作区 | `git status --short` 输出为空 |
| 进入时本地远端跟踪 SHA | `9161516f3c205cf7d8c6a18e936073f45eb1245d`；两个指定提交均在它之后 |
| 本次提交 | 只包含本报告与 `doc/LOOP.md`；准确 SHA 用 `git log -1 --format='%H %s' -- doc/tasks/O3-T01-report.md` 查询，避免在提交自身写入自身 SHA |

### 阶段二问题

**P2-01：U4 要求验证的现有 PMP 放行逻辑不存在。**

- 冻结 spec §7 U4 要求：“阶段二必须用定向测试确认现有 `pmp_checker` 在该配置、M 模式下放行取指与数据访问；若不放行，停下报告，不得修改 `pmp_checker` 的规则来凑结果。”
- 当前源码 `rtl/common/pmp_checker.sv:24` 明确写“空壳。只有端口与注释，没有任何逻辑，输出未驱动”；`:44`～`:50` 声明输出，`:52`～`:53` 直接结束模块，没有赋值或时序逻辑。`s3_valid_o`、`s3_allow_o`、`s3_fault_o`、`cfg_update_done_o` 均未驱动。
- 该接口 `:40`～`:49` 没有数据读/写访问类型输入，注释 `:3`～`:5` 也说明数据侧权限输入待补。不能把取指接口的测试宣称为完整数据访问权限验证。
- `rg -n 'pmp_checker' rtl sim/cocotb` 只找到模块声明和 filelist 条目，未找到实际实例或既有 cocotb 包装。文件头的“前端 ICache 与数据侧 LSU/PTW 各自实例化”说法与当前源码检索结果不符。
- U6 未授权修改 `pmp_checker.sv`，§1 也明确不实现后续 PMP/MMU 机制。不能自行填实现、接常量成功响应、删掉 U4 测试要求，或把缓存整核现有 PASS 当作 PMP 放行证据。

这是静态源码核对发现的 spec／代码接缝，**不是已经执行的定向测试失败**。未用 DUT 输出生成期望，未删除、放宽或跳过已有测试／断言。停在实现前，等待用户明确 U4 对空壳 PMP 的处理合同及范围；LQ-M 例外不适用于此问题。

### 命令、结果与日志

以下本地命令原始输出和退出码保存在 `/tmp/o3-t01-phase2-stop-20261005/audit.log`；lint 另有 `/tmp/o3-t01-phase2-stop-20261005/lint.log`。`/tmp` 是本机临时证据位置，不是 Alan 日志。

| 命令 | 结果 | 日志／证据 |
| --- | --- | --- |
| `git status --short` | 通过，退出码 0；进入时干净 | `audit.log` |
| `git branch --show-current` | 通过，退出码 0；`feat/L1-closure` | `audit.log` |
| `git log -6 --oneline` | 通过，退出码 0；确认两个提交及父子顺序 | `audit.log` |
| `git rev-parse HEAD 26246a8 origin/feat/L1-closure` | 通过，退出码 0；完整 SHA 如上 | `audit.log` |
| `git log origin/feat/L1-closure..HEAD --oneline` | 通过，退出码 0；两个指定提交尚未在本地跟踪的远端分支中 | `audit.log` |
| `nl -ba rtl/common/pmp_checker.sv` | 通过，退出码 0；确认没有实现 | `audit.log` |
| `rg -n 'pmp_checker' rtl sim/cocotb` | 通过，退出码 0；只有声明和 filelist，未发现实例／测试 | `audit.log` |
| 输出驱动检索（准确命令见下） | 通过，退出码 0；只有注释／输出声明 | `audit.log` |
| `scripts/lint.sh`（本地、本次文档提交前） | 通过，退出码 0；Verilator 5.050，0 errors、211 warnings | `lint.log` |

输出驱动检索命令：

```sh
rg -n 's3_valid_o|s3_allow_o|s3_fault_o|cfg_update_done_o' rtl/common/pmp_checker.sv
```

原始 lint 输出：

```text
[lint] verilator : Verilator 5.050 2026-07-01 rev conda-forge build 0
[lint] filelist  : rtl/rtl.f
[lint] top       : o3_core
[lint] errors=0 warnings=211
[lint] PASS —— RTL 解析通过（不代表功能正确）
```

以下验收均因 P2-01 停止而**未运行**，不存在 Alan 功能证据，不作为豁免或通过：

| spec | 命令／检查 | 结果 | 日志 |
| --- | --- | --- | --- |
| §6.2 | Alan `scripts/lint.sh` | 未运行 | 无 |
| §6.2 | `make -C sim/o3 build` | 未运行 | 无 |
| §6.2 | `make -C sim/o3 run-smoke` | 未运行 | 无 |
| §6.2 | `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1` | 未运行 | 无 |
| §6.2 | `make -C sim/o3 run-rv64i-instructions` | 未运行 | 无 |
| §6.2 | `make -C sim/cocotb/store_queue SIM=verilator` | 未运行 | 无 |
| §6.2 | `make -C sim/cocotb/dcache SIM=verilator` | 未运行 | 无 |
| §6.2 | `make -C sim/cocotb/backend_issue_queue SIM=verilator` | 未运行 | 无 |
| §6.2 | `make -C sim/cocotb/load_store_unit SIM=verilator` | 未运行 | 无 |
| §6.2 | `make -C sim/o3 run-dcache-data run-dcache-replay` | 未运行 | 无 |
| §6.2 | `make -C sim/cocotb/backend SIM=verilator TEST_SEED=1` | 未运行 | 无 |
| §6.1 | 新增／扩展四宽、C/M 合同、U3、U4、缺口 2 DUT 随机 cocotb | 未实现、未运行；具体入口尚未新增 | 无 |
| §6.3 | `make -C sim/o3 run-l3-branch-dense` | 未实现、未运行 | 无 |
| §6.3 | 缺口 1 修复前后同程序、同配置、同种子的两个 SHA 周期对比 | 未运行；尚无比较 SHA 或周期数 | 无 |
| §7 附加 | LQ-M 定向检验／授权修复、PRF 同地址读写行为报告 | 未进行；停止时未进入这些检查 | 无 |

### 与 spec 的偏离

无实现偏离：未修改 RTL／测试／filelist／冻结 spec，按停止条款报告问题。阶段二**未完成**，四宽、空壳清理、缺口 1、U3/U4、缺口 2 测试和分支密集门禁均未交付。相关模块未发生改动，模块头注释未更改；LOOP 已记录停止状态。提交与 push 的执行结果另由本次交付命令日志记录。


### 交付结果

停止报告／LOOP 提交：`76601b93e5d9e2d86039d6b5b68bec4d5703c059`。以下执行成功，日志为 `/tmp/o3-t01-phase2-stop-20261005/delivery.log`；本节的后续文档提交 SHA 用本节前述 `git log` 命令查询。

| 命令 | 结果 |
| --- | --- |
| `git diff --check` | 通过，退出码 0 |
| `git add doc/LOOP.md doc/tasks/O3-T01-report.md` | 通过，退出码 0；按沙箱权限提升执行 |
| `git commit -m 'docs(o3): record O3-T01 phase-two stop on missing U4 PMP implementation' -m '<详细提交说明见 delivery.log>'` | 通过，退出码 0；生成 `76601b9`；仅两份文档 |
| `git push origin feat/L1-closure` | 通过，退出码 0；远端 `9161516..76601b9`，包含指定的两个冻结／审阅提交 |
| `git rev-parse HEAD`、`git status --short`、`git diff b48ddf3 --name-only` | 通过，退出码 0；HEAD 为 `76601b9`、工作区干净、仅本报告与 LOOP 不同 |
| `scripts/lint.sh`（交付结果记录提交前） | 通过，退出码 0；0 errors、211 warnings；`/tmp/o3-t01-phase2-stop-20261005/delivery-record-lint.log` |


## 8. 阶段二恢复（U4/U6 修订后）

进入 SHA：`ffd11e1e1f7957bac13a59b67f5586badaa6cfc0`，工作区干净。P2-01 已由用户修订解除，其余冻结要求不变。

### 四宽／空壳／U3/U4 基线

- Rename=4，Decode Queue=16（4 bank × 4 行）；其余容量与执行资源不变。
- spec §3 清单的后端空壳实例及独占 filelist 条目已移除，文件保留；修订 U6 的 PMP/PMA 和 L2/DMA 协调亦移出清单。共享 INT 模块、真实 DCache/LSU/SQ/L2/probe/DTCM 保留。后续归属按 U5 更新 LOOP。
- U3：已有 decoded_uop_t 的 `ext.ftq_slot`、动态 `ftq_id`、`ftq_last` 经队列／rename 保留；ROB 新增 alloc/retire 槽位端口与存储，backend 将每条实际退休转换为 `ftq_commit_t`。跨模块影响仅 backend→ROB 槽位字段，前端和 o3_core 未改。M 拍分支自身区域末项沿用原 ROB 行为。L5 原样并入 commit_ctrl。
- U4：集中定义 PRIV_M、SATP_BARE、MPRV/SUM/MXR=0、epoch=0、PMP entries/update=0；dmmu 保存派生 priv_eff=M（MPRV=0）。断言 update 永远为 0；禁用 PTW/预取/系统请求全部显式 tie-off，不伪造成功响应。
- PRF 核实：非 FPGA `mem_generic` 的组合读扫描写口形成同地址 bypass；FPGA flat/consistent/latest-tag 三种读路径也已有 bypass，较大写口号优先。x0 读零、写忽略。没有新增旁路。源码依据 `rtl/backend/physical_regfile.sv` 的 `gen_generic_read`、`gen_read_ports_*`。
- 新程序独立模型 `sim/o3/tests/l3_branch_dense_model.py` 生成固定 HEX／expected JSON，不读取 DUT。525 静态指令（跨 131 个以上 FTQ 区域）、365 条架构退休，40 正确 BNE、40 taken BEQ、40 JAL；错路寄存器／store／load，正确路径 readback，旧未知 store replay。新增解析计数器观察 one-shot `exec_resolve.valid`，包含 JAL。
- 原保守 R 阻塞保持不变，此提交作为缺口 1 前测基线；后续控制修复提交另记录。

命令／当前结果：

| 命令 | 结果 | 日志 |
| --- | --- | --- |
| `scripts/lint.sh` | PASS，0 errors、99 warnings，退出码 0 | `/tmp/o3-t01-baseline-lint.log`（提交前另检查） |
| `python3 sim/o3/tests/l3_branch_dense_model.py` | PASS；words=525，retires=365，correct=40，mispredict=80 | 会话输出；固定生成物已纳入提交 |
| 独立 wrapper 的 `verilator --lint-only` | WQ PASS；ROB 首次因包装未限定 ftq_id_t 类型失败，已限定类型，提交前复检 | `/tmp/o3-wq-wrapper-lint.log`、`/tmp/o3-rob-wrapper-lint.log` |
| Alan 功能门禁 | 待运行，不计为通过 | 无 |

与 spec 的实现偏离：无。阶段二问题：当前无新增未决设计问题。模块测试／Alan 门禁／周期对比未完成，不声明 L3 收尾完成。


### 基线首次 Alan 执行／测试包装修正

`a5ca40147eeecfc35161ca257989a630921b7de7`：Alan `make -C sim/o3 build` PASS；`make -C sim/o3 run-l3-branch-dense` FAIL（退出码 2）：仿真 1967 周期、365 退休、40 正确解析、80 误预测、10 replay；checker 首项 PC 字符串补零格式不符（数值相同）。新 oracle 序列化按已有 `main.cpp` 的 PC 10 位／数据 16 位十六进制格式修正；修正前后 365 条 PC、instruction、rd、rd_write、rd_wdata **数值完全一致**，未改程序／架构期望值／既有 checker。日志：Alan `/home/chen/FUN/CISLC-O3-runs/20261005-o3t01/baseline/build.log`、`branch-dense.log`。

同 SHA `make -C sim/cocotb/uop_queue TEST_SEED=1` PASS（`baseline/wq.log`）。新 ROB 包装模型的数组观察从声明顺序改为明确 lane0→lane3 索引，保持最老前缀的期望不变（`baseline/rob.log`）；Alan 复跑待记录。

`48526165ae6844b0000a962e6504c88c8a4e68cb`：`make -C sim/cocotb/load_queue TEST_SEED=1` FAIL，2 tests：1 PASS／1 FAIL，LQ-M 断言 `LQ-M lost old execute` 复现 M 分支不更新存活老 load 的地址记账。日志 `baseline/lq-m-before.log`；按 spec §7 附加授权修复，不修改期望。

Alan 原 checkout 保持不变，新增隔离 worktree。GitHub fetch 直连 TLS 失败，已有代理亦连接 reset；改为本地 `git bundle create /tmp/o3-t01-baseline.bundle feat/L1-closure`／`git bundle verify`、`scp`、Alan `git fetch /tmp/o3-t01-baseline.bundle refs/heads/feat/L1-closure`，均成功。源码完整 SHA 核对如上；环境 Verilator 5.050、cocotb 2.1.0、Python 命令显示 3.12.14（cocotb 嵌入日志显示 3.12.12）。
