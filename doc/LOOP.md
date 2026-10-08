# CISLC-O3 闭环阶梯与实现状态

本文件是**项目当前状态的唯一权威来源**。规则见 [`agent.md`](../agent.md)，
微架构决策见 [`design/`](design/)。

更新规则：任何改变模块状态或闭环进度的提交，必须同步更新本文件对应的行。
"状态"一栏只描述事实，验证一栏只写有证据的结论（见 agent.md 第 3.3 节）。

## 1. 闭环阶梯

每一级是一条能在共享配置所选仿真主机上验收的端到端路径。历史Alan证据保留；当前主机选择见 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`。用户已决定移除 ITCM，
先打通 ICache→inclusive L2→AXI 取指，再推进分支与数据路径；以下按当前顺序记账。

当前顺序与验收策略以 [`O3-v1-plan.md`](O3-v1-plan.md) 的 2026-10-06 决定为准：L7 → L9 → L10 → L8 → L11；Spike/ACT4 与完整一致性测试推迟到 FPGA，L11 前不综合。

| 级 | 目标 | 验收 | 状态 |
|---|---|---|---|
| L0 | RTL 可解析、`o3_core` 可展开 | `scripts/lint.sh` | Alan PASS（`de9149d`，0 errors、227 warnings） |
| L1（历史） | ITCM 中的直线整数指令按序退休 | 旧 `sim/o3` smoke | Alan 曾 PASS（`a268f16`）；ITCM 已移除，旧验收不再运行 |
| **L4 当前** | **ICache miss → inclusive L2 → AXI RAM → 直线整数退休** | `make -C sim/o3 build && make -C sim/o3 run-smoke` | Alan 回归 PASS（`de9149d`，38 周期、4 条退休、ICache 回填 1 次） |
| **L2 当前** | **taken 分支 / JAL：BRU 解析 → 重定向 → 前端恢复** | `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1 && make -C sim/o3 run-rv64i-instructions` | Alan PASS（`de9149d`；局部 1/1；整核 76 周期、14 条退休、ICache 回填 2 次） |
| L3 部分闭合 | SQ 依赖/转发 → 流水化 DCache → inclusive L2 → AXI 数据访存与退休 | `make -C sim/cocotb/store_queue SIM=verilator`、`make -C sim/cocotb/dcache SIM=verilator`、`make -C sim/cocotb/backend_issue_queue SIM=verilator`、`make -C sim/cocotb/load_store_unit SIM=verilator`、`make -C sim/o3 run-dcache-data run-dcache-replay` | Alan `a8b3fc6`：Memory IQ 1/1、LSU replay/恢复 2/2；整核 `7d59822` 新门禁实测 `load_replays=1`，71 周期退休 6 条且轨迹 PASS；旧 smoke/分支/数据门禁仍 PASS。SQ 3/3、DCache 3/3 沿用前次 Alan 证据。本行是历史L3证据；多MSHR/load pending与FENCE.I已在L8a验收，B49跨行拆分、AMO/DMA仍未验收；PTW/A-D已在L10接入；不是完整 B03～B05 |
| L3 收尾 | 完成 L3；修 B12 缺口 1（分支解析全局停顿）与缺口 2（ALU RegRead 背压时缺 kill）；重命名改 4 宽（B42）；移除当前级不需要的空壳实例（B46） | 现有 L2/L3 门禁 + 分支密集程序 + 缺口 2 定向测试 | 阶段二实现与验收通过：四宽/16 项、空壳/filelist 清理、U3/U4、缺口 1 与授权 LQ-M；缺口 2 具名/随机/真实仲裁测试通过。Alan `ac2aed1` 全部门禁与 seed 1/7/29 通过，`1b7885d` 补充 LQ-M 通过；分支密集 1967 周期/365 退休，前后差值 0。同最终交付 SHA 的复验以 [报告 §9](tasks/O3-T01-report.md) 的 final 目录为准 |
| L5 | Spike 逐条比对；M 模式 CSR、精确异常、ecall/ebreak/illegal、MRET、committed_next_pc | 按 2026-10-06 用户策略带已知问题收口 | **已知问题退出**：Alan `2cc8a91` build、固定 11/11、新增局部 5/5、riscv-tests 5/5 PASS；随机 178/200（14 rd_wdata、8 mem_kind 失败）；M 模式 84 退休后 MRET timeout；ACT4 M 模式 Sail 签名 trap loop 暂不处理。根因未定位项留待上板抓波形，停止 T03 bug 修复，详见 [T03 报告](tasks/O3-T03-report.md) |
| L6 | M 扩展（MUL 采用 DSP，B43）、完成 FIFO/提前唤醒、JALR；首次 OOC 综合 | 按 2026-10-06 策略：定向 cocotb + lint + 整核短程序 + OOC | 机制及简化功能验证收口：Alan 定向 6/6、lint PASS、整核 297 周期 / 71 条退休 / Spike 0 差异。整核 OOC 812 秒后崩溃，整核 PPA 未取得；局部 MUL/DIV OOC PASS，MUL 16 DSP，见 [T04 报告](tasks/O3-T04-report.md) |
| O3-T04b（L7 前） | 整核 BRAM 映射与 OOC 资源/时序基线；不改机制 | 每个 cache 现有 cocotb + 整核 smoke；整核 OOC 耗时/资源/WNS/最差路径 | **定位报告已提交，改造暂停**：同步 BRAM 与 L1D 接纳前 tag 判定、L2 握手当拍写回 error 存在逐拍合同冲突；用户要求保持接口时序，先提交定位报告。另发现原 OOC 的 DTCM 2 Mbit RAM 推断硬错误；整核基线仍未取得，见 [T04b 报告](tasks/O3-T04b-report.md) |
| L7a | uBTB/BTB/TAGE、FTQ 恢复、RAS、F1 预解码修正与 M-mode HPM | 冻结 spec 与 T05 分步门禁 | **实现与定向功能验收完成**：T05c/d `cbe3372`，Alan cocotb 68/68、四源恢复与两组 l7_predict 正确性/性能 PASS，lint 与整核构建 PASS，见 [T05cd 报告](tasks/O3-T05cd-report.md) |
| L7b | 整数 RVC、跨块 edge 指令与 IALIGN=16 | V1～V8 冻结；T06a→T06b 门禁 | **实现与定向功能验收完成**：spec `01c939a`，T06a `2614064`、T06b `2b50184`；Alan 70/70、77/77 cocotb，四个整核回归与 l7b_rvc 自查 PASS；不含 Spike/ACT4/FPGA，见 [T06 报告](tasks/O3-T06-report.md) |
| L8a | 非阻塞L1D/L2、四MSHR、双访存管道、事件唤醒、STA RFO、公开PTE协议、FENCE.I | O3-T09 M1～M6及spec12.8；截止前缀按用户批准解释严格比较 | **L8a实现与分层功能验收完成**：cloud_chen，同SHA门禁与周期/统计见 [T09报告](tasks/O3-T09-report.md)；L8b见下一行，L8c未开始，跨行、AMO、MMIO、DMA、litmus、综合/FPGA不在此证据范围 |
| L8b | AMO/LR/SC、MMIO、跨行/跨页拆分、一致性DMA与load顺序重取 | O3-T10 N1–N6及spec12.8 | **N1–N6分层验收通过**（cloud_chen）；最终收尾提交同SHA总门禁结论以T10报告规定的acceptance.json中passed=true生效；详见 [T10报告](tasks/O3-T10-report.md)。Y11/B36与MMIO中断退休问题已修复；不含SoC/FPGA |
| L8c | 推测load越过地址未知的更老store | 待冻结任务与门禁 | 未开始 |
| L9 | F/D：拆分 CVFPU、FP 重命名、fflags/FS 退休、浮点访存/RVC | T07 定向 cocotb + 整核 FP 自查 + 回归；ACT4 推迟到 FPGA | **单槽 replay 等待环修复，本次指定门禁通过；完整合同验收未完成**（`f0f4106`）：Alan Memory IQ 2/2、整数 replay 自查 121 周期/20 退休、完整 FP 自查 1860 周期/616 退休（另 1 trap）、顺序 FP 与既有五项回归 PASS，lint 0 errors；历史T07采用load按序发射；L8a已改为双发射事件重放，见T09报告；历史证据见 [T07 报告](tasks/O3-T07-report.md) |
| L10 带已知问题收口 | S/U、Sv39 MMU、SFENCE.VMA/satp/PMP、A/D、WFI | T08a→b→c 定向门禁；2026-10-07 用户修订 | T08a `8610b9a`、T08b `2e5333b` 已通过指定既有门禁；T08c `1d0d6f8` 已接入队头 D/CAS/年轻访存排序，Alan 同 SHA 38套件132/132、八项既有整核回归、T08a 全部与 AD 正向程序通过，lint 0 errors。完整 VM 在 cause 15 / PC 0x800001c4 的旧分支断言失败保留，详见 [T08 报告](tasks/O3-T08-report.md)。X2：TLB hit-under-miss/单 miss 槽/单 PTW；X8：SFENCE 先等 SQ 写完成再 PTW idle。L10历史收尾；L8a当前状态见L8a行，L11未开始 |
| L11 | SoC（LiteX，B52）：L2 + DDR4（LiteDRAM）+ CLINT/PLIC + UART + SD（L11 spec 重选）+ SD DMA + FASE | 仿真启动 OpenSBI + Linux；上板经 SD 卡启动 Linux | 未开始 |

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
| `frontend/frontend.sv` | **L8a接口接入**：ICache公开Read/ReadData链路与共享PTW，原取指/恢复/精确同步连线保持 | VM_AD=1已在T10通过；预取性能与平台留后级 | 既有前端套件及M5/M6取指回归；见T09报告 |
| `frontend/icache.sv` / `icache_mshr.sv` | **L8a目标实现**：四行MSHR、按PA合并、公开Read/ReadData整行回填，保留ITLB及异常身份；无I目录/IRecall | 预取性能未验收；VM_AD=1已在T10通过 | M4 seed1/7/29各4/4、M5/M6既有取指回归；见T09报告 |
| `memory/l2_home.sv` / `l2_slots.sv` / `l2_probe_engine.sv` / `l2_mem_engine.sv` | **L8a目标实现**：512×8、8慢槽/2Put槽/2写回槽、组保护、D目录、Down/Inv、AXI分ID回填与B前保留写回；旧l2_cache/recall/DMA协调器删除 | DMA/AMO/MMIO留L8b/L11 | M1压力/槽满/默认23例、M3八组合与真实AXI代理；见T09报告 |
| `frontend/itlb.sv` / `lsu/dtlb.sv` | **L8a接口适配**：DTLB双查询共享数组，I/D各单miss槽、单共享PTW；保留ASID/G/权限/SFENCE/epoch | VM_AD=1已在T10通过；不宣称多walker | MMU seed1/7/29各7/7、公开PTE独立各2/2；见T09报告 |
| `lsu/ptw.sv` / `walk_cache.sv` | **L8a接口适配**：单walker/PMP/PMA/epoch规则保持，PTW物理读走公共访存协议 | VM_AD=1已在T10通过；单walker | M2 PMP客户端、M3物理序列、M4 MMU/PTE与整核AD；见T09报告 |
| `lsu/pte_ad_updater.sv` | **L8a接口适配**：公共PTE CAS、队头D owner/重遍历、接受事务drain，AD内部请求具来源授权 | reservation/AMO留后级 | M2 CAS/PMP、M3 A/D序列、M4 D-refresh回归及整核AD；见T09报告 |
| `lsu/dcache.sv` / `dcache_mshr.sv` / `dcache_writeback.sv` / `dcache_probe.sv` | **L8a目标实现**：64×8/八bank/四MSHR/二WB、双S2重放、整行install/probe/WB、保留资源、STA授权RFO与SQ drain | AMO/跨行/MMIO/DMA留后级；FENCE.I不扫描DCache | M2 MSHRS1/4为26/28例、M3八组合各5例、M6 64KiB自查与统计；见T09报告 |
| `backend/store_queue.sv` | **L8a目标实现**：双地址执行/双转发查询，最近完整覆盖旧store、SQ事件唤醒与队头drain，DTCM路径移除 | 跨行/AMO/MMIO留后级 | M4 seed1/7/29各6/6、M5/M6原数据golden与AD；见T09报告 |
| `backend/backend_issue_queue.sv` | **L8a目标实现**：MEM双发射，删除旧按序load及allow_load门控；源域/唤醒及INT/BR/FP结构保留 | FP提前唤醒及性能优化留后级 | M4直接IQ3/3、L3 kind0/1/2×seed1/7/29；既有early_wakeup原断言通过；见T09报告 |
| `backend/load_store_unit.sv` | **L8a目标实现**：双管道/双翻译，每路二项结果FIFO与在途预留；内部AD/PTW/SQ来源优先；D刷新只重验证owner，年轻LQ等完成/取消 | 跨行/跨页/MMIO/AMO留后级；单D owner | M4 seed1/7/29各6/6、L5异常2/2，AD定向首失修复及M5/M6；见T09报告 |
| `frontend/fetch_return_queue.sv` | **闭环简化（L7a）**：单槽身份匹配、年龄清除；kill 拍保留槽接收匹配响应 | 单槽吞吐限制保留，多项返回队列留后级 | T05b `b122d59` Alan 3/3 PASS；本次未改行为 |
| `frontend/rvc_expander.sv` | **闭环简化（L9）**：整数 RV64C 加四条浮点 RVC，C.LUI nzimm 修正 | 完整 ISA 一致性留后级 | Alan 3/3 PASS（`50ff873`），含 FP RVC 与 C.LUI；顺序整核 PASS |
| `frontend/ifu_f0.sv` | **闭环简化（L7b）**：四条/拍、首拍出队、hold/pend、整数 RVC 展开、edge/D34、kill/截断 | 浮点 RVC 在 L9；ITLB/PTW 在 L10 | Alan 6/6 PASS，含 120 拍 RV64I 随机事务 |
| `frontend/ifu_f1.sv` | **闭环简化（L7b）**：按长度/位置 a～f 核对；直接截断、零指令拍 c′、寄存式请求 | 完整 ISA 一致性留后级 | Alan 18/18 PASS，保留 L7a 17 项 |
| `frontend/redirect_arbiter.sv` | **闭环简化（L7a）**：四源年龄仲裁、busy 替换、接受拍计数；F1 寄存请求已接入 | SYS committed 上下文仍为已知边界 | Alan 仲裁器 2/2、l7_recovery 2/2 PASS；T06 复验通过 |
| `frontend/fetch_buffer.sv` | **闭环简化（L7a）**：按 FTQ 身份/槽位选择性保留，kill 拍阻塞握手 | 吞吐与综合时序留后级 | Alan 2/2、l7_recovery 2/2 PASS；T06 复验通过 |
| `system/hpm_counters.sv` / `system/csr_file.sv` / `system/backend_perf_events.sv` | **L10/L8a接入**：保留特权CSR/epoch规则，新增DC/L2/MSHR/RFO事件编码0x2a～0x37并沿用原HPM选择/增量链路 | 平台PMU、FPGA验证留后级 | 同SHA CSR10/10、HPM19/19，保留原逐拍增量检查并新增14项L8a事件覆盖；整核统计见T09报告 |
| `system/commit_ctrl.sv` / `system/wfi_ctrl.sv` | **L8a适配**：FENCE.I数据侧下一拍clean_done、busy=0、不扫描DCache；保留特权/SFENCE/needs_D精确退休规则 | DMA/fatal与平台留后级；VM_AD=1已在T10通过 | M4 commit6/6，既有WFI与特权/AD回归；见T09报告 |
| `common/pmp_checker.sv` / `common/pma_checker.sv` | **L8a/X5**：16项G=2，PA高位先检查再截断；物理主存仅0x80000000～0x801fffff，旧DTCM拒绝 | MMIO在L11；VM_AD=1已在T10通过 | 原PMP/PMA2/2（保持边界/随机规模）、M2所有内部来源拒绝用例；见T09报告 |
| `frontend/frontend_sync_ctrl.sv` / `backend/decoder.sv` | **闭环简化（L10/L8a）**：原精确同步/操作数x0身份保持；FENCE.I数据侧按L8a在下一拍确认 | 完整ISA一致性留后级 | 既有sync/decoder与M6共享代码数据行自查；见T09报告 |
| `frontend/frontend.sv` | **L8a接口接入**：ICache公开Read/ReadData链路与共享PTW，原取指/恢复/精确同步连线保持 | VM_AD=1已在T10通过；预取性能与平台留后级 | 既有前端套件及M5/M6取指回归；见T09报告 |
| `backend/backend.sv` | **L8a总装**：双访存结果/三INT二FP写口、公开L2/PTW/PTE接口、SQ/LQ独立AD唤醒；mispredict/flush不消费LSU异常 | VM_AD=1已在T10通过；平台在L11 | backend2/2、backend_control1/1、M4旧异常FIFO及M5/M6；见T09报告 |
| `backend/rob.sv` | **闭环简化（L10）**：原四宽退休/FP/trap，保存 SFENCE 第二 preg 与 needs_D；mark/clear/idx 使任何包含 D 未完成项的前缀停止 | L5 已知问题/完整一致性见报告 | T08c ROB 4/4（含旧前缀可退、D 项及年轻项等待）；整核 AD 正向程序通过 |
| `backend/uop_queue.sv` | **闭环简化（L3）**：四宽、16 项、bank/回绕/满空/前缀握手/M flush | 更深流水按 B42 时序触发 | Alan WQ 900 周期 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/rename_stage.sv`、`rename_map_table.sv`、`free_list.sv` | **闭环简化（L9）**：INT/FP 独立预算与映射、src3 RAW、f0/p0、共享 tag 恢复 | R1/R2 按 B42 时序触发 | L9 顺序整核功能覆盖；本模块独立门禁未运行；此前 O3-T01 证据仅对应旧版 |
| `backend/branch_checkpoint_file.sv` | **闭环简化（L3）**：C 释放/清 parent 与不同 tag create 合并；只看拍初空闲，不同拍复用 | 系统整体恢复待 L5 | Alan CK full/C/M 700 周期 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/rename_dispatch_queue.sv`、`dispatch_stage.sv` | **闭环简化（L9）**：四宽前缀增加 FP 分流；FP 访存走 MEM，异常只消费 RDQ | 后续级 AMO 等 | L9 顺序整核功能覆盖；本模块独立门禁未运行；RDQ 本次未改 |
| `backend/backend_issue_queue.sv`、`prf_read_arbiter.sv` | **L8a读口适配**：双Memory发射使用INT 6R/FP 8R预算，保留分域源身份与就绪/唤醒合同 | FP提前唤醒及独立完整合同留后级 | M4真实PRF仲裁、IQ kind0/1/2及既有RR/early_wakeup；见T09报告 |
| `backend/branch_unit.sv`、`alu_pipe.sv` | **闭环简化（L3）**：one-shot C/M 与 JAL 链接解耦；ALU 独立 kill 保留旧 Result | JALR 在 L6；L7b IALIGN=16 已接入，完整目标边界留后级 | Alan 缺口 2 具名/700 事务 DUT/真实 WB 竞争与总装 C 合同 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/load_queue.sv` | **L8a目标实现**：原VA/uop/generation保存，按MSHR install/error/free、TLB、SQ、AD事件等待/唤醒，两路选择重试；C/M身份规则保留 | 跨行/AMO与完整一致性留后级 | M4 seed1/7/29各6/6，M3随机与M6整核；见T09报告 |
| `core/o3_core.sv` | **L8a总装**：新L2Home、公开whole-line链路、双访存与性能事件，删除DTCM/旧L2数据路径 | VM_AD=1已在T10通过；L8b/L11未开始 | M5单管道与M6默认全部目标及run-l8a-mem；见T09报告 |
| `sim/o3/` | **L8a验收接入**：AXI RAM 2MiB、JSONL v2、双配置参数、只读MSHR/RFO/bank统计、独立run-l8a-mem参考与严格成功tohost截止前缀比较 | VM_AD=1已在T10通过；Spike/ACT4/SoC/FPGA不在本次范围 | 同SHA M5/M6全部原自查与退休前缀、比较边界5例；周期/前缀/尾部/统计见T09报告 |

## 3. 其他模块状态概览

以下保留2026-10-03历史概况；当前相关模块以第2.4节及L8a行为准，旧L2/recall/DMA协调器已删除，ICache MSHR已接入公开协议：

- **单模块实现、有 cocotb**：`ubtb`、`main_btb`、`tage`、`ras`。
- **本轮新增局部 cocotb**：`branch_recovery`（BRU/重定向/fetch buffer/ALU kill，Alan 1/1 PASS，`de9149d`）、
  `l2_cache`（2 项）、`dcache` 空副本维护口（1 项）；
  `icache` recall 回归（3 项合计）、`backend` 整核缓存路径（1 项）已在 Alan 通过。
- **单模块实现、有 SV testbench**：`ftq`（`tb/ftq_tb.sv`）、`branch_history`、`history_snapshot_store`（`tb/` 下，仅记录过 lint）。
- **单模块实现、无独立 cocotb**：`fetch_buffer`、
  `decoder`、`axi_master`、`simple_data_sram`；后端主要队列/rename/资源合同已有 O3-T01 cocotb，见上表；
  L1 整核冒烟仅覆盖本轮四条 addi 的路径。
- **空壳/待扩展**：`lsu/*` 的 AMO/DMA/完整维护路径、`system/*` 的后级部分、
  `l2_recall_ctrl`/`dma_line_coord`、`icache_mshr`、预取相关、
  重命名新结构（`rename_dep_r1` 等）、`O3.sv`/`Tile.sv`。

`backend.sv` 保留当前实际数据流，2026-10-02 搭建但未接入的非 L3 目标实例已移除。O3-T01 已移除本级后端空壳实例及独占 filelist 条目；文件保留。
归属：入口/提交/CSR/trap L5，M/FIFO/融合 L6，性能计数 L7，数据预取/非阻塞访存/AMO/LRSC L8，FP L9，PTW/A-D/WFI/PMP/PMA L10，fatal/L2-recall/DMA 协调 L11。
R1 依赖与级间暂存按 B42 综合时序触发，不指定 Ln。

## 4. 已知的文档不一致

- `doc/CISLC_O3.md` 的"当前实现状态"描述的是旧数据流，并引用已删除的
  `rtl/frontend/ifu.sv`、`rtl/backend/issue_queue.sv`。
- `doc/CISLC_O3_frontend.md` 中描述 `ifu.sv` 状态机的章节已失效。
- `rtl/common/o3_cfg_pkg.sv` 保留未使用的空宏 `` `O3_TBD ``；backend 相关过期说明已在 O3-T01 修正。

- B49（2026-10-07）取代 B31 跨 line 报异常：L10 已修正触及模块注释，旧跨 line 异常身份/计数仍保留；硬件跨 line/跨页拆分留 L8。历史 `backend_perf_events.sv` 的旧目标描述待 L8 触及时修正。

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
| `backend/backend.sv` | **L8a总装**：双访存结果/三INT二FP写口、公开L2/PTW/PTE接口、SQ/LQ独立AD唤醒；mispredict/flush不消费LSU异常 | backend2/2、backend_control1/1、M4旧异常FIFO及M5/M6；见T09报告；边界：VM_AD=1已在T10通过；平台在L11 |
| `backend/physical_regfile.sv`、`preg_ready_table.sv` | **L8a/X3**：INT 6R/3W、FP 8R/2W，FP p0普通寄存器；实际写口同拍旁路/ready保持 | M4真实PRF仲裁、M5/M6整数及FP回归；非独立完整PRF合同证明 |
| `backend/fpu/fpu_{fma,divsqrt,misc,conv}_fu.sv` | 直接拆分 opgroup；8 项身份侧表、killed 保留到终结、共同结果保持、FMV 旁路轮转 | Alan FU 2/2 PASS（含 32 组固定种子加法）；顺序整核 PASS |
| `backend/fp_writeback_arbiter.sv`、`writeback_arbiter.sv`、`rob.sv` | **L8a写回接入**：双load头按年龄竞争3 INT/2 FP写口，完成槽随两管道展开；保留kill/flush与FP flags规则 | 经用户批准迁移的WB fixture保持原背压/kill检查，另检查更老load完成；M4旧异常FIFO及M5/M6，见T09报告 |
| `backend/load_store_unit.sv` | **L8a目标实现**：双管道/双翻译，每路二项结果FIFO与在途预留；内部AD/PTW/SQ来源优先；D刷新只重验证owner，年轻LQ等完成/取消 | M4 seed1/7/29各6/6、L5异常2/2，AD定向首失修复及M5/M6；见T09报告；边界：跨行/跨页/MMIO/AMO留后级；单D owner |
| `system/commit_ctrl.sv`、`csr_file.sv` | 实际退休 OR flags、写 FPR/flags 置 Dirty、CSR 写/FS Off/保留 frm 与 SD | Alan CSR 4/4 PASS；commit_ctrl 经整核覆盖，独立门禁未运行 |
| `third_party/cvfpu`、`rtl/rtl.f`、`scripts/cvfpu.vlt` | 固定 gitlink 和 common_cells；统一文件清单与限定 CVFPU BLKANDNBLK 豁免 | Alan lint PASS：0 errors / 361 warnings，固定依赖工作树无修改 |

B33 闭环简化：FP FU 不发提前唤醒；INT/FP 消费者由真实目的域 PRF 写授权唤醒。
**代码 SHA `50ff873817305dc2696de1f7457fda1b80c337dd` 已推送。** Alan 9/9 模块用例、
`run-l9-fp-smoke`（890 cycles / 267 retires）与五项既有整核回归通过。
`run-l9-fp` 保留 FAIL：年轻 load 进入单槽 replay 后禁止更老 load 发射，
阻塞依赖该老 load 的 store；纯整数复现也 FAIL。未修改访存设计或删除失败用例。
本次仅记基本执行功能验证；完整 L9 spec 门禁、Spike/ACT4、综合/FPGA/SoC 未运行。

2026-10-07 后续修复更新：上述 `50ff873` 等待环 FAIL 为历史记录；最新代码
`f0f410640a27abe4f62f3cf728f387ab8b6bde6e` 已推送并在 Alan 独立目录通过本次全部指定门禁。
当时Memory IQ load按序发射，store/replay门控保留；这是历史B04/L3简化，当前L8a已替换为双发射事件重放。`run-replay-order` 为 121 周期/20 退休、1 replay；`run-l9-fp` 为
1860 周期/616 退休、1 个预期 trap、2 replay，均 tohost=1。Memory IQ 2/2、lint 0 errors，
顺序 FP 与五项既有回归全部通过，完整命令/exit code 见 [T07 报告](tasks/O3-T07-report.md)。
全套 L9 合同验收仍未完成；本次未运行 Spike/ACT4、访存类 cocotb、综合/FPGA/SoC。

### 2026-10-07 L10 收尾证据

代码 `1d0d6f8369fa69476d07538157be234a88db08bf`；Alan GitHub 独立 clone
`/home/chen/FUN/CISLC-O3-runs/20261007-t08c-1d0d6f8/`，完整命令/exit/log 在 `evidence/final/`。
38 套件 132/132（FAIL/SKIP=0）；八项既有整核回归、T08a 特权与 AD 正向整核通过；
完整 VM cause 15 与正确分支解析同拍触发旧推进断言，保留为已知问题。
跨模块合同与全部自行决定、复现命令见 [T08 报告](tasks/O3-T08-report.md)。
本段是T08历史收尾记录；当前L8a状态见上表及T09报告，L11未开始。

### 2026-10-08 L8a 收尾证据

O3-T09限定非阻塞访存底座；M1～M6与最终spec12.8证据、实际cloud_chen预检、完整SHA/命令/exit/XML/原trace、M5→M6周期与统计见 [T09报告](tasks/O3-T09-report.md)。退休比较采用用户批准的成功tohost截止前缀，仅豁免同拍后槽位的终止自跳转；没有扩大其他例外。完整VM仍失败，首点为PTE A位检查PC0x80000204，未宣称VM通过；不含Spike/ACT4/litmus/综合/FPGA，L8b/L8c未开始。


### 2026-10-08 L8b 收尾证据

O3-T10的N1–N6分层门禁已通过。用户批准B36成功置A时的物理行广播与年轻load重取；四宽ROB退休前缀不得跨过order标记。MMIO触发中断的外部写效果必须先退休，backend保护覆盖HEU完成到退休的空隙。N6原子、MMIO、拆分、DMA程序全部自查/tohost通过，MMIO副作用96次、拆分事件55的精确检查保持。新增模块mem_head_unit、dcache_amo_unit、lrsc_reservation、mmio_axil_master、dma_line_adapter由N1/N2/N4/N6验证。证据与自行决定见[T10报告](tasks/O3-T10-report.md)。

本收尾提交冻结后完整新跑12.8；最终同SHA结论仅在报告指定acceptance.json的sha匹配且passed=true时生效。L8c与L11未开始；未运行Spike/ACT4/litmus/综合/FPGA。
