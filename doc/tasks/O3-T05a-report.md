# O3-T05a：基础设施与选择性清除实施报告

日期：2026-10-06。分支：`feat/L1-closure`。

RTL / 测试提交：`5f25616a13aa2c2cb6565454007811035f0ad6aa`。
实施前 HEAD：`90e02ccc8b053e18daec57729d421ae68ed8091d`。
行为依据：`doc/spec/l7a-predictor-spec.md`（`35bfff9`，U1～U23）；
步骤及门禁依据：`doc/tasks/O3-T05-l7a-tasks.md`（`90e02cc`）。两份文件与 `doc/design/` 均未修改。

## 改动

- 配置调整为 uBTB 32 项、主 BTB 512 组 × 4 路、TAGE base 2048 项、六张 tagged 表 index_bits 均为 10；其余预测器配置不变。
- `bpu_pred_t`、`btb_resp_t`、`bpu_train_t` 与 uBTB / 主 BTB 表项增加 `cfi_is_rvc`、`edge`；L7a 写入及传递为 0。`edge` 是 SystemVerilog 保留字，源码用转义标识符 `\edge` 保留该字段名。
- `o3_types_pkg` 增加 `fe_age(id, slot, head)`、`fe_killed_by(kill, id, slot, head)`：相对 FTQ head 比较环形索引及槽位，代际用于动态身份匹配。
- fetch buffer 在 kill 拍阻塞入队、出队，逐项保留未被边界杀掉的指令，按程序顺序压紧；`kill.all` / `flush_i` 清空。frontend 将 FTQ head 接入两种队列。
- 单槽返回队列按 `(ftq_id, slot=0)` 选择性清除；保留 pending 身份。kill 拍保留槽继续接收匹配响应，被清槽丢弃响应（U7）。
- uBTB 未命中的区域只为 taken CFI 分配；已命中的项仍接收 not-taken BR 训练。新增测试检查 not-taken-only 训练不分配、不挤出已满表的旧项，也不推进替换指针（U18）。
- 前端事件按 spec 6.3 显式编号，移除 `PE_RAS_LOG_FULL`；RAS 不再产生 `PE_RECOVER_CYCLE`（U13）。已有 RAS 测试继续检查其余事件，并检查恢复时该事件保持 0。
- 新增 fetch buffer cocotb；扩展返回队列的边界、回绕、kill 同拍响应测试；uBTB / 主 BTB 适配器检查两项预留位为 0。branch recovery 适配器明确缓冲项比执行取消边界年轻，以保持原回归的测试含义。

## Alan 验证与源码对应

全部仿真、构建及 lint 在 Alan 执行。环境为 `cislc-o3`，Verilator 5.050、cocotb 2.1.0。
为遵守“正确性全过后才能提交”，先同步未提交源码到独立目录，运行完整门禁，再提交。
提交前核对本地源码与 Alan 最终验证源码的逐文件 SHA256；全部一致。

日志目录：`/home/chen/FUN/CISLC-O3-runs/20261006-t05a-5f25616/`。
该路径是原预提交工作目录 `20261006-t05a-90e02cc-work/` 的符号链接；原路径保留，保证已生成构建文件中的绝对路径继续有效。
目录内 `source/` 是验证源码，`t05a-manifest.txt` 是其源码清单，
`manifest-check.log` / `final-manifest-check.log` 是校验结果；
`t05a-gate.sh` / `t05a-core-gate.sh` 及两个 `*-summary.tsv` 保存实际命令和 exit code。

以下命令均在 Alan 的 `source/` 下、激活上述环境后执行；每个 cocotb 命令均运行整个套件。

| 命令 | exit code | 用例 | 日志 |
| --- | --- | --- | --- |
| `make -C sim/cocotb/fetch_buffer SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `fetch_buffer.log` |
| `make -C sim/cocotb/fetch_return_queue SIM=verilator TEST_SEED=1` | 0 | 3/3 PASS | `fetch_return_queue.log` |
| `make -C sim/cocotb/ubtb SIM=verilator TEST_SEED=1` | 0 | 3/3 PASS | `ubtb.log` |
| `make -C sim/cocotb/main_btb SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `main_btb.log` |
| `make -C sim/cocotb/tage SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `tage.log` |
| `make -C sim/cocotb/ras SIM=verilator TEST_SEED=1`（默认 `TEST_DEPTH=16`） | 0 | 2/2 PASS | `ras.log` |
| `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1` | 0 | 4/4 PASS | `branch_recovery.log` |
| `make -C sim/cocotb/bpu SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `bpu.log` |
| `make -C sim/cocotb/ifu_f0 SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `ifu_f0.log` |
| `make -C sim/cocotb/ifu_f1 SIM=verilator TEST_SEED=1` | 0 | 2/2 PASS | `ifu_f1.log` |
| `scripts/lint.sh` | 0 | errors=0，warnings=92 | `lint.log` |

合计 **24/24 cocotb 用例 PASS，FAIL=0，SKIP=0**。
新 fetch buffer 测试覆盖边界前 / 边界本身 / 边界后、`kill_self` 0/1、`all`、FTQ 环形回绕、FIFO 指针回绕、回压、同拍入出队、保留项元数据及 kill 拍握手阻塞。
返回队列对 pending / 已完成两种状态分别覆盖老于、等于、年轻于边界，以及 U7 同拍响应保留 / 丢弃和迟到响应。

整核构建：`make -C sim/o3 build BUILD_DIR=/home/chen/FUN/CISLC-O3-runs/20261006-t05a-90e02cc-work/core-build`，exit code 0，日志 `core-build.log`。
使用该新构建的二进制运行下列命令，均显式设置 `SPIKE_ARGS=`；没有 `--spike`。

| 命令（同上 `BUILD_DIR`） | exit code | 动态结果 / trace oracle | 日志 |
| --- | --- | --- | --- |
| `make -C sim/o3 run-smoke BUILD_DIR=…/core-build SPIKE_ARGS=` | 0 | PASS cycles=38，retired=4；trace 校验 4 条通过 | `run-smoke.log` |
| `make -C sim/o3 run-rv64i-instructions BUILD_DIR=…/core-build SPIKE_ARGS=` | 0 | PASS cycles=76，retired=14；trace 校验 14 条通过 | `run-rv64i-instructions.log` |
| `make -C sim/o3 run-l3-branch-dense BUILD_DIR=…/core-build SPIKE_ARGS=` | 0 | PASS cycles=1968，retired=365；trace 校验 365 条通过；correct_resolves=40，mispredicts=80，load_replays=10 | `run-l3-branch-dense.log` |

逐条可复制的整核命令也保存在 `t05a-core-gate.sh`，表中 `…` 指上文完整工作目录。
整核 traces 位于 `source/sim/o3/{icache_smoke,rv64i_instructions,l3_branch_dense}.jsonl`。
本地仅执行源码阅读、编辑、范围与 SHA256 核对和 `git diff --check`（exit code 0），未运行本地仿真。

首轮 lint / 编译因未经转义的 `edge` 字段名出现语法错误，已修复并重跑通过；首轮日志保存在 `attempt1/`。
最终上述所有正确性项通过后才创建 RTL / 测试提交。

## 未做项与范围

- 本次只实施 T05a；T05b 的 BPU 总装、慢核对、四路仲裁、FTQ 扩展，T05c 的 F1 预解码修正，T05d 的 HPM / CSR 与 `l7_predict.S` 均未实施、未运行。
- bpu / ifu_f1 在本步运行现有用例；不将其通过宣称为尚未实施的预测闭环或预解码修正验证。
- 返回队列仍为 spec 第 7 节允许的单槽实现，是已知吞吐限制；没有扩展为 8 项。
- 未运行 Spike、ACT4、访存类 cocotb、综合、时序 / PPA / FPGA；本步没有 HPM 计数器数值表或性能阈值验收。
- 保留实施前已有的未跟踪 `sim/o3/__pycache__/`，未纳入提交。

结论：T05a 正确性门禁全部通过；范围到 T05a 结束。
