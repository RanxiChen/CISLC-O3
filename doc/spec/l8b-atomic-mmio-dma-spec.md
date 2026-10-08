# O3-T10：L8b 原子、MMIO、跨行拆分与一致性 DMA RTL spec（已冻结）

日期：2026-10-08。分支：`feat/L1-closure`。审计快照：`ac4eedd`（L8a M6 通过 `6f0565f` 之后）。行号均指该快照。

依据：[v1 计划](../O3-v1-plan.md) 第 3 节 L8；[后端基线](../design/CISLC-O3-BACKEND-DESIGN-BASELINE.md) B05、B09、B23、B26、B31、**B35**、B36、B39、B48、**B49、B50、B51（40.1、40.5、40.7、40.9）**；[L8a spec](l8a-nonblocking-mem-spec.md)（已冻结，本文只写增量）。

机制参考：Breeze `/home/chen/leisure/flow` 提交 `a304cc2`（同 L8a）。之后到 `bd48477` 只有 `09a105e` 改了 `L2Home.scala` 的阵列映射（协议与行为不变），两份 spec 未改，所以参考号不变。
- spec：`docs/l1d-rtl-spec.md`（**BL**）第 5.1、8、9、10.2、11、12 节；`docs/coherence-l2-rtl-spec.md`（**BC**）第 1.1、1.4、4.4、5.2 节。
- 源码：`design/src/main/scala/l1d/{L1DCache,L1DMmio,L1DProbe}.scala`、`cache/BreezeAmoAlu.scala`、`bus/{Axi4LiteArbiter,DmaWishboneClient}.scala`。
- 测试思路：`design/src/test/scala/memsys/{L1DCacheSpec,L1DL2SystemSpec,L2HomeSpec,L1DL2MultiCoreFaultSpec}.scala`；`docs/tasks/MEM-single-core-atomics-report.md`（两个已修 bug：AMO 等 GetM 时压住共享者 Inv 导致死锁；trap 清 reservation 的组合环）。

**原则**（沿用 L8a）：先完成后完美；机制复用不逐行翻译；流水线不停顿，慢事务交给状态机，等待记在 LQ/SQ；能由硬件做的不交给软件 trap（B49）。

**状态：已冻结（2026-10-08，用户确认第 14 节 Y1～Y14 全部按推荐实施，Y13 含仿真专用一致性断言；同日用户修订 Y1：参照 L8a，RTL 一次写完，测试按 N1～N6 逐层加入）。**

---

## 0. 任务书

```
目标：L8b —— 让 L8a 的访存底座满足 Linux 的功能需求：
      队头执行单元（HEU）：AMO / LR / SC / MMIO / 跨行拆分统一在 ROB 队头执行；
      A 扩展（RV64A）+ LR/SC reservation（B35，按 Y3 修订）；
      MMIO：PMA 新增 IO 区，核顶层 AXI4-Lite 主口；
      B49 跨 line / 跨页非对齐硬件拆分；
      一致性 DMA 客户端接入 L2 Home + DMA 写引起的 load 顺序冲刷；
      清理：FENCE.I 遗留端口与事件、旧跨行异常字段；修复 run-l10-vm（Y11）。
涉及模块（允许改动）：
  rtl/common/{o3_cfg_pkg,o3_types_pkg,o3_isa_pkg,pma_checker}.sv
  rtl/backend/{decoder,rename_stage,backend,backend_issue_queue,load_queue,store_queue,load_store_unit,rob,
               writeback_arbiter,fp_writeback_arbiter}.sv；新增 rtl/backend/mem_head_unit.sv
  rtl/lsu/{dcache,dcache_probe,dcache_mshr,dcache_amo_unit,lrsc_reservation,dtlb,ptw,pte_ad_updater}.sv
  rtl/memory/{l2_home,l2_slots,l2_probe_engine}.sv；新增 rtl/memory/{dma_line_adapter,mmio_axil_master}.sv
  rtl/system/{commit_ctrl,csr_file,trap_ctrl}.sv
  rtl/core/o3_core.sv；rtl/rtl.f
  对应 sim/cocotb/*；sim/o3/{o3_tandem_top.sv,main.cpp,Makefile,tests/*}；新增 sim/o3/o3_mmio_model.sv
实施：RTL 一次写完（第 12.1 节），测试按 N1～N6 六层逐层加入（第 12.2～12.7 节），下层通过后再加上层
不做：第 13 节
验收：第 12.8 节总门禁
```

## 1. 现状（`ac4eedd` 源码核实）

| 位置 | 现状 | L8b 要做 |
| --- | --- | --- |
| `decoder.sv:23-34`、`:506`、`:72` | 不认 opcode 0x2F，按非法指令处理 | 第 3 节 |
| `csr_file.sv:80` | `MISA=…14112c`，A 位（bit 0）为 0 | 置 1 |
| `o3_types_pkg.sv:760,775-778,839-841,990,1014,1020` | 已有 `FU_AMO`、`amo_op_e`、`uop_ext_t.{amo_op,aq,rl}`、`DC_SRC_AMO`、`dcache_req_t.amo_op`、`dcache_resp_t.sc_fail` | 沿用或按需改 |
| `o3_types_pkg.sv:1083-1097` | `rsv_clear_e` 按原 B35 清除表 | 按 Y3 修订 |
| `rtl/lsu/dcache_amo_unit.sv`、`lrsc_reservation.sv` | 空壳，不在 `rtl.f`，未例化 | 重写并接入 |
| `commit_ctrl.sv:219-220`、`backend.sv:251,2197` | `rsv_clear_*` 已计算，后端未连接 | 接到 reservation |
| `writeback_arbiter.sv:22`、`backend.sv:1551` | 第 5 个 INT 写回源留给 AMO，无人驱动 | HEU 结果从这里写回 |
| `pma_checker.sv:9-13`、`o3_cfg_pkg.sv:44-45` | 只有主存一个区域 `[0x8000_0000, 2^32)`，其余地址全部 access fault | 第 6 节 |
| `o3_core.sv:15-56` | 只有 AXI4 内存主口、DMA 口、中断口；没有 MMIO 口 | 加 AXI4-Lite 主口 |
| `commit_ctrl.sv:160` | FENCE 只按 `pred.W` 等 SQ 排空 | 第 9 节：行为已满足，只补测试 |
| `commit_ctrl.sv:94-95,216`、`dcache.sv:21,367-369,484` | `clean_all_*` 已改为“下一拍完成”，FENCE.I 实际不等它 | 删除端口（L8a 第 9 节约定） |
| `dcache.sv:262-264` | 跨 line 非对齐报 cause 4/6，`tval=vaddr` | 第 7 节拆分 |
| `o3_types_pkg.sv:1172,1224`、`rob.sv:18` | `crossline_misalign` 字段无人读写 | 删除 |
| `dtlb.sv` | 两个查询口、一个 miss 槽；每条指令只翻译一次 | HEU 用管道 1 再查一次（第 7 节） |
| `o3_core.sv:97-98,164` | DMA 顶层口 `ready=0`，`l2_home` 的 DMA 口 tie-off | 第 8 节 |
| `l2_home.sv:204-213,234-238,267-272` | DMA 客户端（端口 2）的 READ / MASKWRITE 分类、probe、合并与 `error` 回包**已实现**，从未被测试驱动 | 接入并测试；`coh_snp_t` 加 `dma_write`（Y9） |
| `o3_types_pkg.sv:1062-1074` | 顶层 `dma_req_t/dma_resp_t` 与 `coh_req_t` 形状不同 | 加转换模块 |
| `dcache_probe.sv`、`load_queue.sv:7-20` | probe 不查 LQ，LQ 无已执行 load 的顺序检查 | 第 10 节 |
| `o3_types_pkg.sv:1252-1269` | DMA 事件 `'h16-'h1c`、`'h23`、`'h24` 无人驱动；`'h22 FENCEI_RETIRED` 也未驱动 | 第 11 节 |
| `sim/o3/tests/l10_vm.S:116-124` | 投机 load 置 A 后，读回叶 PTE 的 A 位仍为 0（`0x20040c07 & 0xc0 = 0`），PC `0x80000204` 跳 fail | Y11，在 N2/N3 复现，N5 起必须通过 |

## 2. 参数

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `be.lsu.heu_enable` | 1 | 调试开关；0 时 HEU 类指令按旧行为报异常（AMO 非法、IO 区 access fault、跨行非对齐） |
| `be.lsu.split_enable` | 1 | 调试开关；0 时只关闭跨行拆分（恢复跨行非对齐异常），AMO 与 MMIO 不受影响 |
| `be.lsu.order_flush_enable` | 1 | 调试开关；0 时 LQ 不响应 `dma_write` 广播（只用于定位，N3 以上的 DMA 测试必须为 1） |

调试开关与 L8a 第 2 节相同：默认值即目标配置，必须由参数控制，不得用 `ifdef` 删减逻辑；L8a 的 `mem_pipes`、`mshrs`、`rfo_enable` 继续有效。
| `be.dcache.rsv_window` | 80 | LR 之后压住同行 probe 的最长拍数（Y4，同 Breeze `rsvWindow`） |
| `be.dcache.atomic_hold_max` | 16 | HEU 原子请求的行安装后压住同行 probe 的上限（Y5），断言不超 |
| `core.pma` IO 区 | `[0x0200_0000, 0x8000_0000)` | Y7；L11 按 SoC 地址图细化 |
| `mmio.axil_data_bits` | 64 | AXI4-Lite 数据宽度 |
| DMA 在途数 | 1 | 同 L8a 第 3 节与 BC 1.1 |

## 3. A 扩展：译码与分配

- 译码 opcode `0x2F`，funct3 = 2（`.W`）/ 3（`.D`），funct5 → `amo_op_e`：LR、SC、SWAP、ADD、XOR、AND、OR、MIN、MAX、MINU、MAXU。其余编码为非法指令。保留 `aq`、`rl` 位。
- 不是 `.W/.D` 或 funct5 未定义的，按非法指令处理。LR 的 rs2 字段按规范保留，忽略不检查。
- 分配：每条 AMO/LR/SC 分配 ROB 项与**一个 SQ 项**（不分配 LQ 项），有目的寄存器时分配 INT preg。SQ 项的 `kind = ATOMIC`。
- 进入 Memory IQ，源操作数 rs1（地址）与 rs2（AMO/SC 的数据）都就绪后发射。AGU 计算 VA = rs1（无立即数），数据与 VA 写入 SQ 项，**不在此时翻译，也不访问 L1D**。
- 对年轻 load：`kind = ATOMIC` 的 SQ 项在执行完成之前一律视为“地址未知的更老 store”，年轻 load 按 B32 等待（`OLDER_STORE_ADDR`），完成后唤醒。年轻 store 照常进 SQ，按序 drain（AMO 之后）。
- `misa.A = 1`；整核新程序用 `-march=rv64imac_zicsr_zifencei`（含 F/D 的程序按需加）。

## 4. 队头执行单元 HEU（`rtl/backend/mem_head_unit.sv`）

### 4.1 职责与触发

HEU 是 LSU 旁边的一个单项状态机，处理四类“到 ROB 队头才执行”的访存（B05、B09、B49、B51 40.1）：

| 类别 | 何时被标记 | 在 HEU 中做什么 |
| --- | --- | --- |
| AMO / LR / SC | 译码（第 3 节） | 翻译检查 → 取得 E/M → L1D 内 RMW / 读+置 reservation / 条件写 |
| MMIO load / store | S2 判定 PA 落在 IO 区（第 6 节） | 经 AXI4-Lite 读或写 |
| 跨 line 非对齐 load / store | AG 判定 `VA[5:0] + size > 64`（第 7 节） | 两半分别翻译检查，再两次 line 内访问并拼接 |

**启动条件**（三者同时满足）：该指令是 ROB 队头；`sq_committed_empty`（更老 store 都已收到 L1D 写完成确认）；没有正在进行的 trap 或 flush。
- 因为在队头且更老 store 已排空，HEU 的每个操作都同时满足 `aq` 和 `rl`；FENCE 类排序不需要额外处理。
- HEU 同时只处理一条。

### 4.2 HEU 访问 L1D

- HEU 的 L1D 请求按 **CPU 请求格式**进入管道 1（带 VA，经 DTLB 端口 1 翻译，走 S1 的 PMP 与 S2 的 PMA 检查，与普通请求相同）。
- 时隙优先级（L8b 起取代 L8a 5.6 节与 X4 的排序）：整行操作 > PTW / PTE A/D > **HEU** > committed store drain > LQ 重放 > IQ 新发射。HEU 启动时 SQ 已排空，所以与 drain 实际不冲突。
- 翻译 miss → 等 PTW 后重发；store 类（AMO、SC、拆分 store）遇到 D=0 → 在队头直接走 B36 的非推测 D 位更新（复用 `pte_ad_updater`；现有 `st_d_req` 要求 ROB 项已完成，HEU 的接法自定），完成后重发。
- 新增 `ld_wait_e` 值 `HEAD`：ROB 队头等于该 load 时唤醒（扩展 L8a 6.1 节表）。
- L1D 对 HEU 请求的判定：
  - 翻译异常、PMA/PMP 拒绝、非对齐：S2 给 `EXC`，HEU 记入 ROB，按 B26 精确处理（不退休）。
  - 需要 E/M 而行缺失或为 S 态：分配 MSHR 发 GetM（可使用预留项，同 L8a 5.5 的队头 load），HEU 等 `install{k}` 后重发。
  - 同行写回槽、bank 冲突、快照失效：`REPLAY`，HEU 按 L8a 6.1 的唤醒事件重发。

### 4.3 结果与完成

- 有目的寄存器的（AMO、LR、SC、MMIO load、拆分 load）：结果经 INT 写回仲裁的第 5 个写回源（`writeback_arbiter.sv:22` 已预留）或 FP 写回仲裁（FP 的 MMIO/拆分 load）写 PRF，同时向 ROB 报完成。
- 结果在写回前保存在 HEU 内，写回被仲裁推迟时保持等待，**不重新执行**（B09 11.1）。
- 没有目的寄存器的（MMIO store、拆分 store、`rd=x0`）：操作完成即报 ROB 完成。
- 退休时释放该 SQ 项，不再 drain（数据已经由 HEU 写完）。

### 4.4 不可撤销区与中断

- **不可撤销区**：从“第一次改变外部可见状态”起，到 ROB 完成为止。具体为 AMO 的 RMW 写入拍、SC 成功写入拍、拆分 store 的第一半写入、MMIO 的 AR/AW 发出。
- 不可撤销区内：`commit_ctrl` 不接受中断（同 Breeze `mmioBusy`）；flush 不取消 HEU。由于 HEU 只服务队头，正常不会有比它更老的指令触发 flush。
- 不可撤销区之前：中断或 flush 可以取消 HEU，HEU 回到空闲；已发出的 GetM 照常安装，没有等待者（同 Breeze kill 规则）；reservation 不受影响。

## 5. AMO 与 LR/SC 在 L1D 中的执行（`dcache.sv`、`dcache_amo_unit.sv`、`lrsc_reservation.sv`）

### 5.1 AMO

- 判定：S2 命中 E/M 且 PS 空闲 → 开始 RMW；PS 被占 → `REPLAY(CONFLICT)`。
- RMW（沿用 BL 8.3 第 5 步与 `L1DCache.scala:489-507`）：
  - 旧值 `old = 命中字 >> (PA[2:0]*8)`。`.W` 取所在 32 位，`.D` 取 64 位。
  - `dcache_amo_unit` 是纯组合 ALU（同 `BreezeAmoAlu`）：9 种运算，宽度 32/64。
  - 新值按 `PA[2:0]` 左移，按 size 生成字节掩码装入 PS；E 态时 PS 同时把 tag 写成 M。
  - 返回值 = 旧值；`.W` 符号扩展到 64 位。
  - RMW 窗口（判定拍 + PS 写入拍）内，同行 probe 等待（BL 10.2，`probe.hold` 加入 `amo_rmw`）；窗口最多 2 拍，断言。
- PMA：只有主存区支持 AMO（第 6 节）；IO 区或不支持区域 → store access fault（7）。非自然对齐 → store 地址非对齐（6），不拆分（B49）。
- refill 错误（`install.err`）→ store access fault（7），不写入。

### 5.2 LR

- 判定：S2 命中 E/M → 读出数据（`.W` 符号扩展）并建立 reservation；缺失或 S 态 → 先发 GetM（同 Breeze：LR 取独占权，SC 才能直接成功）。
- 非对齐 → load 地址非对齐（4）；PMA 不支持 → load access fault（5）；页错误 → 13。

### 5.3 reservation（`lrsc_reservation.sv`，B35 按 Y3 修订）

字段：`valid`、`paddr`（LR 的物理地址）、`size`、`line`（paddr 所在行）、`timer`（Y4 窗口剩余拍数）。

| 事件 | 动作 |
| --- | --- |
| LR 完成 | 置 `valid`，写 `paddr/size/line`，`timer = rsv_window` |
| SC 执行（成功或失败） | 清除 |
| 本核 store drain 或 AMO 写到 `line` | 清除（B35） |
| PTE A/D 实际写到 `line` | 清除（B35） |
| trap 入口、合法 xRET、SFENCE.VMA、satp 写 | 清除（B35；`commit_ctrl` 已产生 `rsv_clear_*`，在本级接上） |
| L1D 处理到 `line` 的 **Inv** probe（任何来源） | 清除（Y3 新增） |
| L1D 把 `line` 选为 victim 逐出 | 清除（Y3 新增） |
| L1D 处理到 `line` 的 **Down** probe | **不清除**；行降为 S，SC 时再 GetM |
| 普通 load、其他行的 store、`timer` 到 0、分支恢复 | 不清除 |

- 同拍规则：清除优先于建立；trap 清除只作用于寄存后的状态，SC 判定与 probe 窗口只读寄存后的 reservation（避免 Breeze `f2da3e8` 修过的组合环）。
- LR 保护窗口（Y4）：`valid && timer ≠ 0` 时，目标为 `line` 的 probe 留在 `dcache_probe` 的接收寄存器中等待（`snp_ready=0`）；`timer` 每拍减 1；SC、trap 或 `timer=0` 结束窗口。窗口内 HEU 的 SC 可以进入 L1D（同 Breeze `rsvProbeHeld`）。这是 BC 1.4 依赖纪律 2 允许的有界本地延迟。

### 5.4 SC

- 先完成地址翻译、PMA/PMP、对齐检查（权限错误优先于 reservation 失败，同 Breeze）。
- `success = valid && paddr == SC 的 PA && size == SC 的 size`（B35 的“同地址同大小”比 Breeze 的同行更严格）。
- 成功：行必须为 E/M（S 态或缺失 → GetM，安装后重发，届时重新判定）；经 PS 写入；返回 0。
- 失败：不写，不发 GetM，没有 L2 流量；返回 1。
- 无论成败都清除 reservation。

### 5.5 原子请求的前进保证（Y5）

- HEU 原子请求（AMO、LR、成功路径的 SC）分配的 MSHR 在 INSTALL 后，L1D 对该行**压住 probe**，直到 HEU 的重发在 S2 判定，最多 `atomic_hold_max` 拍（断言）。这对应 Breeze 的 `holdForMiss`（WAIT→REPLAY 期间压住同行 probe）。
- 等待 GetM 授权期间**不**压 probe：probe 照常处理（Breeze `7ecb4f0` 的修复：否则 AMO 等 GetM 时压住共享者 Inv，造成死锁）。

## 6. PMA 与 MMIO

### 6.1 PMA 区域（`pma_checker.sv`）

| 区域 | 地址 | 属性 |
| --- | --- | --- |
| 主存 | `[0x8000_0000, 2^32)`（不变） | 可缓存、RWX、AMO（算术类）、LR/SC、允许非对齐 |
| IO | `[0x0200_0000, 0x8000_0000)`（Y7） | 不可缓存、RW、不可执行、无 AMO、无 LR/SC、只允许自然对齐 |
| 其余 | — | 不存在：load/store/取指/PTW 一律 access fault（不变） |

- `pma_checker` 输出增加 `io`、`amo_ok`、`rsrv_ok`。访问跨越区域边界时判为不存在（同 Breeze `PMAChecker`）。
- 取指落在 IO 区：instruction access fault（1）。PTW 读到 IO 区：按 L10 的 PTW 访问错误处理。
- RFO 与预取不进 IO 区（L8a 5.8，不变）。

### 6.2 MMIO 路径

- 普通 load/store（含 FLW/FLD/FSW/FSD）在 S2 判定 PA 落在 IO 区时：
  - 不可缓存、不分配 MSHR、不更新 PLRU；
  - load：LQ 项保存 PA，记等待原因 `HEAD`（新增，ROB 队头成为该项时唤醒），交给 HEU；
  - store：SQ 项写入 PA 与数据，标记 `kind = MMIO`，**不向 ROB 报完成**，交给 HEU。
- 年轻 load 不因 MMIO store 等待（IO 区与主存不重叠）。
- IO 区非自然对齐 → 地址非对齐异常（4/6），不拆分（B31/B49）。
- HEU 执行（`rtl/memory/mmio_axil_master.sv`，状态机同 Breeze `L1DMmio`：Idle → Issue → Resp）：
  - 读：AR（`addr = PA`，`prot = 0`），R 返回后按 size 截取、符号扩展或 NaN-boxing（与 L1D load 格式化相同）。
  - 写：AW 与 W 独立握手；`wdata = 数据 << PA[2:0]*8`，`wstrb = ((1<<bytes)-1) << PA[2:0]`。
  - 响应 `RRESP/BRESP ≠ OKAY` → access fault（load 5、store 7），在队头精确报告。
  - 同时只有一笔 MMIO 在途。
- 核顶层（`o3_core.sv`）新增 AXI4-Lite 主口 `m_axil_*`（地址 32 位，数据 64 位）。

### 6.3 权限检查先寄存再判定（Y13、Y14）

起因：Breeze tiny 版 100 MHz 布线后 WNS = −6.112 ns，最差路径是 L1D S2 当拍做 PMP/PMA，再经判定驱动全局停顿（Breeze `docs/tasks/SOC-2-bram-report.md`、`SOC-3-timing.md` M1）。O3 没有 `s2Hold`，但 LSU 的 S1 一拍内串了 TLB → PA → PMA → PMP → 异常位 → SQ 查询门控（`load_store_unit.sv:100-115`），dcache S2 又组合地重查一次（`dcache.sv:258-259`）。L8b 给 PMA 加属性，链会更长。

- CPU 请求（含 HEU 请求）：S1 由 TLB 结果得到 PA 后，计算 PMP 结果与 PMA 的 `exists/io/amo_ok/rsrv_ok/high_addr` 位，**寄存进 S2**；S2 的异常判定、MMIO 路由、原子权限只读这些寄存位。dcache S2 删除对 CPU 请求的 PMP/PMA 组合重查。
- 内部来源（PTW 读、PTE A/D）：PA 在 S0 已知，在 S0/S1 计算并寄存，S2 同样只读寄存位。committed store drain 沿用 STA 已完成的授权（`24415b2`，不变）。
- S1 的 SQ 转发查询**不再用本拍的异常位门控**：照常查询，有异常的请求在 S2 丢弃查询结果（Y14）。
- 一致性：寄存位必须等于“按 S2 当拍的 PMP/特权上下文重算”的结果。依据是写 PMP、切换特权（trap/xRET、MPRV）都在 ROB 队头串行执行，并且会 flush（`commit_ctrl.sv:211` 的 `SYS_PMP`）。实施时在报告里核对这一点，特别是 ITLB 的 PTW 内部请求是否会跨过上下文切换。另加一个只在仿真中存在的断言（Y13）：S2 按当拍上下文重算一遍，和寄存位比较，不一致就 `$fatal`。重算逻辑与断言一起放在 `ifndef SYNTHESIS` 里，不进综合；L11 综合时核对网表中没有这份重算逻辑。
- S2 的判定优先级与结果不变：同一请求在同一上下文下，判定结果、响应、MSHR 分配与改动前一致。

## 7. 跨 line / 跨页非对齐拆分（B49）

- 范围：主存区内普通标量 load/store（含 FP），`VA[5:0] + size > 64`。AMO/LR/SC 与 IO 区不拆分（第 5、6 节）。
- 发现：AG 阶段按 VA 判定（4KB 页内行偏移与 PA 相同）。
  - load：LQ 项记等待原因 `HEAD`，交给 HEU，不访问 L1D。
  - store：SQ 项标记 `kind = SPLIT`，保存 VA 与数据，**不在此时翻译**；在 HEU 完成前，对年轻 load 视为地址未知的更老 store（B32 等待，同第 3 节 ATOMIC）。不向 ROB 报完成。
- HEU 执行：
  1. 两半：`lo` 从原 VA 到行尾，`hi` 从下一行开头到结束，字节数分别为 `64 − VA[5:0]` 与 `size − 前者`。
  2. 两半依次经管道 1 翻译与检查（跨 4KB 页时两次翻译各自独立，A/D 按各自页面处理）。**任一半异常**：整条指令报异常，cause 取出错那一半，`tval` = 出错那一半的首个 VA（B49 固定口径），两半都不写。
  3. load：两半分别读出（各自命中或 miss 等待），拼接后统一格式化（符号扩展 / NaN-boxing）写回。
  4. store：两半检查都通过后才开始写；每半需要 E/M（缺失或 S 态先 GetM），经 PS 写入。第一半写入后进入不可撤销区。不承诺两半整体原子（B49）。
- SQ 转发：年轻 load 已经等待 SPLIT 项，SPLIT 项本身不参与转发。
- 事件：`'h24` 改为 `BE_MISALIGNED_CROSSLINE_SPLIT`，在拆分访存退休时加 1（错误路径和异常不计）。

## 8. 一致性 DMA 客户端（`dma_line_adapter.sv`、`l2_home.sv`）

- 核顶层 DMA 口保持行粒度（Y8），改为 valid/ready 两个方向：
  - 请求 `dma_req_t {write, line_paddr, wdata[511:0], wmask[63:0]}`；
  - 响应 `dma_resp_t {rdata[511:0], error}`，带 `dma_resp_valid_o / dma_resp_ready_i`。
- `dma_line_adapter` 把请求转成 `coh_req_t`（`READ` 或 `MASKWRITE`，`id = 0`，行地址取 `line_paddr[31:6]`），把 RSP↓ 的 `READDATA / WRITEACK` 转回响应。断言：在途至多 1 笔；`line_paddr` 高于 `mem_paddr_bits` 的位为 0、且落在主存区（否则不发出，直接回 `error=1`）。
- `l2_home` 的 DMA 处理已在 L8a 实现（BC 4.4 分类表：Read 命中 UNIQUE → Down；MaskWrite 命中 SHARED/UNIQUE → Inv；合并规则 BC 5.2）。本级只改：
  - `coh_snp_t` 增加 `dma_write` 位：仅当 probe 引擎为 DMA MaskWrite 分配的槽发 Inv 时为 1（Y9）；
  - DMA 端口加 op 断言（只能是 READ/MASKWRITE，同 Breeze `L2Home.scala:567-571`）；
  - MaskWrite 遇到 AXI 读错误：`WRITEACK.error = 1`（L8a 已这样实现，与 Breeze 不同，保留），不安装。
- WriteAck 表示数据已写入 L2，此后 L1D 的任何 miss 都能看到新数据。
- L11 再加 AXI 从口到行请求的转换（按 SD/DMA 主设备的突发格式），本级不做。

## 9. FENCE 与 FENCE.I

- **FENCE**：现有实现已满足（B23）。FENCE 在 Decode 阻塞年轻指令；更老 load 已完成后才退休；`pred.W=1` 时等 SQ 排空；MMIO 在队头同步完成，I/O 排序自然满足；`FENCE.TSO` 按 `FENCE RW,RW`。本级不改 RTL，只补测试（第 12 节）。
- **FENCE.I**：按 L8a 第 9 节约定，正式删除 `dcache.clean_all_req_i / clean_all_done_o / clean_all_busy_o` 与 `commit_ctrl` 的对应端口和连线。流程保持：等 SQ 排空 → 前端同步（ICache 全清）→ 退休重取。`commit_ctrl` 头注释改为当前流程。
- 驱动 `BE_FENCEI_RETIRED`（`'h22`，退休握手计 1）。`'h23 BE_FENCEI_DCACHE_EVICT_CYCLE` 保留编码、恒 0、注释“已取消（B51 40.7）”，不删除不重排（枚举注释要求只追加）。

## 10. DMA 写引起的 load 顺序冲刷（B51 40.5）

问题：两个同地址的 load，年轻的先执行读到旧值；然后 DMA 写入；年老的后执行读到新值。按 RVWMO 的同地址读读一致性（CoRR），这是不允许的。

- 触发：L1D 处理 `dma_write = 1` 的 Inv probe（Y9），在置 I 的同拍把该行地址广播给 LQ。
- LQ：所有 `executed = 1`、未退休、PA 与该行相同的 load 置 `order_flush`（含用 SQ 转发得到数据的 load，保守处理）。S0～S2 中尚未判定的 load 由 L8a 的快照失效（`Replay(SNAP)`）覆盖。
- 处理（Y10）：带 `order_flush` 的 load 到 ROB 队头时，不退休，冲刷它和所有更年轻的指令，从该 load 的 PC 重新取指（复用 `commit_ctrl` 的 refetch 流程）。
- 被 HEU 处理的 load（MMIO、拆分）不需要标记：它们在队头执行，没有更老的未执行 load。
- 事件：`ld_order_flush`（新增）。

## 11. 性能事件

新增：`amo_exec`、`lr_exec`、`sc_fail`、`rsv_probe_hold_cycle`、`mmio_read`、`mmio_write`、`ld_order_flush`、`dma_read`、`dma_write`。改名：`'h24` → `BE_MISALIGNED_CROSSLINE_SPLIT`（第 7 节）。驱动：`'h16 BE_DMA_LINE_TXN`（DMA 请求被 L2 接受时加 1）、`'h22 BE_FENCEI_RETIRED`。`'h17～'h1c`（B08 行保护口径）与 `'h23` 保留编码、恒 0。新事件追加在 `'h38` 之后。

## 12. 实施顺序与门禁

主机按 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md` 选择（首选 cloud_chen，备用 Alan）。退休条数比较沿用 T09 用户批准的截止前缀解释。Y13 断言在全部仿真中开启。

### 12.1 RTL 一次写完

- 第 2～11 节全部 RTL 一次写完：译码与 `misa`、HEU、AMO/LR/SC 与 reservation、6.3 节权限寄存、PMA IO 区与 MMIO 主口、跨行拆分、DMA 转换模块与 `dma_write` 位、load 顺序冲刷、FENCE.I 遗留端口与 `crossline_misalign` 删除、事件；`rtl/rtl.f` 同步（加入 `mem_head_unit`、`dcache_amo_unit`、`lrsc_reservation`、`dma_line_adapter`、`mmio_axil_master`）。
- 门禁（RTL 提交的门槛）：整核与所有新模块能 elaborate；第 2 节新旧调试开关的每种取值都能 elaborate；`scripts/lint.sh` 0 errors。这时还不要求任何测试通过。
- 提交：`feat(memsys): implement L8b atomic, MMIO, split and DMA RTL (untested)`。之后到 N5 之前，旧的整核回归处于失败状态是预期的。

### 12.2～12.7 测试逐层加入（N1～N6；N 表示 L8b 测试层，与 L8a 的 M 层、LOOP 的 L 级无关）

每层的规则（同 L8a）：
- 本层测试全部通过，再加下一层。
- 本层失败就修 RTL，不放宽本层或下层的断言、黄金值和用例规模。修 RTL 后，已通过的下层要重跑；L8a 的 M1～M6 视为 N1 之下的既有层，受影响时同样重跑。
- 每通过一层提交一次，提交信息写明 `L8b test layer Nk pass`。
- Y11（`run-l10-vm`）：先在 N2/N3 用同样的 PTE A 位写入加普通 load 读回序列复现，再修 RTL。根因在 PTW 或 `pte_ad_updater` 时允许改这两个文件（第 0 节已列），但不改 B36 合同；需要改合同时停下。

| 层 | 测试 | 内容 |
| --- | --- | --- |
| N1 | 叶模块：`sim/cocotb/l2_home/`（扩充）、新增 `mmio_axil_master`、`dma_line_adapter` 套件 | `l2_home`（各 1 个）：DMA MaskWrite 命中 UNIQUE 脏行 → Inv 带数据 → 合并后写入；MaskWrite 未命中 → 读内存合并；MaskWrite 命中 SHARED → Inv；DMA Read 命中 UNIQUE → Down → 返回最新数据；MaskWrite 读错误 → `error=1` 且不安装；`dma_write` 位只在 DMA 引起的 Inv 上为 1；DMA 端口 op 断言。L8a M1 随机加入 DMA 代理（读写混合），2 种子 × 2000 笔。`mmio_axil_master`：读、写、AW/W 先后任意、字节选通、错误响应。`dma_line_adapter`：请求字段转换、在途 1 笔、越界地址直接回 `error=1` |
| N2 | `sim/cocotb/dcache/`（扩充） | 6.3 节：CPU 与内部请求的权限位寄存后判定结果与改动前一致；PMP/特权改变后紧接访问（允许与拒绝两个方向）；PTW 访问 PMP 拒绝区；Y13 断言全程开启。AMO（各 1 个）：9 种 AMO 的 `.W`（偏移 0/4）与 `.D`，另一半字不变；冷 miss → GetM；S 态升级 → AckE；RMW 窗口内同行 probe 等待，应答带 AMO 后的数据；AMO 等 GetM 时共享者 Inv 先完成（不死锁）；安装后到重发判定之间压住同行 probe。LR/SC：LR 取 GetM 建 reservation；SC 成功一次、再 SC 失败且无流量；同行不同地址、不同大小的 SC 失败；reservation 清除表每行 1 例（含 Inv 清、逐出清、Down 不清、timer 到 0 不清）；LR 窗口内 probe 被压住、SC 成功后应答带新数据。IO 区：不分配 MSHR、交回 HEU；IO 区 AMO → 7；非对齐 → 4/6；页错误 cause；refill 错误不写入；不可撤销区之前取消 → 无写入、无 reservation。`dma_write` Inv 置 I 同拍发出行地址广播。`run-l10-vm` 的 PTE A 位写入加普通 load 读回序列（Y11 复现） |
| N3 | `sim/cocotb/memsys/`（扩充） | L8a M3 的随机流量中加入 AMO/LR/SC（按 HEU 语义一次一条、在队头发出）与 DMA 代理（读写混合），黄金内存逐个比对，SWMR/目录监视，看门狗；`run-l10-vm` 序列若在 N2 未复现，在此复现。组合：默认几何 + 压力几何，MSHR 1 与 4，各 2 种子 × 2000 笔 |
| N4 | LSU 侧与系统模块 | L8a M4 的现有套件更新到新接口后全部通过。新增：`decoder` AMO/LR/SC 全部编码与非法编码；`store_queue` ATOMIC/MMIO/SPLIT 三种项（年轻 load 等待与唤醒、退休时直接释放不 drain）；`load_queue` `HEAD` 等待原因、`order_flush` 标记（已执行同行 load 被标记、未执行的不标记、被取消的忽略）；`load_store_unit` 跨行判定与拆分 2/4/8 字节各种偏移与 FP 版本，跨页且 `hi` 半页错误 → `tval = hi` 首地址、两半都不写，S1 SQ 查询不受异常位门控（Y14）；`mem_head_unit` 四类请求的启动条件、不可撤销区、结果保持；`commit_ctrl` 不可撤销区内不接受中断、`order_flush` 到队头冲刷重取、FENCE.I 不再有 `clean_all`；`csr_file` `misa.A=1` |
| N5 | 整核既有回归，默认配置 | L8a M6 的全部目标（含 `run-l8a-mem`）；`run-l10-vm`（`VM_AD=1`）**必须通过**，程序内全部自查（含 trap 计数）通过；另以 `mem_pipes=1` 跑 L8a M5 的目标。周期数允许变化，截止前缀必须一致 |
| N6 | 整核新程序，默认配置 | 仿真顶层新增 `o3_mmio_model.sv`（AXI4-Lite 从设备）：4KB 可读写寄存器区、一个 SLVERR 窗口、一个“读一次加一”的副作用计数寄存器、DMA 测试引擎（CPU 用 MMIO 写目标行地址、字节掩码、数据样式并启动，引擎经顶层 DMA 口发一笔行读或行写，结果与状态放在寄存器里）。四个程序（自查 + tohost）：`l8b_amo.S`：9 种 AMO 的 `.W/.D` 与边界值；LR/SC 自增循环 1000 次结果正确；SC 地址不同、大小不同、中间夹 trap 时都失败；`rd=x0` 的 AMO；AMO 非对齐 trap；`misa` 读出 A 位。`l8b_mmio.S`：1/2/4/8 字节读写与选通；副作用计数器在含分支误预测、中断的程序里**每条 MMIO load 恰好计一次**；SLVERR → 5/7；IO 区非对齐 → 4/6；IO 区取指 → 1；IO 区 AMO → 7；`FENCE` 前后 MMIO 写与主存 store 的顺序。`l8b_misalign.S`：跨行 load/store 全部偏移，与逐字节读回比对；跨页 + 第二页无映射 → page fault 的 cause/tval；跨页 + 第二页 D=0 → D 位置位；`misaligned_crossline_split` 计数等于退休的跨行访存条数。`l8b_dma.S`：CPU 写脏一行 → DMA 读到最新数据；DMA 写 CPU 持有的行 → CPU 读到 DMA 字节；LR 后 DMA 写同行 → SC 失败；DMA 写与 CPU load 交替时，load 数据始终是某一次完整写入的值。报告记录各程序周期数与第 11 节新事件计数（只记录，不设阈值） |

### 12.8 L8b 总门禁

最终 SHA 上：L8a 12.8 总门禁（M1～M6 + 既有非访存 cocotb）与 N1～N6 全部测试同 SHA 重跑通过；lint 0 errors；`doc/LOOP.md` 的 L8 行与相关模块行更新；报告写清自行决定的事项、已知问题与证据边界。

## 13. 不做

- L8c：访存依赖推测与 1 位等待表、L1D stride 预取、load 地址预测。
- 非对齐 AMO/LR/SC（规范允许报异常）；Zacas、Zabha 等后续原子扩展。
- AXI 从口到 DMA 行请求的突发转换、SD 控制器、CLINT/PLIC/UART 设备本体（L11）。
- MMIO 的多笔在途、写合并、投机读（MMIO 读可能有副作用，必须在队头）。
- litmus、多核一致性测试、综合（L11/FPGA）。

## 14. 待确认的决定

| # | 问题 | 推荐 | 其他选项 |
| --- | --- | --- | --- |
| Y1 | 实施方式 | **已定（用户修订）**：参照 L8a，RTL 一次写完，测试按 N1～N6 逐层加入（第 12 节），配合第 2 节调试开关 | 原推荐的按功能分 T10a～e 五步，未采用 |
| Y2 | AMO/LR/SC、MMIO、跨行拆分放在哪里执行 | 统一用一个 HEU，在 ROB 队头执行（第 4 节） | AMO 走 `commit_ctrl` 串行通路（像 CSR）：但 `commit_ctrl` 没有 TLB 口，要另接翻译；跨行拆分做成全流水：快，但 LQ/SQ 要存两份 PA、转发要查两行，复杂度高 |
| Y3 | reservation 清除表（改 B35） | 任何 Inv 与逐出都清除，Down 不清除（5.3 节）。理由：新的精确目录下，行被逐出后 DMA 写不会再 probe L1D，按原 B35“替换不清”会让 SC 错误成功 | 保持原 B35：需要另加机制让 L2 在 DMA 写时检查 reservation |
| Y4 | LR 之后压住同行 probe 的窗口 | 80 拍（同 Breeze），保证 LR/SC 循环前进 | 不设窗口：DMA 频繁写同行时 LR/SC 可能一直失败 |
| Y5 | 原子请求行安装后到重发判定之间 | 压住同行 probe（上限 16 拍，断言） | 不压：可能被 probe 抢走，靠重试和看门狗兜底 |
| Y6 | 跨行拆分的执行方式 | 在队头由 HEU 串行执行两半（第 7 节）。跨行访存少见，代价是每次几十拍，仍远小于 trap 模拟的几百拍 | 流水拆分：见 Y2 |
| Y7 | IO 区地址 | 暂定 `[0x0200_0000, 0x8000_0000)`，L11 按 SoC 地址图细化 | 现在就定死 CLINT/PLIC/UART 等具体地址 |
| Y8 | DMA 顶层口 | 保持行粒度（一次一行 + 字节掩码），AXI 从口转换在 L11 | 现在做 AXI 从口：要先定 DMA 主设备 |
| Y9 | 哪些 probe 触发 load 顺序冲刷 | `coh_snp_t` 加 1 位 `dma_write`，只有 DMA 写引起的 Inv 才触发 | 所有 Inv 都触发：不改协议，但 L2 替换引起的 Inv 会造成无用冲刷 |
| Y10 | 冲刷时机 | 标记 `order_flush`，到 ROB 队头再冲刷重做 | 立即冲刷：恢复更快，但要从 LQ 找最老项并发起非队头冲刷，逻辑多 |
| Y11 | `run-l10-vm` 的 A 位问题 | 纳入 L8b：在 N2/N3 复现定位，N5 起必须通过 | 继续作为已知问题留到 FPGA：Linux 启动一定会碰到 |
| Y12 | 被取消的事件编码 | `'h23`、`'h17～'h1c` 保留编码恒 0；`'h24` 改名为拆分计数 | 删除并重排：违反枚举“只追加”的约定，软件侧编号会变 |
| Y13 | 权限检查的位置（6.3 节） | S1 算完寄存，S2 只读寄存位；加一个仿真专用的一致性断言 | 保持 S2 组合检查：L11 综合时可能成为最差路径之一（Breeze 已经遇到）；不加断言：只靠串行规则的论证和定向测试 |
| Y14 | SQ 转发查询 | S1 不用异常位门控，S2 再丢弃 | 保持门控：TLB、PMP 与 SQ 比较串在同一拍 |
