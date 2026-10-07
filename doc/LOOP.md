# CISLC-O3 闭环阶梯与实现状态

本文件是**项目当前状态的唯一权威来源**。规则见 [`agent.md`](../agent.md)，
微架构决策见 [`design/`](design/)。

更新规则：任何改变模块状态或闭环进度的提交，必须同步更新本文件对应的行。
"状态"一栏只描述事实，验证一栏只写有证据的结论（见 agent.md 第 3.3 节）。

## 1. 闭环阶梯

每一级是一条能在 Alan 上用一条命令验收的端到端路径。用户已决定移除 ITCM，
先打通 ICache→inclusive L2→AXI 取指，再推进分支与数据路径；以下按当前顺序记账。

当前顺序与验收策略以 [`O3-v1-plan.md`](O3-v1-plan.md) 的 2026-10-06 决定为准：L7 → L9 → L10 → L8 → L11；Spike/ACT4 与完整一致性测试推迟到 FPGA，L11 前不综合。

| 级 | 目标 | 验收 | 状态 |
|---|---|---|---|
| L0 | RTL 可解析、`o3_core` 可展开 | `scripts/lint.sh` | Alan PASS（`de9149d`，0 errors、227 warnings） |
| L1（历史） | ITCM 中的直线整数指令按序退休 | 旧 `sim/o3` smoke | Alan 曾 PASS（`a268f16`）；ITCM 已移除，旧验收不再运行 |
| **L4 当前** | **ICache miss → inclusive L2 → AXI RAM → 直线整数退休** | `make -C sim/o3 build && make -C sim/o3 run-smoke` | Alan 回归 PASS（`de9149d`，38 周期、4 条退休、ICache 回填 1 次） |
| **L2 当前** | **taken 分支 / JAL：BRU 解析 → 重定向 → 前端恢复** | `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1 && make -C sim/o3 run-rv64i-instructions` | Alan PASS（`de9149d`；局部 1/1；整核 76 周期、14 条退休、ICache 回填 2 次） |
| L3 部分闭合 | SQ 依赖/转发 → 流水化 DCache → inclusive L2 → AXI 数据访存与退休 | `make -C sim/cocotb/store_queue SIM=verilator`、`make -C sim/cocotb/dcache SIM=verilator`、`make -C sim/cocotb/backend_issue_queue SIM=verilator`、`make -C sim/cocotb/load_store_unit SIM=verilator`、`make -C sim/o3 run-dcache-data run-dcache-replay` | Alan `a8b3fc6`：Memory IQ 1/1、LSU replay/恢复 2/2；整核 `7d59822` 新门禁实测 `load_replays=1`，71 周期退休 6 条且轨迹 PASS；旧 smoke/分支/数据门禁仍 PASS。SQ 3/3、DCache 3/3 沿用前次 Alan 证据。仍缺多 MSHR、多 load pending、跨行异常、FENCE.I、PTW/AMO/DMA；不是完整 B03～B05 |
| L3 收尾 | 完成 L3；修 B12 缺口 1（分支解析全局停顿）与缺口 2（ALU RegRead 背压时缺 kill）；重命名改 4 宽（B42）；移除当前级不需要的空壳实例（B46） | 现有 L2/L3 门禁 + 分支密集程序 + 缺口 2 定向测试 | 阶段二实现与验收通过：四宽/16 项、空壳/filelist 清理、U3/U4、缺口 1 与授权 LQ-M；缺口 2 具名/随机/真实仲裁测试通过。Alan `ac2aed1` 全部门禁与 seed 1/7/29 通过，`1b7885d` 补充 LQ-M 通过；分支密集 1967 周期/365 退休，前后差值 0。同最终交付 SHA 的复验以 [报告 §9](tasks/O3-T01-report.md) 的 final 目录为准 |
| L5 | Spike 逐条比对；M 模式 CSR、精确异常、ecall/ebreak/illegal、MRET、committed_next_pc | 按 2026-10-06 用户策略带已知问题收口 | **已知问题退出**：Alan `2cc8a91` build、固定 11/11、新增局部 5/5、riscv-tests 5/5 PASS；随机 178/200（14 rd_wdata、8 mem_kind 失败）；M 模式 84 退休后 MRET timeout；ACT4 M 模式 Sail 签名 trap loop 暂不处理。根因未定位项留待上板抓波形，停止 T03 bug 修复，详见 [T03 报告](tasks/O3-T03-report.md) |
| L6 | M 扩展（MUL 采用 DSP，B43）、完成 FIFO/提前唤醒、JALR；首次 OOC 综合 | 按 2026-10-06 策略：定向 cocotb + lint + 整核短程序 + OOC | 机制及简化功能验证收口：Alan 定向 6/6、lint PASS、整核 297 周期 / 71 条退休 / Spike 0 差异。整核 OOC 812 秒后崩溃，整核 PPA 未取得；局部 MUL/DIV OOC PASS，MUL 16 DSP，见 [T04 报告](tasks/O3-T04-report.md) |
| O3-T04b（L7 前） | 整核 BRAM 映射与 OOC 资源/时序基线；不改机制 | 每个 cache 现有 cocotb + 整核 smoke；整核 OOC 耗时/资源/WNS/最差路径 | **定位报告已提交，改造暂停**：同步 BRAM 与 L1D 接纳前 tag 判定、L2 握手当拍写回 error 存在逐拍合同冲突；用户要求保持接口时序，先提交定位报告。另发现原 OOC 的 DTCM 2 Mbit RAM 推断硬错误；整核基线仍未取得，见 [T04b 报告](tasks/O3-T04b-report.md) |
| L7a | uBTB/BTB/TAGE、FTQ 恢复、RAS、F1 预解码修正与 M-mode HPM | 冻结 spec 与 T05 分步门禁 | **实现与定向功能验收完成**：T05c/d `cbe3372`，Alan cocotb 68/68、四源恢复与两组 l7_predict 正确性/性能 PASS，lint 与整核构建 PASS，见 [T05cd 报告](tasks/O3-T05cd-report.md) |
| L7b | 整数 RVC、跨块 edge 指令与 IALIGN=16 | V1～V8 冻结；T06a→T06b 门禁 | **实现与定向功能验收完成**：spec `01c939a`，T06a `2614064`、T06b `2b50184`；Alan 70/70、77/77 cocotb，四个整核回归与 l7b_rvc 自查 PASS；不含 Spike/ACT4/FPGA，见 [T06 报告](tasks/O3-T06-report.md) |
| L8 | 多 MSHR、重放、同 line 非对齐、A 扩展、FENCE/FENCE.I | RV64IMAC + litmus + 死锁 watchdog | 未开始 |
| L9 | F/D：拆分 CVFPU、FP 重命名、fflags/FS 退休、浮点访存/RVC | T07 定向 cocotb + 整核 FP 自查 + 回归；ACT4 推迟到 FPGA | **基础功能门禁通过，完整验收未完成**（`50ff873`）：Alan 模块 9/9、顺序 FP 自查、既有五项整核回归 PASS；较长 FP 用例发现单槽 replay 等待环，保留 FAIL，见 [T07 报告](tasks/O3-T07-report.md) |
| L10 | S/U、Sv39 MMU、SFENCE.VMA/satp/PMP、A/D、WFI | 特权测试 + riscv-tests p/v | 未开始 |
| L11 | SoC：L2 + DDR4（MIG）+ CLINT/PLIC + UART + SD（AXI Quad SPI，B44）+ SD DMA + FASE | 仿真启动 OpenSBI + Linux；上板经 SD 卡启动 Linux | 未开始 |

## 2. L4 缓存取指闭环（历史范围；L7a/L7b 已完成定向验收）

### 2.1 范围

- 镜像装入 AXI RAM（`0x8000_0000`）；复位 PC 从该地址开始。
- 顺序取指经过 ICache miss、L2 miss、AXI 四拍回填，再交给后端退休。
- L2 的同组容量替换须先 recall L1I 并 probe L1D；脏副本先写回 AXI。
- 本节描述 L4 取指门禁的历史范围；彼时 L1D 只能应答空副本探测。此后
  L3 已接入基础有效数据行与 load/store，见上表，不能把 L4 通过当成 L3 证据。

### 2.2 验收

```sh
make -C sim/o3 build
make -C sim/o3 run-smoke
```

通过条件：按序退休 4 条指令，PC 依次为 `0x8000_0000/04/08/0c`，
`x1..x4` 写回值依次为 `1/2/3/4`，至少一次 ICache 回填，无超时。

Alan 在 `1d2caeb` 上输出 `icache_refills=1`、`PASS cycles=38 retired=4`、
`RV64I_INSTRUCTION_TRACE_PASS retires=4`。
Alan 在 `de9149d` 上重建并回归得到相同的 38 周期、4 条退休和 1 次回填。
Alan 的持久环境和重建方法见 [`sim/alan-env.yml`](../sim/alan-env.yml) 与
[`sim/o3/README.md`](../sim/o3/README.md)。

### 2.3 L2 直接控制流恢复验收

顺序预测器下，taken BEQ 和 direct JAL 由 BRU 产生带 FTQ 身份的解析结果；
重定向器在 R0 杀掉年轻项并改写取指 PC，在 R1 等待历史/RAS 的同身份恢复完成，
再允许 R2 重新分配。执行重定向会清空尚未交付的 fetch buffer 项；已经发出的
错路缓存请求可完成，但其返回不会进入退休轨迹。

```sh
make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1
make -C sim/o3 run-rv64i-instructions
```

Alan 在 `de9149d` 上局部测试 1/1 PASS（150 ns）；整核输出
`icache_refills=2`、`PASS cycles=76 retired=14`、
`RV64I_INSTRUCTION_TRACE_PASS retires=14`。退休轨迹包含 taken BEQ 与 direct JAL，
并排除两条错路 `addi`。上述历史 SHA 采用顺序预测与每次分支解析保守暂停一拍；O3-T01 已解除 C 拍暂停，M 恢复不变；
JALR、RVC 和 predecode/slow/system 多来源重定向不在本级范围。

### 2.4 缓存取指路径与模块状态

信号流向：

```
AXI RAM 镜像（TB 经 axi_init_* 预装）
  → bpu（预测 PC、分配 FTQ）
  → ftq（demand 发射，携带 ftq_id / rq_idx）
  → icache（双 bank 四拍查找，miss 发 L2）
  → l2_cache（组相联/PLRU，miss 发 AXI，包含关系回收）
  → ICache 回填（四个 16B beat，带身份的 icache_resp_t）
  → fetch_return_queue（按序出队）
  → ifu_f0（长度识别）→ ifu_f1（生成 fetch_entry_t）
  → fetch_buffer → backend（旧数据流：decode → rename → IQ → ALU → ROB）
  → retire_info_o → sim/o3 退休轨迹
```

| 模块 | 状态 | 后续工作 | 测试 |
|---|---|---|---|
| `frontend/bpu.sv` | **闭环简化（L7b）**：快/慢预测、history/RAS 快照、训练；真实长度/edge 与返回地址 | BRAM 映射留后级 | Alan BPU 5/5 PASS，见 T06 报告 |
| `frontend/bpu_slow_check.sv` | **闭环简化（L7b）**：候选排序、缺目标、快慢覆盖；核对长度/edge、真实历史/RAS 地址 | 完整 ISA 一致性留后级 | Alan 1/1 PASS，含字段比较定向向量 |
| `frontend/ftq.sv` | **闭环简化（L7b）**：实际长度/edge 训练；年轻区域任意提交关闭更老空区域 | 完整一致性留后级 | Alan FTQ fixture 3/3 PASS；整核 RVC PASS |
| `frontend/icache.sv` | **闭环简化（L4）**：整行双 bank、S0–S3、单 demand MSHR/四拍回填；按行 recall；ITCM 已移除 | ITLB/PMP/PMA、预取、多 MSHR、性能事件与综合时序待后级 | `sim/cocotb/icache/` Alan 3/3 PASS（`1d2caeb`） |
| `memory/l2_cache.sv` | **闭环简化（L4）**：256 set/4-way 配置、tree-PLRU、AXI 回填、双 L1 回收、脏行 AXI 写回 | 普通请求单未决；B03/B41 并发、DMA/维护协调与完整 L1D 数据路径未实现 | `sim/cocotb/l2_cache/` Alan 2/2 PASS（`1d2caeb`） |
| `lsu/dcache.sv` | **闭环简化（L3）**：4 个 16B word bank、整行 tag/valid/dirty、两级查询、单行 miss、hit-under-miss、脏 victim 写回、L2 回填、probe | 多 MSHR/同 line 合并、PTW/AMO/预取、DMA 行保护；clean_all 不会虚假确认但尚未执行 | Alan 3/3 PASS（`022f90c`）；整核基本数据门禁 PASS |
| `backend/store_queue.sv` | **闭环简化（L3）**：SQ 年龄顺序查询、最近完整覆盖旧 store 转发；未知地址与部分覆盖保守等待；DCache 完成后释放，DTCM 保留本地 drain | LQ replay、依赖等待事件、跨行异常与整核冲突覆盖 | Alan 既有三项+四宽/C/M/commit/drain 随机合同 4/4 PASS（`ac2aed1`，seed 1/7/29）；整核数据门禁 PASS |
| `backend/backend_issue_queue.sv` | **闭环简化（L9）**：Memory 保留单发射/replay 选择，新增分域源就绪与唤醒 | 多项 replay、多 load 在途留 L8 | FP 顺序访存 PASS；无串行边界的 load→store→load 单槽 replay 等待环 FAIL（T07）；本模块独立门禁未运行；此前 Memory IQ/replay 证据仅对应旧版 |
| `backend/load_store_unit.sv` | **闭环简化（L9）**：保留单 load pending/replay；FP 目的域经过 pending/result，FLW boxing、FLD 原样；多项 LQ replay、翻译/异常、跨行与 MMIO 留后级 | FP 顺序访存 PASS；无串行边界的 load→store→load 单槽 replay 等待环 FAIL（T07）；本模块独立门禁未运行；此前 LSU/replay 证据仅对应旧版 |
| `frontend/fetch_return_queue.sv` | **闭环简化（L7a）**：单槽身份匹配、年龄清除；kill 拍保留槽接收匹配响应 | 单槽吞吐限制保留，多项返回队列留后级 | T05b `b122d59` Alan 3/3 PASS；本次未改行为 |
| `frontend/rvc_expander.sv` | **闭环简化（L9）**：整数 RV64C 加四条浮点 RVC，C.LUI nzimm 修正 | 完整 ISA 一致性留后级 | Alan 3/3 PASS（`50ff873`），含 FP RVC 与 C.LUI；顺序整核 PASS |
| `frontend/ifu_f0.sv` | **闭环简化（L7b）**：四条/拍、首拍出队、hold/pend、整数 RVC 展开、edge/D34、kill/截断 | 浮点 RVC 在 L9；ITLB/PTW 在 L10 | Alan 6/6 PASS，含 120 拍 RV64I 随机事务 |
| `frontend/ifu_f1.sv` | **闭环简化（L7b）**：按长度/位置 a～f 核对；直接截断、零指令拍 c′、寄存式请求 | 完整 ISA 一致性留后级 | Alan 18/18 PASS，保留 L7a 17 项 |
| `frontend/redirect_arbiter.sv` | **闭环简化（L7a）**：四源年龄仲裁、busy 替换、接受拍计数；F1 寄存请求已接入 | SYS committed 上下文仍为已知边界 | Alan 仲裁器 2/2、l7_recovery 2/2 PASS；T06 复验通过 |
| `frontend/fetch_buffer.sv` | **闭环简化（L7a）**：按 FTQ 身份/槽位选择性保留，kill 拍阻塞握手 | 吞吐与综合时序留后级 | Alan 2/2、l7_recovery 2/2 PASS；T06 复验通过 |
| `system/hpm_counters.sv` / `system/csr_file.sv` | **闭环简化（L9）**：保留 HPM；增加 FP CSR、FS/SD、退休 flags/Dirty，misa=RV64IMFDC | S/U 与 Sscofpmf 在 L10 | Alan CSR 4/4 PASS（`50ff873`），含既有 HPM 用例；hpm 独立套件未重跑 |
| `frontend/frontend.sv` | 总装：F0/F1 拍有效、末拍、pending、截断与年龄头指针连线 | ITLB/PTW、预取仍待后级 | Alan 四个整核回归与 RVC 自查 PASS |
| `backend/backend.sv` | **闭环简化（L9）**：保留 INT/MEM/BR 路径，增加 FP 资源/IQ/RegRead/FU/WB/退休连线与入口检查 | B42 R1/R2 按时序触发；后级访存/系统机制 | L9 顺序整核功能覆盖；本模块独立门禁未运行；此前总装/整核证据仅对应旧版 |
| `backend/rob.sv` | **闭环简化（L9）**：四宽按序退休，目的域/逐项 flags，新增两个 FP 完成口，FP 观察写使能抑制 | L5 已知问题见 T03；完整一致性留后级 | L9 顺序整核功能覆盖；本模块独立门禁未运行；此前 ROB 合同证据仅对应旧版 |
| `backend/uop_queue.sv` | **闭环简化（L3）**：四宽、16 项、bank/回绕/满空/前缀握手/M flush | 更深流水按 B42 时序触发 | Alan WQ 900 周期 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/rename_stage.sv`、`rename_map_table.sv`、`free_list.sv` | **闭环简化（L9）**：INT/FP 独立预算与映射、src3 RAW、f0/p0、共享 tag 恢复 | R1/R2 按 B42 时序触发 | L9 顺序整核功能覆盖；本模块独立门禁未运行；此前 O3-T01 证据仅对应旧版 |
| `backend/branch_checkpoint_file.sv` | **闭环简化（L3）**：C 释放/清 parent 与不同 tag create 合并；只看拍初空闲，不同拍复用 | 系统整体恢复待 L5 | Alan CK full/C/M 700 周期 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/rename_dispatch_queue.sv`、`dispatch_stage.sv` | **闭环简化（L9）**：四宽前缀增加 FP 分流；FP 访存走 MEM，异常只消费 RDQ | 后续级 AMO 等 | L9 顺序整核功能覆盖；本模块独立门禁未运行；RDQ 本次未改 |
| `backend/backend_issue_queue.sv`、`prf_read_arbiter.sv` | **闭环简化（L9）**：分域唤醒、三源 FP IQ 双发射、五个 FU 槽容量、一个跨域 INT 读候选 | FP 提前唤醒按 B33 推迟到性能优化 | L9 顺序整核功能覆盖；本模块独立门禁未运行；此前 INT/MEM/BR/RR 证据仅对应旧版 |
| `backend/branch_unit.sv`、`alu_pipe.sv` | **闭环简化（L3）**：one-shot C/M 与 JAL 链接解耦；ALU 独立 kill 保留旧 Result | JALR 在 L6；L7b IALIGN=16 已接入，完整目标边界留后级 | Alan 缺口 2 具名/700 事务 DUT/真实 WB 竞争与总装 C 合同 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/load_queue.sv` | **闭环简化（L3）**：四宽；C 合并正常记账，M 仅取消年轻并保留旧 execute/request/response | 多事务代际/异常待 L8/L5 | Alan LQ-C/M PASS（`ac2aed1`）；240 事务复用/迟到合同 PASS（`1b7885d`，seed 1/7/29） |
| `core/o3_core.sv` | 总装（连线） | ICache/L2/AXI、直接控制流恢复及基础 DCache 数据路径已接通 | 整核 Alan smoke、分支及基础数据门禁 PASS（`6b4c540`） |
| `sim/o3/` | AXI RAM 2 MiB、JSONL v2、进程内固定版本 Spike、LSU/ROB 访存观测、ACT4 迁移、3000 动态退休随机生成与五类自测 | 循环控制流差异已修复；CSR/异常由 O3-T03、RVC 等由后续任务闭合 | Alan `3cbd759` 固定 6/6、自测 5/5、ACT4 51/51、随机 200/200 全部通过，0 差异；准确命令/日志见 O3-T02 报告 §7 |

## 3. 其他模块状态概览

当前缓存取指路径以外的模块概况（2026-10-03）：

- **单模块实现、有 cocotb**：`ubtb`、`main_btb`、`tage`、`ras`。
- **本轮新增局部 cocotb**：`branch_recovery`（BRU/重定向/fetch buffer/ALU kill，Alan 1/1 PASS，`de9149d`）、
  `l2_cache`（2 项）、`dcache` 空副本维护口（1 项）；
  `icache` recall 回归（3 项合计）、`backend` 整核缓存路径（1 项）已在 Alan 通过。
- **单模块实现、有 SV testbench**：`ftq`（`tb/ftq_tb.sv`）、`branch_history`、`history_snapshot_store`（`tb/` 下，仅记录过 lint）。
- **单模块实现、无独立 cocotb**：`fetch_buffer`、
  `decoder`、`axi_master`、`simple_data_sram`；后端主要队列/rename/资源合同已有 O3-T01 cocotb，见上表；
  L1 整核冒烟仅覆盖本轮四条 addi 的路径。
- **空壳/待扩展**：`lsu/*` 的 PTW/AMO/DMA/完整维护路径、`system/*` 的后级部分、
  `l2_recall_ctrl`/`dma_line_coord`、`itlb`、`icache_mshr`、预取相关、
  重命名新结构（`rename_dep_r1` 等）、`O3.sv`/`Tile.sv`。

`backend.sv` 保留当前实际数据流，2026-10-02 搭建但未接入的非 L3 目标实例已移除。O3-T01 已移除本级后端空壳实例及独占 filelist 条目；文件保留。
归属：入口/提交/CSR/trap L5，M/FIFO/融合 L6，性能计数 L7，数据预取/非阻塞访存/AMO/LRSC L8，FP L9，PTW/A-D/WFI/PMP/PMA L10，fatal/L2-recall/DMA 协调 L11。
R1 依赖与级间暂存按 B42 综合时序触发，不指定 Ln。

## 4. 已知的文档不一致

- `doc/CISLC_O3.md` 的"当前实现状态"描述的是旧数据流，并引用已删除的
  `rtl/frontend/ifu.sv`、`rtl/backend/issue_queue.sv`。
- `doc/CISLC_O3_frontend.md` 中描述 `ifu.sv` 状态机的章节已失效。
- `rtl/common/o3_cfg_pkg.sv` 保留未使用的空宏 `` `O3_TBD ``；backend 相关过期说明已在 O3-T01 修正。

- B49（2026-10-07）取代 B31 跨 line 报异常：`load_store_unit.sv`、`dcache.sv`、`dtlb.sv`、`commit_ctrl.sv`、`backend_perf_events.sv`、`rob.sv`、`o3_types_pkg.sv`（`crossline_misalign`）头注释仍按旧口径；L8/L10 触及时修正。`csr_file.sv:7`“首版不依赖 Sstc”同样过期。

- 58 个 RTL 文件头注释仍写着"本阶段不写测试代码和仿真代码"（旧规则，已作废，见 agent.md 第 4.1 节）。

以上随相关模块被闭环触及时顺手修正。

## 5. O3-T02 验证边界（2026-10-06）

冻结规格 §8 Q1–Q10 已实施，只增加退休观测字段，不改变执行行为。
`unified_memory` 是旧 ITCM/软件内存地址门禁，按 Q7 排除 Spike；原 checker
及命令保留，当前 AXI 路径无法用它建立闭环证据，标为历史。
随机 200 种子全部执行，参考端每种子 3000 条，DUT 匹配前缀共 114412 条。
种子 120 通过（3001 条，含 tohost 同拍年轻 lane），其余 199 个均首差异为 PC。
12 条指令的缩减复现位于 `sim/o3/repros/branch_loop.hex`，旧 O3-T01 二进制亦复现。
O3-T01 60 条既有命令和全部新门禁的最终提交复验记录见
[O3-T02 阶段二报告](tasks/O3-T02-report.md)，不得以开发轮次替代同 SHA 复验。
用户已授权随后直接执行 O3-T02-fix；需要改 Dxx/Bxx 决策时才停。

O3-T02 收尾（2026-10-06）：上节 15/51、1/200 是修复前历史失败。
修复后补跑 137–200 为 64/64；重新构建后的同 SHA 全量复验为 O3-T01 60/60、
固定 6/6、ACT4 51/51、随机 200/200（600160 条匹配），无新 bug。
日志 Alan `/home/chen/FUN/CISLC-O3-runs/20261006-o3t02-close/final/`；
收尾文档提交原样复验另存 delivery/，其 sha.txt 与 commands.tsv 为准确交付证据。

## 6. O3-T03 已知问题退出（L5）

接入 rename_entry_gate、commit_ctrl、csr_file、trap_ctrl；ROB 保存队头串行/异常/
实际后继元信息；CSR 在队头一次读改写并写回，trap 不退休故障指令，MRET 自身退休。
RAT/free list 从提交态恢复；SQ 只取消未提交项；LSU 保留已发事务的所有权并丢弃迟到结果。
存储访问在退休前通过只读 DCache 探测确认；probe 不修改数据，成功才 complete Store。
FENCE.I 只排空 SQ + 失效 ICache，完整数据 clean 待 L8。Spike 增加 CSR/trap 事件。
Alan `2cc8a91` 的通过项和三个已知问题见 [T03 报告](tasks/O3-T03-report.md)；L5 带已知问题退出，不宣称完整通过。

O3-T03 首版发现 PRF/ROB unpacked array lane 方向不一致；修正并追加三条静态
指令的固定 Spike 门禁，详情 O3-T03 报告 Bug 1；最小 PRF 门禁在 `2cc8a91` 已通过。

L5 F0 已保留非法短编码位置及返回队列取指错误，交给 ROB 精确 trap；C 仍不执行。
测试 sim/cocotb/ifu_f0 在 Alan `2cc8a91` 2/2 PASS，固定 illegal_zero 门禁 PASS。

## 2026-10-06 L6 合同更新

完成 FIFO 双入队、取消归还与独立单双容量；renamed_uop 携带融合成员 tag；共享 INT IQ 加入 FU 可用性与完成头唤醒；WB extra 源完成口；BRU 目标异常。详见 T04 报告。验证按用户新策略从简；T03 已知问题不再阻塞 L6。

### L6 当前模块状态

| 模块 / 路径 | 当前状态 | 定向证据 |
| --- | --- | --- |
| signed_mul65x65 / mul_execute_unit | DSP 四拍数据通路与完整身份、双结果和按条取消 | mdu DIV=0 |
| unsigned_radix4_divider / div_execute_unit | MSB 对齐 radix-4、符号与 W / 除零 / 溢出 | mdu DIV=1 |
| fu_completion_fifo | 预留信用、双入队、WB 背压、选择性取消 | fu_completion_fifo |
| mul_fusion_detect / rename_stage / dispatch_stage | 两条架构指令、整对接纳、单次执行 | mul_fusion_detect、整核 L6 短程序 |
| backend_issue_queue / backend / writeback_arbiter | 共享 INT IQ 的 MUL/DIV 可用性、额外写回、早唤醒和头部 bypass | early_wakeup、整核 L6 短程序 |
| branch_unit / branch_execute_unit | JALR 重定向 / 链接保持 / RAS 提示；L6 时 IALIGN=32，L7b 已改 IALIGN=16（见 T06） | jalr、整核 L6 短程序 |

最终实现与综合证据以 [T04 报告](tasks/O3-T04-report.md) 为准。

## L9 RTL 交付与基础功能测试（2026-10-07）

先前用户授权写完 T07a/T07b RTL、测试另做；本轮授权补基本功能测试。当前采用 T07b
译码与 misa，RTL 本轮未改行为；未保留由测试宏裁剪 RTL 的过渡模式。实现与验证见
[O3-T07-report.md](tasks/O3-T07-report.md)，不改冻结 spec/设计基线。

| 模块 | 本次 RTL 行为 | 验证 |
|---|---|---|
| `backend/decoder.sv`、`frontend/rvc_expander.sv` | FP 指令表/域/格式/rm、四条浮点 RVC、C.LUI nzimm 合法性 | Alan RVC 3/3 PASS；译码经整核覆盖，独立译码门禁未运行 |
| `backend/backend.sv` | Rename 入口 FS/rm 异常撤销、FP 四套域资源、五个弹性 RegRead 槽、FU/访存/写回/退休连线 | 顺序整核 PASS；独立模块门禁未运行 |
| `backend/physical_regfile.sv`、`preg_ready_table.sv` | FP p0 普通读写/ready，7R/2W、实际写口同拍旁路与唤醒 | 顺序整核 PASS；独立模块门禁未运行 |
| `backend/fpu/fpu_{fma,divsqrt,misc,conv}_fu.sv` | 直接拆分 opgroup；8 项身份侧表、killed 保留到终结、共同结果保持、FMV 旁路轮转 | Alan FU 2/2 PASS（含 32 组固定种子加法）；顺序整核 PASS |
| `backend/fp_writeback_arbiter.sv`、`writeback_arbiter.sv`、`rob.sv` | 分域年龄仲裁、同拍取消/全局 flush 过滤、FP→x0 完成和 flags、ROB 增加两个 FP 完成口 | 顺序整核 PASS；独立模块门禁未运行 |
| `backend/load_store_unit.sv` | **闭环简化（L9）**：保留单 load pending/replay；FP 目的域经过 pending/result，FLW boxing、FLD 原样 | 多项 LQ replay、翻译/异常、跨行与 MMIO 留后级 | FP 顺序访存 PASS；无串行边界的 load→store→load 单槽 replay 等待环 FAIL（T07）；本模块独立门禁未运行；此前 LSU/replay 证据仅对应旧版 |
| `system/commit_ctrl.sv`、`csr_file.sv` | 实际退休 OR flags、写 FPR/flags 置 Dirty、CSR 写/FS Off/保留 frm 与 SD | Alan CSR 4/4 PASS；commit_ctrl 经整核覆盖，独立门禁未运行 |
| `third_party/cvfpu`、`rtl/rtl.f`、`scripts/cvfpu.vlt` | 固定 gitlink 和 common_cells；统一文件清单与限定 CVFPU BLKANDNBLK 豁免 | Alan lint PASS：0 errors / 361 warnings，固定依赖工作树无修改 |

B33 闭环简化：FP FU 不发提前唤醒；INT/FP 消费者由真实目的域 PRF 写授权唤醒。
**代码 SHA `50ff873817305dc2696de1f7457fda1b80c337dd` 已推送。** Alan 9/9 模块用例、
`run-l9-fp-smoke`（890 cycles / 267 retires）与五项既有整核回归通过。
`run-l9-fp` 保留 FAIL：年轻 load 进入单槽 replay 后禁止更老 load 发射，
阻塞依赖该老 load 的 store；纯整数复现也 FAIL。未修改访存设计或删除失败用例。
本次仅记基本执行功能验证；完整 L9 spec 门禁、Spike/ACT4、综合/FPGA/SoC 未运行。
