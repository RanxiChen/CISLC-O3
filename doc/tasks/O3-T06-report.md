# O3-T06：L7b RVC 实施与 Alan 验收报告

日期：2026-10-06～07。分支：`feat/L1-closure`。基线：`cbe3372`。
依据：冻结 [L7b spec](../spec/l7b-rvc-spec.md) V1～V8 与 [任务书](O3-T06-l7b-tasks.md)。

## 提交与实现

- `01c939a`：冻结 V1～V8，提交 spec 与任务书。
- `2614064`（T06a）：类型、整数 RV64C 展开器、ROB 实际指令长度、BRU/CSR IALIGN=16。
  展开器手工翻译 Flow `02e3f6fd2219186c9ddbe7cc7dd3e486ae9709f6`；浮点 RVC、保留编码沿用非法判定。
  CSR 的 MISA 加 C，mepc 保留 bit1，mtvec 行为不变。前端在本步仍只交付 32 位指令。
- `2b50184`（T06b）：F0 每拍四条、首拍消费返回队列块、hold/pend、跨块拼接与后半字异常；
  F1 按半字位置/实际长度核对、直接截断与零指令拍 c′；预测器长度/edge 字段、RAS/历史地址；
  FTQ 实际字段训练与空区域回收；整核 RVC 程序。两步门禁分别通过后提交。
- 本轮未改冻结 spec 的行为与 `doc/design/`，未推进 L8～L11。提交未推送。

## 测试环境与证据目录

全部构建、仿真及程序布局/轨迹检查在 Alan 独立目录运行，原 Alan 开发树未改：

- `$A=/home/chen/FUN/CISLC-O3-runs/20261006-t06a-01c939a`
- `$B=/home/chen/FUN/CISLC-O3-runs/20261006-t06b-2614064`

工作目录为各自 `source/`；整核输出为 `core-build/`。目录后缀是实施前基线，生产提交号见上节。
环境：`source /home/chen/miniforge3/bin/activate cislc-o3`，Verilator 5.050、cocotb 2.1.0。
`status.log` 记录完整门禁的每项 exit code。完整门禁后只补慢核对模型的字段支持和定向向量、
更新 F1 文件说明；受影响的 slow check/BPU 及 lint 再次通过，见 `*-final.log`。
最终源文件与对应生产提交的内容核对见各目录 `final-source-check.log`。

## cocotb 门禁

以下命令均从 `source/` 执行；所有行 A/B 的 exit code 均为 **0**，seed=1 去重计。
日志分别为 `$A/<套件>.log`、`$B/<套件>.log`；B 的 slow check/BPU 最后复验为同名 `-final.log`。

| 命令 | T06a PASS | T06b PASS |
| --- | --- | --- |
| `make -C sim/cocotb/rvc_expander SIM=verilator TEST_SEED=1` | 2/2 | 2/2 |
| `make -C sim/cocotb/ifu_f0 SIM=verilator TEST_SEED=1` | 2/2 | 6/6 |
| `make -C sim/cocotb/ifu_f1 SIM=verilator TEST_SEED=1` | 17/17 | 18/18 |
| `make -C sim/cocotb/hpm_counters SIM=verilator TEST_SEED=1` | 17/17 | 17/17 |
| `make -C sim/cocotb/csr_file SIM=verilator TEST_SEED=1` | 3/3 | 3/3 |
| `make -C sim/cocotb/l7_recovery SIM=verilator TEST_SEED=1` | 2/2 | 2/2 |
| `make -C sim/cocotb/ubtb SIM=verilator TEST_SEED=1` | 3/3 | 3/3 |
| `make -C sim/cocotb/main_btb SIM=verilator TEST_SEED=1` | 2/2 | 2/2 |
| `make -C sim/cocotb/tage SIM=verilator TEST_SEED=1` | 2/2 | 2/2 |
| `make -C sim/cocotb/ras SIM=verilator TEST_SEED=1` | 2/2 | 2/2 |
| `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1` | 4/4 | 4/4 |
| `make -C sim/cocotb/fetch_buffer SIM=verilator TEST_SEED=1` | 2/2 | 2/2 |
| `make -C sim/cocotb/fetch_return_queue SIM=verilator TEST_SEED=1` | 3/3 | 3/3 |
| `make -C sim/cocotb/bpu_slow_check SIM=verilator TEST_SEED=1` | 1/1 | 1/1 |
| `make -C sim/cocotb/redirect_arbiter SIM=verilator TEST_SEED=1` | 2/2 | 2/2 |
| `make -C sim/cocotb/bpu SIM=verilator TEST_SEED=1` | 4/4 | 5/5 |
| `make -C sim/cocotb/bpu SIM=verilator TEST_SEED=1 COCOTB_TOPLEVEL=ftq_training_tb_top COCOTB_TEST_MODULES=test_ftq` | 2/2 | 3/3 |
| 合计 | **70/70** | **77/77** |

F1 原有 17 项保留；适配器把八个半字位置上的有效项压紧到四条输入 lane，位置字段不变。
F0 的原 IALIGN=32 oracle 更新为按 lane 压紧的 RV64I oracle；随机事务仍为 120 拍。
新增用例直接核对混合长度、两拍/背压、首拍出队、hold 截断、pending 保存/丢弃、零指令拍、D34、kill/sync。
BPU 检查压缩/edge call 的字段读回与 RAS push，slow check 检查字段不一致覆盖；
FTQ 检查年轻区域的非末条提交即可关闭更老空区域，并核对实际长度/edge 训练值。

## lint、整核与性能回归

表内 `$RUN` 分别取 `$A`、`$B`，命令从 `source/` 执行。所有最终 exit code 均为 **0**。
`+L7_CHECK` 是既有只读监测器开关，不代表执行了 Spike。

| 命令 | T06a | T06b | 日志 |
| --- | --- | --- | --- |
| `scripts/lint.sh` | errors=0，warnings=84 | errors=0，warnings=90 | `lint.log`；B 最后复验 `lint-final.log` |
| `make -C sim/o3 build BUILD_DIR=$RUN/core-build VERILATOR='verilator -j 8'` | PASS | PASS | `core-build.log` |
| `make -C sim/o3 run-smoke BUILD_DIR=$RUN/core-build SPIKE_ARGS=+L7_CHECK` | 38 cycles / 4 retires | 同左 | `run-smoke.log` |
| `make -C sim/o3 run-rv64i-instructions BUILD_DIR=$RUN/core-build SPIKE_ARGS=+L7_CHECK` | 70 cycles / 14 retires | 同左 | `run-rv64i-instructions.log` |
| `make -C sim/o3 run-l3-branch-dense BUILD_DIR=$RUN/core-build SPIKE_ARGS=+L7_CHECK` | 1966 cycles / 365 retires | 同左 | `run-l3-branch-dense.log` |
| `make -C sim/o3 run-l7-predict BUILD_DIR=$RUN/core-build SPIKE_ARGS=+L7_CHECK` | 两组正确性/性能 PASS | 两组正确性/性能 PASS | `run-l7-predict.log`、`core-build/l7_predict_summary.json` |
| `make -C sim/o3 run-l7b-rvc BUILD_DIR=$RUN/core-build SPIKE_ARGS=+L7_CHECK` | 本步未运行 | **5673 cycles / 2216 retires；tohost=1 PASS** | `run-l7b-rvc.log` |

T06b `l7_predict` 的三个测量窗口与 L7a 相同：A/B 的 EXEC 为 5/2/2、CMT_REGION 为 2003/2502/4003；
B 四类分类和逐段等于 CMT_REGION，共同事件一致。性能：`5*4<2001`、`2*4<2500`、慢覆盖 `41>0`，全部 PASS。

整核 RVC 程序循环 100 次，累加器自查为 400，含 C.BEQZ/BNEZ、C.J、C.JALR/JR、跨块 32 位分支和零指令块入口。
ELF 符号与真实退休轨迹独立核对：`edge_branch=0x8000003e`、`zero_target=0x8000005e` 均为槽 7；
两处及 `loop=0x8000001a`、`leaf=0x8000007e` 各退休 100 次。检查 exit code 0，见 `$B/evidence-audit.log`。

## 失败、修复与未做项

- 本轮记录的 RTL 功能门禁无失败；首轮 F0/F1 定向测试也通过。
- 最后源码复核发现慢核对 Python oracle 尚未推广长度/edge 字段，补齐 oracle 与比较向量后，
  slow check/BPU 复验分别 1/1、5/5 PASS；未修改或放宽旧比较项。
- SSH 执行连接曾断流（本地 SSH exit 255），重新读取远端完整 `status.log` 与各项日志确认命令均 exit 0；
  这是传输状态，不记作 RTL PASS 或 FAIL。原日志保留。
- 本地仅编辑、打包与 `git diff --check`；硬件构建/仿真均在 Alan。
- Spike、ACT4、独立访存类 cocotb、formal、综合、时序/PPA、FPGA：**未运行**。
- 浮点 RVC、Zc*、S/U 与完整 ISA 一致性不在本级证据范围。L5/L6 已知问题沿用原报告。
- 原未跟踪的 BPU XML 与 `sim/o3/__pycache__/` 保留，未纳入提交。
