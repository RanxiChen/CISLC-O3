# O3-T05b：BPU 总装、慢核对、四路仲裁与 FTQ 实施报告

日期：2026-10-06。分支：`feat/L1-closure`。

RTL / 测试提交：`b122d590bf8ed99e494c4117789b84b16536bdfc`。
实施前 HEAD：`4ffd56daa8a3de546c0b68db5ac3a765852b2793`。
唯一行为依据：`doc/spec/l7a-predictor-spec.md`（`4ffd56d`，U1～U24）；
步骤及门禁依据：同一提交中的 `doc/tasks/O3-T05-l7a-tasks.md`。
spec、任务书与 `doc/design/` 均未修改。本步在用户确认 T05a（`5f25616`）后实施。

## 改动

- 先完成 U24：三个公共记录以及 uBTB / 主 BTB 私有表项的预留字段统一改为 `is_edge`；RTL 和测试不再使用转义字段名。`cfi_is_rvc` / `is_edge` 继续恒为 0。
- BPU 使用目标接口总装 uBTB、主 BTB、TAGE、history、RAS 与慢核对，删除旧 BPU 接口。预测入口的 history / RAS 快照与 FTQ 身份沿两级流水线传递；主 BTB 的 N+1 返回寄存到 N+2，与 TAGE 对齐。测试启用断言检查有效结果对齐。
- `alloc_valid` 按 spec 的复位、hold、恢复、kill 条件产生；只在 `alloc_fire` 发主 BTB / TAGE 查询、推进 history 和 RAS。快预测的返回目标取分配前 RAS 栈顶，慢核对取入口保存的 checkpoint；训练只在三张表均 ready 时广播同一事务。kill 清除在途预测，重定向更新 PC。
- 慢核对屏蔽 entry 之前的槽，按最早候选选择 taken BR / JAL / owner JALR；更早的缺目标候选不跳过。缺目标保持 raw taken，输出顺序 next_pc、不产生 exit（U1）；owner 目标匹配要求 `cfi_type != CFI_NONE`（U17）。比较 CFI 有效性、槽、类型、RAS 动作和 next_pc，生成完整覆盖请求与本模块事件；不组合依赖 kill。
- 仲裁器支持 SYS / EXEC / PREDECODE / SLOW：SYS 优先，其余按相对 FTQ head 的年龄、槽位选择，同位置 EXEC > PREDECODE > SLOW。接受拍广播完整请求、kill 与快照读请求；恢复中的请求只有被 SYS、更老请求或同位置更高优先级替换时才重新接受。恢复完成检查 history、RAS 及 RAS 身份。重定向事件按接受拍计数（U13），恢复周期按 busy 计数。frontend 的 `predecode_i` 本步显式接 0。
- FTQ brief 增加 `ras_ckpt`；分配初始化 `final_next_pc`，慢返回写 `slow_next_pc` 与 `final_next_pc`，接受拍的有效、存活、非 `kill_self` 赢家更新最终 next_pc。保留执行解析对最终预测的修正，并用共享 `fe_killed_by` 处理区域清除。训练提交握手产生区域事件、四类 fast / slow 正误事件及区域误预测事件；`PE_FTQ_FULL_CYCLE` 只统计实际分配被阻塞的周期。
- 改写 BPU cocotb；新增慢核对、四路仲裁 cocotb（含模块级 predecode 输入）。在 BPU 测试目录增加 FTQ 元数据 fixture，覆盖 brief、赢家接受拍、四类提交、执行修正、训练回压与 full 事件。同步 uBTB / 主 BTB 测试的 U24 字段名。

## Alan 验证与源码对应

全部构建、仿真和 lint 在 Alan（`chen-System-Product-Name`）执行。
环境：`cislc-o3`，Python 3.12.12、cocotb 2.1.0、Verilator 5.050。
为遵守“正确性项全过后才能提交”，先将未提交源码同步到独立目录运行门禁，全部通过后才提交。
最终本地源码、Alan 验证源码以及上述 RTL / 测试提交的 **471 个源码文件 SHA256 全部一致**。

日志目录：`/home/chen/FUN/CISLC-O3-runs/20261006-t05b-b122d59/`。
该路径是预提交工作目录 `20261006-t05b-4ffd56d-work/` 的符号链接；保留原目录，保证构建文件中的绝对路径有效。
Alan 原有开发树未修改；独立目录内 `source/` 为验证源码。

- `t05b-source.tar` / `t05b-manifest.txt`：最终源码归档与逐文件清单。
- `final-manifest-check.log`：最终清单在 Alan 的校验结果，exit code 0。
- `t05b-validated-commit.json`：提交、tree、归档及清单 SHA256 与门禁结果。
- `t05b-gate.sh` / `t05b-recheck.sh` / `cocotb-summary.tsv`：测试命令与最终 exit code；原轮次记录保留在 `attempt1/`、`attempt2/`。
- `t05b-core-gate.sh` / `core-summary.tsv`：构建及三个整核回归的实际命令和 exit code。

以下命令均在 Alan 的 `source/` 下、激活上述环境后执行。每条 cocotb 命令运行整个套件。

| 命令 | exit code | 用例 | 日志 |
| --- | --- | --- | --- |
| `make -C sim/cocotb/bpu_slow_check SIM=verilator TEST_SEED=1` | 0 | 1/1 PASS | `bpu_slow_check.log` |
| `make -C sim/cocotb/redirect_arbiter SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `redirect_arbiter.log` |
| `make -C sim/cocotb/bpu SIM=verilator TEST_SEED=1` | 0 | 4/4 PASS | `bpu.log` |
| `make -C sim/cocotb/bpu SIM=verilator TEST_SEED=1 COCOTB_TOPLEVEL=ftq_training_tb_top COCOTB_TEST_MODULES=test_ftq` | 0 | 2/2 PASS | `bpu-ftq.log` |
| `make -C sim/cocotb/fetch_buffer SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `fetch_buffer.log` |
| `make -C sim/cocotb/fetch_return_queue SIM=verilator TEST_SEED=1` | 0 | 3/3 PASS | `fetch_return_queue.log` |
| `make -C sim/cocotb/ubtb SIM=verilator TEST_SEED=1` | 0 | 3/3 PASS | `ubtb.log` |
| `make -C sim/cocotb/main_btb SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `main_btb.log` |
| `make -C sim/cocotb/tage SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `tage.log` |
| `make -C sim/cocotb/ras SIM=verilator TEST_SEED=1`（默认 `TEST_DEPTH=16`） | 0 | 2/2 PASS | `ras.log` |
| `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1` | 0 | 4/4 PASS | `branch_recovery.log` |
| `make -C sim/cocotb/ifu_f0 SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `ifu_f0.log` |
| `make -C sim/cocotb/ifu_f1 SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `ifu_f1.log` |
| `scripts/lint.sh` | 0 | errors=0，warnings=85 | `lint.log` |

合计 **31/31 cocotb 用例 PASS，FAIL=0，SKIP=0**。
慢核对的单个用例包含候选排序、entry 屏蔽、缺目标、ownerless 槽 0 / 目标 0、返回 checkpoint、比较字段扰动及固定种子随机候选组合。
仲裁器检查四源组合、回绕、同位置优先级、忙时替换、过期完成身份与保持期间事件不重复。
BPU 覆盖两拍返回、hold / 分配回压、history 一次推进及恢复、call / return、已保存 RAS 与当前 RAS 不一致、uBTB 驱逐后的慢覆盖及在途 kill。

整核构建命令（exit code 0，日志 `core-build.log`）：

```bash
make -C sim/o3 build BUILD_DIR=/home/chen/FUN/CISLC-O3-runs/20261006-t05b-4ffd56d-work/core-build
```

三个整核命令均使用上述新构建的二进制、显式 `SPIKE_ARGS=`，没有 `--spike`。

| 命令 | exit code | 动态结果 / trace oracle | 日志 |
| --- | --- | --- | --- |
| `make -C sim/o3 run-smoke BUILD_DIR=/home/chen/FUN/CISLC-O3-runs/20261006-t05b-4ffd56d-work/core-build SPIKE_ARGS=` | 0 | PASS cycles=38，retired=4；trace 校验 4 条通过 | `run-smoke.log` |
| `make -C sim/o3 run-rv64i-instructions BUILD_DIR=/home/chen/FUN/CISLC-O3-runs/20261006-t05b-4ffd56d-work/core-build SPIKE_ARGS=` | 0 | PASS cycles=76，retired=14；trace 校验 14 条通过 | `run-rv64i-instructions.log` |
| `make -C sim/o3 run-l3-branch-dense BUILD_DIR=/home/chen/FUN/CISLC-O3-runs/20261006-t05b-4ffd56d-work/core-build SPIKE_ARGS=` | 0 | PASS cycles=1968，retired=365；trace 校验 365 条通过；correct_resolves=40，mispredicts=80，load_replays=10 | `run-l3-branch-dense.log` |

traces 位于 `source/sim/o3/{icache_smoke,rv64i_instructions,l3_branch_dense}.jsonl`。
本地仅进行阅读、编辑、Python 语法检查、允许范围及 SHA256 核对、`git diff --check`（exit code 0），未运行本地仿真或 lint。

## 首轮失败与修复记录

- 仲裁器第二个用例在第一个复位边沿之前比较恢复状态，误将同一仿真中前一个用例遗留状态视为失败。调整测试只在复位后检查清除结果；复位期间仍检查握手阻塞。旧日志及最初源码归档保留在 `attempt1/`。
- FTQ 测试的公共记录编码最初按 39 位地址打包，而当前 `vaddr_t` 实际为 64 位，导致 valid / 字段错位。适配器导出 `VADDR_W`，Python 从端口获取地址宽度，取消 codec 的默认地址宽度并增加记录总宽度断言。旧失败日志保留在 `attempt2/`。
- 上述均为测试平台修复，未改动已跑门禁的生产 RTL。修复共享 codec 后重跑慢核对、仲裁器、BPU 与 FTQ 四组，全部通过；其余未受影响的前序套件、lint 和三个整核回归保留本次独立目录的已通过结果。最终所有正确性项通过后才创建 RTL / 测试提交。

## 未做项与范围

- 本次到 T05b 结束。T05c 的 F1 预解码修正、异常细则及 frontend 的 predecode 连线未实施；现有 ifu_f1 套件通过仅证明前序行为。仲裁器模块级 predecode 路径已测。
- 本模块 `perf_o` 已按本步 spec 产生事件；T05d 的汇总、HPM / CSR 可读路径、`l7_predict.S` 两组采样及性能阈值未实施、未运行。本报告的周期数据只作回归证据。
- SYS 保留 spec 第 7 节允许的 L5 已知入口行为，提交态 history / RAS 上下文机制未扩展。返回队列保持单槽，是已知吞吐限制。
- 未运行 Spike、ACT4、访存类 cocotb、formal、综合、时序 / PPA / FPGA。
- 保留实施前已有的未跟踪 `sim/o3/__pycache__/`，未纳入提交。

T05b 正确性门禁全部通过。停在本步，等待用户确认后再进入 T05c。
