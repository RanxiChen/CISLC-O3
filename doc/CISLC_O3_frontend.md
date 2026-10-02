# CISLC_O3 Frontend Notes

## 首版规模预算（2026-10-02，暂定，未做 FPGA fit）

`O3_CFG` 现有字段已给首版数值，不再靠空 `O3_TBD` 阻止编译；这只是开始写真实
RTL 所需的容量假设，不是设计基线冻结值。参照 BOOM Medium 的 32 项 FTQ、16 项
fetch buffer 和 64 项 ROB 量级；本核取指区域为 16B（8 个半字槽位），最多交付 4 条，
不能把 BOOM 的 8B fetch 直接视作相同带宽。
BOOM 对照源码：[`WithNMediumBooms`（v3，固定 commit）](https://github.com/riscv-boom/riscv-boom/blob/54f11b85c9a670ef3dd18bc675994b9a661b06ee/src/main/scala/v3/common/config-mixins.scala#L131-L163)。

| 部件 | 首版参数 | 理由/调优触发 |
| --- | --- | --- |
| 取指/队列 | 16B 区域，F0 8 槽、F1 4 条，FTQ 32，返回队列 8，ibuf 16，训练队列 4 | 先限制在途窗口；若 FTQ/返回队列满导致持续气泡，量化后再加深 |
| 预测器 | uBTB 16 项；BTB 64 组×2 路；TAGE 6×128 项、8-bit tag、3-bit counter、2-bit useful，base 512 项；RAS 16 项 | 首版优先控制多槽查询端口和逻辑布线；若容量冲突率高，再提高表项数，不盲目复制端口 |
| ICache/翻译 | ICache 16KiB（64 组×4 路×64B，2 个整行 bank）、4 MSHR、16B refill beat；ITLB 32 项×4 路 | MSHR 占用、重放、bank 冲突、时序经仿真与综合确定 |
| 预取 | 近期翻译复用 4 项、领先 2 区域、请求队列 4 | 先限制预取挤占 demand 与 PTW |
| 公共宽度 | VA 64、PA 56、ASID 16、翻译 epoch 8、PMP 16、commit 4 | 寄存器保留完整 RV64 地址；合法性和实际物理地址图另行实现 |

每个 D22 历史快照暂为 `128×8+6×(7+2×8−1)=1156` bit；32 项约 37 kbit，
还不含身份、RAS 与训练元数据。L1I 原始数据为 128 Kibit。KCU105 的片上 BRAM
预算不能直接证明能布线、满足端口或时序：实现后必须分别看 LUT/FF/BRAM、SRAM
映射、关键路径、FTQ/ICache stall 与预测命中率。`gen_bits=8` 也不能单靠位宽防止
旧响应在回绕后撞上新身份；复用槽位前必须完成旧响应/训练的生命周期约束。

## 逐模块实现进度（2026-10-02）

- `ftq` 目标端口已改为 `CFG.ftq.depth` 项动态描述环。每次占用一个槽都使该槽的
  generation 递增；完整 `ftq_id` 校验慢预测、执行解析、提交、brief 和 D29 RAS
  检查点读口。队头、分配、demand、prefetch 四个游标分别推进；ICache 接受 demand
  与返回队列同拍预留后只标记 issued，不释放 FTQ 容量。demand 等待 ICache ready
  时锁住请求载荷；返回队列必须在这段等待中保持所报预留槽可用且身份稳定。
- 慢预测写回最终摘要和 TAGE 元数据；执行解析记录条件分支实际方向、taken CFI
  和误预测，提交各 lane 按完整身份累积已提交条件分支 mask。`region_last` 只将区域
  标为待训练：队头依次请求原入口历史快照、等待响应、保持 `bpu_train_valid` 到 BPU
  接受，之后才释放槽。以 FTQ 项本身保存待训练区域，因此同时提交多个区域时不会
  被固定小训练 FIFO 溢出；BPU 反压会占住 FTQ 容量。
- D24 kill 优先于本拍分配与 demand/prefetch 发射。部分 kill 校验边界完整身份并清除
  更年轻项；kill-all 保留已提交但尚未交接训练的连续队头前缀。存活边界的预测 mask
  截至指定槽位，同拍执行误预测可用 `resolve_i` 修正 target/类型。当前 `kill_i`
  只有边界、没有预解码修正后的完整预测信息，因此预解码型边界的最终摘要还不能由
  FTQ 独立精确改写；需后续在 F1/统一重定向接缝补齐。旧 16 项 BPU/IFU/释放端口
  现已隔离为常量，仅 `ftq_pkg` 暂留供旧 BPU 类型引用，旧接口不可再作为数据路径。
  generation 8 位只提供身份比较，回绕前旧请求/训练生命周期仍需系统级约束。
- `ras` 已按 D29 在原端口实现参数化寄存器环形栈。`top_idx` 指向非空栈顶；空栈保留
  最后弹出位置，复位设为 `depth-1`，因此首次 push 写第 0 项。push 向下一格写，
  满栈覆盖最旧项且 `count` 饱和；空栈 pop 保持状态，pop-push 在非空时原位替换
  栈顶、在空栈时等价于 push。`ckpt_o` 始终是本拍操作前的索引、占用数和有效栈顶
  地址；空栈地址为 0 且恢复时忽略。调用者负责只在成功分配时给一次 `op_valid_i`，
  并提供按原始指令长度计算的返回地址。
- 恢复与普通操作同拍时，恢复独占状态更新。R1 组合给出
  `recover_done_o/recover_done_id_o`，表示本拍边沿可接受对应身份；边沿从检查点
  装载索引/计数，非空时先修复旧栈顶，再执行 `recover_fix_i`。修正 push 与旧栈顶
  同址时，修正地址最终胜出。R2 的组合栈顶读直接看到写后的地址。只修复保存的
  栈顶，深层污染可留下；上游仲裁器仍须过滤旧恢复身份并冻结错误路径普通操作。
  `perf_o` 对当拍 push/pop、空栈、满栈和恢复周期给出增量；return 命中/错误、
  栈顶修复次数和被替换恢复次数尚无独立事件编码，也未测资源或整机恢复拍数。
  采用临时顶层展开 `O3_CFG.fe` 的 Verilator 5.050 局部 lint 退出码为 0；仅有
  公共包已有的 ASCRANGE/SYMRSVDWORD 警告。`ras_ckpt_t` 位宽由全局 `O3_CFG`
  推导，实例深度必须可由该索引和占用数字段表示。
- `tage` 已按原端口实现首版三阶段方向表：`O3_CFG.fe.tage` 控制 base 容量、
  六张 tagged 表的 index/tag 位宽与计数/useful 位宽；每行共享 tag/valid，
  八个半字槽分别保存方向和 useful。S0 算索引与 tag，S1 同步读取，S2
  组合比较并输出每槽方向。最长历史命中为 provider，弱且无 useful 时用
  次长命中/base；`tage_meta` 保存各槽 provider 与原预测供提交训练。训练
  始终使用原区域入口 `train_i.ctx.folds`，对所有已提交条件槽更新 base，
  更新仍命中的 provider；方向错误时向更长表分配。stall 保持在途读，kill
  清除在途有效位，提交训练独立进行。同拍 S1 读表与训练同行按旧值读。
  这是首版组织/分配策略，尚无预测率、SRAM 映射、综合或 FPGA 时序证据。
- `ubtb` 已按原端口实现首版组合快预测：`O3_CFG.fe.ubtb.entries` 项全相联、
  `tag_bits` 位折叠 tag，单区域保留已提交 BR/JAL mask 与最近一次 taken CFI
  的目标。条件分支 owner 用 2-bit 饱和计数器决定快方向，JAL/JALR 恒预测
  taken；实际入口槽之后才可采用该目标，否则沿顺序区域推进。提交训练优先
  更新命中项，再取空项，满表按全局 round-robin 替换；stall 只门控查询，
  不阻挡训练。查询是组合读：同拍训练边沿前见旧状态，边沿后见新状态。
  `PE_UBTB_LOOKUP/HIT` 给出有效查询的当拍增量，可用于后续容量/别名调优。
  表组织、折叠 tag 和方向策略是首版选择，尚未证明预测率或 FPGA fit。
- `main_btb` 已按现有接口实现首版 64 组×2 路、每项单目标的组相联表。
  查询在接受边沿锁存各路，下一拍比较部分 tag 并输出；stall 保持在途结果、
  kill 立即抑制并清除有效位。提交训练累积已提交条件分支位置，最近一次提交的
  taken CFI 更新唯一目标；无 taken 时保留旧目标，同拍查询/训练读旧值。
  容量、折叠 tag 和 round-robin 替换均为首版实现选择，未做预测率/资源测量。
  使用临时静态展开顶层运行 Verilator 5.050 `--lint-only`，退出码 0。
  `sim/cocotb/main_btb/` 已加入独立包装顶层、周期参考模型和 cocotb 测试；
  Alan 隔离 checkout 在 `59c35e2` 上使用 cocotb 2.1.0 / Verilator 5.050
  运行定向合同和每种子 600 周期随机检查，种子 `1`、`0xC15C` 均为 2/2 PASS。
  后者启用 VCD，产生 `results.xml` 和 `dump.vcd`；先前 FST 因 Alan 临时环境
  缺少 `lz4.h` 编译失败，故首版波形改用 VCD。以上仅证明单模块测试，尚未
  验证 BPU/FTQ 集成、预测率、综合或 FPGA 时序。
- `branch_history` 已实现 D22 事件编码、E 阵列、六组 C 增量折叠，以及 D23 完整快照恢复。
  恢复优先于普通 push；同一上升沿可装载快照并注入一条修正事件。调用者仍负责
  D09 事件资格、停止新预测以及被替换恢复的身份过滤。
- 对该模块运行了 Verilator 5.050 局部 `--lint-only`，使用 `-DO3_TBD=4` 临时展开
  未冻结字段，退出码为 0。占位值使其他包类型出现无意义宽度警告；这不是功能验证。
  未运行仿真、综合或 FPGA。
- BPU 输入控制与恢复仲裁仍是框架；快照存储虽已单独实现，前端仍不能运行。
- `history_snapshot_store` 已实现按动态 FTQ 身份保存完整 E/C；恢复、训练各有一拍
  同步读口，同拍同身份写读取新值。输出按当前等待读身份门控，调用者必须在收到
  响应前保持该身份；FTQ 分配与释放仍需保证旧训练读取完成后才复用槽位。
- 新增 `tb/branch_history_tb.sv` 和 `tb/history_snapshot_store_tb.sv`，分别固定历史
  推进/恢复的边沿语义，以及双读口、代际过滤、同拍写读旁路。两份 testbench 与
  实际 `O3_CFG` 一起通过 Verilator 5.050 `--lint-only --timing`（均 exit 0）；
  尚未运行仿真，PASS 字样只会在用户实际执行后出现。`o3_cfg_pkg`、`o3_types_pkg`
  也已不借助占位宏通过单独 lint。现存 ASCRANGE 与 SYMRSVDWORD 警告仍需整理。

## 原始目标框架记录（2026-10-02 搭建，非当前完整状态）

本节记录按前端设计基线（D01～D28，第 16 节）搭建时的模块与端口框架。初始框架只有端口、
连线和注释；下面“当前边界”及之后各节描述的是 HEAD `06462b0` 的旧实现，保留作迁移参考。
该段“未编译/未测试”只指初始搭架时点；现阶段检查结果见文首逐模块进度。

### 参数组织

- `rtl/common/o3_cfg_pkg.sv`：全工程唯一写数值的位置。按子系统分组的配置结构
  `o3_cfg_t`（当前含 `core` 与 `fe`），每个字段注明已定/暂定/待定/现状沿用及出处。
  初版未冻结字段已填暂定值，仅供实现和资源测量，不能当作 FPGA fit 结论。
- `rtl/common/o3_types_pkg.sv`：只从 `O3_CFG` 推导位宽与跨模块合同结构（`ftq_id_t`、
  `fetch_entry_t`、`redirect_req_t`、`fe_kill_t`、`bru_resolve_t`、`sys_redirect_t`、
  `ptw_req_t`、`l2_req_t` 等）。
- 模块参数 `parameter o3_cfg_pkg::frontend_cfg_t CFG` 不写默认值，由顶层传入
  `O3_CFG.fe`；`frontend` 内用断言检查影响接口位宽的字段与 `O3_CFG.fe` 一致。
- `fetch_entry_t` 已从 `o3_pkg` 迁入 `o3_types_pkg`，补充动态 FTQ 身份（idx+代际）与槽位。

### 模块清单

| 模块 | 状态 | 机制出处 |
| --- | --- | --- |
| `frontend` | 目标总装连线已写；旧总装被替换 | 第 1 节 |
| `bpu` | 新增目标端口与子模块例化；保留旧顺序 32B 生成器为旧合同 | D01/D02 |
| `ubtb` / `tage` | 两者单模块 RTL 已实现；预测总装仍未接通 | D02/D04～D08/D22 |
| `main_btb` | 单模块 RTL 已实现，尚未接入可运行慢预测路径、未做功能仿真 | D02/D05～D08 |
| `branch_history` / `history_snapshot_store` | 两者已单独实现，尚未接成可运行预测路径 | D09/D22/D23 |
| `ras` | D29 单模块 RTL 已实现；BPU 分配与恢复仲裁仍未接成可运行路径 | D29（第 6.2 节） |
| `bpu_slow_check` | 新增空壳 | 第 4.1、6.3 节 |
| `redirect_arbiter` | 新增空壳 | D24 |
| `ftq` | 目标端口单模块 RTL 已实现；旧端口隔离，BPU/返回队列/重定向总装仍未形成可运行路径 | 第 7 节 |
| `fetch_return_queue` | 新增空壳 | D14～D17 |
| `ifu_f0` / `ifu_f1` | 新增空壳 | 第 3.3、10 节 |
| `fetch_buffer` | 保留实现；参数改由 CFG；新增 `kill_i`（未实现） | 第 10 节 |
| `ICache` | 新增目标端口与子模块例化；保留旧阻塞实现为旧合同 | D10～D14 |
| `itlb` / `icache_mshr` | 新增空壳 | 第 8～9 节、D19/D26～D28 |
| `pmp_checker` / `pma_checker` | 新增空壳；2026-10-02 移到 `rtl/common/`，前后端共用 | 第 8 节、D28 |
| `fetch_prefetcher` / `prefetch_xlate_cache` | 新增空壳 | D18/D19 |
| `frontend_sync_ctrl` | 空壳；2026-10-02 只负责前端部分，删除 dclean 接口，由后端 commit_ctrl 编排 | D25～D28、B23/B24 |
| `frontend_perf_events` | 新增空壳 | D21，第 12 节 |
| `ifu` | 已删除（2026-10-02），由 `fetch_return_queue`/`ifu_f0`/`ifu_f1` 取代 | — |

### 框架中明确标为“未设计”的内容

- 异常/中断/xRET 主流程已定（后端 B26/B27），前端只接收已形成的系统重定向；系统入口首笔取指可与
  历史/RAS 恢复解耦（16.4），但系统 committed 预测上下文来源、入口取指返回槽与元数据绑定仍未闭合。
- 重定向赢家在前后端之间的归属与同一取消边界的接口。
- D25～D28 同步握手的信号编码与拍数（归属已定：后端 commit_ctrl 编排，前端不发起 DCache clean）。
- 跨块补半字辅助请求、后半字异常报告；非法 RVC 的 tval。
- 训练排程与提交带宽；uBTB 首版方向/替换规则已实现，但仍待预测率与资源测量后调优。
- PMA 地址图、不可缓存取指路径；ITCM 去留。
- 性能计数读取 ABI。

### 2026-10-02 第二轮框架补齐（D29、系统同步、L2 回收）

- `o3_types_pkg::ras_ckpt_t` 改为 `{top_idx,count,top_addr}`；`O3_CFG.fe.ras.undo_log_depth` 删除。
  `bpu`/`ftq`/`redirect_arbiter`/`frontend` 删除 `ras_commit_free_*`/`ras_free_*`/`log_full`，新增恢复
  身份 `ras_recover_id`/`ras_done_id`；`bpu_slow_check` 删除 `ras_top_*`，改用区域保存的 `fast_ras_ckpt_i`。
  `redirect_arbiter` 注释写明普通分支 R0～R2 目标与系统入口取指解耦边界。
- `frontend_sync_ctrl`：删除 `dclean_req_o/dclean_done_i`；`frontend` 顶层删除 `dclean_*`。
- L2 inclusive 回收（后端 B41）：`frontend` 新增 `l1i_recall_*`，直通 `ICache` 新增的 `recall_*` 维护入口
  （不进入 S0 demand 路径）。`itlb` 注释按 B36 更新 A 位。
- 该段记录的是框架补齐当时的状态；当前单模块进度见文首。

### 已知的不一致（符合 agent.md 顺序重构约定）

- 2026-10-02 后端框架阶段已把 `o3_core.sv`、`backend.sv` 改为新合同（见 `doc/CISLC_O3.md`）；
  `tb/*` 与 `sim/o3` 仍按旧接口。
- `sim/o3/Makefile` 未加入新文件。
- 各模块保留的旧合同端口在目标总装中不连接，迁移完成后删除。


## 当前边界

前端当前形成第一版顺序预测与恢复闭环：

```text
sequential BPU -> FTQ -> serial IFU -> ICache -> Fetch Buffer -> Backend
       ^                                                       |
       +---------- branch resolution / redirect ---------------+
```

- BPU只生成最大32B的预测取指块，当前没有BTB/BHT/RAS，固定按not-taken顺序推进。
- FTQ是16项预测块环形队列，不是一级流水寄存器。IFU消费与Commit释放使用独立指针。
- IFU暂时采用单块、单ICache请求状态机，不实现多请求并发。
- ICache内部包含`0x10000000`起始的64KiB ITCM；完整16B窗口位于该范围时固定一拍
  返回，范围外继续走blocking Cache refill，由仿真器的软件后备内存响应。
- Fetch Buffer继续作为前后端交接的紧凑指令队列。
- Backend提交某块最后一条存活指令时，按序释放对应FTQ entry。
- 分支误预测时，Frontend保留包含该分支的FTQ entry，截断所有年轻entry，并从
  `redirect_pc`重新生成预测块。
- FTQ能够记录分支实际方向和目标并在释放时形成训练观察值；当前BPU不使用训练数据。

统一内存定向测试已经覆盖ITCM初始化取指和范围外软件内存refill。RVC、真实预测算法、
TLB/PMP、跨页取指、异常恢复和并发ICache请求仍未实现。

## 预测块与FTQ合同

`ftq_entry_t`保存：

- `[start_pc,end_pc)`预测取指范围；当前最大32B。
- 预测控制流位置、类型、方向、目标、fallthrough和`next_pc`。
- 分支执行后回填的实际分支PC、类型、方向和目标。
- 取指异常占位字段。

当前BPU始终生成无已知分支的完整32B块：`has_branch=0`、`pred_taken=0`、
`next_pc=end_pc`。未来预测器命中块内控制流时，可以缩短有效块边界并改变`next_pc`，
而不改变FTQ到IFU的接口。

FTQ维护：

- `alloc_tail_q`：BPU下一次分配位置。
- `ifu_head_q`：IFU下一次消费位置。
- `release_head_q`：Commit下一次释放位置。
- `allocated_count_q`：已分配但尚未提交释放的块数。

IFU消费只推进`ifu_head_q`，不回收容量。Commit输出本拍跨过的`ftq_last`数量，FTQ从
`release_head_q`连续释放相同数量的entry。

## 串行IFU状态机

`rtl/frontend/ifu.sv`当前有四个状态：

- `IFU_IDLE`：等待并接收一条FTQ entry。
- `IFU_REQ`：保持一个16B对齐请求，直到ICache ready/valid握手。
- `IFU_WAIT`：等待该请求唯一对应的ICache返回。
- `IFU_OUT`：把128位返回拆成最多4条32位指令，保持到Fetch Buffer接受。

一个32B预测块通常依次产生两个16B请求。只有第一组返回已经进入Fetch Buffer后，IFU
才发第二组请求；当前故意不重叠请求、返回和块处理。

每条`fetch_entry_t`携带：

- 原始和规范32位指令、PC、长度和统一异常字段。
- `ftq_idx`：所属预测块。
- `ftq_last`：该指令是不是块内最后一条有效指令。
- `predicted_next_pc`：该指令当初预测的下一PC；无预测控制流时为`pc+4`。

当前没有RVC解压，正常指令固定`inst_len=4/is_rvc=0`。地址不满足4字节对齐时直接生成
`EXCEPTION_CAUSE_INST_ADDR_MISALIGNED`；ICache错误转换为统一取指访问异常。

## Redirect与ICache

分支错误解析到达Frontend时：

1. BPU在上升沿把预测PC改为`redirect_pc`。
2. FTQ删除出错块之后的所有entry，`alloc_tail/ifu_head`恢复到该块之后。
3. IFU清除当前块、请求和返回保持状态。
4. Fetch Buffer整体清空；其中所有指令都比分支年轻。
5. ICache杀死查找/replay并丢弃旧miss的迟到refill。

Branch redirect不会清空ICache有效数据。`icache.flush`保留给reset级维护语义，redirect使用
独立`kill`输入，仅处理错误路径的在飞控制状态。

ITCM使用绝对物理地址初始化口。完整16B窗口命中ITCM时不查询tag、不分配Cache line；
窗口跨越ITCM末端时整笔按范围外请求处理。flush和redirect都不擦除ITCM内容。当前数据端
写ITCM不会同步修改该阵列，因此不支持自修改代码。

第一版只有一个请求在飞，因此IFU被清空后可以直接忽略迟到返回；ICache在discard miss
完成前保持blocking，不会把旧返回误配给新请求。未来增加多个outstanding后，需要epoch或
请求tag。

## 分支恢复与训练时序

- BRU结果先进入Backend Branch Result寄存器。
- 下一周期`branch_resolution.valid`广播实际方向、目标、FTQ/ROB/checkpoint身份。
- 正确预测只更新FTQ实际结果并释放后端checkpoint，不清前端。
- 错误预测同时触发后端checkpoint恢复和上述Frontend redirect。
- 默认not-taken可能在32B块中部遇到真实taken分支；ROB会把该分支改记为`ftq_last`，使
  被杀掉的原块尾指令不会阻止FTQ最终释放。
- 该FTQ块提交时产生训练观察值并释放。当前训练输出未连接预测表。

## 文件索引

- `rtl/frontend/bpu.sv`：顺序预测块生成与redirect PC恢复。
- `rtl/frontend/ftq.sv`：预测块存储、IFU消费、Commit释放、误预测截断和训练观察。
- `rtl/frontend/ifu.sv`：单块单请求取指状态机。
- `rtl/frontend/icache.sv`：64KiB ITCM、blocking ICache、refill以及redirect kill。
- `rtl/frontend/fetch_buffer.sv`：前后端交接的紧凑指令队列。
- `rtl/frontend/frontend.sv`：上述模块总装和恢复信号分发。
- `rtl/core/o3_core.sv`：Backend resolution/release到Frontend的闭环连接。

## 后续顺序位置

当前前端只具备固定not-taken预测结构。下一步若继续前端，应先讨论BTB记录的块边界、
条件分支方向表和训练端口吞吐；在此之前不引入RAS、GHR恢复或多bank ICache优化。
