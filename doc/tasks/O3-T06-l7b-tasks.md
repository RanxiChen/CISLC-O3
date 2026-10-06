# O3-T06：L7b 分步任务书（T06a～T06b）

唯一实施依据：[L7b spec](../spec/l7b-rvc-spec.md)（V1～V8）；spec 未写到的行为沿用 [L7a spec](../spec/l7a-predictor-spec.md)（U1～U24）。
本文只规定分步顺序与每步测试范围，不新增任何行为。

## 共同规则（每一步都适用）

- spec 未覆盖或有歧义的行为：**停下提问**，不自行补设计；不改 spec 与 `doc/design/`。
- 只改 spec 第 0 节允许的文件；不跑 Spike、ACT4、访存类 cocotb；不综合。
- 测试在 Alan 上运行（`source /home/chen/miniforge3/bin/activate cislc-o3`，Verilator 5.050、cocotb 2.1.0），
  使用独立运行目录 `/home/chen/FUN/CISLC-O3-runs/<日期>-t06<x>-<sha>/`，不改 Alan 原开发树。
- 门禁（spec 第 8 节）：
  - 正确性项必须全部通过才能提交：本步列出的 cocotb、L7a 全部 cocotb、
    `make -C sim/o3 run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`、`run-l7-predict`
    （整核回归带 `SPIKE_ARGS=+L7_CHECK`，不带 `--spike`），以及 `scripts/lint.sh` 0 errors。
  - 正确性项修不好：不提交 RTL，停下报告失败用例与复现命令。
- **T06a、T06b 连续执行**：T06a 门禁通过、提交后直接进入 T06b，不等确认；
  只有正确性项修不好、或遇到 spec 未覆盖的行为时才停下。两步合写一份报告 `doc/tasks/O3-T06-report.md`。
- 精简流程：开发迭代时只重跑受影响的套件；提交前跑一次完整门禁即可。
  报告只需提交号、命令、exit code、用例数、日志目录、失败与修复记录、未做项；不需要 SHA256 清单。
- 提交信息：`feat(frontend|backend|system): ...`，可多次提交。

## T06a：类型、展开器、IALIGN=16（不改前端取指行为）

内容：
- 第 6 节类型改动中与前端行为无关的部分：`f0_inst_t.crosses_region` → `is_edge`（V5）、`fetch_entry_t.is_edge`、
  FTQ 项两位（先只加字段，写入在 T06b）、ROB 分配口 `t_alloc_inst_len_i`。
- 2.2 新增 `rvc_expander.sv`（加入 `rtl/rtl.f`），本步只做模块与单测，不接入 F0。
- 第 5 节全部：BRU 删除 bit1 异常；ROB `inst_len/succ_pc`；`backend.sv` 接线；CSR `MISA` 与 `mepc` 掩码。

测试：新增 `sim/cocotb/rvc_expander`；更新 `sim/cocotb/csr_file`（spec 第 8 节两项）；L7a 全部 cocotb；四个整核回归。
说明：本步前端仍只送 32 位指令（F0 未改），所以 IALIGN=32 程序的行为必须与 `cbe3372` 一致。

## T06b：F0/F1、预测器字段、FTQ、整核 RVC 程序

内容：
- 第 2 节 F0 全部（2.1 配置 `f0_slots=4`、2.3 半字索引、2.4 识别与输出、2.5 握手、2.6 异常含 D34、2.7 kill/截断/同步）。
- 第 3 节 F1 全部（3.1 推广、3.2 c′、3.3 锁存与 `trunc_o`）；`frontend.sv` 连线（第 6 节新端口）。
- 第 4 节全部（4.1 字段启用与出口 PC、4.2 训练来源、4.3 空区域回收）。
- 第 8 节整核程序 `sim/o3/tests/l7b_rvc.S` 与 Makefile 目标 `run-l7b-rvc`。

测试：spec 第 8 节 `ifu_f0`、`ifu_f1`、`bpu`/`ubtb` 用例；T06a 全部用例；L7a 全部 cocotb；
`run-l7b-rvc`（带 `SPIKE_ARGS=+L7_CHECK`）与四个整核回归。

---

## 交给 Codex 的提示（复制使用）

```
在 /home/chen/work/CISLC-O3（分支 feat/L1-closure，基线 cbe3372 + L7b spec 提交）实施 L7b RVC。

唯一依据：doc/spec/l7b-rvc-spec.md（已冻结，V1～V8）；未写到的行为沿用 doc/spec/l7a-predictor-spec.md。
分步与门禁：doc/tasks/O3-T06-l7b-tasks.md。先完整读这两份文件和 spec 第 1 节列出的源码位置再动手。

要求：
1. 按 T06a → T06b 顺序做，连续执行；每步门禁通过后提交，再进入下一步。
2. spec 没写或有歧义的行为：停下问我，不自己补设计；不改 doc/spec、doc/design。
3. 只改 spec 第 0 节允许的文件。RVC 展开器手工翻译 ~/flow-mem 提交 02e3f6fd 的
   design/src/main/scala/air/AirRvcDecompressor.scala，测试向量翻译同目录 test 下的 AirRvcDecompressorSpec.scala。
4. 测试在 Alan 的独立运行目录跑（任务书“共同规则”），不跑 Spike/ACT4，不综合。
5. 正确性门禁修不好就不提交 RTL，停下报告失败用例和复现命令。
6. 最后写 doc/tasks/O3-T06-report.md：提交号、每条命令与 exit code、用例数、日志目录、失败与修复记录、未做项。
   同时更新 doc/LOOP.md 中 L7b 一行和相关模块行的状态。
```
