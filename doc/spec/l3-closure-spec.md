# O3-T01 阶段一：L3 收尾 RTL spec（冻结候选）

日期：2026-10-05。分支：`feat/L1-closure`。审计快照：`711c762`（第 0 步文档采纳提交）；RTL 与进入任务时的 `9ec5591ecd9e8b6e25428c48d78c60d78c33870c` 相同。下述文件行号均指该快照，区间写法为 `文件:起始行–结束行`。

依据：[任务书](../tasks/O3-T01-l3-closure.md)“阶段一”、[v1 计划](../O3-v1-plan.md)、[后端基线](../design/CISLC-O3-BACKEND-DESIGN-BASELINE.md) B12/B42/B46。**状态：冻结候选，待用户确认。第 7 节 U1～U6 已由审阅给出决定（2026-10-05）；用户宣布冻结后才是阶段二实施授权。** 本轮仅阅读代码和编写文档；未修改 RTL、测试程序或 Makefile，未运行功能仿真。源码核实、未来要求、未决选择分别标明。

## 1. 边界与保留的合同

- B42：Decode/Rename/Dispatch/Commit 统一四宽，B02 两拍 rename 暂缓；不是增加四条执行管线。当前 decode/dispatch/commit 已为 4，rename 为 6，ALU 为 2、整数 PRF 为 4 读/2 写（`rtl/common/o3_cfg_pkg.sv:279`、`:345–368`）。
- B12 与任务书：预测正确解析不能额外阻止任何一级推进；误预测保留现有恢复边界，分支自身及更老项存活，年轻项不产生副作用。解析和链接值写回解耦的现状见 `rtl/backend/branch_unit.sv:66–96`、`:109–158`。
- B46：移除本级不需要的后端目标实例及其独占文件清单条目，保留文件；不把实际 L3 DCache 当作空壳删除（有效连接见 `rtl/backend/backend.sv:954–988`、`:1809–1833`）。
- 不实现 Spike、CSR/trap、M/F/D、预测器升级、MMU、AMO、新访存机制；这些是后续阶梯。现有单 replay 槽和单 pending load 仍按原合同工作（`rtl/backend/load_store_unit.sv:240–265`、`:385–449`）。
- 阶段二的允许改动范围以任务书为准。本文列出范围外的依赖和测试需求，并不授权修改它们；范围接缝见 U6。

## 2. 宽度变更影响清单

检索范围为仓库源码、测试、脚本及 `tb/`；使用 `rg -n 'BACKEND_MACHINE_WIDTH|rename\.width|RENAME_W|RENAME_SLOT_W|BE_PERF_INC_W'` 核对直接使用者。下表包含直接消费者、类型派生及已经核实的关键间接接口。未通过四宽展开或仿真核实的行为均为未来要求，不记为已通过。

### 2.1 配置与实际数据流

| 文件和位置 | 当前用法；6→4 的影响 | 阶段二需要做/验证的内容 |
| --- | --- | --- |
| `rtl/common/o3_cfg_pkg.sv:164`、`:346–359` | rename 配置 6；Decode Queue 深度 18；decode/dispatch 已为 4 | rename 数值改为 4，相关 B01 注释改按 B42；容量不能直接沿用 18，见 U1 |
| `rtl/common/o3_pkg.sv:31–41` | `BACKEND_MACHINE_WIDTH` 已直接取 rename 配置，不是“未来接入” | 值随配置变 4；旧注释与事实不符，注释修改范围见 U6 |
| `rtl/common/o3_types_pkg.sv:531–541`、`:675–688`、`:1078–1079` | `RENAME_W` 6→4；R1 生产者 slot 位宽 3→2；性能事件增量位宽 `$clog2(W+1)` 仍为 3 | 类型自动推导；不接入 R1/性能空壳，不手工复制宽度常数 |
| `rtl/backend/backend.sv:67–83`、`:164`、`:183–185`、`:518–542`、`:619–632`、`:377–379` | rename/分配数组变 4 lane；lane count 位宽仍为 3；退休计数/旧 FTQ count 仍可表示 0～4 | 所有原子分配和 checkpoint tail 前缀计算限制到实际接受的 0～4 条；decode/dispatch/retire 维度仍各为 4 |
| `rtl/backend/uop_queue.sv:46–68`、`:105–153`、`:188–192` | dequeue 6→4，enqueue 为 4；bank 数 6→4；18 项不满足整除断言，`ROWS_PER_BANK` 会整数截断 | U1 冻结容量后再实现；验证各 head/tail 偏移、回绕、0～4 前缀接受、满/空/同拍进出、flush |
| `rtl/backend/rename_stage.sv:22`、`:64–118`、`:123–179` | 单拍资源前缀及 uop 输出 6→4 | 保持最老连续前缀和 preg/ROB/LQ/SQ/checkpoint/RDQ 原子接纳；资源不足不得部分分配一条指令 |
| `rtl/backend/rename_map_table.sv:33–38`、`:80–118`、`:134–165` | INT 映射读与组内 RAW/WAW 旁路循环缩为 4；commit 仍为 4 | 验证最近旧 lane 优先、同名多写、x0、分支自身目的映射进入快照；参数传播不要求改算法 |
| `rtl/backend/free_list.sv:31–35`、`:78–103`、`:121–162` | 每拍候选分配 6→4，提交释放仍 4；容量不随宽度变化 | 验证 0～4 分配与同拍释放、allocation mask、恢复回收；不把本拍释放自动旁路进候选集合 |
| `rtl/backend/branch_checkpoint_file.sv:28–45`、`:68–119` | 候选 tag/新建数组 6→4，checkpoint 数仍 16（配置 `rtl/common/o3_cfg_pkg.sv:352`） | 验证四个分支的不同 tag、父 mask、tail；正确解析与 create 的合并要求见第 4 节及 U2 |
| `rtl/backend/rob.sv:58`、`:186–220`、`:225–270`、`:354–397` | 分配端 6→4；退休宽度仍为 4 | 验证 ROB 满/回绕、同拍 allocate/complete/retire，以及正确解析拍的计数和顺序 |
| `rtl/backend/rename_dispatch_queue.sv:18–30`、`:58–84` | enqueue 6→4，dequeue 仍 4；计数仍 3 bit，深度不变 | 验证同拍 rename/dispatch/解析，传入的新项 mask 必须已经清理；不要依赖旧项扫描替新项清位 |
| `rtl/backend/preg_ready_table.sv:31–45`、`:59–69` | 新分配目的寄存器输入 6→4；写回端口数不随之改变 | 验证分配置 busy、合法写回置 ready，且被 kill 的结果不产生 ready/wakeup |
| `rtl/backend/load_queue.sv:28`、`:34–52`、`:103–110`、`:138–192` | 分配 6→4；release count 仍 3 bit，release 循环缩为 4 | 四条 load 同拍退休计数不丢失；验证分配/释放/响应/解析相交；LQ 身份代际机制本任务不升级 |
| `rtl/backend/store_queue.sv:35`、`:42–46`、`:167`、`:320–351` | 分配端 6→4，commit 端由提交宽度决定，仍 4 | 验证多 store 分配、提交和独立后台 drain；恢复保留 committed store |
| `rtl/frontend/ftq.sv:107`、`:126–129`、`:250–257` | 旧合同 release/train lane 数 6→4；旧输出已 tie-off | 目标提交端依赖 `COMMIT_W`，不是此旧参数；前端旧端口未连接（`rtl/frontend/frontend.sv:275–278`）。不凭此声称 FTQ 退休回收已连接，见 U3 |
| `sim/cocotb/store_queue/store_queue_tb_top.sv:31–49` | 测试包装数组随 rename 宽度变化，但只驱动 lane 0 | 现有单 lane 测试不能证明四 lane 分配；阶段二扩展包装/测试，输出配置并由模型读取 |

### 2.2 直接使用 rename 宽度、但本级移除的目标实例

| 文件和位置 | 宽度影响 | 本级处置 |
| --- | --- | --- |
| `rtl/backend/mul_fusion_detect.sv:37–50` | uop/count/pair_head 变为 4 lane | 移除实例和独占 filelist 条目，L6 才接入 |
| `rtl/backend/rename_entry_gate.sv:28–51` | uop/count/accepted_count/pair_head 变为 4 lane | 移除未连接实例；L5 起按串行机制接入 |
| `rtl/backend/rename_dep_r1.sv:27–38` | 输入 4 lane，依赖类型 slot 2 bit | B42 暂缓，不实施；固定 Ln 未确认，见 U5 |
| `rtl/backend/rename_stage_buffer.sv:23–47` | 固定槽/依赖/accept_mask 变为 4 lane | 与 R1 一起暂缓，固定 Ln 未确认，见 U5 |
| `rtl/backend/backend.sv:1632–1667` | 上述空壳连线及 `t_r2_accept_mask` 随之变宽 | 随实例一起删掉无人使用的连线，不留悬空“目标网络” |

### 2.3 间接带宽与证据限制

Dispatch/IQ enqueue 由 dispatch=4 决定，INT issue=2、MEM/BR issue=1（`rtl/backend/backend_issue_queue.sv:40–48`）；PRF 读写口由执行配置决定（`rtl/backend/backend.sv:170–171`），均不会因为 rename=4 自动变为四发射。整核退休包装仍按 commit_width=4 导出（`sim/o3/o3_tandem_top.sv:25–35`、`:92–100`），现有 backend 测试只期望四条 addi（`sim/cocotb/backend/test_backend.py:45–52`）。四宽持续 rename、满队列回压及恢复交错是否正确：**未确认，待阶段二测试**。

## 3. 空壳移除清单与 tie-off 边界

### 3.1 后端实例清单

这里的“移除”指阶段二计划，阶段一没有修改任何实例。所有行均以 `rtl/backend/backend.sv` 实际实例连接为依据；同文件末尾“全部空壳”的总注释不能替代逐项核实。

| 模块/实例；当前位置 | 所属级/触发条件 | 移除后信号处置 |
| --- | --- | --- |
| `mul_fusion_detect/u_mul_fusion_detect`：`rtl/backend/backend.sv:1638–1644` | L6，B34 | `t_fuse_uop/t_fuse_pair_head` 只服务待移除入口/R1 网络（`:1648–1681`），删除局部网络，无外部输出需 tie-off |
| `rename_entry_gate/u_rename_entry_gate`：`rtl/backend/backend.sv:1646–1658` | L5 首次 CSR 串行入口；WFI/fatal 后续分别 L10/L11 | 删除 `t_gate_pass_count/t_csr_block_younger_cycle` 及无消费者的入口阻塞线；不阻止正在工作的旧 rename |
| `rename_dep_r1/u_rename_dep_r1`：`rtl/backend/backend.sv:1669–1673` | B42：rename 时序成为关键路径后；固定 Ln **未确认**（U5） | 删除 `t_r1_dep` |
| `rename_stage_buffer/u_rename_stage_buffer`：`rtl/backend/backend.sv:1675–1687` | 与 R1 相同 | 删除 `t_rsb_* / t_r2_accept_mask`，保留旧单拍 rename |
| `rename_map_table/u_fp_rename_map_table`：`rtl/backend/backend.sv:1691` | L9 | 空连接，无输出需要 tie-off；保留 INT 实例和共享模块文件 |
| `free_list/u_fp_free_list`：`rtl/backend/backend.sv:1692` | L9 | 同上，保留 INT free_list 文件 |
| `preg_ready_table/u_fp_preg_ready_table`：`rtl/backend/backend.sv:1693` | L9 | 同上，保留 INT ready 表文件 |
| `physical_regfile/u_fp_physical_regfile`：`rtl/backend/backend.sv:1694` | L9 | 同上，保留 INT PRF 文件 |
| `backend_issue_queue/u_fp_issue_queue`：`rtl/backend/backend.sv:1696–1697` | L9 | 未连有效事务端口；保留 INT/MEM/BR IQ 文件 |
| `mul_execute_unit/u_mul_execute_unit`：`rtl/backend/backend.sv:1706–1712` | L6，B43 | 删除无人消费的 `t_mul_resp_valid/t_mul_resp/t_mul_bypass/t_mul_wake`（写回 extra 未接：`:1012`） |
| `div_execute_unit/u_div_execute_unit`：`rtl/backend/backend.sv:1713–1719` | L6 | 删除同类 `t_div_*`；不加入新的除法机制 |
| `fpu_fma_fu/gen_fma[*].u_fpu_fma_fu`：`rtl/backend/backend.sv:1723–1727` | L9 | 删除 generate 块；当前只连 clk/rst/resolution，没有活跃响应连接 |
| `fpu_divsqrt_fu/u_fpu_divsqrt_fu`：`rtl/backend/backend.sv:1728` | L9 | 无有效输出连接需保留 |
| `fpu_misc_fu/u_fpu_misc_fu`：`rtl/backend/backend.sv:1729` | L9 | 同上 |
| `fpu_conv_fu/u_fpu_conv_fu`：`rtl/backend/backend.sv:1730` | L9 | 同上 |
| `fp_writeback_arbiter/u_fp_writeback_arbiter`：`rtl/backend/backend.sv:1731–1733` | L9 | 当前只连 rob_head/resolution，无活跃 PRF/ROB 写回输出 |
| `ptw/u_ptw`：`rtl/backend/backend.sv:1773–1789` | L10，共享 MMU | 对外 ITLB ready=0、resp='0、idle=1（本级不存在 walker）；LSU 侧 `t_dtlb_ptw_req_ready=0/t_ptw_resp='0`；DCache 侧 PTW 请求 valid=0、载荷='0 |
| `pte_ad_updater/u_pte_ad_updater`：`rtl/backend/backend.sv:1792–1807` | L10，B36 | DCache `t_dc_pte_ad_valid=0/t_dc_pte_ad_req='0`、`t_rsv_pte_ad_conflict='0`；内部 rewalk/A/D 网络无消费者时删除 |
| `data_prefetcher/u_data_prefetcher`：`rtl/backend/backend.sv:1836–1841` | v1 计划未单列数据预取所在 Ln，**未确认**（U5） | DCache `t_pf_req_valid=0/t_pf_req='0`；不伪造完成应答 |
| `commit_ctrl/u_commit_ctrl`：`rtl/backend/backend.sv:1858–1880` | L5 起精确提交/系统，屏障 L8、FP L9、MMU L10 | `sys_redirect_o='0/fe_sync_valid_o=0/fe_sync_o='0`；DCache `t_dc_clean_all_req=0/t_rsv_clear_valid=0`；LSU `t_sfence='0`；`ftq_commit_o` 不能未经 U3 决定永久 tie-off |
| `csr_file/u_csr_file`：`rtl/backend/backend.sv:1883–1893` | L5 M CSR，L10 完整特权/MMU | `fe_csr_o/t_dmmu_csr/fe_pmp_o/t_pmp` 需明确静态语义，值**未确认**（U4）；不能把全零自动当作 M-mode/PMP allow-all |
| `trap_ctrl/u_trap_ctrl`：`rtl/backend/backend.sv:1896–1901` | L5 | `t_trap_*` 只连待删除系统网络，整体删除；系统重定向已在 commit_ctrl 行明确禁用 |
| `wfi_ctrl/u_wfi_ctrl`：`rtl/backend/backend.sv:1903–1907` | L10 | 删除只连空壳入口/提交控制的 `t_wfi_stall/t_wfi_retire`；旧数据流不接 WFI |
| `fatal_err_ctrl/u_fatal_err_ctrl`：`rtl/backend/backend.sv:1912–1916` | L11，B39 | `fatal_o=0` 标明“本级尚未实现 fatal 隔离”，删除无消费者的 `t_isolate/t_fatal_evt`；不得声称故障已被处理 |
| `backend_perf_events/u_backend_perf_events`：`rtl/backend/backend.sv:1918–1922` | 硬件性能计数落地级**未确认**（U5），L7 要求性能基线并不自动指定此模块 | `perf_rd_data_o='0`，明确本级未支持读计数器；保留旧退休计数 `retired_inst_count_o`（`:570`、`:1542–1543`） |

Tie-off 必须写本级原因；未使用的载荷置零表示无事务，ready=0 表示不接受。没有 PTW 的 idle=1 只表示没有 walker 在途，不能当作已完成翻译。内部 `t_rsv_clear_reason` 在 valid=0 时仍需确定的合法枚举值；具体编码实现前核对类型，当前未确认。不增加成功响应来掩盖未实现功能。

### 3.2 必须保留的实际路径

保留 `u_dcache` 及与 LSU/SQ/L2/probe 的全部有效连接（`rtl/backend/backend.sv:870–890`、`:954–988`、`:1809–1833`）。其 SRAM 阵列、miss FSM、refill/writeback/probe 已有逻辑（`rtl/lsu/dcache.sv:245–337`），与独立空壳 `dcache_mshr/dcache_writeback` 不等价。保留 INT rename、INT free_list/PRF/ready、ROB、LQ/SQ、三个 IQ、ALU、BRU、LSU 和 DTCM（对应连接 `rtl/backend/backend.sv:689–1060`；DTCM 在 `rtl/backend/load_store_unit.sv:344` 起）。不扩大到删除历史 DTCM。

### 3.3 filelist 删除清单

下表每行均只删除 `rtl/rtl.f` 条目，不修改/删除对应 SV 文件。共享模块只移除 FP 实例，**不删 filelist**：`free_list/rename_map_table/preg_ready_table/physical_regfile/backend_issue_queue` 仍被有效 INT 路径实例化（`rtl/backend/backend.sv:753`、`:827`、`:918–950`、`:1016`、`:1038`）。

| 模块/文件 | filelist 位置 | 所属级与依赖事实 |
| --- | --- | --- |
| `rename_dep_r1`、`rename_stage_buffer`、`rename_entry_gate` | `rtl/rtl.f:63–65` | 分别对应 §3.1 的 B42 延后、B42 延后、L5；实例移除后不服务实际路径 |
| `mul_fusion_detect` | `rtl/rtl.f:71` | L6 |
| `fp_writeback_arbiter` | `rtl/rtl.f:79` | L9 |
| `fu_completion_fifo` | `rtl/rtl.f:80` | L6，B33；当前只有端口，未实现 FU 内实例化（`rtl/backend/fu_completion_fifo.sv:42–73`、`rtl/backend/mul_execute_unit.sv:68`） |
| `signed_mul65x65`、`unsigned_radix4_divider` | `rtl/rtl.f:87–88` | L6；空壳（`rtl/backend/signed_mul65x65.sv:17–25`、`rtl/backend/unsigned_radix4_divider.sv:18–31`）；后续 MUL 按 B43，不能把旧模块名等同选用旧乘法树 |
| `mul_execute_unit`、`div_execute_unit` | `rtl/rtl.f:89–90` | L6 |
| `fpu_fma_fu`、`fpu_divsqrt_fu`、`fpu_misc_fu`、`fpu_conv_fu` | `rtl/rtl.f:91–94` | L9 |
| `dcache_mshr`、`dcache_writeback` | `rtl/rtl.f:98–99` | L8 完整非阻塞路径；目前是未实例化的独立端口空壳（`rtl/lsu/dcache_mshr.sv:19–52`、`rtl/lsu/dcache_writeback.sv:18–46`），现有 DCache 自带闭环简化 FSM，见 §3.2 |
| `dcache_amo_unit` | `rtl/rtl.f:100` | L8；独立端口空壳（`rtl/lsu/dcache_amo_unit.sv:31–63`） |
| `dtlb`、`walk_cache` | `rtl/rtl.f:102–103` | L10；独立端口空壳（`rtl/lsu/dtlb.sv:26–53`、`rtl/lsu/walk_cache.sv:14–41`） |
| `pte_ad_updater`、`ptw` | `rtl/rtl.f:104–105` | L10；删除后端实例后移出清单 |
| `lrsc_reservation` | `rtl/rtl.f:106` | L8；独立端口空壳（`rtl/lsu/lrsc_reservation.sv:39–69`） |
| `data_prefetcher` | `rtl/rtl.f:107` | 固定 Ln 未确认（U5） |
| `csr_file`、`trap_ctrl`、`commit_ctrl` | `rtl/rtl.f:114–116` | L5 起 |
| `wfi_ctrl`、`fatal_err_ctrl`、`backend_perf_events` | `rtl/rtl.f:117–119` | 分别 L10、L11、固定 Ln 未确认（U5） |

上表之外，filelist 仍列前端待实现文件和独立 L2/DMA 框架（`rtl/rtl.f:34`、`:38–46`、`:126–127`）。本任务没有授权改前端/核心总装；不能只删除仍被实例化的文件。是否进一步移出完全未实例化的 L2/DMA 空壳见 U6（端口空壳位置 `rtl/memory/l2_recall_ctrl.sv:43–87`、`rtl/memory/dma_line_coord.sv:33–62`）。这里不声称已完成全仓 B46 清理。

## 4. 缺口 1：新的控制方程、mask 更新和同拍结果

### 4.1 术语与组合停顿方程

定义周期 N 的拍初状态 `q`，N 末边沿写入 `q'`。`R=branch_resolution_i.valid`，`M=R && branch_resolution_i.mispredict`，`C=R && !branch_resolution_i.mispredict`，`t=branch_tag`。`K(x)=M && x.branch_mask_q[t]`；`clear(x.mask)` 在 R=1 时将原 mask 的 t 位清零，其余位不变。kill **先使用原 mask 判定**，不能用已经 clear 的 mask 判断；现有 helper 定义见 `rtl/common/o3_pkg.sv:489–503`。

以下是 task/B12 要求的局部控制替换。M 拍保留当前 issue/rename/dispatch/retire 阻塞，不增加“误预测拍更老候选继续发射/退休”的优化；在途更老操作的执行、写回和 SQ drain 继续按现有恢复合同。表中正常资源条件与 R 无关，不将“预测正确不停顿”解释为忽略资源满/背压。

| 信号/行为 | 新精确条件 | C=1 时 | M=1 时 | 当前代码位置 |
| --- | --- | --- | --- | --- |
| Decode ready | `uopq_enq_ready && !M` | 与普通拍相同 | 0 | `rtl/backend/backend.sv:558–559` |
| Fetch ready | `!M && (!fetch_entry_valid_q || decode_ready)` | 正常接受/替换 fetch 组 | 0，末边沿清旧 fetch 组 | `rtl/backend/backend.sv:560–562`、`:1608–1616` |
| IQ candidate block | `M`，替换内部选择里的 `resolution_valid_i` 限制 | 选择拍初最老源 ready 项；MEM load 仍受 allow_load 限制 | 不选新候选 | `rtl/backend/backend_issue_queue.sv:105–125` |
| PRF `issue_block_i` | `M` | 年龄仲裁和全部源读口原子授予照常 | grants=0 | `rtl/backend/backend.sv:639–661`、`rtl/backend/prf_read_arbiter.sv:99–175` |
| INT grant | `!M && candidate_selected && alu_regread_ready && all_required_reads_fit` | 允许 | 0 | 同上；读数为 rs1_en + (rs2_en && !use_imm) |
| MEM grant | `!M && candidate_selected && (!mem_execute_q.valid || mem_execute_ready) && all_required_reads_fit` | 允许；读数为 rs1_en+rs2_en | 0 | `rtl/backend/backend.sv:648`；仲裁 `rtl/backend/prf_read_arbiter.sv:143–159` |
| BR grant | `!M && candidate_selected && branch_regread_ready && all_required_reads_fit` | 允许；读数为 rs1_en+rs2_en | 0 | `rtl/backend/prf_read_arbiter.sv:160–175` |
| rename `recovery_block_i` | `M` | 接受资源满足的 0～4 最老连续前缀；`rename_fire=(accept_count!=0)` | accept_count=0 | `rtl/backend/backend.sv:563–565`、`:724`；资源条件 `rtl/backend/rename_stage.sv:69–115` |
| dispatch `recovery_block_i` | `M` | 接受各类 IQ 容量允许的最老连续前缀 | accept_count=0 | `rtl/backend/backend.sv:906`、`rtl/backend/dispatch_stage.sv:56–87` |
| IQ enqueue | `dispatch_accept_count!=0 && !M` | 真正入队，不能仍用 `!R` 丢弃输入 | 不入队 | `rtl/backend/backend_issue_queue.sv:172–185` |
| ROB retire lane j | `!M && AND(i=0..j){q.valid[head+i] && q.complete[head+i] && !q.exception[head+i]}` | 拍初完成的连续前缀照常退休 | 全部为 0 | `rtl/backend/rob.sv:256–270` |
| 写回资格 | `q.result_valid && !K(result)`，写目的者还须原年龄仲裁获写口 | 不因 R 阻塞写回 | 保留分支自身/更老结果；kill 的结果不写 PRF/complete | `rtl/backend/writeback_arbiter.sv:66–151` |

`candidate_selected` 是原 PRF 仲裁按 ROB 环形年龄扫描所得，并非新增不受约束的选择器（`rtl/backend/prf_read_arbiter.sv:89–175`）。IQ 删除仅发生在 candidate valid 与 read grant 同时成立时（`rtl/backend/backend_issue_queue.sv:130–135`）；C 拍不能删除没有取得读口的项。候选使用拍初 ready，N 拍写回在 N+1 才参与选择，保持原时序（`:110–114`、`:157–182`）。不增加同拍 wakeup-select。

### 4.2 branch mask 与状态更新的时机

所有新形成的 mask 必须反映 N 拍解析，包括**解析同拍新入队、新分配和新建 checkpoint**；仅遍历拍初旧项清位不足。对于同拍新分支，分支自己的 mask 不含自身 tag，更年轻 lane 才加入它的 tag，仍按原 lane 顺序（`rtl/backend/rename_stage.sv:99–113`）。tag 复用策略待 U2，不能在实现中自行加旁路。

| 结构 | 周期 N 组合/握手要求 | N 末边沿与 N+1 可见结果 | 当前代码与需要补齐处 |
| --- | --- | --- | --- |
| checkpoint active/rename mask | rename 起始 mask 必须清除已正确解析 t；随后按接受 lane 建立新分支依赖 | C 拍既释放旧 t、清存活 parent mask，又写全部实际接受的新 checkpoint；M 拍释放本分支及年轻后代，禁止 create | active 当前直接来自 valid_q；create 当前被所有解析跳过：`rtl/backend/branch_checkpoint_file.sv:63`、`:100–119`。rename 使用 active 的位置：`rtl/backend/rename_stage.sv:75`；必须合并 C 与 create，U2 控制同 tag 冲突 |
| rename RAT/free list | C 拍资源规划仍按拍初映射/空闲资源；新 mask 送 ROB/LQ/SQ/checkpoint/RDQ 时已归一化 | speculative map 接受四宽前缀；committed map 接受实际退休；新快照含分支自身目的映射；释放与新分配均只一次 | `rtl/backend/rename_map_table.sv:134–165`；free list 本拍 commit 释放重新合入，解析 tag allocation mask 清空：`rtl/backend/free_list.sv:121–162`。同 tag 复用未冻结（U2） |
| RDQ | C 拍旧 head 可 dispatch，新 rename 输出已经 clear；不能让 RDQ 输出的旧 mask 在下游重新污染新项 | 移走接受前缀，存活旧项清 t，追加新项；M 拍按原 mask 保留不依赖 t 的项 | `rtl/backend/rename_dispatch_queue.sv:58–81`；旧项清位只覆盖未出队项，append 没有再清位。需在本任务总装的 rename/dispatch 边界保证新载荷正确（`rtl/backend/backend.sv:545–555`、`:893–913`） |
| INT/MEM/BR IQ | C 拍候选正常生成；握手输出入下级时 clear；enqueue 载荷也 clear | 先丢已握手项/被 kill 项，压紧存活项清 t，再追加 C 拍新项且 mask 已 clear；写回唤醒只更新 N+1 ready | 旧项清位已有，选择/入队仍阻塞 R，新入队直接复制输入：`rtl/backend/backend_issue_queue.sv:110`、`:147–183` |
| ALU RegRead/Result | 任何 K(RegRead) 优先取消；C 拍本来 ready 时可接新 grant；结果竞争正常写口 | 存活 hold 槽清 t；新 RegRead/Result 保存 clear 后 mask；不能 kill 之后重新执行年轻项 | 已有 independent kill、载荷和 hold 清位：`rtl/backend/alu_pipe.sv:77–119`。不改变原 ready/consume 关系（`:53`） |
| BR RegRead/Result | 解析 one-shot 不等链接值写口；C 拍下一级容量允许时可读下一条分支 | 新 RegRead/Result 清 t；旧 RegRead 被 M kill 时 valid=0；链接结果背压时 sent=1 防止重复解析 | `rtl/backend/branch_unit.sv:66–96`、`:111–158`；结果槽被 hold 时完整 mask 更新能力不能凭注释假定，相关交错必须测试 |
| MEM execute | C 拍存活执行级可继续前进/接受新 grant；K 项不能发请求/写 SQ | 新槽 clear；hold 槽 clear；M 拍原 LSU `mem_ready` 令 killed 项离开、grant=0 | `rtl/backend/backend.sv:1581–1605`，请求/执行 kill 资格 `rtl/backend/load_store_unit.sv:243–265`、`:309–320` |
| LSU replay/pending/load result | 保留单 pending 生命周期；请求/转发/返回先以原 mask 判 K、再清位；迟到被取消 load 不写回 | replay 被 kill 清 valid；存活 replay/pending/result 清 t；新请求/转发/响应产生的 mask 也 clear | `rtl/backend/load_store_unit.sv:385–463`。pending_valid 不因清 mask 自动代表请求已结束；响应仍须 LQ live 身份检查（`:433–449`） |
| LQ | C 拍同拍释放/分配/执行/request/response 可进行，新分配 mask 已 clear | count 更新 `old_count+alloc_count-release_count`；原代际检查保留；M 拍删除年轻项并恢复 tail | `rtl/backend/load_queue.sv:98–101`、`:126–192`。M 分支当前没有正常执行/request/response 的更新代码，存活老 load 与恢复相交的记账结果**未确认**，见测试 LQ-M |
| SQ | C 拍分配/execute/commit/drain 独立合并，新分配 mask 已 clear | committed 项不被恢复取消；存活项清 t；保留旧 store 的 execute/drain 事件，释放只在完成 | `rtl/backend/store_queue.sv:253–351`；当前 M 拍已有存活老 store 更新，不能破坏 |
| ROB | C 拍旧完整前缀退休，新 rename 分配，合法旧结果 complete 同时接受 | head/tail/free_count 更新一次；新分配项初始 incomplete，新 mask 已 clear；解析无目的分支置 complete；新 complete 在 N+1 可见 | `rtl/backend/rob.sv:340–397`；旧 mask 扫描之后新 allocation 会覆盖整 mask（`:366`），需给已清理输入。M 拍存活 mask 当前未清 t（`:311–338`），恢复后 tag 重用的安全性需测试，不能把旧恢复当作已验证 |

同拍解析与 checkpoint create 的新合同来自“预测正确不停顿”和原子 rename，不允许 create 被忽略。**不会通过把 `resolution_valid` 改成 M 来停发正确解析广播**：R 仍必须送到所有结构，M 仅作为取消/恢复门控。

### 4.3 同拍优先级与可观察结果

1. **复位**覆盖全部更新，沿用模块 reset 分支（例如 `rtl/backend/rob.sv:284–310`、`rtl/backend/alu_pipe.sv:71–75`）。
2. **M 拍**：先由拍初 mask 判 kill；取消年轻项与恢复 tail/RAT 优先于年轻分配。fetch/Decode Queue 清空；没有新 issue/read grant/rename/dispatch/retire。分支自身链接值和存活旧结果若获得写口，PRF、ready、ROB complete 仍在 N 末一起生效，不能被恢复吞掉（`rtl/backend/rob.sv:321–338`、`rtl/backend/writeback_arbiter.sv:83–149`）；已提交 SQ 后台 drain 继续（`rtl/backend/store_queue.sv:253–298`）。
3. **C 拍**：没有解析专属停顿。读口授予、新 RegRead 捕获、写回和拍初已完成 ROB 前缀退休可以同拍发生；checkpoint release 与不同新 checkpoint create 均须生效。所有跨边界新 mask 和存活 hold mask 在 N+1 不再携带旧 t。是否允许本拍刚释放的 t 立即 create 新分支见 U2。
4. **complete 与 retire 同拍**：retire 仅看拍初 complete，不将本拍刚解析完成的分支或刚写回结果旁路为本拍可退休项（`rtl/backend/rob.sv:263–270`、`:344–345`、`:379–385`）。已经在更早拍 complete 的旧项正常退休。
5. **allocate 与 retire 同拍**：候选资源基于拍初 free_count/map，末端计数加退减入，commit map 更新与 speculative rename 同时生效；不增加“用本拍 retire 的资源继续扩大 rename 前缀”的旁路（`rtl/backend/rob.sv:195–196`、`:397`；`rtl/backend/free_list.sv:73`、`:129–141`；`rtl/backend/rename_map_table.sv:134–165`）。
6. **源依赖与写回同拍**：新 IQ 项可以在 N 末采纳 wakeup；已在 IQ 的候选本拍仍按旧 ready 选择，不新增组合 wakeup-select（`rtl/backend/backend_issue_queue.sv:110–114`、`:157–182`）。PRF 新读值与同拍同地址写入的实际可见行为须按现有 PRF 核实，**未确认**，不可在 spec 中臆造 bypass。

具体周期例子（未来验收激励，不是已运行结果）：N 拍 B 的正确解析 `R=1,M=0,t=3`；INT IQ 的 X 已 ready 且拿到读口；Result 的 Y 拿到写口；ROB 队头 Z 在拍初已完成；rename 的新分支 B2 在资源允许时接纳。N 末 X 进入 RegRead，Y 写 PRF/置 ready/complete，Z 退休，B 的 tag 释放，B2 checkpoint 建立；所有存活项清旧 bit3。N+1 才允许 Y/B 新置的 complete 参与退休。若改为 M=1，X/B2 无新 grant/分配，Z 本拍不退休；Y 仅在原 mask 不依赖 B 时可写回。资源代价目标是增加已有控制更新的合并/清位逻辑，不新增队列、FU 或恢复阶段；面积/时序开销**未确认**，本阶段无测量。

### 4.4 必需断言（阶段二新增，当前未运行）

- `C` 不得直接成为 issue/read/rename/dispatch/retire 的 block 原因；资源不足仍可合法阻塞。
- `M -> grants==0 && rename_accept_count==0 && dispatch_accept_count==0 && retire_valid=='0`。
- IQ remove 必须有实际 read grant；每条 uop 的所需读口全部得到或全部不得到。
- 被 `K` 命中的 RegRead/Result/LSU 工作不能写 PRF、唤醒、complete ROB、执行年轻 store；kill 判定使用旧 mask。
- C 拍接受的新 checkpoint 与 RAT/free_list/ROB/RDQ/LQ/SQ 分配一致，不能缺一个状态所有者。
- 存活、新建/新入队的状态不得保留旧解析 tag 依赖；同 tag 新生依赖例外只在 U2 明确后定义。
- 四宽接受数在 0～4，资源计数无下溢/溢出，等待不得重复分配，恢复保留 JAL 自身新映射和 committed SQ。
- 实际正常 retire 只来自拍初已完成连续前缀；本拍完成不冒充本拍退休。

## 5. 缺口 2 核实结论

**源码中已修复；明确的定向序列已存在；本轮未重新运行，当前提交上的动态结论未确认。**

- 背压条件由 `regread_ready_o = !alu_regread_q.valid || result_consume_i` 给出（`rtl/backend/alu_pipe.sv:53`）。在年轻 RegRead 有效、旧结果不消费时为 0。
- `br_killed(alu_regread_q.branch_mask,resolution_i)` 分支在 ready 分支之前独立清 valid（`rtl/backend/alu_pipe.sv:94–119`）。Result 替换也按原 RegRead mask 阻止年轻结果生成（`:77–88`）。这与 B12 旧审计描述的“只清 mask”不同。
- 总装确实实例化该 `alu_pipe`，解析输入和 consume 输入已接（`rtl/backend/backend.sv:1048–1059`）；不能只依据模块头判断。
- 现有定向序列：旧 ROB1 无依赖 mask 进入 RegRead，下一拍形成 Result；年轻 ROB2 mask=1 进入 RegRead；Result consume=0、误预测 tag0；断言年轻 valid 消失、旧 Result 保留；解除背压后断言年轻项未进入 Result（`sim/cocotb/branch_recovery/test_branch_recovery.py:133–158`）。包装直接驱动一个 ALU，consume 是测试输入，不经过共享写回仲裁（`sim/cocotb/branch_recovery/branch_recovery_tb_top.sv:172–205`）。
- 现有测试的“随机”末段只比较 Python redirect helper，没有随机激励 DUT（`sim/cocotb/branch_recovery/test_branch_recovery.py:160–165`），不能作为 ALU kill 的固定种子随机合同证据。
- `rtl/backend/backend.sv:35` 的缺口 2 说明过期；阶段二按任务书更正它及 LOOP 的已知缺口。阶段一不修改基线或这些源注释。完整 BRU 解析输出其实已驱动（`rtl/backend/branch_unit.sv:84–96`、`rtl/backend/backend.sv:998`），`:36` 的“未驱动”也过期；这不等于 L7 的所有预测/恢复机制已闭合。

## 6. 测试计划（阶段二，全部未运行）

所有改动模块都需要独立合同模型、定向测试、复位和真正驱动 DUT 的固定种子随机事务。模型读取包装导出的配置；按程序身份/顺序维护状态，不照抄 RTL 实现。每个失败输出 seed、周期、身份、输入和实际/期望。删除实例用展开与接口测试证明没有悬空/多驱动，而不把被禁用机制写成“已验证”。

### 6.1 变更到测试的映射

| 测试标识/模块 | 定向场景和断言 | 随机合同/入口规划 |
| --- | --- | --- |
| WQ：uop_queue | 0～4 连续 lane、所有 head/tail bank 偏移、边界回绕、满/空、部分接受、长回压、同拍进出、M flush；容量按 U1 | 拟增 `sim/cocotb/uop_queue/`，软件有序 FIFO 参考模型 |
| WR：rename_stage + map/free_list | RAW/WAW 链、最近旧 lane、同名多写、x0/无目的、每种资源只剩 0～3、混合 load/store/branch，分支在每个 lane；原子分配一次 | 拟增 `sim/cocotb/rename_stage/`；map/free_list 若实际改动需各自套件（范围 U6）；随机资源与依赖图 |
| CK：branch_checkpoint_file | C + create 0～4 分支、C + 新非分支、full checkpoint、存活 parent 清位、M 恢复 tail、同 tag 生命周期 U2 | 拟增 `sim/cocotb/branch_checkpoint_file/`；独立分支依赖树模型 |
| IQ-C/M：三个 IQ | C 拍同时选择/删除/入队/写回唤醒；清新旧 mask；未获读口不删除；M 不选新项、年轻取消；MEM replay 阻塞 load 仍允许 store | 扩展现有 `sim/cocotb/backend_issue_queue/`（现有行为入口 `test_backend_issue_queue.py:7`）；随机源就绪、grant、解析、队列满 |
| RR：prf_read_arbiter | C + INT/MEM/BR 竞争 4 个读口；部分读口不足不能半授予；无源 JAL；RegRead/Result 背压；M grants 全零；环形 ROB 年龄 | 拟增 `sim/cocotb/prf_read_arbiter/`；独立资源/年龄模型 |
| ROB-C：rob | C + 0～4 退休 + allocate + complete；本拍新 complete 下一拍才 retire；异常前缀停下；full/empty/wrap；M + JAL 链接 WB 存活、mask 清位和恢复 tail | 拟增 `sim/cocotb/rob/`；软件按序 ROB/身份模型，不借本级实现 trap |
| ALU-K：alu_pipe / branch_recovery | 将既有 §5 序列拆成具名测试；背压维持 1/多拍、各 tag，kill/不匹配/正确解析、旧结果保留、后续年轻项绝不生成 Result；增加真实仲裁竞争的总装场景 | 扩展 `sim/cocotb/branch_recovery/`；固定种子 DUT 事务，导出 ready/RegRead/Result 身份，避免只测 Python helper |
| LQ-C、LQ-M：load_queue | 四 load 分配/释放、C + alloc/release/execute/request/response；M 与存活老 load/年轻迟到响应相交、复用身份、tail 恢复；不丢老事务记账 | 拟增 `sim/cocotb/load_queue/`，记录每笔 live/代际/在途生命周期；LQ-M 当前是否满足合同未确认（§4.2） |
| SQ-C/M：store_queue | 四 store 分配/提交、C + drain/write completion、旧转发；M 保留 committed 和老 execute，取消年轻，drain 响应不重复释放 | 扩展现有 `sim/cocotb/store_queue/`，现有包装只驱动 lane0（`store_queue_tb_top.sv:41–49`），必须补多 lane 和恢复激励 |
| LSU-C/M：LSU + backend | C 与 MEM 槽、replay capture/recheck、pending response、forward/result 背压交错；M 错路取消、老 load/store 存活，不引入第二 pending | 扩展现有 `sim/cocotb/load_store_unit/`（测试入口 `test_load_store_unit.py:5`、`:63`）与 `sim/cocotb/backend/`；SQ 事件和总线延迟随机化 |
| SHELL：backend/filelist | 每个 §3 输出确定且无重复驱动；DCache/LSU/SQ/L2/probe 连接保留；禁用请求 valid=0；未知默认状态 U3/U4 冻结后断言 | `scripts/lint.sh` + backend 总装合同 + 下列现有门禁；不通过修改断言掩盖失败 |

若只由参数传播改变维度，不改算法，也必须覆盖四宽合同；不因为当前已经有单 lane 测试而免除。现有 suite 的存在不等于本任务验证：例如 SQ 现有三条测试入口在 `sim/cocotb/store_queue/test_store_queue.py:5`、`:80`、`:132`，不能据此声称多 lane/恢复已覆盖。

### 6.2 必须保持的现有门禁

依据 LOOP 第 1 节，只把“当前”路径当本轮要求；ITCM 的历史 L1 命令不复活。下面全部在阶段二推送的**同一准确 SHA**上由 Alan 执行，记录完整 SHA、工具版本、命令、退出码和日志。

```sh
scripts/lint.sh
make -C sim/o3 build
make -C sim/o3 run-smoke
make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1
make -C sim/o3 run-rv64i-instructions
make -C sim/cocotb/store_queue SIM=verilator
make -C sim/cocotb/dcache SIM=verilator
make -C sim/cocotb/backend_issue_queue SIM=verilator
make -C sim/cocotb/load_store_unit SIM=verilator
make -C sim/o3 run-dcache-data run-dcache-replay
make -C sim/cocotb/backend SIM=verilator TEST_SEED=1
```

本地 lint 是提交检查；Alan 才是功能验收证据。现有整核目标与期望入口已核实：`sim/o3/Makefile:28–85`；退休检查比较数量、PC、instruction、rd、rd_write 和有效写回值（`sim/o3/check_trace.py:21–40`）。这不是 Spike 比对；现有 checker 不比较访存地址/数据，分支访存交错另需 read-back 与副作用观测。

### 6.3 新分支密集整核门禁

拟增 `make -C sim/o3 run-l3-branch-dense`（**尚不存在**，现有目标表见 `sim/o3/Makefile:19`），沿现有 HEX + expected retirement JSON 模式。程序/期望在阶段二实现前独立推导并固定，不以 DUT 输出反写期望。

- 使用已有 RV64I BEQ/BNE/直接 JAL，连续 not-taken 分支与 taken 分支交错；顺序预测的实际正确/错误资格以 `actual_next_pc == predicted_next_pc` 判定（`rtl/backend/branch_execute_unit.sv:63–64`；单指令预测后继赋值 `rtl/frontend/ifu_f1.sv:90`）。不为制造“正确解析”改预测器。
- 每个正确解析之后放置独立 ALU 与依赖 ALU 链，在资源具备时观察 C 拍 rename/dispatch/read/retire 的推进；总装局部测试必须形成实际同拍重合，不能仅以总周期下降代替控制断言。
- 分支与缓存 load/store、旧未知地址 store 引起的 replay 交织；错路放置唯一的寄存器值/普通 store，正确路径读回验证其没有可见写入。只用当前支持的普通可缓存、自然对齐地址，不借本任务引入 MMIO/跨行异常。
- 覆盖 JAL 链接写回与共享端口竞争、较老 store 同拍执行/已提交 store drain、被取消年轻 load 的迟到返回；退休 PC/指令/写回值逐条符合固定期望。
- 程序至少越过一次 checkpoint tag 循环复用；跨 FTQ 容量的长程序回收用例依 U3 冻结，不能通过无声缩短程序隐藏接口缺口。
- 输出周期数、退休数、正确解析数及误预测次数。误预测次数按 `exec_resolve.valid && exec_resolve.mispredict` 的一次解析计数，包含直接 JAL，不能重复计算背压保持的链接结果（one-shot 源码 `rtl/backend/branch_unit.sv:70`、`:109–119`）。目前驱动只报告 load replay 和 PASS 周期/退休数（`sim/o3/main.cpp:418–419`），阶段二需在测试包装/驱动加入解析观测。
- 缺口 1 前后比较使用同一程序/期望/四宽配置/容量/缓存参数/种子与相同停止条件：先保存“已四宽且清理空壳、仍保守 R 阻塞”的 SHA 和 Alan 日志，再保存“只改变缺口 1 控制”的 SHA 与日志，列两个周期数及差值。不用不同宽度或不同缓存热度直接归因收益，不预先承诺周期改进。
- 固定种子随机测试至少覆盖 `TEST_SEED=1`，另保留若干记录过的种子；seed、事务数和停止条件固定并随报告保存。不得为 PASS 改写期望/断言。

## 7. 审阅决定（原未决问题 U1～U6，2026-10-05）

以下决定取代原未决问题表；正文中引用 U1～U6 之处均按本节执行。

| 编号 | 决定 |
| --- | --- |
| U1 Decode Queue 容量 | **16 项**（4 bank × 4 行），`be.decode.queue_depth` 由 18 改为 16。理由：decode 与 rename 同为 4 宽，队列只吸收后端回压，不再需要消化六宽积压；16 满足整除断言。验证项按 §6.1 WQ。 |
| U2 checkpoint tag 同拍复用 | **不允许同拍复用。**create 的候选 tag 只看拍初空闲（`~valid_q`）；C 拍释放的 tag 在 N+1 才可被分配。C 拍中 release(t) 与 create(其他 tag) 同时生效；由于 t 在拍初有效，create 不可能选中 t，不需要同 tag 优先级规则。所有在 C 拍新建或新入队的 mask 都必须清除 t（§4.2）。以 16 个 checkpoint 计，延迟一拍复用的代价可以忽略。新增断言：同一 tag 不得在同一拍既释放又分配。 |
| U3 ROB→FTQ 提交通知 | **本级补最小通路**，否则长程序会因 FTQ 不回收而停住，§6.3 的分支密集门禁无法成立。做法：移除 `commit_ctrl` 实例后，`ftq_commit_o[lane]` 直接由 ROB 的退休 lane 驱动：`valid` = 该 lane 实际退休，`ftq_id`、`slot`、`region_last` 取自该 ROB 项。若 ROB 项或 uop 目前没有完整保存 `slot`、`region_last` 或动态 `ftq_id`，沿 `fetch_entry_t → decode → rename → ROB` 补齐字段（允许修改 `o3_types_pkg.sv`、`decoder.sv`、`rob.sv`、`backend.sv`）。该通路在 L5 原样并入 `commit_ctrl`，L5 不得改变其语义。验证：长程序跨越 FTQ 容量（>32 个区域）多次回收；同拍多条退休跨不同区域；误预测后被取消的年轻指令不产生提交通知。 |
| U4 CSR/PMP 静态占位 | 移除 `csr_file` 后，以命名常量显式驱动：特权级 = **M**（`PRIV_M`，不能用数值 0 代替），`satp.mode` = **Bare**，翻译 epoch = 0，`mstatus.MPRV/SUM/MXR` = 0；PMP 全部条目 `A=OFF`、地址 0。按 RISC-V 规范，M 模式下无匹配 PMP 条目的访问应当放行。阶段二必须用定向测试确认现有 `pmp_checker` 在该配置、M 模式下放行取指与数据访问；若不放行，停下报告，不得修改 `pmp_checker` 的规则来凑结果。这些常量集中定义在 `backend.sv` 一处并注明“L5 由 csr_file 取代”。 |
| U5 后续归属 | R1 依赖预处理与级间暂存：**不指定 Ln，按综合时序触发**（B42）。`data_prefetcher`：**L8**（依赖多 MSHR 的非阻塞访存，B07）。`backend_perf_events`：**L7**（与误预测率/IPC 基线一同落地，B10）。阶段二按此写入移除清单与 `LOOP.md`。 |
| U6 阶段二范围 | 允许修改：`o3_cfg_pkg.sv`、`o3_pkg.sv`、`o3_types_pkg.sv`（含注释与 U3 所需字段）、`rename_map_table.sv`、`free_list.sv`、`rename_dispatch_queue.sv`、`preg_ready_table.sv`、`physical_regfile.sv`、`decoder.sv`、`writeback_arbiter.sv`、`dispatch_stage.sv`、`branch_unit.sv`、`load_store_unit.sv`，以及任务书原列文件；行为改动只限于本 spec 规定的内容。允许把未实例化的 `l2_recall_ctrl`、`dma_line_coord` 移出 `rtl/rtl.f`（归属 L11）。不允许修改前端（U3 只用前端已有的 `commit_i` 输入）和 `o3_core.sv` 的接线以外的内容。 |

**附加要求**（审阅补充）：

- §5 的缺口 2 结论接受：已在源码中修复。阶段二把 `sim/cocotb/branch_recovery/` 中的定向序列拆成具名测试，并补一个真正驱动 DUT 的固定种子随机测试（现有末段随机只测 Python helper，不能算数）。
- §4.2 中 LQ 在 M 拍的记账（存活老 load 的正常执行、请求、响应在恢复拍是否被丢失）标为“未确认”。阶段二先用 LQ-M 定向测试检验：若发现确实丢失，按“存活老项照常更新、只删除年轻项”修复，属于缺口 1 修复的必要部分，不需要另行审批；修复方式写进报告。
- §4.3 第 6 条 PRF 同地址读写可见性：阶段二先核实并在报告中写明现有行为，不新增旁路。

## 8. 阶段一交付状态

spec：冻结候选，待用户确认；阶段二：未开始。缺口 1 仅给出方程与测试计划，未修 RTL；缺口 2 仅完成实时源码/测试内容核实。所有本轮命令、提交和验证边界见 [阶段一报告](../tasks/O3-T01-report.md)。
