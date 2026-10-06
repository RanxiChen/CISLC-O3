# O3-T05cd：L7a RTL 代码阶段交接（未验收）

日期：2026-10-06。分支：`feat/L1-closure`。工作区基线：`28ff6b7`。
本次用户要求：先完成 L7a 剩余全部 RTL，具体测试由用户随后处理。
因此本次连续写入 T05c/d 的生产代码，不执行原任务书的逐步功能门禁；
没有提交或推送 RTL，不将工作区实现记为 L7a 闭环通过。
行为依据仍为冻结 `doc/spec/l7a-predictor-spec.md`（U1～U24），未修改 spec 与设计基线。

## RTL 改动

- `ifu_f1.sv`：解码合法 BR/JAL/JALR 与 x1/x5 RAS 提示；按 a/b > c > d > e > f
  逐指令核对，第一处修正截断交付；d 重算不沿用 a/b 的位置前提。
  `pred_taken` 按规则而非目标地址关系设置。异常项原样交付并截断，修正先于异常时不交付异常项。
  `pd_req_q` 仅在交付握手时写入，下一拍发出一次，输出不组合依赖 kill。
- `frontend.sv`：F1 请求接入四源仲裁；按事件累加子模块增量，输出 `fe_perf_o`。
  BPU 已包含 RAS/slow 事件，顶层不重复计数。预取器仍为空壳，其未驱动 perf 输出不接入，事件明确置 0。
  删除 `frontend_perf_events` 实例；旧 `perf_rd_*` 接口保留作零值兼容口，正式读写走 CSR。
- `hpm_counters.sv`：新增计数状态唯一所有者。实现 mcycle/minstret、8 个 HPM、
  16 位事件选择与 mcountinhibit。源 1 为 FE，源 2 为 BE；零号、编号空洞和未知来源计数为 0。
  CSR 读/RMW 使用旧值；计数器写只覆盖自身本拍增量，配置写下一拍生效（U11）。
  11～31 号读 0/写忽略，写入观测值归零（U21）；只读别名写非法。
- `csr_file.sv`：迁出 mcycle/minstret 状态，将 HPM 地址读写及 WARL 观测委派给新模块。
  保持现有 M/Bare、trap/MRET、MISA RV64IM 与 IALIGN=32 行为。
- `o3_core.sv` / `backend.sv`：连接 FE → CSR/HPM，汇总现有 commit_ctrl/LSU/DCache 的 BE 事件。
  现有 BE 生产者当前仍输出 0，本级未新增事件产生机制或后端恢复行为。
- `o3_cfg_pkg.sv`：新增 `O3_CFG.core.hpm_counters=8`。
- `o3_types_pkg.sv`：BE 事件按现有顺序从 0x01 开始显式编号，`BE_PERF_NUM=0x26`；FE 编号未改。
- `rtl/rtl.f`：新增 HPM（先于 CSR），移除旧 frontend_perf_events 条目；旧独立文件未删除。

## 测试阶段接口交接

- F1 生产接口形状不变，行为已变化。旧测试的 `predecode_valid_o==0` 恒等断言不再适用。
  适配器需提供预测类型/直接目标/RAS 动作、入口 RAS count/top、异常字段，导出完整修正请求。
- frontend 新增 `fe_perf_o`；backend 新增 `fe_perf_i`；csr_file 新增 `fe_perf_i` 和 `be_perf_i`。
  独立测试若不检查事件，应明确接 0；HPM/CSR 测试应提供可控增量。
- HPM 的接口是原始 `csr_req_t`、`req_valid_i`、退休条数与两类事件增量；
  输出 `implemented_o`、`csr_resp_t` 与归一化 `write_value_o`。
  NUM_HPM 在实例化时由唯一配置传入；单模块测试使用 `O3_CFG.core.hpm_counters`。
- CSR 单模块 Makefile 必须在 csr_file 前加入 hpm_counters；读取整份 rtl.f 的套件自动获得依赖。
- 本次没有改任何测试文件，也没有创建 `l7_predict.S`、`run-l7-predict` 或两组差值检查脚本。
  它们属于后续测试阶段；原 T05c/d 功能门禁及两组一致性/性能口径仍见任务书与 spec 9.1～9.3。

## 检查与未做项

- 本地 `git diff --check`：exit code 0（仅格式检查）。
- Alan `scripts/lint.sh`：exit code 0，errors=0、warnings=84，Verilator 5.050。
  日志 `/tmp/cislc-o3-l7a-rtl-20261006-28ff6b7/lint.log`；只解析 o3_core 编译单元，
  不代表功能验证。使用独立临时目录，未改 Alan 原开发树。
- cocotb、整核构建/仿真、`l7_predict` 两组验收、性能阈值：未运行。
- Spike、ACT4、访存类 cocotb、formal、综合、时序/PPA/FPGA：未运行。
- 新增 RTL 的功能正确性与性能尚无验证结论。T05a/b 历史 Alan 证据不覆盖本次新增行为。
- 未跟踪的 `sim/o3/__pycache__/` 保持原样。

## 2026-10-06 测试补充与 Alan 功能复验

本节更新上文“功能未验证”的状态，保留前一轮代码交接作为历史记录。
用户授权补充测试代码；本轮没有修改生产 RTL，没有提交或推送。
运行对象为 `28ff6b7` 加当前未提交工作区；与补测前归档比较，94 个 `rtl/` 文件内容均未变化。

### 新增覆盖

- F1：b/c 同时成立、块内最早修正；x0/x1/x5/x6 组成的完整 JALR RAS 提示矩阵（栈空/非空）；BR/JAL 立即数边界及保留 funct3；异常恰在预测出口；连续背压后释放、kill 与寄存请求并存；空栈 d 的顺序越过、f 保留 `pc+4` 目标仍 taken；待发请求在同步复位沿清除。
- HPM：FE→BE 非零事件切换；带增量的 RS/RC 与只读操作；无效请求保留写载荷；11～31 的 RW/RS/RC 读值和归一化写入观测；逐个暂停全部八个 HPM；活动状态复位。
- CSR：trap/MRET 拍无效请求保留旧写载荷、事件照常累加；HPM RMW 和 U21 观测经 csr_file 路由；事件位宽由适配器导出，取消 Python 固定 4/3 位假设。没有构造违反 RTL 合同的 trap 与有效 CSR 请求同拍输入。
- `sim/cocotb/l7_recovery/`：生产 F1、仲裁器、fetch buffer、返回队列与 CSR/HPM 的公开端口连接测试；检查预解码胜出、败给更老 EXEC、busy 期间被替换、FTQ 回绕、旧/修正项字段保留、年轻项清除、kill 拍旧响应保留/年轻响应丢弃、过期恢复完成身份、事件只计接受拍。
- `sim/o3/l7_event_checks.sv`：`+L7_CHECK` 启用的只读整核断言；从真实子模块事件独立求和，检查 frontend→core→backend→CSR→HPM 连线、赢家与恢复周期口径、提交分类和，以及按 U11 的逐拍计数状态。监测器不驱动生产状态。
- `l7_predict.S` / `l7_predict.ld` 与 `run-l7-predict`：spec 9.2 三段程序、两组事件、统一暂停/初始化/采样及各段差值。固定数据与失败入口地址；ELF 检查证明测量前 394 条静态指令的地址/编码一致，仅六个事件初始化立即数不同。动态 CFI 分母由 trace 再核对为 2001、2500。
- `check_l7_predict.py`：从退休 CSR 结果和退休 SD 数据交叉提取样本，检查分类和、A/B 共同事件、性能标记；`test_l7_checks.py` 包含缺样本、重复样本、CSR/存储不符、未暂停采样、错误标记、动态分母错误、trap、分类错误及两种共同事件不一致的注错检查。

### 运行环境、命令与日志

所有构建/仿真及检查器自测在 Alan 独立目录执行：
`/home/chen/FUN/CISLC-O3-runs/20261006-l7a-added-tests/`。
源码位于 `source/`，整核构建与两组 trace 位于 `core-build/`；原 Alan 开发树未改。
环境：`source /home/chen/miniforge3/bin/activate cislc-o3`，Verilator 5.050、cocotb 2.1.0。
最终本地与 Alan 的 115 个生产 RTL、相关测试及整核检查文件 SHA256 全部一致；
校验日志 `final-source-check.log`，exit code 0。本地 `git diff --check` 通过。

以下命令在 `source/` 运行，表内的 `$RUN` 指上述运行目录。

| 命令 | 最终 exit code | 结果 | 日志 |
| --- | --- | --- | --- |
| `make -C sim/cocotb/ifu_f1 SIM=verilator TEST_SEED=<1/7/29/101>` | 0，各种子 | 各 17/17 PASS | `ifu_f1-final-seed*.log` |
| `make -C sim/cocotb/hpm_counters SIM=verilator TEST_SEED=1` | 0 | 17/17 PASS | `hpm_counters.log` |
| `make -C sim/cocotb/csr_file SIM=verilator TEST_SEED=1` | 0 | 3/3 PASS | `csr_file.log` |
| `make -C sim/cocotb/l7_recovery SIM=verilator` | 0 | 2/2 PASS | `l7_recovery.log` |
| 前序 `ifu_f0/ubtb/main_btb/tage/ras/branch_recovery/fetch_buffer/fetch_return_queue/bpu_slow_check/redirect_arbiter/bpu` 的整个套件，`SIM=verilator TEST_SEED=1` | 全部 0 | 合计 27/27 PASS | 各目录同名 `.log` |
| `make -C sim/cocotb/bpu SIM=verilator TEST_SEED=1 COCOTB_TOPLEVEL=ftq_training_tb_top COCOTB_TEST_MODULES=test_ftq` | 0 | 2/2 PASS | `ftq.log` |
| `scripts/lint.sh` | 0 | errors=0，warnings=84 | `lint.log` |
| `make -C sim/o3 build BUILD_DIR=$RUN/core-build` | 0 | 整核构建通过 | `core-build.log` |
| `make -C sim/o3 run-l7-predict BUILD_DIR=$RUN/core-build` | 0 | 两组 tohost、布局、分类、共同事件及性能检查通过 | `run-l7-predict-final.log` |
| `make -C sim/o3 run-smoke BUILD_DIR=$RUN/core-build SPIKE_ARGS=+L7_CHECK` | 0 | 38 cycles / 4 retires，trace PASS | `run-smoke.log` |
| `make -C sim/o3 run-rv64i-instructions BUILD_DIR=$RUN/core-build SPIKE_ARGS=+L7_CHECK` | 0 | 70 cycles / 14 retires，trace PASS | `run-rv64i-instructions.log` |
| `make -C sim/o3 run-l3-branch-dense BUILD_DIR=$RUN/core-build SPIKE_ARGS=+L7_CHECK` | 0 | 1966 cycles / 365 retires，trace PASS，load_replays=10 | `run-l3-branch-dense.log` |
| `cd sim/o3 && python test_l7_checks.py` | 0 | 4/4 检查器自测，含十种注错变体 | `checker-selftest.log` |

按 seed=1 去重计，全部 cocotb **68/68 PASS**；F1 另三个种子各 17/17。
`SPIKE_ARGS=+L7_CHECK` 只传入测试断言开关，没有运行 Spike。
组 A 整核 43787 cycles / 19396 retires；组 B 43838 cycles / 19447 retires。
组别相关的最终检查代码不同，完整程序总周期与总退休数不要求相同；共同事件仅比较三个测量窗口的差值。

### 三段计数器差值

每个数字均为“段后样本减段前样本”，来源列明确区分 A/B。

| 段 | UBTB_HIT A | SLOW_OVERRIDE A | PREDECODE A | EXEC A/B | CMT_REGION A/B | CMT_MISPRED A | 快对慢对 B | 快对慢错 B | 快错慢对 B | 快错慢错 B |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 条件分支循环 | 2072 | 21 | 0 | 5 / 5 | 2003 / 2003 | 5 | 2001 | 0 | 0 | 2 |
| 八层调用/返回 | 2564 | 0 | 10 | 2 / 2 | 2502 / 2502 | 2 | 2484 | 0 | 0 | 18 |
| 四十个 taken 区域 | 3978 | 41 | 33 | 2 / 2 | 4003 / 4003 | 2 | 4001 | 0 | 0 | 2 |

正确性：每段 B 的四类分类和等于区域总数，A/B 的 `CMT_REGION` 和 `REDIRECT_EXEC` 差值全部一致。
性能：第 1 段 `5*4 < 2001`，第 2 段 `2*4 < 2500`，第 3 段慢覆盖 `41 > 0`，均 PASS。
原始结果：`core-build/l7_predict_summary.json` 与 `core-build/l7_layout.json`。

### 失败与修复记录、证据范围

- 恢复适配器首轮缺少显式 enum 值，Verilator 拒绝默认 bit→enum 转换；显式填 `CFI_NONE/RAS_NONE` 后 2/2 通过。只改测试台。
- 首轮 ELF 布局检查发现组别相关末尾代码使 fail 标签移动，前面分支编码随之变化；固定 fail 地址后布局检查通过。没有放宽布局断言。
- trace 检查器最初将 JSONL header 当作退休项；明确校验并跳过 header 后两组检查通过，加入检查器自测覆盖该格式。
- seed 7 随机用例末拍有待发请求，后续用例在同步复位首沿前误判其应为 0；复位 helper 先执行首沿再检查，并新增待发请求同步复位定向用例，四个种子最终均通过。原失败日志 `ifu_f1-seed7.log` 保留。
- 本次没有改生产 RTL；上述均为测试代码修复。未复跑用户先前的七个 RTL 注错实验。
- 当前未提交；本节的工作区功能证据不对应一个新增提交，也不代表全 ISA 或后续级验收。
- Spike、ACT4、独立访存类 cocotb、formal、综合、时序/PPA/FPGA：未运行。
