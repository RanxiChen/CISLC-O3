# O3-T01：L3 收尾

按 [`agent.md`](../../agent.md) 第 7 节格式，加 v1 的两阶段流程（[`O3-v1-plan.md`](../O3-v1-plan.md) 第 2.3 节）。**阶段一只写文档，阶段二必须等用户宣布冻结后才开始。**

## 目标

完成 L3 收尾，为 L5 打基础：

1. **机器宽度改为 4（B42）**：`o3_cfg_pkg.sv` 中 `be.rename.width` 由 6 改为 4。注意 `o3_pkg.sv:33` 的 `BACKEND_MACHINE_WIDTH` 取自该值，正在运行的旧数据流（`uop_queue`、`rename_stage`、`load_queue` 等）宽度随之改变；所有现有门禁必须仍然通过。
2. **移除当前级不需要的空壳（B46）**：`backend.sv` 第 1626 行起的“目标结构”实例中，不属于 L3 的空壳移除实例化并移出 `rtl/rtl.f`，文件保留。逐个列出移除清单及其所属级（按 `O3-v1-plan.md` 第 3 节）。
3. **B12 缺口 1**：当前任何 `branch_resolution_i.valid`（包括预测正确）都阻止 Decode/rename/dispatch、读口授予与 ROB 退休（`backend.sv:639-641,724,906`）。改为：**预测正确的分支解析不停顿任何级**，只清除各结构中对应的 branch mask 位；误预测时按现有恢复合同（B12 15.2）取消年轻项。
4. **B12 缺口 2**：`alu_pipe.sv` 头注释（第 12–22 行）称已修复并由 `sim/cocotb/branch_recovery/` 覆盖，但 `backend.sv:33` 与 `LOOP.md` 仍列为缺口。核实是否已修复：若已修复，补一条明确复现“较老结果背压 + 年轻 RegRead + 误预测”的定向测试并更正文档；若未修复，按 B12 修复。
5. **分支密集的整核门禁**：新增 `sim/o3` 程序，包含连续的预测正确与预测错误分支、分支与 load/store 交织，退休轨迹与期望一致。

## 涉及模块

`rtl/common/o3_cfg_pkg.sv`、`rtl/backend/backend.sv`、`rtl/backend/prf_read_arbiter.sv`、`rtl/backend/alu_pipe.sv`、`rtl/backend/rob.sv`、`rtl/backend/rename_stage.sv`、`rtl/backend/uop_queue.sv`、`rtl/backend/backend_issue_queue.sv`、`rtl/backend/load_queue.sv`、`rtl/backend/store_queue.sv`、`rtl/backend/branch_checkpoint_file.sv`、`rtl/rtl.f`，以及对应 `sim/cocotb/` 与 `sim/o3/`。超出范围先问。

## 阶段一（只写文档）

产出 `doc/spec/l3-closure-spec.md`：

- **宽度变更影响清单**：所有使用 `BACKEND_MACHINE_WIDTH` 或 `rename.width` 的模块，逐个说明 6→4 后的行为与需要修改的地方（附文件:行号）。
- **空壳移除清单**：模块名、所属级、移除后需要 tie-off 的信号。
- **缺口 1 的新控制方程**：分支解析拍的每个停顿信号（issue、读口授予、rename、dispatch、ROB 退休）在“预测正确”“误预测”两种情况下的精确条件；branch mask 清位在 IQ、RegRead、Result、LSU、ROB、checkpoint 文件中各自的时机；同拍发生“分支解析 + 读口授予 + 写回 + 退休”时的结果。
- **缺口 2 的核实结论**：附代码位置与现有测试位置。
- **测试计划**：每条改动对应的 cocotb 定向/随机测试与整核门禁，以及必须保持通过的现有门禁列表（见 `LOOP.md` 第 1 节 L0～L4、L2、L3 行）。
- **未决问题**：设计基线没有覆盖、需要用户决定的点。不得自行决定。

阶段一不修改 `.sv`、`.py`、`Makefile`。

## 阶段二（spec 冻结后）

按冻结的 spec 实现；小步提交，每个提交 lint 通过。

## 闭环简化许可

本任务不实现 L5 及以后的机制（Spike 比对、CSR、异常、M 扩展等）。B02 两拍重命名按 B42 推迟。

## 验收

- `scripts/lint.sh` PASS。
- 改动涉及的每个模块的 cocotb 在 Alan 通过（含新增的缺口 1、缺口 2 定向测试，固定种子随机测试）。
- 现有门禁全部在 Alan 通过：`make -C sim/o3 build && make -C sim/o3 run-smoke`、`make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1 && make -C sim/o3 run-rv64i-instructions`、L3 行列出的全部命令。
- 新增分支密集整核门禁在 Alan 通过，报告周期数、退休数、误预测次数。报告缺口 1 修复前后同一程序的周期数对比。
- `doc/LOOP.md` 状态行、相关模块头注释按 `agent.md` 第 4 节更新；`backend.sv` 头注释中的缺口描述与事实一致。

## 不做

L5 及以后的任何机制；B02 拆分；预测器改动；新的访存机制。

## 回报

每个阶段结束写 `doc/tasks/O3-T01-report.md`：提交号与分支、实际运行的命令及结果（通过/失败/未运行）与日志位置、与 spec 的偏离（应为空）、未决问题。
