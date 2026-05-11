# Branch Mispredict Flush 分任务提示词文档

本文档用于把 `docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md` 拆成可顺序执行的独立 agent 任务。每个任务目标控制在单个 agent 约 30-60 分钟内完成，且默认前一个任务合入后再开始后一个任务。

## 全局执行约束

1. 开始前先读 `agent.md`、`doc/CISLC_O3_frontend.md`、`doc/CISLC_O3.md`，严格遵守仓库里的"修改前先说明方案、等待批准再改代码"的规则。
2. 每个 agent 在真正编辑前，先用简短中文回复本次要改哪些文件、为什么改、影响哪些接口和文档，再等待批准。
3. 严格限制范围，只实现计划里定义的短期能力：仅支持"前端预测 not-taken，后端条件分支实际 taken，触发 redirect"。
4. 不要顺手做完整 rollback、rename checkpoint restore、commit-time recovery、异常恢复、分支预测器升级等计划外内容。
4a. 当前计划已经明确要求最小 branch checkpoint recovery，因此允许且要求实现：
`rename_map_table` checkpoint restore、`free_list` checkpoint restore、`rob.sv` younger squash；但不要把范围扩展成通用异常恢复框架。
5. 修改 RTL 时保持现有命名风格、注释风格和模块职责边界；接口或周期行为变化必须同步更新对应文档。
6. 不得破坏现有 `sim/frontend/tests/frontend_basic.cpp` 对应回归，也不得破坏 `sim/core_single_inst` smoke test。
6a. 不得破坏现有 `sim/core_three_alu/tests/three_alu_branch.cpp` 所覆盖的 branch retire metadata 语义；新 recovery 路径落地后，它也是必跑回归之一。
7. 除非任务明确要求，不要修改现有 `frontend_basic` 和 `core_single_inst` 的测试语义；新增验证优先放到新测试里。
8. 如果实际代码结构与计划不完全一致，优先做"最小闭环"的等价实现；若需要扩大范围，先停下来说明。

## 推荐顺序

1. Task 1: 冻结 redirect 契约与文档边界
2. Task 2: BPU 支持 redirect reseed
3. Task 3A: FTQ redirect repair 接口
4. Task 3B: FTQ entry repair
5. Task 3C: FTQ pointer/count rewind
6. Task 3D: FTQ redirect 文档收口
7. Task 4: IFU 和 fetch buffer flush
8. Task 5: backend 同拍恢复 + redirect 打通
9. Task 6: 新增定向 redirect 验证，并完成固定回归与文档收口

---

## Task 1 提示词：冻结 Redirect 契约与文档边界

目标：先把短期 redirect 契约、字段定义、职责归属和限制写清楚；如有必要，在 `rtl/common/o3_pkg.sv` 定义共享 redirect payload 类型，但不要提前接入完整功能逻辑。

依赖：无。

需要修改的文件：`doc/CISLC_O3_frontend.md`、`doc/CISLC_O3.md`、`rtl/common/o3_pkg.sv`（仅当你确认共享类型确实能减少后续接口歧义时才改）。

具体修改内容：
1. 明确第一版 redirect packet 的字段，至少包含 `valid`、`ftq_idx`、`branch_pc`、`redirect_pc`、`actual_taken`，可选 `fallthrough_pc`。
2. 明确 ownership：backend 负责发现 mispredict，`o3_core` 负责转发，frontend 负责消费，FTQ 负责修复 block/window，BPU 负责从 redirect PC 重新开始预测。
3. 在前后端文档里明确这版只支持"conditional branch + pred not-taken + actual taken"。
4. 如果改 `o3_pkg.sv`，只新增最小共享类型或字段定义，不做行为改动，不提前侵入各模块。
5. 更新模块/文档描述时，明确"错误路径立即失效"和"提交后释放容量"是两件事，不要混淆。

验收标准：
1. 后续 agent 不需要再猜 redirect 包里应该有哪些字段。
2. `doc/CISLC_O3_frontend.md` 和 `doc/CISLC_O3.md` 都清楚说明当前支持范围和后续未实现项。
3. 如果引入了共享类型，命名清晰、字段最小、不会误导人以为已经支持完整恢复路径。
4. 本任务不引入接口编译错误，不影响现有测试入口。

注意事项：
1. 不要在这一任务里顺手修改 BPU、FTQ、IFU、backend 逻辑。
2. 如果你认为共享类型没必要，可以只更新文档，不强行改 `o3_pkg.sv`。
3. 文档用语要精准，避免写成"完整 flush/recovery 已实现"。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 1，不要顺手做 Task 2 及之后的实现。

开始前先读：
1. agent.md
2. doc/CISLC_O3_frontend.md
3. doc/CISLC_O3.md

工作范围：
- 目标是冻结第一版 branch redirect 契约与职责边界。
- 只允许修改：
  - doc/CISLC_O3_frontend.md
  - doc/CISLC_O3.md
  - rtl/common/o3_pkg.sv（仅当你确认共享 redirect 类型确实必要时）

你必须完成的内容：
1. 在文档中明确第一版 redirect packet 的字段，至少包含：
   - valid
   - ftq_idx
   - branch_pc
   - redirect_pc
   - actual_taken
   - 可选 fallthrough_pc
2. 在文档中明确 ownership：
   - backend 发现 mispredict
   - o3_core 转发 redirect
   - frontend 消费 redirect
   - FTQ 修复 block/window
   - BPU 从 redirect PC 重新开始
3. 明确这版只支持：
   - conditional branch
   - frontend pred not-taken
   - backend actual taken -> mispredict
4. 如果改 rtl/common/o3_pkg.sv，只新增最小共享类型或字段定义，不做行为逻辑修改。
5. 明确“错误路径立即失效”和“提交后释放容量”不是一回事。

硬约束：
- 不要修改 BPU、FTQ、IFU、backend 的行为逻辑。
- 不要把文档写成“完整 recovery 已实现”。
- 不要引入接口编译错误。

完成后请汇报：
1. 改了哪些文件
2. redirect 契约最终字段是什么
3. 是否新增了共享类型；如果新增，为什么有必要
4. 没有跑哪些测试
```

---

## Task 2 提示词：让 BPU 支持 Redirect Reseed

目标：给 `rtl/frontend/bpu.sv` 增加最小 redirect reseed 能力，使 BPU 在收到 redirect 时从 `redirect_pc` 重新开始生成后续 block，而不是继续走顺序 PC。

依赖：Task 1 已完成，redirect 字段定义已经固定。

需要修改的文件：`rtl/frontend/bpu.sv`、`doc/CISLC_O3_frontend.md`。

具体修改内容：
1. 给 BPU 增加 redirect 输入，概念上至少有 `redirect_valid_i` 和 `redirect_pc_i`。
2. 调整 BPU 内部时序优先级：`reset` 最高后，`redirect` 优先于普通 `enqueue fire` 自增。
3. 在 redirect 周期，`pred_pc_q` 必须被重置到 `redirect_pc_i`，不能继续顺序加 `FTQ_BLOCK_BYTES`。
4. 保持 BPU 职责最小化，BPU 只负责"未来从哪里开始预测"，不要让它回写旧 FTQ entry。
5. 更新 BPU 模块头注释和前端文档，说明 redirect 会覆盖顺序生成流。

验收标准：
1. BPU 在 redirect 到来时能明确切换到新起点。
2. 没有把 FTQ repair 逻辑塞进 BPU。
3. 文档已说明 redirect 覆盖顺序推进的优先级。
4. 编译接口与后续 frontend 顶层接线保持清晰，不制造额外耦合。

注意事项：
1. 不要在本任务里改 FTQ repair、IFU flush 或 backend 逻辑。
2. 如果当前 BPU 没有独立状态机，只做最小寄存器更新改动，不重构整体结构。
3. 注释要写清"为什么 redirect 要高优先级"。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 2。

开始前先读：
1. agent.md
2. doc/CISLC_O3_frontend.md
3. doc/CISLC_O3.md
4. rtl/frontend/bpu.sv

工作范围：
- 只允许修改：
  - rtl/frontend/bpu.sv
  - doc/CISLC_O3_frontend.md

目标：
- 给 BPU 增加最小 redirect reseed 能力。
- redirect 到来时，BPU 必须从 redirect_pc 重新开始，不再继续顺序 pred_pc + FTQ_BLOCK_BYTES。

你必须完成的内容：
1. 给 BPU 增加 redirect 输入，概念上至少有：
   - redirect_valid_i
   - redirect_pc_i
2. 调整时序优先级：
   - reset 最高
   - redirect 次高
   - normal enqueue fire 最后
3. redirect 周期必须把 pred_pc_q 装载为 redirect_pc_i。
4. 不要让 BPU 回写或修复旧 FTQ entry。
5. 更新模块注释和前端文档，写清 redirect 为什么覆盖顺序推进。

硬约束：
- 不要改 FTQ repair。
- 不要改 IFU flush。
- 不要改 backend。
- 优先做最小寄存器更新，不重构整体结构。

完成后请汇报：
1. 改了哪些文件
2. BPU 新接口是什么
3. pred_pc_q 的新优先级规则是什么
4. 没有跑哪些测试
```

---

## Task 3A 提示词：给 FTQ 增加 Redirect Repair 接口

目标：先把 `rtl/frontend/ftq.sv` 的 redirect repair 输入和本地优先级框架接上，为后续 entry 修复和指针调整留出清晰边界；本任务不直接实现完整 wrong-path 修复。

依赖：Task 1、Task 2 已完成。

需要修改的文件：`rtl/frontend/ftq.sv`。

具体修改内容：
1. 给 FTQ 增加 redirect repair 输入，字段至少覆盖 `valid`、`ftq_idx`、`branch_pc`、`redirect_pc`、`actual_taken`。
2. 在 FTQ 内部明确 redirect repair 相对正常 enqueue / consume 的优先级，保证后续实现不会把 redirect 当成普通数据面更新。
3. 保持接口最小，只服务 frontend block history repair，不要顺手引入 backend-specific 恢复策略。

验收标准：
1. FTQ 有清晰的 redirect repair 输入边界。
2. 后续 agent 不需要再猜 redirect 在 FTQ 里应该以什么优先级生效。
3. 本任务不引入多余耦合，也不提前实现完整 entry repair。

注意事项：
1. 不要在这一任务里实现 younger invalidation、branch entry 修复或 pointer rewind。
2. 不要为了"更优雅"大改 FTQ 结构；优先最小、安全、可验证。
3. 不要改文档，文档收口放到 Task 3D。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 3A。

开始前先读：
1. agent.md
2. doc/CISLC_O3_frontend.md
3. doc/ftq.md
4. rtl/frontend/ftq.sv

工作范围：
- 只允许修改：
  - rtl/frontend/ftq.sv
目标：
- 只给 FTQ 接上 redirect repair 输入和本地优先级框架。
- 不要在这一任务里直接实现完整 wrong-path 修复。

你必须完成的内容：
1. 增加 redirect repair 输入，字段至少覆盖：
   - valid
   - ftq_idx
   - branch_pc
   - redirect_pc
   - actual_taken
2. 明确 redirect repair 相对正常 enqueue / consume 的优先级。
3. 保持接口最小，不要引入 backend-specific 恢复策略。

硬约束：
- 不要实现 younger invalidation。
- 不要实现 branch entry 修复。
- 不要实现 pointer rewind。
- 不要大改 FTQ 结构。
- 不要改文档。

完成后请汇报：
1. 改了哪些文件
2. FTQ 新增的 redirect 接口是什么
3. redirect repair 在 FTQ 内部的优先级是什么
4. 没有跑哪些测试
```

---

## Task 3B 提示词：修复 FTQ Entries 的 Wrong-Path 语义

目标：只实现 `rtl/frontend/ftq.sv` 内部的 FTQ entry 级 wrong-path 修复逻辑，让 redirect 到来后，branch 所在 entry 被截断并改写为真实跳转结果，同时让所有 younger wrong-path entries 立即失效；本任务不处理 tail/head/count 回绕策略。

依赖：Task 1、Task 2、Task 3A 已完成。可从 `git log` 确认：
- `64eb528` `docs: define branch redirect contract`
- `efccb00` `feat: add bpu redirect reseed`
- `2c00e9c` `feat: add ftq redirect repair interface (Task 3A)`
- `318c5bf` `fix: properly connect FTQ redirect ports and suppress signals`

需要修改的文件：`rtl/frontend/ftq.sv`。

具体修改内容：
1. 在已有 redirect repair 框架上，真正实现 younger-entry invalidation。
2. younger 的判定必须基于当前 FTQ 已分配窗口语义，正确处理环形队列，不要偷懒用简单的数值大小比较替代 age 判断。
3. 对 branch 所在 entry 执行 repair：
   - `end_pc = branch_pc + 4`
   - `next_pc = redirect_pc`
   - 如有必要，为了保持 entry 自洽，同步修正 `pred_taken`、`target_pc`、`fallthrough_pc` 等字段
4. older entries 必须保持不变。
5. 本任务只做 entry 内容与 valid 语义修复，不修改 `alloc_tail_q`、`ifu_head_q`、`release_head_q`、`allocated_count_q` 的策略；这些留给 Task 3C。
6. 保持 Task 3A 已建立的本地优先级语义：redirect 仍然是最高优先级 correctness event。

验收标准：
1. redirect 后，branch 之后的 wrong-path entries 至少 `entry.valid=0`，不会继续对 IFU 可见。
2. branch entry 被正确截断到 `branch_pc + 4`，并把 `next_pc` 指向 `redirect_pc`。
3. older entries 内容与可见性保持不变。
4. 代码读者可以直接看懂：
   - 哪些 entry 算 younger
   - branch entry 怎么 repair
   - 哪些指针/容量问题明确故意留给 Task 3C
5. 不引入 tail/head/count 行为变化，不偷做 Task 3C。

注意事项：
1. 只允许修改 `rtl/frontend/ftq.sv`。
2. 不要改文档，文档收口放到 Task 3D。
3. 不要实现 backend commit/release 语义。
4. 不要把范围扩大成"redirect 后 FTQ 完整恢复"；这里只修 wrong-path entry 语义。
5. 如果当前代码结构需要辅助函数来判断环形窗口中的 younger/older，可以加最小必要的本地 helper，但不要大改 FTQ 架构。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 3B，不要顺手做 Task 3C 及之后的内容。

开始前先读：
1. agent.md
2. doc/CISLC_O3_frontend.md
3. doc/ftq.md
4. rtl/frontend/ftq.sv

额外上下文：
- Task 1 / 2 / 3A 已完成。
- git log 中可见这些提交：
  - 64eb528 docs: define branch redirect contract
  - efccb00 feat: add bpu redirect reseed
  - 2c00e9c feat: add ftq redirect repair interface (Task 3A)
  - 318c5bf fix: properly connect FTQ redirect ports and suppress signals
- 当前 ftq.sv 已经有 redirect repair 输入、redirect 最高优先级框架，以及 Task 3B/3C 的 TODO 占位。
- 当前任务只补上 entry 级 wrong-path 修复，不处理 tail/head/count 回绕策略。

工作范围：
- 只允许修改：
  - rtl/frontend/ftq.sv

目标：
- 只实现 FTQ entries 的 wrong-path 语义修复：
  - older entries 保留
  - branch entry repair
  - younger entries invalidation
- 不要在这一任务里处理 alloc_tail_q / ifu_head_q / release_head_q / allocated_count_q 的策略。

你必须完成的内容：
1. 在 redirect_valid_i 生效时，实现 younger-entry invalidation：
   - 对 branch 所在 FTQ entry 之后、属于当前已分配窗口中的 younger wrong-path entries 做失效处理
   - 至少要清掉这些 entry 的 entry.valid
   - younger 判定必须正确考虑 FTQ 是环形队列，不能偷懒假设 index 数值大就一定更年轻
2. 修复 branch 所在 entry（redirect_ftq_idx_i）：
   - end_pc = redirect_branch_pc_i + 4
   - next_pc = redirect_redirect_pc_i
   - 如有必要，为了保持 entry 自洽，可同步修正：
     - pred_taken
     - target_pc
     - fallthrough_pc
   - 但不要把它扩展成新的预测协议
3. older entries 必须保持不变：
   - 不要修改 branch 之前的有效历史 entry
4. 保持 redirect 作为最高优先级 correctness event 的语义，不要破坏 Task 3A 已建立的优先级框架。

硬约束：
- 不要修改 alloc_tail_q / ifu_head_q / release_head_q / allocated_count_q 的策略。
- 不要实现 pointer rewind。
- 不要实现 backend commit/release 语义。
- 不要改文档。
- 不要大改 FTQ 结构；如确实需要，请只增加最小必要的本地 helper/function 来表达环形 younger/older 判断。

你完成后，结果应该满足：
1. redirect 后，wrong-path younger entries 不再对 IFU 可见。
2. branch entry 被截断为 branch_pc + 4，并把 next_pc 指到 redirect_pc。
3. older entries 完全不受影响。
4. 代码中能清楚看出：
   - younger 是如何判定的
   - branch entry 是如何 repair 的
   - 哪些状态明确留给 Task 3C 处理

完成后请汇报：
1. 改了哪些文件
2. younger / branch / older entries 分别怎么处理
3. 你如何处理环形队列下的 younger 判定
4. 哪些 tail/head/count 问题明确留给 Task 3C
5. 没有跑哪些测试
```

---

## Task 3C 提示词：安全回绕 FTQ Window 状态

目标：单独处理 redirect 后 FTQ 的 `alloc_tail_q`、`ifu_head_q`、`allocated_count_q` 策略，避免 stale-full、deadlock 或覆盖 older history。

依赖：Task 3B 已完成。

需要修改的文件：`rtl/frontend/ftq.sv`、`doc/ftq.md`、`doc/CISLC_O3_frontend.md`。

具体修改内容：
1. 选择并实现最小安全的指针策略。优先推荐让未来分配从 branch entry 之后重新覆盖错误路径窗口，并避免 FTQ stale-full 或 deadlock。
2. 如有必要，调整 `alloc_tail_q`、`ifu_head_q`、`allocated_count_q`，并把周期语义写清楚。
3. 明确区分"wrong-path 立即失效"和"release_head_q 负责未来容量回收"，不要把两者混成一个机制。

验收标准：
1. FTQ 不会因为 redirect 后 tail/count 处理错误而卡死或永远满。
2. older history 仍然保留，未来分配可以重新覆盖错误路径窗口。
3. 文档明确说明 invalidation 与 release 是两条语义不同的路径。

注意事项：
1. 不要大改 FTQ 结构；优先最小、安全、可验证。
2. 如果改 `allocated_count_q`，必须解释调整原因和周期语义。
3. 不要把这一步扩大成 commit/release 真正实现。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 3C。

开始前先读：
1. agent.md
2. doc/CISLC_O3_frontend.md
3. doc/ftq.md
4. rtl/frontend/ftq.sv

工作范围：
- 只允许修改：
  - rtl/frontend/ftq.sv
  - doc/ftq.md
  - doc/CISLC_O3_frontend.md

目标：
- 单独处理 redirect 后 FTQ 的 tail/head/count 策略，避免 stale-full 或 deadlock。

你必须完成的内容：
1. 选择并实现最小安全指针策略。
2. 如有必要，调整：
   - alloc_tail_q
   - ifu_head_q
   - allocated_count_q
3. 在文档中明确：
   - wrong-path invalidation
   - release_head_q 未来容量回收
   这两者不是同一件事。

硬约束：
- 不要实现 commit/release 真正功能。
- 不要大改 FTQ 结构。
- 如果改 allocated_count_q，必须解释周期语义。

完成后请汇报：
1. 改了哪些文件
2. 你选的指针策略是什么
3. allocated_count_q 的新语义是什么
4. 没有跑哪些测试
```

---

## Task 3D 提示词：收口 FTQ Redirect 文档语义

目标：把 FTQ redirect repair 的最终短期语义收口到文档里，确保后续恢复上下文时不需要反推 RTL。

依赖：Task 3C 已完成。

需要修改的文件：`doc/ftq.md`、`doc/CISLC_O3_frontend.md`。

具体修改内容：
1. 更新 redirect 输入字段说明。
2. 写清 branch entry repair、younger invalidation、pointer/count 策略。
3. 明确区分 invalidation 和 future release。
4. 明确当前仍未实现的范围，避免文档超卖。

验收标准：
1. 后续 agent 只看文档就能理解 FTQ redirect repair 的边界。
2. 文档不声称已经实现 commit-time release、通用恢复或 backend-driven FTQ walkback。
3. 文档与当前 RTL 行为一致。

注意事项：
1. 这一步只做文档收口，不再改 RTL。
2. 文档要写得能支持 resume，不要留模糊措辞。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 3D。

开始前先读：
1. agent.md
2. doc/CISLC_O3_frontend.md
3. doc/ftq.md
4. docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md

工作范围：
- 只允许修改：
  - doc/ftq.md
  - doc/CISLC_O3_frontend.md

目标：
- 收口 FTQ redirect repair 的文档语义，让后续 agent 可以直接恢复上下文。

你必须完成的内容：
1. 更新 redirect 输入字段说明。
2. 写清：
   - branch entry repair
   - younger invalidation
   - pointer/count 策略
3. 明确 invalidation 和 future release 不是同一件事。
4. 明确当前仍未实现的范围，避免文档超卖。

硬约束：
- 不要改 RTL。
- 不要把文档写成“完整 recovery 已实现”。

完成后请汇报：
1. 改了哪些文件
2. 文档中如何描述 branch/younger/older 规则
3. 文档中如何区分 invalidation 和 release
4. 没有跑哪些测试
```

---

## Task 4 提示词：精确 Flush IFU 与 Fetch Buffer

目标：让 frontend 在收到 redirect 时清掉瞬态错误路径取指状态，包括 IFU 内部在途状态和 fetch buffer 已排队的 wrong-path 指令，但不清 ICache 内容。

依赖：Task 1、Task 2、Task 3A-3D 已完成。

需要修改的文件：`rtl/frontend/ifu.sv`、`rtl/frontend/fetch_buffer.sv`、`rtl/frontend/frontend.sv`、`doc/CISLC_O3_frontend.md`。

具体修改内容：
1. 在 `ifu.sv` 增加 redirect flush 处理，至少清掉 `current_block_q`、`block_valid_q`、S1 valid、S2 slot valid/data-valid 等会把旧路径数据继续推出去的状态。
2. 确保 redirect 后旧 ICache 返回不会继续变成 fetch output。第一版允许用"清空所有在途上下文"的保守方案实现。
3. 复用或扩展 `fetch_buffer.sv` 的 flush 能力，让 frontend 能在 redirect 时清空已入队的 wrong-path entries。
4. 在 `frontend.sv` 内部把 redirect 分发给 BPU、FTQ、IFU、fetch buffer flush 路径，但先只做 frontend 内部分发，不要求在本任务里把 backend 真正接进来。
5. 更新前端文档，明确 redirect 只 flush 控制状态，不 flush ICache array/refill state。

验收标准：
1. redirect 后 IFU 不会继续吐出旧路径 block 或旧路径指令。
2. fetch buffer 中旧路径条目会被清掉。
3. 文档明确写出"保留 ICache 内容，只清控制状态"的策略。
4. frontend 内部 redirect 接口清晰，便于下一任务从 core/backend 接入。

注意事项：
1. 不要在这一任务里生成 backend redirect。
2. 不要修改 ICache 的数据数组或 refill 正确性策略，除非发现没有清 S2 就无法阻断旧返回。
3. 如果 flush 会影响 `frontend_basic` 的原有行为，必须解释原因并确保默认无 redirect 时行为不变。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 4。

开始前先读：
1. agent.md
2. doc/CISLC_O3_frontend.md
3. rtl/frontend/ifu.sv
4. rtl/frontend/fetch_buffer.sv
5. rtl/frontend/frontend.sv

工作范围：
- 只允许修改：
  - rtl/frontend/ifu.sv
  - rtl/frontend/fetch_buffer.sv
  - rtl/frontend/frontend.sv
  - doc/CISLC_O3_frontend.md

目标：
- redirect 到来时清掉 IFU 和 fetch buffer 中的 wrong-path 瞬态状态。
- 保留 ICache 数据内容，不做 cache array flush。

你必须完成的内容：
1. 在 IFU 中清掉至少这些状态：
   - current_block_q
   - block_valid_q
   - S1 valid
   - S2 slot valid/data-valid
2. 确保 redirect 后旧 ICache 返回不会再变成 fetch output。
3. 利用或扩展 fetch_buffer 的 flush 能力，清掉已入队的 wrong-path entries。
4. 在 frontend.sv 内部分发 redirect 给：
   - BPU
   - FTQ
   - IFU
   - fetch_buffer flush
5. 更新文档，明确 redirect 只 flush 控制状态，不 flush ICache arrays/refill state。

硬约束：
- 不要生成 backend redirect。
- 不要改 ICache 数据数组。
- 无 redirect 时默认行为必须保持不变。

完成后请汇报：
1. 改了哪些文件
2. IFU 清了哪些状态
3. fetch_buffer 如何被 flush
4. 没有跑哪些测试
```

---

## Task 5 提示词：实现 Backend 同拍恢复并打通 Redirect 到 Frontend

目标：让 backend 在条件分支实际 taken 且前端预测 not-taken 时，在**同一个 mispredict 周期**完成最小 backend younger squash、恢复 rename/free-list checkpoint 状态，并生成 redirect 事件通过 `backend.sv`、`o3_core.sv` 接到 `frontend.sv`。

依赖：Task 1、Task 4 已完成。Task 2、Task 3A-3D 已完成可减少联调风险。

需要修改的文件：`rtl/common/o3_pkg.sv`、`rtl/backend/branch_execute_unit.sv`、`rtl/backend/backend.sv`、`rtl/backend/free_list.sv`、`rtl/backend/rename_map_table.sv`、`rtl/backend/rob.sv`、`rtl/core/o3_core.sv`、`rtl/frontend/frontend.sv`（只做顶层接口接入，如 Task 4 已预留则只补接线）、`doc/CISLC_O3.md`、`doc/CISLC_O3_frontend.md`。

具体修改内容：
1. 确认 branch 执行路径一路保留了最小必要恢复元数据；至少要能在 branch resolve 时拿到：
   - `ftq_idx`
   - `rob_idx`
   - `branch_pc`
   如果当前路径里缺字段，优先在 `rtl/common/o3_pkg.sv` 的 branch 相关 uop/pipe 结构中补齐。
2. 在 `backend.sv` 顶层实现固定容量 checkpoint table：
   - 容量固定为 4
   - 分配策略是“第一个空闲槽”
   - 每个 rename group 最多只允许一条 branch 分配新 checkpoint
   - 若同拍多于一条 branch，阻塞整组 rename，并加仿真断言
   - 若 checkpoint table 满，阻塞整组 rename
3. checkpoint 必须保存：
   - `branch_rob_idx`
   - `branch_pc`
   - rename map snapshot
   - free list `head/tail/count`
   同时在 backend 顶层维护：
   - `rob_has_checkpoint[rob_idx]`
   - `rob_checkpoint_id[rob_idx]`
4. `rename_map_table.sv` 增加直接恢复端口，支持 mispredict 同拍整表装载 checkpoint，不做逐项回滚。
5. `free_list.sv` 改成显式 `head_q/tail_q/count_q` 状态，并增加直接恢复端口；mispredict 同拍应当：
   - 先装载 checkpoint 的 `head/tail/count`
   - 再把 backend 顶层筛出来的 **older-than-branch** `rob_retire_*` release 追加进去
   - 丢弃 younger release
   - 禁止该拍普通 alloc 生效
6. `rob.sv` 不做 checkpoint restore，只做 younger squash。给它增加直接接口，语义是：
   - 保留 older-than-branch
   - 保留 branch 自己
   - invalidate younger-than-branch
   - 清掉 younger completion / retire-info sideband
7. 对 backend 其余状态，尽量不扩散子模块接口，而是在 `backend.sv` 顶层完成 same-cycle kill：
   - fetch-entry staging
   - decode / uop queue
   - integer issue queue
   - branch issue queue
   - integer pipeline registers
   - branch pipeline registers
   对这些状态优先采用 kill valid / suppress side effects，而不是新增一圈子模块 squash 端口。
8. mispredict 同拍的优先级必须明确：
   - older writeback / complete / retire 可以保留
   - branch 自己保留
   - younger writeback / complete / retire 必须同拍丢弃
9. 实现统一的 ROB 环形年龄判断 helper，并在以下路径复用：
   - `rob.sv` younger invalidate
   - checkpoint younger release
   - writeback/complete/retire younger kill
   - 任何顶层 side-effect 过滤
10. 在 backend 生成单一 redirect 事件，字段必须与 Task 1 契约一致；通过 `o3_core.sv` 接到 `frontend.sv`。
11. 更新前后端文档，明确：
   - 这是最小 branch checkpoint recovery
   - recovery 为 same-cycle
   - `rename_map_table` / `free_list` / `rob.sv` 的职责边界
   - 当前仍只支持 `pred not-taken / actual taken` 条件分支 redirect

验收标准：
1. backend 能在目标 branch 情况下输出 redirect。
2. backend 在 mispredict 同拍完成最小恢复：younger side effects 被杀掉，rename/free-list 恢复，ROB younger entries 被清。
3. `o3_core.sv` 已把 redirect 从 backend 连到 frontend。
4. 文档准确描述当前恢复边界与限制，不夸大成完整通用 rollback。
5. 默认单指令 smoke 和前端基本回归不因接口破坏而挂掉。

注意事项：
1. `rob.sv` 做的是 younger squash，不是 checkpoint restore；不要把 `rename_map/free_list` 的恢复语义塞进 ROB。
2. `rename_map_table.sv` 和 `free_list.sv` 可以新增 direct recover 接口；其余 backend 状态优先在顶层处理。
3. older release 必须来自现有 `rob_retire_*` 顶层筛选，不要发明另一套 release 来源。
4. 如果 `retire_info_o` 已有 branch 字段，优先复用已有信息来源和命名习惯。
5. 若发现 `frontend.sv` 已在 Task 4 预留端口，优先补接线，不要重复改内部逻辑。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 5。

开始前先读：
1. agent.md
2. doc/CISLC_O3.md
3. doc/CISLC_O3_frontend.md
4. rtl/backend/backend.sv
5. rtl/backend/free_list.sv
6. rtl/backend/rename_map_table.sv
7. rtl/backend/rob.sv
8. rtl/backend/branch_execute_unit.sv
9. rtl/core/o3_core.sv

目标：
- 在同一个 mispredict 周期完成最小 backend recovery：
  - younger side effects 被杀掉
  - rename_map_table 恢复 checkpoint
  - free_list 恢复 checkpoint
  - rob younger entries 被 squash
  - redirect 被送到 frontend

允许修改：
- rtl/common/o3_pkg.sv
- rtl/backend/branch_execute_unit.sv
- rtl/backend/backend.sv
- rtl/backend/free_list.sv
- rtl/backend/rename_map_table.sv
- rtl/backend/rob.sv
- rtl/core/o3_core.sv
- rtl/frontend/frontend.sv
- doc/CISLC_O3.md
- doc/CISLC_O3_frontend.md

你必须完成的内容：
1. 补齐 branch execute 路径的最小恢复元数据，至少保证 resolve 时拿得到：
   - ftq_idx
   - rob_idx
   - branch_pc
2. 在 backend.sv 顶层实现 checkpoint table：
   - 固定容量 4
   - 取第一个空闲槽分配
   - 每个 rename group 最多 1 条 branch checkpoint
   - 同拍多 branch -> 阻塞整组 rename 并加断言
   - table 满 -> 阻塞整组 rename
3. checkpoint 内容至少保存：
   - branch_rob_idx
   - branch_pc
   - rename map snapshot
   - free list head/tail/count
4. backend 顶层维护：
   - rob_has_checkpoint[rob_idx]
   - rob_checkpoint_id[rob_idx]
5. 给 rename_map_table.sv 增加 direct recover port，支持 mispredict 同拍整表装载 checkpoint。
6. 把 free_list.sv 改成显式 head_q/tail_q/count_q，并增加 recover 端口。恢复拍必须：
   - 先装载 checkpoint 的 head/tail/count
   - 再并入 backend 顶层按年龄筛出的 older rob_retire releases
   - 丢弃 younger release
   - 禁止普通 alloc 生效
7. 给 rob.sv 增加 younger squash 接口：
   - 保留 older-than-branch
   - 保留 branch 自己
   - invalidate younger-than-branch
   - 清掉 younger completion / retire-info sideband
   注意：ROB 不做 checkpoint restore。
8. 其余 backend 状态优先在 backend.sv 顶层完成 same-cycle kill，不要大面积扩 child-module 接口：
   - fetch-entry staging
   - decode/uop queue
   - integer issue queue
   - branch issue queue
   - integer pipeline registers
   - branch pipeline registers
9. mispredict 同拍优先级必须明确：
   - older writeback/complete/retire 保留
   - branch 自己保留
   - younger writeback/complete/retire 丢弃
10. 实现统一的 ROB 环形年龄 helper，复用到：
   - rob younger invalidate
   - checkpoint younger release
   - writeback/complete/retire younger kill
   - 顶层 side-effect 过滤
11. 生成单一 redirect 事件并通过 o3_core.sv 接到 frontend.sv。
12. 更新文档，明确：
   - same-cycle recovery
   - rename_map_table / free_list / rob.sv 各自职责
   - 当前只支持 pred not-taken / actual taken 条件分支

硬约束：
- 不要做通用异常恢复框架。
- 不要把 rename_map/free_list 的恢复塞进 ROB。
- older release 只能来自现有 rob_retire_* 顶层筛选。
- 其余 backend 状态优先顶层 kill valid / suppress side effects。

完成后请汇报：
1. 改了哪些文件
2. 新增了哪些接口
3. mispredict 同拍的优先级规则最终是什么
4. 跑了哪些测试，哪些没跑
5. 是否影响后续验证提示词
```

---

## Task 6 提示词：新增 Directed Redirect 验证

目标：新增 core 级 redirect 定向测试，证明 wrong-path 指令不会退休，redirect target 指令会退休，并检查 branch retire 元数据正确；随后跑固定回归并同步收口文档。

依赖：Task 5 已完成。可从 `git log` 确认最近相关提交至少包含：
- `49ede9b` `finish task 5`
- `a1779ee` `task 5`

需要修改的文件：优先新增 `sim/core_three_alu/tests/three_alu_redirect.cpp`（如你确认复用现有文件更合适，也可改 `sim/core_three_alu/tests/three_alu_branch.cpp`，但不要破坏现有 branch metadata 回归的职责）、`doc/CISLC_O3.md`、`doc/CISLC_O3_frontend.md`、`docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md`。

具体修改内容：
1. 按计划中的固定指令布局实现一个 directed program：
   `0x00: addi x1, x0, 1`
   `0x04: addi x2, x0, 1`
   `0x08: add  x3, x1, x2`
   `0x0c: bne  x3, x2, +16`
   `0x10: ori  x4, x0, 9`
   `0x14: xori x5, x0, 6`
   `0x18: addi x6, x0, 7`
   `0x1c: addi x7, x0, 11`
   `0x20: add  x8, x7, x1`
2. 复用现有 `sim/core_three_alu` 的直接 `Vo3_core` 仿真和 refill-driver 风格，不要新造另一套 test harness，也不要改 `sim/core_three_alu/Makefile` 的基本用法；该目录已经支持通过 `make test TEST=<name>` 运行新测试。
3. 每周期观察 `retire_info_o`，按顺序断言必须退休 `0x00/0x04/0x08/0x0c/0x1c/0x20`，并明确禁止 `0x10/0x14/0x18` 退休。
4. 对 branch retire 额外检查：`branch_taken == 1`、`branch_mispredict == 1`、`branch_target_pc == 0x1c`、`branch_fallthrough_pc == 0x10`。
5. 若新增测试文件，命名和输出格式保持与 `three_alu.cpp`、`three_alu_branch.cpp` 一致，便于后续扩展；优先把 redirect 场景放在独立测试文件中，保留 `three_alu_branch.cpp` 继续作为现有 branch retire metadata 回归。
6. 跑固定回归：
   - `cd sim/frontend && make clean-test TEST=frontend_basic && make test TEST=frontend_basic`
   - `cd sim/core_single_inst && make test`
   - branch metadata 回归：`cd sim/core_three_alu && make clean-test TEST=three_alu_branch && make test TEST=three_alu_branch`
   - redirect 定向测试：`cd sim/core_three_alu && make clean-test TEST=three_alu_redirect && make test TEST=three_alu_redirect`（若你最终没有新建文件，而是增量修改现有测试，则把这里替换成对应测试名并说明原因）
7. 回归完成后，更新文档与计划文件，明确：
   - redirect packet
   - FTQ repair
   - BPU reseed
   - IFU/fetch-buffer flush
   - backend same-cycle recovery 边界
   - 尚未实现项

验收标准：
1. 新测试能稳定复现 taken-branch redirect 场景。
2. 错误路径三条指令绝不退休。
3. branch retire 元数据与计划完全一致。
4. `frontend_basic`、`core_single_inst`、现有 `three_alu_branch` 风格 branch 回归都通过。
5. 文档与计划文件已同步到真实实现状态。
6. 测试失败时日志能直接看出是 refill、timeout、退休顺序错误还是 wrong-path retired。

注意事项：
1. 不要修改 `core_single_inst` 的既有语义来适配这个测试。
2. 优先新增独立 redirect 测试，而不是把 `three_alu_branch.cpp` 改成同时承担两类回归；只有在你确认独立文件会明显重复大量样板且难以维护时，才允许复用现有文件。
3. 指令编码必须正确，但不要在此任务里扩展 ISA 支持范围。

可直接使用的最终提示词：

```text
你在仓库 /home/chen/FUN/CISLC-O3 中工作。请只完成 docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md 的 Task 6。

开始前先读：
1. agent.md
2. doc/CISLC_O3.md
3. doc/CISLC_O3_frontend.md
4. sim/core_three_alu/tests/three_alu_branch.cpp
5. sim/core_three_alu/Makefile
6. docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md

目标：
- 新增 directed redirect 验证
- 跑固定回归
- 同步文档和计划状态

允许修改：
- 优先新增 sim/core_three_alu/tests/three_alu_redirect.cpp
- 如确有必要，也可改 sim/core_three_alu/tests/three_alu_branch.cpp，但不能破坏它现有的 branch metadata 回归职责
- doc/CISLC_O3.md
- doc/CISLC_O3_frontend.md
- docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md

你必须完成的内容：
1. 用以下固定程序布局构造 directed test：
   - 0x00: addi x1, x0, 1
   - 0x04: addi x2, x0, 1
   - 0x08: add  x3, x1, x2
   - 0x0c: bne  x3, x2, +16
   - 0x10: ori  x4, x0, 9
   - 0x14: xori x5, x0, 6
   - 0x18: addi x6, x0, 7
   - 0x1c: addi x7, x0, 11
   - 0x20: add  x8, x7, x1
2. 复用现有 sim/core_three_alu 的 Vo3_core + refill-driver 风格。
   - 当前 sim/core_three_alu/Makefile 已支持 `make test TEST=<name>`，不要为新测试额外设计新入口。
3. 每周期观察 retire_info_o，断言：
   - 必须退休 0x00/0x04/0x08/0x0c/0x1c/0x20
   - 禁止退休 0x10/0x14/0x18
4. 对 branch retire 额外检查：
   - branch_taken == 1
   - branch_mispredict == 1
   - branch_target_pc == 0x1c
   - branch_fallthrough_pc == 0x10
5. 跑固定回归：
   - cd sim/frontend && make clean-test TEST=frontend_basic && make test TEST=frontend_basic
   - cd sim/core_single_inst && make test
   - cd sim/core_three_alu && make clean-test TEST=three_alu_branch && make test TEST=three_alu_branch
   - cd sim/core_three_alu && make clean-test TEST=three_alu_redirect && make test TEST=three_alu_redirect
6. 更新文档与计划文件，明确：
   - redirect packet
   - FTQ repair
   - BPU reseed
   - IFU/fetch-buffer flush
   - backend same-cycle recovery 边界
   - 尚未实现项

硬约束：
- 不要改 core_single_inst 的既有语义。
- 优先新增独立 redirect 测试文件，保留 three_alu_branch 作为既有 branch metadata 回归。
- 不要借测试扩展新的 ISA 范围。
- 若你最终没有新建 `three_alu_redirect.cpp`，必须在汇报里说明为什么复用现有文件更合理，以及如何保证没有削弱既有 branch metadata 回归。

完成后请汇报：
1. 改了哪些文件
2. directed test 最终放在哪个文件，为什么
3. 所有回归命令和结果
4. 文档与计划更新了哪些关键信息
```

---

## 交接格式要求

每个 agent 完成后，回复应包含以下内容：

1. 实际修改了哪些文件。
2. 哪些接口或周期行为发生了变化。
3. 跑了哪些测试，结果是什么。
4. 是否影响后续任务的提示词假设；如果影响，明确指出需要更新哪一条。

## 最终里程碑判定

当以下条件同时满足时，这份短期计划可视为完成：

1. taken 条件分支在 backend resolve 后能产生 redirect 并送到 frontend。
2. frontend 能 flush wrong-path 瞬态状态，但保留 ICache 内容。
3. FTQ 会保留 older history、截断 branch block、失效 younger blocks。
4. BPU 会从 redirect PC 重新开始。
5. directed branch test 只退休 `0x00/0x04/0x08/0x0c/0x1c/0x20`，绝不退休 `0x10/0x14/0x18`。
6. `frontend_basic` 与 `core_single_inst` 都没有被破坏。
7. `sim/core_three_alu/tests/three_alu_branch.cpp` 风格 branch retire metadata 回归没有被破坏。
8. 文档和计划文件准确记录了已实现能力与未实现限制。
