# O3-T09：L8a 非阻塞访存底座 RTL spec（已冻结）

日期：2026-10-07。分支：`feat/L1-closure`。审计快照：`48be80d`（B51 记录后）。行号均指该快照。

依据：[v1 计划](../O3-v1-plan.md) 第 3 节 L8；[后端基线](../design/CISLC-O3-BACKEND-DESIGN-BASELINE.md) B03～B05、B07、B32、B33、B36、B39、B47、B49、**B50、B51（第 39、40 节）**；
[前端基线](../design/CISLC-O3-FRONTEND-DESIGN-BASELINE.md) 第 9 节（ICache MSHR）、D25。

机制参考：Breeze `/home/chen/leisure/flow`，分支 `feat/pcie-fase-20260920`，提交 `a304cc2`。
- spec：`docs/coherence-l2-rtl-spec.md`（下称 **BC**）、`docs/l1d-rtl-spec.md`（下称 **BL**）。
- 源码：`design/src/main/scala/{coherence,l1d,l1i,l2}/*.scala`。
- 测试思路：`design/src/test/scala/memsys/`（`MemAgents`、`MemCoherenceMonitor`、`L1DL2SystemSpec`）。

**原则：**
- 先完成后完美（2026-10-06）：每个新行为一个简单定向用例，再加一个黄金内存随机用例；litmus、完整一致性测试推迟到 FPGA；L11 前不综合。
- 机制复用，不逐行翻译（B50/B51）：沿用 Breeze 的协议消息、MESI/目录、依赖纪律、状态机、流水级划分和同拍冲突规则；规模、并发度和后端接口按本文修改；不做 B47 等价检查。
- 三类等待者（B51 40.1）：流水线不停顿；行事务由状态机负责；指令等待记在 LQ/SQ。
- 能由硬件做的不交给软件 trap（B49）。

**状态：已冻结（2026-10-07，用户确认第 14 节 X1～X10 全部按推荐实施；X1 按用户要求改为“RTL 一次写完，测试逐层加入”）。**

---

## 0. 任务书

```
目标：L8a —— 非阻塞访存底座：
      MESI 协议链路 + L2 Home（256KB/8 路/8 慢槽）+ AXI 内存引擎；
      L1I（现有 ICache）改为协议只读客户端；
      新 L1D（32KB/8 路/8 个字 bank/4 MSHR + 合并/2 写回槽/probe/PTW 与 PTE A/D 入口）；
      LSU 改为 Replay 合同 + LQ 等待与唤醒，两条访存管道，store 所有权预取（RFO）。
涉及模块（允许改动）：
  rtl/common/{o3_cfg_pkg,o3_types_pkg,o3_pkg,pma_checker}.sv
  rtl/memory/：新增 l2_home、l2_slots、l2_probe_engine、l2_mem_engine；删除 l2_cache、l2_recall_ctrl、dma_line_coord
  rtl/lsu/：dcache 重写；新增 dcache_probe；dcache_mshr、dcache_writeback 重写；dtlb、ptw、pte_ad_updater 接口适配
  rtl/frontend/{icache,icache_mshr,frontend}.sv（L2 侧接口与回填）
  rtl/backend/{load_store_unit,load_queue,store_queue,backend,backend_issue_queue,prf_read_arbiter,
               writeback_arbiter,fp_writeback_arbiter,physical_regfile}.sv
  rtl/system/{commit_ctrl,backend_perf_events}.sv（只改 FENCE.I 数据侧与事件）
  rtl/core/o3_core.sv；rtl/rtl.f
  对应 sim/cocotb/*；sim/o3/{o3_tandem_top.sv,main.cpp,Makefile,tests/*}
实施：RTL 一次写完（第 12.1 节），测试按 M1～M6 六层逐层加入（第 12.2～12.7 节），下层通过后再加上层
不做：第 13 节
验收：第 12.8 节总门禁
```

## 1. 现状（`48be80d` 源码核实）

| 位置 | 现状 | L8a 要做 |
| --- | --- | --- |
| `o3_cfg_pkg.sv:286`、`:395-427` | `paddr_bits=56`；dcache 64 组 × 4 路 × 64B、4 bank、4 MSHR、2 写回；L2 256 组 × 4 路、8 MSHR、`recall_slots=2`、AXI 128 位 | 第 2 节新参数 |
| `o3_types_pkg.sv:96`、`:598-650` | `L2_BEAT_BYTES = icache.refill_beat_bytes`（16B）；`l2_req_t/l2_resp_t` 按 16B beat；`l1_recall_req_t`、`l1i_recall_resp_t`、`dc_probe_req_t`（DMA/RECALL） | 换成第 3 节协议类型；删除回收与旧 probe 类型 |
| `o3_types_pkg.sv:1019-1050` | `dcache_req_t/dcache_resp_t`、`dc_status_e`（OK/MISS_WAIT/BANK_CONFLICT/MSHR_FULL/DMA_BLOCK/ERROR）、`dc_wake_t`（按行地址）；`ld_wait_e` 已有 TLB_MISS、OLDER_STORE_ADDR、DMA_BLOCK、AD_ORDER 等 | 第 6 节 Replay 原因与唤醒 |
| `rtl/memory/l2_cache.sv` | 一次一笔、L1I recall + L1D probe 回收、16B beat 回填（闭环简化 L4） | 删除，换 `l2_home`（第 4 节） |
| `rtl/lsu/dcache.sv` | 4 × 16B bank、单个 demand 行事务、命中穿越 miss、四拍回填、inclusive probe、PTW 读与 PTE 条件置位；`clean_all_*` 遍历脏行 | 重写（第 5 节）；`clean_all_*` 改为立即完成（第 9 节） |
| `rtl/frontend/icache.sv`、`icache_mshr.sv` | 4 MSHR、16B beat 回填；接收 L2 recall | 改为 Read/ReadData 一拍整行；删除 recall（第 8 节） |
| `load_store_unit.sv:20-27` | 单发射、单 load 在途；单个依赖等待 replay 槽；DTCM 路径 | 第 6、7 节重写 |
| `load_queue.sv` | 四宽分配、按序退休；1 位 generation；无 replay 等待 | 第 6.3 节 |
| `backend.sv:395-397`、`:1366-1373` | Memory IQ 每拍发 1 条；`allow_load_i(!mem_replay_busy && !mem_replay_capture)`（T07 的按序 load 简化） | 每拍 2 条（第 7.1 节）；删除 T07 门控 |
| `dtlb.sv:14-15` | 只实现端口 0；端口 1 恒 0 | 两个查询端口（第 7.2 节） |
| `o3_cfg_pkg.sv` exec | INT PRF 4 读 2 写；FP PRF 7 读 2 写 | X3 |
| `o3_core.sv:205` | 例化 `l2_cache` | 换 `l2_home` |
| `sim/o3/main.cpp:23-24`、`o3_tandem_top.sv` | DTCM `0x1100_0000`/256KB；`unified_memory` 用例使用它 | X5 |

## 2. 参数（`o3_cfg_pkg.sv`）

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `core.paddr_bits` | 56（不变） | 架构可见：satp/PTE/TLB/PMP |
| `core.mem_paddr_bits`（新增） | 32 | L1D/L1I/L2/链路使用；`require`（`initial assert`）固定为 32 |
| `fe.icache` | 64 组 × 4 路 × 64B、4 MSHR（不变）；删除 `refill_beat_bytes` 的回填含义；`l2_txn_id_bits` → 2 | |
| `be.dcache` | `sets=64, ways=8, line_bytes=64, banks=8, mshrs=4, wb_buffers=2` | 每路 4KB，VIPT |
| `be.dcache.mshr_reserve`（新增） | 1 | 预留给 ROB 队头请求与 PTW（5.5 节） |
| `be.l2` | `sets=512, ways=8, line_bytes=64, slots=8, put_buffers=2, mem_write_buffers=2, axi_id_bits=4, axi_data_bits=128`；删除 `mshrs`、`recall_slots`、`wb_buffers`、`dma_inflight_lines` | `slots` 替代原 `mshrs` |
| `be.lsu.agu_pipes` | 2（不变，L8a 起真正使用两条） | |
| `be.lsu.ld_result_fifo`（新增） | 2 | 每条管道的 load 结果 FIFO（7.4 节） |
| `be.exec` PRF 端口 | 见 X3 | |

调试开关（X1，用于逐层排查，默认值即目标配置；必须由参数控制，不得用 `ifdef` 删减逻辑）：

| 开关 | 取值 | 默认 | 作用 |
| --- | --- | --- | --- |
| `be.lsu.mem_pipes` | 1 / 2 | 2 | 1 时只用管道 0；管道 1 的 IQ 发射与重放时隙关闭，内部来源改占管道 0 |
| `be.dcache.mshrs` | 1～4 | 4 | MSHR=1 时 `mshr_reserve` 视为 0 |
| `be.dcache.rfo_enable` | 0 / 1 | 1 | 0 时不发 RFO |

压力配置（只用于模块测试，不进 `O3_CFG`）：L1D 2 组 × 2 路、2 MSHR、1 写回槽；L2 2 组 × 2 路、2 慢槽。几何参数必须全部可推导，模块内不得写死常量（同 BL 0.2 节）。

## 3. 协议链路（`o3_types_pkg.sv` 新增 coh 段）

沿用 BC 第 1 节的四条链路、消息语义与**依赖纪律（BC 1.4）**；以下只列与 Breeze 不同的地方。

| 项 | Breeze | O3 |
| --- | --- | --- |
| 数据宽度 | 256 位（32B 行） | 512 位（64B 行），一拍一行 |
| `addr` | `paddrBits − 5` | `mem_paddr_bits − 6` = 26 位行地址 |
| REQ `id` | 1 位，只用于 L1I | `COH_ID_W = 2` 位：L1D 的 Get 用 MSHR 号，L1I 用 ICache MSHR 号，DMA 恒 0 |
| RSP↑ `Put` | 无 id（L1D 至多 1 笔） | 带 `id` = 写回槽号；`PutAck` 回送该 `id` |
| REQ `mask` | 32 位 | 64 位（只用于 DMA MaskWrite，L8a 不产生） |

```text
coh_req_t      {op: GETS/GETM/READ/MASKWRITE, addr, id, mask, data}
coh_rsp_up_t   {op: PUT/INVACK/DOWNACK, has_data, addr, id, data}
coh_snp_t      {op: INV/DOWN, owner, addr}
coh_rsp_down_t {op: DATAS/DATAE/ACKE/PUTACK/READDATA/WRITEACK, id, error, data}
```

- 握手：valid/ready；发送方在 fire 前保持全部字段（断言）。RSP↑ 与 RSP↓ 的接收方 `ready` 恒为 1（BC 1.3、3.2）。
- 在途上界（决定缓冲深度，断言不超）：L1D 的 Get = MSHR 数（4），Put = 写回槽数（2），同时至多 1 个 probe 应答；L1I 的 Read = ICache MSHR 数（4）；DMA = 1（L8a 不接）。
- 字段编码、struct 顺序和打包方式自行决定。

## 4. L2 Home（`rtl/memory/l2_home.sv` 及子模块）

**沿用 BC 第 2～11 节的全部机制**：
- S0 仲裁顺序 Put 任务 > 槽任务 > 新请求；
- S0 读 meta/PLRU，S1 比较 tag、只读命中路的 data（BC 4.2），S2 写回并形成响应；
- REQ 到 S2 才握手；槽满时撤销本次查询并置 `slotWait`；
- 同 set 串行（BC 4.3），不同 set II=1；
- 精确目录，任何 L1D 逐出都发 Put，包括干净行；
- 快路径与慢槽的分类表（BC 4.4）；
- probe 引擎、Put 任务、内存引擎的状态机；
- 断言（BC 10）。

本节只列修改项：

| 项 | 内容 |
| --- | --- |
| 客户端 | `nCores=1`：REQ 端口为 L1D、L1I、DMA；SNP 只发往 L1D。DMA 端口存在，L8a 输入 tie-off 为 0（L8b 接入） |
| 阵列 | `meta`：512 组 × 8 路 {valid, dirty, tag, dir_state, sharer}，tag = 32 − 9 − 6 = 17 位；`data`：按 `{set, way}` 寻址，每项 512 位；`plru`：每组 7 位 tree-PLRU。复位时由初始化状态机逐组清 meta，共 512 拍 |
| 目录 | 只跟踪 L1D（sharer 1 位）。**L1I 不进目录**：`Read` 命中 NONE/SHARED 直接返回 `ReadData`；命中 UNIQUE{L1D} 时分配槽发 `Down`，拿到最新数据后再回 `ReadData`（BC 4.4）。替换时只 probe L1D；L1I 中的副本不回收（B51 40.7） |
| Put 缓冲 | `put_buffers=2`，按 RSP↑ 的 `id` 存入；断言写入时该项为空 |
| probe | probe 引擎同时只处理一笔，向 L1D 至多 1 个 SNP 在途；probe 答复缓冲 1 项 |
| 慢槽 | 8 个；类型、状态机与 BC 第 5 节相同 |
| 内存引擎 | AXI4 主口，数据 128 位，一行 4 拍 INCR；读在途数 = 慢槽数，每槽固定 AXI ID；写缓冲 2 项，B 通道确认后释放；BRESP 错误按 B39 上报 fatal |
| RSP↓ 输出 FIFO | 每个客户端一个，深度 = 该客户端最大在途响应数（L1D 6、L1I 4、DMA 1），S2 写入时必有空位（断言） |
| 读错误 | 下游 RRESP 错误：`DataS/DataE/ReadData.error=1`，不安装为有效行（同 BC） |
| 性能事件 | `l2_hit`、`l2_miss`、`l2_slot_full`、`l2_probe`、`l2_writeback`（按 B48 事件表接入，编码自定） |

## 5. L1D（`rtl/lsu/dcache.sv` 重写）

### 5.1 阵列

| 阵列 | 组织 | 端口 |
| --- | --- | --- |
| tag/state | 64 组 × 8 路 × {state 2 位 I/S/E/M，tag 20 位}；放 LUTRAM，复制两份，供两条管道同拍读 | 每份 2R1W 或 1R1W，写时所有副本同写 |
| data | 8 个字 bank（bank = PA[5:3]）。每个 bank 64 组 × 8 路 × 64 位，按 `{set}` 寻址，一次读出 8 路的同一个字（同 BL 2 节“S1 预选”）；按字节掩码写 | 每 bank 1R1W（SDP BRAM） |
| plru | 每组 7 位 tree-PLRU，寄存器；选 victim 时跳过锁定的 way，优先无效 way | |
| lock | 每组每路 1 位：MSHR 目标 way、写回中的 victim | |

- 整行操作（回填安装、写回读出、probe 读出）**一拍**访问全部 8 个 bank。占用的那一拍，两条管道对任何 bank 都不能访问。
- 同一 line 内的非对齐访问可以占用两个相邻 bank，同拍读出（B49 的同 line 部分）。
- 复位：初始化状态机逐组写 tag 为 I，共 64 拍，期间所有入口 `ready=0`。
- 同拍同地址读写的返回值不被依赖（同 BL 2 节），由 5.3 节的冲突检查与快照失效覆盖。

### 5.2 流水级（每条管道）

| 级 | 动作 |
| --- | --- |
| S0 | 用 VA[11:6] 读 tag 副本 p，用 VA[11:3] 读目标 bank；LSU 同拍向 DTLB 端口 p 发查询 |
| S1 | 收 DTLB 结果（PA 或翻译异常）；寄存 8 路 tag/state 与 data |
| S2 | tag 比较，检查 PMA（含 PA ≥ 2^32 → access fault），PMP 由 LSU 并行检查；按 5.4 节给出判定 |
| PS | 提交 store 的写级（BL 3 节），每拍 1 笔，按字节掩码写 1～2 个 bank；E→M 写 tag |

- 两条管道都支持 load 与 store 地址（STA）。committed store drain、PTW 读、PTE A/D 请求使用管道 1 的 S0 时隙（5.6 节）。
- **流水线永不停顿**：S1/S2 不保持。资源不足时 S2 给出 `Replay`，请求离开流水线（取代 BL 的 `s2Hold`）。
- 取消：每个请求带 LQ/SQ 身份、代际与 branch mask；分支恢复或 flush 时，S0～S2 中被取消的请求当拍作废，不改 PLRU、不分配 MSHR。已分配的 MSHR、写回槽、PS 和 probe 不受取消影响（同 BL 3 节）。

### 5.3 S0 冲突检查与快照失效

- 沿用 BL 第 4 节：S1、S2、PS 中有效的 store 类请求与本请求同字（PA/VA 的 [11:3]）时，load 不进 S0，`Replay(CONFLICT)` 下一拍重发。
- 沿用 BL 5.3 节的快照失效规则：在本请求读阵列之后、S2 判定之前，若同组发生 refill 安装、probe 改 tag、victim 置 I 或 PS 的 E→M，则 S2 判定为 `Replay(SNAP)`，下一拍可重发。
- 两条管道在 S0 访问同一个 bank 的不同组时，较年轻的一条 `Replay(BANK)`；访问同组同字时两条都可读。

### 5.4 S2 判定（CPU load）

先按 BL 5.1 节的顺序检查翻译异常、PA 越界、PMA/PMP。可缓存 load 的判定：

| 条件 | 判定 |
| --- | --- |
| 命中（tag 匹配、state ≠ I、该路未锁定） | `Hit`，数据按 BL 5.4 节格式化（含 `isFlw` 的 NaN-boxing）；与 SQ 转发结果合并（6.2 节） |
| 与某 MSHR 同行（任意类型） | `Miss(mshr_id)`，合并，不分配新 MSHR |
| 与某写回槽同行 | `Replay(WB_LINE)`，等任一写回槽释放 |
| 未命中，MSHR 可分配，但 victim 需要写回槽而写回槽已满 | `Replay(WB_LINE)`，等任一写回槽释放（X11） |
| 未命中，可分配（5.5 节） | 分配 MSHR 发 GetS → `Miss(mshr_id)` |
| 未命中，不可分配 | `Replay(MSHR_FULL)`，等任一 MSHR 释放 |

- `Hit` 时 PLRU 更新为命中路；`Miss` 时不更新，安装时更新。
- 分配 MSHR 的同拍：选 victim、锁 way；victim 有效时分配写回槽（写回槽满则不分配 MSHR，改判 `Replay(WB_LINE)`，X11），victim 的 tag 置 I（同 BL 5.2 节）。

### 5.5 MSHR（4 项）与写回槽（2 项）

- **MSHR 只跟踪行事务**，不保存原请求，不负责回放，也没有 BL 的 REPLAY/LATE 状态。字段：`line_addr`、`is_getm`、`way`、`upgrade`、`refill[511:0]`、`err`、`grant_e`。状态：IDLE →（等写回槽读出）→ SEND → WAIT → INSTALL → IDLE。
- SEND：多个 MSHR 按分配先后轮流使用 REQ 链路（`id` = MSHR 号）。WAIT：按 `RSP↓.id` 收 DataS/DataE/AckE。INSTALL：抢占一拍整行写（5.1 节），写 tag {grant_e ? E : S}、PLRU touch、解锁 way；同拍发出唤醒事件 `install{mshr_id}`。`err=1` 时只清 tag 为 I，不写 data，唤醒事件带 `err`（同 BL 6.2 节）。
- 回到 IDLE 的同拍发 `mshr_free` 脉冲。
- **预留规则**（B51 40.3）：
  - 普通 load miss 与 RFO 只在空闲 MSHR ≥ `1 + mshr_reserve` 时分配；
  - 下列请求在空闲 MSHR ≥ 1 时即可分配：ROB 队头那条 load（由 LSU 用 `is_rob_head` 标志指示）、committed store drain、PTW 读、PTE A/D；
  - RFO 不能使用预留项，也不能占用最后一个空闲 MSHR。
- **写回槽**：沿用 BL 6.3 节。状态 READ（一拍整行读）→ SEND（Put，`id` = 槽号，M 态带数据，S/E 态 `has_data=0`）→ WAIT_ACK（按 `id` 收 PutAck）。槽有效时，同行请求 `Replay(WB_LINE)`，同行 Get 不得发出。
- 防活锁：被唤醒的 load 重发时，若该行又被替换，可以再次 `Miss`。新安装的行是 MRU，再加上队头 load 的分配优先，保证能前进；看门狗断言兜底（12 节）。L8a 不额外锁行。

### 5.6 内部来源与 S0 仲裁

优先级从高到低：

1. 复位初始化；
2. 整行操作：probe 读、refill 安装、写回读（三者由各自状态互斥；占用全部 bank 一拍）；
3. PTW 读、PTE A/D（占管道 1）；
4. committed store drain（占管道 1）；
5. LQ 重放与新发射的 CPU 请求（两条管道，见 7.1 节）。

被高优先级来源占用的管道时隙，由 LSU 在 IS 阶段事先避开（7.1 节），所以 CPU 请求不会在 S0 被丢弃。整行操作的占用拍由 L1D 提前 2 拍告知 LSU（`full_line_busy` 预告），保证这一点；实现方式自定，但不得让 CPU 请求在 S0 被静默丢弃。

### 5.7 committed store drain

- SQ 队头的已提交 store 经管道 1 进入 S0～S2：命中且 state ∈ {E, M} → 进入 PS，写完后回 `st_done`，SQ 释放；命中 S 态或未命中 → 分配 MSHR（GetM，S 态时 `upgrade=1`，锁原路），SQ 等 `install` 后重发；同行 MSHR 为 GetS → 等该 MSHR 释放后重发；PS 被占 → 下一拍重发。
- drain 不阻塞其他 load 的命中（B05）。

### 5.8 store 所有权预取（RFO，B51 40.4）

- STA 在 S2 完成地址翻译与检查后，若该行未命中或为 S 态、没有同行 MSHR 或写回槽、空闲 MSHR ≥ `2 + mshr_reserve`，就分配一个 MSHR 发 GetM（不挂等待者）；否则直接放弃。
- RFO 不改变架构顺序，不产生异常。目标不可缓存时不发。
- 事件：`rfo_issued`、`rfo_dropped`。

### 5.9 PTW 与 PTE A/D 入口

- 保持 L10 已接好的 PTW 读口与 `pte_ad_*` 口的语义（形式同 Breeze `PtwMemIO`，B50），PTW 与 `pte_ad_updater` 两侧不改。
- 两者都是内部来源（5.6 节第 3 级），按 PA 访问，不查 DTLB。命中 → 直接响应；未命中 → 分配 MSHR（PTW 用 GetS，A/D 用 GetM），等 `install` 后重发；同行 MSHR → 等该 MSHR 安装后重发。
- PTE A/D 的“完整 64 位比较 + 条件写”在 S2 判定：行必须为 E/M 态（否则先 GetM），比较成功就进入 PS 写入，不成功返回 mismatch。行为与 L10 一致，只是行获取改走协议。

### 5.10 probe 处理（`rtl/lsu/dcache_probe.sv`）

- 沿用 BL 第 10 节的接收、压住条件与处理规则。压住条件按 O3 调整：本地有同行 MSHR 处于 WAIT 时，probe 等到 INSTALL 完成（BL 10.2 节）；PS 中有同行 store 时，等 PS 写完。不得因为 LQ/SQ 中等待的请求而压住 probe（B51 40.1：流水线不停顿，所以不存在 Breeze 那种被年轻 store 卡住的环）。
- 处理：一拍整行读；`Inv` → 置 I；`Down` → M/E 降为 S。M 态时应答带数据（`InvAck`/`DownAck` 的 `has_data=1`）。同组在途请求触发快照失效。
- L8a 不做 probe 引起的 load 顺序冲刷：L8a 里只有 L2 替换（Inv）和 L1I Read（Down）会产生 probe，都不改数据内容，单 hart 没有别的写者。DMA 写入引起的冲刷在 L8b（B51 40.5）。

### 5.11 对 LSU 的接口（语义合同；信号编码自定）

| 方向 | 内容 |
| --- | --- |
| 每条管道 S0 入 | `valid`、`kind`（LOAD / STA / RFO）、VA、size、signed、`is_flw`、LQ/SQ 身份 + 代际 + branch mask、`is_rob_head` |
| 每条管道 S1 入 | DTLB 结果（PA、翻译异常）、PMP 结果、当拍取消 |
| 每条管道 S2 出 | `HIT`（数据）/ `MISS`（`mshr_id`）/ `REPLAY`（原因 ∈ {CONFLICT, SNAP, BANK, WB_LINE, MSHR_FULL}）/ `EXC`（cause） |
| 事件出 | `install{valid, mshr_id, err}`、`mshr_free`、`wb_free`、`full_line_busy` 预告 |
| store drain | 请求 / `st_done` / `st_retry{reason, mshr_id}` |
| 其他 | PTW 读口、`pte_ad_*` 口（不变）；`idle_o`；`fatal_o`（B39）；`perf_o` |

## 6. LSU 等待者：LQ 与 SQ

### 6.1 原因与唤醒

| 原因 | 唤醒事件 |
| --- | --- |
| `MSHR(k)` | `install{k}`；`err=1` 时该 load 收到 access fault（cause 5，tval = 原 VA） |
| `MSHR_FULL` | 任一 `mshr_free` |
| `WB_LINE`（写回槽同行，或替换时写回槽已满） | 任一 `wb_free` |
| `CONFLICT`、`SNAP`、`BANK` | 立即可重发 |
| `TLB_MISS`（已有） | PTW 完成（L10 已有） |
| `OLDER_STORE_ADDR`（已有，B32） | 该 store 的地址写入 SQ，或该 store 被取消 |
| `AD_ORDER`（已有，B36） | needs_D 慢路径完成 |

- 用 `ld_wait_e` 扩展实现；不得用固定拍数超时代替事件（B32）。

### 6.2 SQ 转发

- 保持 B04 6.1 节与 `store_queue.sv` 现有的转发与阻塞规则（最近的、完整覆盖的更老 store 转发；部分覆盖或数据未知就等待）。新要求是提供两个查询口，供两条管道在 S1/S2 使用。
- SQ 完整转发时，即使 L1D 判定 miss，也直接以 SQ 数据完成，不分配 MSHR（B04）。
- 每拍最多写入两个 STA 结果。

### 6.3 LQ

- 每项增加：VA、size、signed、目的 preg/域、`is_flw`、等待原因、`mshr_id`、`ready_to_replay`、`executed`、异常信息；代际位宽用 `lsu.lq_gen_bits`（8）。
- 重放不经过 IQ（B04）：重放的 load 用 LQ 中保存的 VA 直接进入 S0，不重新读 PRF，也不重算 AGU。
- 每拍从 `ready_to_replay` 的项中按年龄选最多 2 条，各占一条管道（7.1 节）。
- 退休与取消：保持现有的“按序退休释放、按 branch mask 取消”；被取消的 load，它的迟到 `install` 唤醒直接忽略。

## 7. LSU 管道与后端接入

### 7.1 发射（`backend.sv`、`backend_issue_queue.sv`）

- Memory IQ 每拍最多发 2 条，按年龄选择就绪项；删除 T07 的 `allow_load_i` 按序门控（`backend.sv:1370`）。
- 每条管道每拍只有一个时隙，按优先级分配：内部来源（5.6 节，只占管道 1）> LQ 重放 > IQ 新发射。在 IS 阶段事先确定该时隙归谁，所以 IQ 发射不会在 S0 撞上内部来源或重放。
- 两条管道的级：`IS → RR → AG → S0 → S1 → S2 → WB`。重放从 IS 选中，在 RR/AG 两级以气泡的形式随流水前进，带着 LQ 中保存的 VA，到 S0 对齐。
- load 结果在 S2 判定后进入本管道的结果 FIFO（7.4 节），不做推测唤醒（B33、B51 2.3 节）。

### 7.2 DTLB

- `dtlb.sv` 实现端口 1，两个查询端口同拍查同一 TLB 阵列。miss 处理沿用 L10 的单 miss 槽：第二条管道的 miss 在槽忙时 `Replay(TLB_MISS)`，等该槽的 PTW 完成。
- PTW 侧不变。

### 7.3 Store

- STA 与数据合并发射（地址源与数据源都就绪才发），在 S2 写入 SQ 的 PA/数据/掩码并向 ROB 报告完成（B05，现有行为）。是否把地址与数据拆开发射见 X6。
- SQ 按序 drain（5.7 节），不新增 SBuffer（B51 40.4）。

### 7.4 写回

- 每条管道的 load 结果 FIFO 深度 `ld_result_fifo=2`。IS 只在该管道 FIFO 有余量（计入在途项）时才发 load，所以 S2 不会因写回拥塞而停顿。
- FIFO 头部参加 `writeback_arbiter`（INT）或 `fp_writeback_arbiter`（FP）的年龄仲裁。PRF 端口数见 X3。

### 7.5 异常

- 翻译异常、PMA/PMP 拒绝、refill 错误：在 S2 或唤醒时记入 LQ/ROB，到提交边界精确处理（B06），故障 VA 与 PA 分开保存（现有行为）。
- 跨 line 非对齐保留当前的旧异常路径（B49 的拆分在 L8b）。

## 8. L1I 客户端（`icache.sv`、`icache_mshr.sv`）

- ICache 的 L2 接口改为协议 REQ（`READ`，`id` = ICache MSHR 号）与 RSP↓（`READDATA`，512 位一拍整行，带 `error`）。L1I 没有 RSP↑ 和 SNP。
- 回填：ICache MSHR 收到整行后，按现有安装路径一次写入（原来是收齐 4 个 16B beat 后安装）。D13/D14/D17/D27 的语义不变：同行合并、hit-under-miss、错误路径已发出的 miss 照常安装、satp 切换后旧事务自然返回。
- 删除 L2 recall 输入与相关逻辑（B51 40.7）。
- 预取（D18/D19）仍走 ICache MSHR，接口不变。

## 9. FENCE.I 数据侧（B51 40.7 提前生效）

- L1I 的 miss 通过 L2 的 Down probe 总能拿到 L1D 的最新数据，所以 L8a 起 FENCE.I **不再遍历 L1D**。`dcache.clean_all_req_i` 收到请求的下一拍就回 `clean_all_done_o`，`clean_all_busy_o` 恒为 0。`commit_ctrl` 的流程（等 SQ 排空 → 前端同步/ICache 全清）不变。
- `fencei_dcache_evict_cycles` 事件恒为 0。端口与事件编码的正式删除放在 L8b。

## 10. 物理地址宽度与 PMA

- `pma_checker` 增加检查：可缓存区必须在 `[0, 2^32)` 之内，≥ 2^32 判为不存在，报 access fault（load 5、store 7、PTW 读按 L10 的 PTW 访问错误处理）。高位不得截断。
- L1D/L1I/L2 内部的 tag 与链路地址只用低 32 位，进入前断言高位为 0。

## 11. 性能事件

L1D 新增：`dc_mshr_alloc`、`dc_mshr_merge`、`dc_replay_mshr_full`、`dc_replay_bank`、`dc_replay_snap`、`dc_wb_put`、`dc_probe`、`rfo_issued`、`rfo_dropped`；另加每拍 MSHR 占用数（用于算平均在途数）。L2 事件见第 4 节。按 B48 接入现有 HPM 事件选择，编码自定。

## 12. 实施顺序与门禁

所有命令在按 `~/leisure/flow/docs/cross-project/simulation-host.md` 选定的仿真主机上运行（首选 cloud_chen，备用 Alan，见任务书）。格式沿用 T08 报告。

### 12.1 RTL 一次写完

- 第 2～11 节全部 RTL 一次写完：新增 `l2_home` 及其子模块、重写 `dcache`、改 ICache 客户端、LSU/LQ/SQ/IQ/DTLB/PRF/写回、`o3_core` 换装、FENCE.I 数据侧、PMA；删除 `l2_cache`、`l2_recall_ctrl`、`dma_line_coord`；`rtl/rtl.f` 同步。
- 门禁（RTL 提交的门槛）：整核与所有新模块能 elaborate；`scripts/lint.sh` 0 errors；第 2 节调试开关的每种取值都能 elaborate。这时还不要求任何测试通过。
- 这一步完成后，旧的整核回归在 M5 之前会处于失败状态，这是预期的。

### 12.2～12.7 测试逐层加入（M1～M6；M 表示访存测试层，与 LOOP 的 L 级无关）

每层的规则：
- 本层测试全部通过，再加下一层。
- 本层失败就修 RTL，不放宽本层或下层的断言、黄金值和用例规模。修 RTL 后，已通过的下层要重跑。
- 每通过一层提交一次，提交信息写明 `L8a test layer Mk pass`。

| 层 | 测试 | 内容 |
| --- | --- | --- |
| M1 | `sim/cocotb/l2_home/` | 单模块，L1D/L1I 用 Python 行为代理，AXI 用 RAM 模型。定向用例（各 1 个）：GetS 未命中→DataE、命中 NONE；GetM；S→M 升级回 AckE；Put 干净行与脏行；L1I Read 命中/未命中；Read 命中 UNIQUE → Down probe 带数据 → ReadData 为最新值；替换 UNIQUE 行 → Inv probe → 脏数据写回 AXI；慢槽满时 REQ 反压，之后恢复；同组串行；AXI 读错误 → `error=1`。随机：压力几何，L1D 代理随机发 GetS/GetM/Put，L1I 代理随机发 Read；带黄金内存、SWMR 与目录监视（思路取自 `MemCoherenceMonitor`）和看门狗；2 个种子，每个种子 2000 笔 |
| M2 | `sim/cocotb/dcache/`（重写） | 单模块，L2 用 Python 行为代理。定向用例（各 1 个）：两条管道访问不同 bank 同拍命中；同 bank 不同组 → `Replay(BANK)`；未命中 → `Miss(k)` → `install{k}`；两个 load 同行合并为一笔 GetS；4 个不同行同时在途；MSHR 满 → `Replay(MSHR_FULL)` → `mshr_free`；预留规则（普通 load 不能用最后一项，队头 load 可以）；store drain 命中 E → PS → E→M；命中 S → GetM 升级回 AckE；未命中 → GetM；脏 victim 带数据 Put；干净 victim 不带数据 Put；写回槽同行 → `Replay(WB_LINE)`；Inv / Down 打在 M 行上；probe 压住条件；快照失效 → `Replay(SNAP)`；S0 store 冲突；PTW 读命中/未命中；PTE A/D 比较成功与 mismatch；RFO 发出 / 被预留规则拦下 / 同行 MSHR 时放弃；refill 错误 → `install.err` → 行保持 I；PA ≥ 2^32 → 异常；被取消的请求不改 PLRU 与 MSHR |
| M3 | `sim/cocotb/memsys/`（新增） | L1D + `l2_home` + AXI RAM，Python 驱动两条管道随机发 load、STA 与 store drain，按 LQ 语义处理重放；同时由 L1I 代理随机发 Read。黄金内存逐个 load 比对，SWMR/目录监视，看门狗。组合顺序：MSHR=1 → MSHR=4；压力几何 → 默认几何；`rfo_enable` 0 → 1。每种组合 2 个种子，每个种子 2000 笔 |
| M4 | LSU 侧模块测试 | `load_queue`、`store_queue`、`load_store_unit`、`backend_issue_queue`、`mmu`（DTLB 双端口）、`icache`、`commit_ctrl`（FENCE.I）等现有套件更新到新接口后通过。新增：LQ 按每种等待原因的等待与唤醒（6.1 节表中每行 1 例）；同拍 2 条重放；`OLDER_STORE_ADDR` 的等待保持不变；被取消 load 的迟到唤醒被忽略 |
| M5 | 整核，`mem_pipes=1` | build；九项既有回归：`run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`、`run-l7-predict`、`run-l7b-rvc`、`run-l9-fp-smoke`、`run-l9-fp`、`run-replay-order`、`run-l10-priv`；另加 `run-l10-ad`、`run-dcache-data`、`run-dcache-replay`、`run-unified-memory`（地址按 X5 改到主存）。`run-l10-vm` 保持 T08 的已知问题，不要求通过，但要记录首个失败点是否变化。周期数允许变化，退休条数与自查结果必须一致 |
| M6 | 整核，默认配置（`mem_pipes=2`、RFO 开） | M5 全部目标；新程序 `sim/o3/tests/l8a_mem.S`（`run-l8a-mem`，自查 + tohost），覆盖：跨度超过 32KB 的流式 load（触发替换与写回）；每个循环体内 4 个以上独立 miss；同行多个 load；大量 store（检查 RFO 命中）；代码与数据在同一行（触发 Down probe）；同 bank 冲突的访问模式。程序结束时打印 MSHR 平均占用、RFO 发出/有用、bank 冲突重放次数。报告记录 M5 → M6 各回归程序的周期数变化（只记录，不设阈值） |

### 12.8 L8a 总门禁

最终 SHA 上：M1～M6 全部测试与既有非访存 cocotb 同 SHA 重跑通过；lint 0 errors；`doc/LOOP.md` 的 L8 行与相关模块行更新；报告写清全部自行决定的事项、已知问题和证据边界。

## 13. 不做（留 L8b/L8c 或以后）

- L8b：A 扩展（AMO、LR/SC 走独占路径）、MMIO（AXI4-Lite，ROB 队头）、FENCE 的完整排序、B49 跨 line/跨页拆分、DMA 客户端、DMA 引起的 load 顺序冲刷、正式删除 `clean_all_*` 端口与 `fencei_dcache_evict_cycles`。
- L8c：访存依赖推测 + 1 位等待表（修订 B32）、L1D stride 预取（B07）、load 地址预测（B25）。
- 不做：推测唤醒、回填数据直接旁路给等待的 load、SBuffer、L2 预取、综合与时序收敛（L11）。

## 14. 已确认的决定（2026-10-07）

| # | 问题 | 推荐 | 其他选项 |
| --- | --- | --- | --- |
| X1 | 实施方式 | **已定（用户修订）**：RTL 一次写完，测试按 M1～M6 逐层加入（第 12 节），配合第 2 节调试开关 | 原推荐的 T09a～d 分步写 RTL，未采用 |
| X2 | 管道级划分 | `IS → RR → AG → S0 → S1 → S2 → WB`，AGU 单独一拍（100MHz 下时序稳妥；load-to-use 从 RR 起算 5 拍） | AG 与 S0 合并：少 1 拍，但“12 位加法 + BRAM 地址建立”在同一拍，L11 时序有风险 |
| X3 | PRF 端口 | INT 读 4→6、INT 写 2→3、FP 读 7→8（给第二条管道的 FP store 数据） | 不加端口，全靠仲裁：省资源，但两条管道的收益会被端口竞争吃掉 |
| X4 | 时隙优先级 | 内部来源 > LQ 重放 > IQ 新发射；内部来源只占管道 1 | 重放与新发射按年龄混合仲裁：更公平，但逻辑更复杂 |
| X5 | DTCM | L8a 移除 DTCM 数据路径与 PMA 区域；`unified_memory` 用例改用主存地址（T04b 曾发现 DTCM 2 Mbit RAM 推断错误，L11 平台也没有安排 DTCM） | 保留：LSU 多一条非缓存路径，两条管道都要接 |
| X6 | STA/STD | L8a 保持地址与数据合并发射（现有行为） | 拆开发射：store 地址能更早进 SQ（有利于 L8c 的依赖推测），但 IQ 与 SQ 都要改 |
| X7 | L1D 数据阵列 | 8 个字 bank 的 SDP BRAM，一拍一行（B51）；资源修正为约 64 块 BRAM36（64 组深度只用到 1/8） | 4 个 bank（每 bank 2 个字）：约 32 块，整行操作 2 拍，bank 冲突更多 |
| X8 | probe 在途 | L2 同时最多向 L1D 发 1 个 SNP（单核时 probe 很少） | 多个：只有 DMA 频繁时才可能有收益 |
| X9 | 防活锁 | 不锁行，依靠 MRU 安装 + 队头 load 的分配优先 + 看门狗 | 安装后锁住该行，直到等待者重放完：更稳，但要额外的计数与解锁逻辑 |
| X10 | AXI 位宽 | 仿真阶段 128 位（现有 AXI RAM 模型），L11 随 MIG 改 | 现在就用 512 位：与 MIG 用户接口一致，但仿真模型要改 |
| X11 | 写回槽满时的重放原因（2026-10-07 M2 发现：原 5.4 判 `MSHR_FULL`，而 6.1 只用 `mshr_free` 唤醒，MSHR 全空闲时 load 永不唤醒） | **已定（用户 2026-10-07 批准）**：判 `WB_LINE`，等任一 `wb_free`；`WB_LINE` 含义扩为“写回槽同行或已满”。唤醒精确，RTL 原本即如此实现 | `MSHR_FULL` 改等 `mshr_free` 或 `wb_free`：可用但有无效唤醒；新增 `WB_FULL`：语义最清，改动最多 |
