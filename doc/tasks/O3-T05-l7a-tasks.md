# O3-T05：L7a 分步任务书（T05a～T05d）

唯一实施依据：[L7a spec](../spec/l7a-predictor-spec.md)（U1～U24）。本文只规定分步顺序与每步测试范围（spec U15），
不新增任何行为；与此前对话中给出的 T05a 任务书冲突时以本文为准。

## 共同规则（每一步都适用）

- spec 未覆盖或有歧义的行为：**停下提问**，不自行补设计；不改 spec 与 `doc/design/`。
- 只改 spec 第 0 节允许的文件；不跑 Spike、ACT4、访存类 cocotb；不综合。
- 门禁（spec 9.3 / U14）：
  - 正确性项必须全部通过才能提交：本步列出的 cocotb、前序步骤已通过的 cocotb、
    `make -C sim/o3 run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`（不带 `--spike`），以及 `scripts/lint.sh` 0 errors。
  - 性能阈值（只在 T05d 出现）未达标：登记为已知问题后继续。
  - 正确性项修不好：不提交 RTL，停下报告失败用例与复现命令。
- 每步结束：提交（`feat(frontend|system): ...`，可多次提交），写 `doc/tasks/O3-T05<x>-report.md`
  （提交号、逐项命令与 exit code、日志目录 `/home/chen/FUN/CISLC-O3-runs/<日期>-t05<x>-<sha>/`、未做项），然后**停下等用户确认再进入下一步**。

## T05a：基础设施与选择性清除

内容：
- 2.1 配置改动；2.6 预留位（`cfi_is_rvc`、`edge`，恒 0）。
- 5 节的 `fe_age` / `fe_killed_by` 放入 `o3_types_pkg`。
- 6.2 选择性清除：`fetch_return_queue`（含 U7 kill 拍响应规则）、`fetch_buffer`；`frontend.sv` 把 FTQ `head_id_o` 接给两者。
- 2.4 的 uBTB 分配条件纠正（U18）。
- 6.3 的 `fe_perf_evt_e` 显式编号、删除 `PE_RAS_LOG_FULL`；`ras.sv` 删除 `PE_RECOVER_CYCLE` 增量（U13）。

测试：新增 `sim/cocotb/fetch_buffer`；扩展 `fetch_return_queue`；`ubtb` 增加 U18 用例；
重跑 `main_btb`、`tage`、`ras`、`branch_recovery`、`bpu`（现有用例）、`ifu_f0`、`ifu_f1`；三个整核回归。

## T05b：BPU 总装、慢核对、四路仲裁、FTQ

内容：
- 先完成 U24：预留位字段 `\edge` 全部改名为 `is_edge`（RTL 与测试）。
- 第 2 节 BPU 总装（2.2～2.5，含组合环约束）。
- 第 3 节 `bpu_slow_check`（含 U1、U17）。
- 第 5 节仲裁器四路（含 U13 接受拍计数）；`predecode_i` 在本步接 0，T05c 接通。
- 6.1 FTQ 全部四项（brief 带 `ras_ckpt`、`slow_next_pc`/`final_next_pc`、`winner_i`、提交口径事件、`PE_FTQ_FULL_CYCLE`）。
- 各模块 `perf_o` 按 spec 产生事件；本步不要求经 CSR 可读。

测试：改写 `sim/cocotb/bpu`；新增 `bpu_slow_check`、`redirect_arbiter`（模块级覆盖四路，包括 predecode 输入）；
T05a 全部用例；三个整核回归。

## T05c：F1 预解码修正

内容：第 4 节全部（4.2 a～f 与 U19、U22 判定细则，U8 `pred_taken`，U10/U20 异常，4.3 寄存式请求）；
把 `ifu_f1.predecode_o` 接到仲裁器。

测试：扩展 `sim/cocotb/ifu_f1`（spec 9.1 所列全部用例）；T05a、T05b 全部用例；三个整核回归。

## T05d：HPM 计数器与完整验收

内容：6.3 全部（新增 `hpm_counters.sv`、`mcycle`/`minstret` 迁入、CSR 地址与行为、U11、U21；
`frontend` 汇总 `fe_perf_o` → `o3_core` → `backend` → `csr_file`；删除 `frontend_perf_events` 实例化与 `rtl.f` 条目）；
9.2 整核程序 `l7_predict.S` 与 `run-l7-predict`（两组运行、U16/U23 采样与差值口径）。

测试：spec 9.1、9.2 完整验收（含 `hpm_counters`、`csr_file`）；三个整核回归。
报告附 9.2 计数器差值表（注明组别）与性能阈值结果。
