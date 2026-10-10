# O3-T12：L7c 任务书（T12a → T12b → T12c → T12d）

唯一实施依据：[L7c spec](../spec/l7c-frontend-throughput-spec.md)（已冻结，W1～W12）。前端基线 D36～D40 是同一决定的设计记录。本文只规定执行顺序、停止条件与报告格式，不新增任何行为。

## 共同规则

- **起点与分支**：PMP 范围预解码任务（`O3-pmp-predecode-task.md`）提交之后的 `fix/memory-ram-ooc-20261008` HEAD，新建分支 `feat/l7c-frontend`。开工前确认 `pmp_allow_dec` 已存在；不存在就停下报告。
- **工作区里不属于本任务的修改**（`doc/LOOP.md` 以外的 T10/memory-ram-ooc 报告等）不要混进本任务提交。`doc/LOOP.md` 的 L7c 行由各步按事实更新。
- **spec 未覆盖的实现细节**（信号编码、struct 字段顺序、内部状态划分、测试脚本写法）：自行决定，写进报告"自行决定"一节，每条写清问题、决定、依据、涉及文件。
  **需要改变 spec 行为或 `doc/design/` 的 Dxx/Bxx 时**：停下问，不改 spec 和 design。
- **允许改动的文件**：只限 spec 第 0 节与 3.3 节列出的。
- **仿真主机**：每次运行前重新读取 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`，按其中当前内容预检首选主机（`cloud_chen`），不可用再预检 Alan；两台都不可用报告具体原因，不在本地跑。测试失败不算主机不可用。不跑 Spike、ACT4，不综合、不跑 OOC。
- **测试纪律**：
  - 失败就修 RTL。不得放宽断言、黄金值、用例规模或种子数，不得删除已有用例。
  - 已预先授权的测试侧修改：因 spec 改变的接口/时序而必须调整的 tb 连线、等待拍数（例如 TAGE/BTB 训练多两拍）、Makefile 过滤与调试日志；每处写进报告。
  - 旧测试断言与冻结 spec 冲突（不只是拍数或连线）时：停下，列出文件、行号、对应 spec 条目和建议补丁，等批准。
  - 修 RTL 后，前序步骤已通过的用例要重跑受影响部分；每步提交前跑完本步范围与整核回归。
- **证据**（T10 批准的轻量规则）：T12a～T12c 每步只需简表：执行 SHA、主机、命令、exit、用例数/通过数，外加整核 smoke。完整同 SHA 证据（全部 14.1、14.2、回归在同一 SHA 上执行，附日志路径）只在 T12d 最终门禁。
- **报告**：`doc/tasks/O3-T12-report.md`，每步追加一节：完成内容、自行决定、证据表、已知问题、14.2 计数器数值（有的话）。

## T12a：多项返回队列

```text
任务：实现 L7c spec 第 4 节（8 项返回队列：槽池 + 程序顺序队列，ZOMBIE 只占容量），
以及 4.3 与 8.2 中的 RQ 事件和交付事件（PE_RQ_FULL_CYCLE/HEAD_WAIT_SLOW/HEAD_WAIT_DATA、
新增 PE_RQ_ZOMBIE=0x3E、PE_DELIVER_LT4_BACKEND_READY_CYCLE、PE_BACKEND_BACKPRESSURE_CYCLE）。
以 spec 为准，先通读 spec 第 0、1、4、8、14、15 节与本任务书"共同规则"。

要点：
- rsv_idx_o 给编号最小的 FREE 槽；分配按 rsv_req_i.rq_idx（FTQ demand_hold 锁存的那个），断言其为 FREE。
- 同一沿次态顺序：预留 → 响应 → kill → 出队（spec 4.2）。
- 断言：被杀槽是 ord 的连续后缀；PEND+ZOMBIE ≤ RQ_DEPTH；响应的 ftq_id 与槽一致。
- PE_RQ_FULL_CYCLE 在 FTQ 产生；PE_NUM 随新增事件更新，事件编号只追加。
- 改写 fetch_return_queue.sv 文件头"当前实现状态"。

验证：
- sim/cocotb/fetch_return_queue 按 spec 14.1 扩展并通过；
- lint 0 errors，warnings 不多于 357（新增逐条说明）；
- MEM_PIPES=2 构建下现有 13 项整核程序 + run-l7-predict 全部通过，记录每项周期数（作为本级前后对比的中间点）。
提交：feat(frontend): L7c T12a multi-entry fetch return queue
```

## T12b：训练交接、训练队列、BRAM 双副本

```text
任务：实现 L7c spec 第 2、3 节与 9.1：FTQ 两级交接即释放、history_snapshot_store 训练口改为带 id 输出、
BPU 训练队列（train_free_o 信用）、统一 T0/T1 训练流水与 1 深写旁路、TAGE/主 BTB 双副本 RAM
（o3_sram_1r1w 新增 ALLOW_COLLISION）、TAGE valid/base_wr FF、查询与训练同沿读新值；
bpu_train_t 改为 folds；FTQ mispred_mask 与部分清除清理；
提交口径事件 0x34～0x3A、0x3D（TAGE 元数据布局常量移到 o3_types_pkg 共用）。
先通读 spec 第 2、3、8、9、14 节。

要点：
- 训练规则逐位不变。实现前先把现有 tage.sv/main_btb.sv 的单沿读改写写成 Python 参考模型，
  用于 14.1 的"连续同行训练等于逐包顺序读改写"比对。
- 碰撞读数在仿真中被取反，遗漏旁路会直接导致比对失败，不要用关闭 ALLOW_COLLISION 绕过。
- stall_i 语义用 RAM 读使能保持（spec 3.3），现有 tage/main_btb 的 stall 用例应继续通过。
- loop 相关字段（loop_train_t、loop_meta）本步只定义类型并传 0，T12d 再接入。
- 新建 sim/cocotb/ftq（spec 14.1 ftq 行中与本步相关的用例）。

验证：
- cocotb：ftq（新）、tage（seed 1/7/29）、main_btb、bpu、ubtb、bpu_slow_check、redirect_arbiter、o3_sram_1r1w、fetch_return_queue；
- lint；MEM_PIPES=2 的 13 项整核程序 + run-l7-predict，记录周期数；
- 在报告中给出 14.2 第 3 段尚未写成前的替代观察：run-l7-predict 中 PE_TRAIN_STALL_CYCLE 与 PE_FTQ_FULL_CYCLE 数值。
提交：feat(frontend): L7c T12b pipelined training handoff and dual-copy predictor RAMs
```

## T12c：FDIP 预取与特性开关 CSR

```text
任务：实现 L7c spec 第 5 节全部（FTQ prefetch 游标规则、fetch_prefetcher、prefetch_xlate_cache、
sv39_tlb 探测查询、ICache 的 MSHR 保留/PMP-PMA-epoch 检查/来源位/探测仲裁/xlate_fill_o、
icache_mshr free_count_o 与 pf_only）、第 7 节 CSR 0x7C0 mo3fecfg（LOOP_DIS 位本步只存储与输出），
以及预取事件（0x29、0x2A～0x2D、0x3F～0x43）。删除 frontend.sv 中 perf_pf 强制为 0。
先通读 spec 第 5、7、8、14 节。

要点：
- 预取 PMP 检查用 pmp_allow_dec，与 demand S3 同一函数。
- 探测查询不得分配 miss、申请 PTW、锁存故障、更新 PLRU，也不计 ITLB_HIT/MISS；预取不发 PTW。
- 探测只在 ICache 的 ITLB s0_valid_i 表达式为 0 的拍授予；加断言：探测下一拍 S1 不使用 ITLB 输出。
- 复用记录的 SFENCE 失效与 ITLB 使用同一范围谓词。
- 删除 o3_cfg_pkg 中未使用的 prefetch.lead_distance、req_queue_depth，新增 mshr_reserve=1。

验证：
- cocotb：fetch_prefetcher（新）、icache、csr_file、mmu、frontend_sync_ctrl，以及 T12a/T12b 的全部用例；
- 写出 sim/o3/tests/l7c_frontend.S 的第 2 段（冷代码流）与 run-l7c-frontend 目标的 PF_DIS 两次运行，
  报告 mcycle、ICACHE_DEMAND_MISS、PF_ISSUED、PF_USEFUL、PF_LATE；
- lint；MEM_PIPES=2 的 13 项整核程序 + run-l7-predict（预取默认开启），记录周期数。
提交：feat(frontend): L7c T12c FTQ-directed instruction prefetch and feature CSR
```

## T12d：loop predictor 与最终门禁

```text
任务：实现 L7c spec 第 6 节 loop predictor（新文件 rtl/frontend/loop_predictor.sv、慢核对接入、
N+2 推测更新与整表检查点、FTQ loop_meta 存储与 loop_meta_rd_o、恢复与 redirect_req_t.exec_br_*、
T1 训练与分配）、事件 0x3B/0x3C，完成 14.2 全部三段与最终门禁。
先通读 spec 第 6、8、12（W7）、14 节。

要点：
- 检查点是本拍更新"之前"的整表 spec_iter；恢复与 D29 RAS 恢复同拍、同一身份。
- 恢复的三种情况严格按 spec 6.4 表；系统重定向不恢复。
- 同一沿分配优先于恢复/推测更新（spec 6.5 第 3 条）。

最终门禁（同一 SHA，完整证据）：
- spec 14.1 全部 cocotb；
- 14.2：run-l7c-frontend 三段，loop 与预取开关两种配置均 tohost 通过；
- 回归：lint；MEM_PIPES=2 的 13 项与 MEM_PIPES=1 的 12 项整核程序；run-l7-predict；
- 报告附：每项整核程序在 T12 起点 SHA 与最终 SHA 的周期数对比表（增加的逐项说明原因）；
  14.2 各段计数器数值表；14.3 性能项是否达标（未达标登记为已知问题，不阻塞提交）。
- 更新 doc/LOOP.md 的 L7c 行为实际结论。
提交：feat(frontend): L7c T12d loop predictor and final gate
```

## 停止条件

- 需要改 spec 或 design：停下问。
- 旧测试与冻结 spec 冲突（超出预授权的拍数/连线调整）：停下，给出建议补丁。
- 某步正确性用例修不好：不提交该步的通过声明；报告写清失败用例、首个失败点、复现命令、已尝试的修复，然后停下，不进入下一步。
- 性能项（spec 14.3）未达标：登记已知问题并附复现命令，继续。
