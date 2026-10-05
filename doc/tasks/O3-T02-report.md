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
