# O3-T08：L10 S/U 特权与 Sv39 MMU RTL spec（已冻结）

日期：2026-10-07。分支：`feat/L1-closure`。审计快照：`2b8f6eb`（L9 收口、B49/B50 记录后）。行号均指该快照。

依据：[v1 计划](../O3-v1-plan.md) 第 3 节 L10；[后端基线](../design/CISLC-O3-BACKEND-DESIGN-BASELINE.md) B06、B07、B22、B24、B26、B27、B29、B35～B38、B48～B50；
[前端基线](../design/CISLC-O3-FRONTEND-DESIGN-BASELINE.md) 第 8 节（ICache S0～S3）、11.2、11.5～11.7（D19、D26～D28）、D24、D34。

**原则：**
- 先完成后完美（2026-10-06）：每个新行为一个简单定向用例；特权测试、riscv-tests p/v、Spike 推迟到 FPGA；L11 前不综合。
- 能由硬件做的不交给软件 trap（B49）：硬件 A/D、`time` 硬件读、Sstc、计数器 S/U 直接读。
- 访存只接现有 L3 L1D/LSU，做到功能可用；PTW→L1D 接口与 Breeze `PtwMemIO` 同形（B50），L8 换 L1D 时 PTW 侧不改。

**状态：已冻结（2026-10-07，用户确认第 14 节 X1～X16 全部按推荐实施）。**

---

## 0. 任务书

```
目标：L10 —— M/S/U 三级特权（RV64 Linux 所需子集）：S 模式 CSR、委托、SRET、TSR/TVM/TW、
      核内中断仲裁与提交（平台中断脚由 testbench 驱动）、WFI、mcounteren/scounteren、Sscofpmf、
      time 硬件读、Sstc；Sv39：ITLB、DTLB、共享 PTW、walk cache、satp、SFENCE.VMA、page fault；
      PMP（取指、数据、PTW 读）与 PMA；硬件 A/D（Svadu）。
涉及模块（允许改动）：
  rtl/common/{o3_isa_pkg,o3_cfg_pkg,o3_types_pkg,o3_pkg,pmp_checker,pma_checker}.sv
  rtl/system/{csr_file,trap_ctrl,commit_ctrl,hpm_counters,wfi_ctrl}.sv
  rtl/frontend/{itlb,icache,frontend_sync_ctrl,frontend,ifu_f0}.sv
  rtl/lsu/{dtlb,ptw,walk_cache,pte_ad_updater,dcache}.sv
  rtl/backend/{decoder,rename_entry_gate,load_store_unit,store_queue,rob,backend}.sv
  rtl/core/o3_core.sv；rtl/rtl.f
  对应 sim/cocotb/*；sim/o3/{o3_tandem_top.sv,main.cpp,Makefile,tests/*}
不做：第 12 节
验收：第 13 节
```

## 1. 现状（`2b8f6eb` 源码核实）

| 位置 | 现状 | L10 要做 |
| --- | --- | --- |
| `csr_file.sv:94-142` | 只有 M 模式 CSR；`mstatus` MPP 固定 11、写掩码 `0x6088`；`fe_csr_o/dmmu_csr_o/pmp_o/priv_o` 为常量；`irq_take_o=0` | 第 2、3 节 |
| `csr_file.sv:133` | 权限检查 `addr[9:8] > 2'b11` 永假 | 按当前特权检查（2.1） |
| `csr_file.sv:135-153` | xRET 只做 MIE←MPIE，不看 MPP、不切特权 | 2.3 |
| `commit_ctrl.sv:143-198` | 只处理 MRET；WFI、SFENCE_VMA 落入 `default: done=1`（WFI 当 NOP）；`irq_take_i` 未用；redirect kind 恒为 `SYS_EXCEPTION`；`sfence_o/wfi_retire_o/st_d_req_valid_o=0` | 第 3、6、7 节 |
| `decoder.sv:481-502` | SRET（`0x10200073`）与 SFENCE.VMA 落入 default → 非法；ECALL cause 写死 `ECALL_M`（`backend.sv:673`） | 2.4 |
| `backend.sv:239,250,263` | `wfi_stall_i/isolate_i/irq_take_i` 接 0；`csr_file` 中断输入接 0 | 接通 |
| `backend.sv:2141-2192` | ITLB/DTLB PTW、`t_ptw_mem_req`、`t_dc_pte_ad`、`t_sfence`、`t_rsv_clear` 全部 tie-off；`:2192` 断言 PMP 永不更新 | 接通；删除该断言 |
| `itlb.sv`、`dtlb.sv`、`ptw.sv`、`walk_cache.sv`、`pte_ad_updater.sv`、`pmp_checker.sv`、`pma_checker.sv`、`wfi_ctrl.sv` | 空壳；后七个不在 `rtl.f`；无实例 | 实现并接入 |
| `icache.sv:171-175,245-246,268,327,397` | `req_pa = region_base`（VA 直接当 PA）；`csr_i/pmp_i/sfence_i/ptw_resp_i` 未用 | 第 5 节 |
| `load_store_unit.sv:179,330`、`store_queue.sv:148` | `paddr = effective_addr`；只有 `(addr >> PADDR_W) != 0` 的访问错误检查 | 第 5 节 |
| `dcache.sv:74-78,99-104` | 已有 PTW 读口与 `pte_ad_*` 口，tie-off | 实现（5.4、第 8 节） |
| `frontend_sync_ctrl.sv:63-82` | 忽略 `sync_req_i.kind`，一律走 FENCE.I 流程；`sfence_o=0` | 第 6 节 |
| `o3_types_pkg.sv:53-61` | `VPN_W = VADDR_W-12 = 52`（不是 Sv39 的 27）；有 `ptw_req_t/resp_t`、`sfence_req_t`、`fe_csr_t`、`dmmu_csr_t`、`pmp_state_t`、`pte_ad_req_t`；`tlb_resp_t` 无 `perm_g`；无 PTE/satp 结构、无中断 cause | 第 11 节 |
| `o3_core.sv:78-81`、`o3_tandem_top.sv:70-71` | 有四个中断脚，全部接 0；无 `mtime_i` | 3.4、13.2 |
| Breeze `~/flow-mem` `02e3f6f` `mmu/sv39/*.scala` | 新 Sv39 MMU：阻塞式（miss 期间 TLB 不收新请求）、一次一个 walk、Svade（A=0 或 store D=0 报 page fault）、walk cache 任何 sfence 全清；**尚未接入 Breeze 核**（核仍用旧 `mmu/BreezeMmu.scala`，含 Svadu） | 第 4 节按 O3 修改 |
| Breeze `core/RegFile.scala:159-838` | M/S CSR、委托、中断优先级、SRET/MRET、TSR/TVM/TW、Sstc、PMP CSR 语义 | 第 2、3 节按语义重写（B29） |

## 2. 特权模式与 CSR（`csr_file.sv`）

### 2.1 当前特权与 CSR 访问检查

- `priv_q`（2 位，复位 M=11）为架构特权。合法值 M/S/U；无 H。
- 访问检查（B22 队头执行时）：`priv_q < addr[9:8]` → 非法；写 `addr[11:10]==11` → 非法；FP CSR 在 FS=Off → 非法（L9）；`satp` 在 S 模式且 `TVM=1` → 非法；计数器与 `stimecmp` 见 3.3、3.4。未实现地址非法。

### 2.2 CSR 清单（语义参考 Breeze `RegFile.scala`，标“修正”处不照搬）

| CSR | 内容 |
| --- | --- |
| `mstatus` | 可写：SIE、MIE、SPIE、MPIE、SPP、MPP（WARL：写 2 视为 U，同 Breeze）、FS、MPRV、SUM、MXR、TVM、TW、TSR。只读：UXL=SXL=2，SD=(FS==3)。MBE/SBE/UBE、XS、VS 为 0 |
| `sstatus` | `mstatus` 的 S 视图：SIE、SPIE、SPP、FS、SUM、MXR、UXL、SD |
| `medeleg` | 可写位 {0,1,2,3,4,5,6,7,8,12,13,15}（11 不可委托；bit 0 在 IALIGN=16 下永不发生，可写无害——**修正**：Breeze 不含 bit 0，按规范可写） |
| `mideleg` | 可写 {1,5,9,13}（SSI、STI、SEI、LCOFI） |
| `mie` / `mip` | `mie` 可写 {1,3,5,7,9,11,13}。`mip`：MSIP/MTIP/MEIP 只读（平台脚，3.1）；SSIP、SEIP（软件位）、LCOFIP 可写；STIP 在 `menvcfg.STCE=0` 时可写，=1 时只读为 `time >= stimecmp`。SEIP 读值 = 软件位 \| 平台 `irq_s_ext_i`，读改写只改软件位（同 Breeze） |
| `sie` / `sip` | `mie/mip & mideleg` 的视图；`sip` 只可写 SSIP、LCOFIP（且须已委托） |
| `stvec`、`mtvec` | 模式 0/1，其他值写为 0；向量模式只对中断加偏移 |
| `sepc`、`mepc` | `& ~1`（IALIGN=16） |
| `scause`、`mcause` | WLRL，O3 实现为：合法值 = 中断位 0 且异常码 ∈ {0,1,2,3,4,5,6,7,8,9,11,12,13,15}，或中断位 1 且中断码 ∈ {1,3,5,7,9,11,13}；其余位为 0。非法写**整次忽略，保留旧值**（Q1）。（**修正**：Breeze 原样存） |
| `stval`、`mtval`、`sscratch`、`mscratch` | 原样 |
| `satp` | MODE ∈ {0 Bare, 8 Sv39}，其他 MODE 写入忽略（整次写不生效，同 Breeze）；ASID 16 位全可写；PPN 44 位。写入触发 6.2 同步 |
| `menvcfg` | 可写 STCE(63)、ADUE(61)（X10）；其余 0 |
| `senvcfg` | 实现为全 0 只读（**修正**：Breeze 未实现会使访问非法；Linux 可能访问，按 B49 不让它 trap） |
| `mcounteren`、`scounteren` | 32 位全可写（3.3） |
| `stimecmp` | 3.4 |
| `pmpcfg0/2`、`pmpaddr0～15` | 第 9 节 |
| `time` | 3.4 |
| `scountovf` | 3.3 |

### 2.3 trap 入口与返回（B26、B27）

- **委托**：`priv_q != M && (is_interrupt ? mideleg : medeleg)[cause]` → 进 S，否则进 M（同 Breeze）。
- **进 S**：`sepc←epc`、`scause`、`stval`（中断为 0）、`SPIE←SIE`、`SIE←0`、`SPP←(priv==S)`、`priv←S`；目标 `stvec`。
- **进 M**：同理写 `m*`，`MPP←priv`、`priv←M`；目标 `mtvec`。
- **MRET**（仅 M 合法）：`MIE←MPIE`、`MPIE←1`、`priv←MPP`、`MPP←U`；`MPP != M` 时 `MPRV←0`；目标 `mepc`。
- **SRET**（U 非法；S 且 `TSR=1` 非法）：`SIE←SPIE`、`SPIE←1`、`priv←SPP`、`SPP←U`、`MPRV←0`；目标 `sepc`。
- `trap_update_i` 增加 `is_sret`（或以 `xret_kind` 区分），`trap_target_pc_o` 按上表选择；`commit_ctrl` 的 redirect kind 对 xRET 用 `SYS_XRET`，中断用 `SYS_INTERRUPT`。
- xRET 与 trap 都是 flush 型重定向（现有 `flush_all` 路径），前端从目标重新取指，新特权在下一拍生效。

### 2.4 译码（`decoder.sv`）

- 新增 SRET（`0x10200073`）→ `sys_op=SRET`；SFENCE.VMA（funct7 `0001001`、rd=0、funct3=0）→ `sys_op=SFENCE_VMA`，记录 `rs1`/`rs2` 是否为 x0（D26）并读两个整数源。两者 `serialize`、`block_younger`（同其他 SYSTEM）。
- 合法性在队头按当前特权判（commit_ctrl，不在译码）：MRET 需 M；SRET 见 2.3；SFENCE.VMA 在 U 非法、S 且 `TVM=1` 非法；WFI 在 U 非法、S 且 `TW=1` 非法（立即非法，不设超时）。非法时按 B26 报非法指令，`tval` = 指令编码。
- ECALL cause 按当前特权：U→8、S→9、M→11。cause 在队头生成（译码只标 ECALL），以免特权在途变化。

## 3. 中断、计数器、时间

### 3.1 中断来源（X3）

- 核内实现完整的中断判定与提交；平台中断由 `o3_core` 的 `irq_m_ext_i`、`irq_m_timer_i`、`irq_m_soft_i`、`irq_s_ext_i` 输入（端口已存在），L10 由 testbench 驱动，L11 接 CLINT/PLIC。
- `mip` 组成：MEIP/MTIP/MSIP = 对应脚；SEIP = 软件位 \| `irq_s_ext_i`；STIP 见 2.2；SSIP、LCOFIP 软件/计数器置位。

### 3.2 判定与提交（B26、B37、B38）

- 优先级（同 Breeze、规范）：MEI > MSI > MTI > SEI > SSI > STI > LCOFI。
- 全局使能：目标 M 的中断在 `priv < M || MIE` 时可取；委托给 S 的在 `priv == U || (priv == S && SIE)` 时可取。未委托的 S 中断按 M 中断处理。
- `csr_file` 组合给出 `irq_take_o`、`irq_cause_o`；`commit_ctrl` 在**指令边界**接受：本拍无正常退休进行中的 trap、队头不是已开始执行的串行项（`serial_done_q` 置位的 CSR 须先退休，B22），且不在 WFI 唤醒检查之外的不可撤销窗口（L10 无 MMIO/AMO，此条只保留接口）。接受拍不退休任何指令（B26），`epc = committed_next_pc`（B37，含 ROB 空），`tval=0`，cause 最高位置 1。
- CSR 写改变使能/挂起/委托后，下一拍重新判定（组合路径自然满足）。

### 3.3 计数器访问（B48 L10 部分）

- `mcounteren`/`scounteren` 的 CY/TM/IR/HPMn 位控制 `cycle`/`time`/`instret`/`hpmcounterN` 的访问：S 模式需 `mcounteren` 对应位；U 模式需 `mcounteren` 与 `scounteren` 都置位；否则非法指令。
- Sscofpmf：`mhpmevent` 的 OF(63)、MINH(62)、SINH(61)、UINH(60) 可写；计数时按当前特权与 *INH 位过滤；从全 1 回绕且 OF=0 时置 OF 并置 `mip.LCOFIP`。`scountovf`（0xDA0）只读：M 模式读各计数器 OF 位；S 模式读 `OF & mcounteren.HPMn`（未授权位读 0，不报非法）；U 模式访问非法（S 级 CSR）。
- `hpm_counters.sv` 增加 `priv_i` 输入用于 *INH 过滤。

### 3.4 `time` 与 Sstc（B49）

- `o3_core` 新增 `mtime_i[63:0]`。`time`（0xC01）读 `mtime_i`，按 3.3 门控（TM 位）。L10 testbench 每拍加 1（13.2）。
- `stimecmp`（0x14D）：复位全 1，原样写。S 模式访问需 `menvcfg.STCE=1 && mcounteren.TM=1`，否则非法；M 总可访问。
- `menvcfg.STCE=1` 时 `mip.STIP = (mtime_i >= stimecmp)`，只读；`STCE=0` 时 STIP 为软件位。
- L10 即可通过 STIP 交付 S 模式定时器中断（3.2）；L11 只接 CLINT 的 `mtime` 与 `mtimecmp/MTIP`。

### 3.5 WFI（B38，`wfi_ctrl.sv`）

- 合法 WFI 在队头正常退休；退休那拍若 `|(mip & mie)` 为 0 则进入睡眠（同拍已有唤醒条件则不睡）。`committed_next_pc` 指向其后继。
- 睡眠：`rename_entry_gate.wfi_stall_i=1`，不放行新指令；SQ drain、cache 回填照常；时钟不门控。
- 唤醒：`|(mip & mie)`，不看全局 MIE/SIE、不看委托。唤醒后 3.2 判定，可取则进 trap，否则继续执行后继。
- 睡眠中发生 trap 以外的系统事件（不存在）不处理。

## 4. Sv39 MMU 结构（X1、X2、X4～X7）

### 4.1 来源与修改

- **机制来源**：Breeze 新 Sv39 MMU（`mmu/sv39/*.scala`，规范 `docs/breeze-mmu-rtl-spec.md`），手工翻译其 TLB 阵列组织、PLRU、PTE 检查、PTW 状态机与 walk cache；按下列 O3 要求修改。**不做 B47 等价检查**（结构已改，X1）；改为把 Breeze `Sv39MmuSpec` T1～T17 中适用的用例翻译成 cocotb，参考模型为独立 Python 页表遍历器。
- 与 Breeze 的差异（O3 修改）：
  1. TLB **非阻塞**：miss 不阻塞后续命中（X2）。
  2. **硬件 A/D**（Svadu，第 8 节），不是 Svade。
  3. walk cache **按 SFENCE 范围精确失效**（4.4），不是任何 sfence 全清。
  4. 有效特权的 MPRV 仅在 `priv == M` 时生效（**修正** Breeze 漏判）。
  5. TLB 同 VPN 多命中不得断言失败（软件可能制造，取最低索引，同 Breeze 旧 MMU 的处理）。
  6. PTW 读页表的 PMP/PMA 失败必须返回带 `access_fault` 的响应（**修正** Breeze L1D 的 TODO：失败时无响应会挂死 PTW）。

### 4.2 参数（X4，取 Breeze 默认）

| 结构 | 组织 |
| --- | --- |
| ITLB、DTLB | 各 8 组 × 4 路 4 KiB 页（同步读 RAM 或寄存器，实现自选）+ 4 项全相联大页（寄存器，2 MiB/1 GiB）；树 PLRU |
| ASID | 16 位；每项带 ASID 与 G |
| walk cache | 上层：key=VPN[2]，1×4；中层：key=VPN[2:1]，2×4；寄存器；ASID 标记 + 路径累计 G（Q2）：G=1 的项对任意 ASID 命中 |
| PTW | 1 个 walker（`ptw_slots=1`）；请求队列 ITLB 1 项、DTLB 1 项 |
| `o3_cfg_pkg` | `itlb.entries=32/ways=4`、`dtlb_entries=32/dtlb_ways=4` 与上表一致；`walk_cache_entries` 改为分层参数；“待定”注释改为本 spec |

- `o3_types_pkg`：Sv39 的 VPN 为 27 位。新增 `SV39_VPN_W=27`；`ptw_req_t.vpn` 等 MMU 内部类型使用 27 位（`VPN_W=52` 保留给其他用途或一并改名，实现自选，报告写明）。

### 4.3 TLB 时序与命中检查

- S0 收请求读阵列，S1 比较、权限检查与响应（同 Breeze 两拍）。每拍可收一个请求。
- **有效特权**：数据访问 `eff = (priv == M && MPRV) ? MPP : priv`；取指 `eff = priv`。`eff == M` 或 `satp.MODE == Bare` 时直通：`paddr = vaddr`（取 PADDR_W 低位，高位非零由 PMA 判不存在）。
- 非规范 VA（Sv39 下 `VA[63:39]` 不全等于 `VA[38]`）→ page fault（取指 12、load 13、store 15）。注：Breeze 用 `[63:38]`，即同一判定。
- 权限（同 Breeze `Sv39Tlb.scala:51-54`，A/D 部分按第 8 节修改）：
  - 取指需 X；load 需 R 或（MXR 且 X）；store 需 W；
  - U 模式需 `pte.U`；S 模式访问 `pte.U=1` 的页：取指一律失败，数据需 `SUM=1`；
  - A=0 或 store 且 D=0：**不报错**，走第 8 节。
- 命中返回 PPN、大页级别、权限位与 G；PA 按级别拼接。TLB 项的 G 为**整条遍历路径的累计 G**（各级 PTE 的 G 取或，规范：非叶子 G=1 表示其下所有映射为全局，Q2）。
- **miss**：DTLB 返回 `miss`，请求方（LSU）挂起该访存并让出流水线（B04，复用现有 replay 槽，`LDW_TLB_MISS`）；DTLB 记录该 VPN 并向 PTW 请求。miss 期间 DTLB **继续服务其他请求的命中**；同 VPN 的第二个 miss 合并，不同 VPN 的第二个 miss 在请求队列满时返回 `miss` 并稍后重试（X2）。
- PTW 返回后回填（无效路优先，否则 PLRU）并唤醒挂起者重新查询；PTW 返回 fault 时不回填，按 Breeze 的“pending fault”方式在该 VPN 下一次查询时交付一次（X7），然后清除。kill（分支误预测、flush）清除未交付的 pending fault。
- ITLB 同理（第 5.1 节），取指 miss 时 ICache 该请求在 S1 判为 miss、不发 L2 请求，挂起到 PTW 返回后重新查询。

### 4.4 SFENCE.VMA 范围（D26，X5）

| rs1 | rs2 | TLB | walk cache |
| --- | --- | --- | --- |
| x0 | x0 | 全部（含 G） | 全部 |
| x0 | ≠x0 | ASID 匹配且非 G | ASID 匹配且非 G |
| ≠x0 | x0 | 覆盖该 VA 的叶子项（含 G，按各项页大小匹配） | 不变 |
| ≠x0 | ≠x0 | 覆盖该 VA、ASID 匹配且非 G | 不变 |

- 依据：规范规定 `rs1≠x0` 只排序该 VA 的**叶子** PTE，非叶子缓存可保留；这比 Breeze 的“任何 sfence 全清”性能好且符合 B07“不得退化为全清”。
- `rs2` 寄存器值的低 16 位为 ASID；VA 非规范不报错（D26）。
- TLB 精确失效需逐组扫描大页阵列与 4 KiB 阵列的对应组：4 KiB 阵列只扫 VA 所在组（1 拍读 + 1 拍写），大页阵列全并行比较；`rs1=x0` 情形为全部项并行比较（寄存器 valid 位）。

### 4.5 PTW（`ptw.sv`）

- 状态机同 Breeze：`IDLE → LOOKUP（walk cache） → REQ → WAIT → CHECK`，每级 L+2 拍；walk cache 中层命中从 level 0 开始，上层命中从 level 1 开始，否则从 `satp.PPN` 的 level 2 开始。
- ITLB/DTLB 请求**轮转**仲裁（X6，Breeze 为 D 固定优先，可能饿死取指）。
- 请求时快照 `satp.PPN/ASID` 与 `xlate_epoch`；返回时 epoch 不等于当前值则丢弃、不回填、不交付（D27）。
- CHECK：`!V || (!R && W)` 或 `pte[63:54] != 0`（无 Svpbmt/Svnapot，N/PBMT 非零即保留）→ page fault；叶子大页 PPN 未对齐 → page fault；level 0 遇非叶子 → page fault；PTE 读访问错误 → access fault（取指 1、load 5、store 7），优先于 page fault。非叶子的 U/A/D 不检查（规范保留位，同 Breeze 新 MMU）。
- 叶子返回后若需要置 A（第 8 节），先完成 A 更新再交付。
- 非叶子 PTE 填 walk cache（level 2→上层，level 1→中层），带 ASID 与截至该级的累计 G；walk cache 捷径命中时以其累计 G 作为遍历的初始 G 继续累计（Q2；新 Breeze 只取叶子 G，此处不照搬）。
- 访存接口 `mem_req{paddr}` / `mem_resp{data, access_fault}`（与 Breeze `PtwMemIO` 同形，B50），接 `dcache.sv` 已有的 PTW 读口（5.4）。PTW 读页表前做 PMP（以 S 模式、8 字节、读权限检查）与 PMA（须为可缓存主存）检查，失败直接以 `access_fault` 结束，不发 DCache 请求。
- `idle_o` 供 SFENCE 等待（第 6 节）。

## 5. 接入取指与数据访存

### 5.1 取指（`icache.sv`，前端第 8 节）

- S0：ITLB 与 tag/data 阵列并行启动（ITLB 用 `region_base` 的 VA）。S1：ITLB 结果，用 PPN 组成 PA 替换 `s1_meta_q.tag`（`icache.sv:298`）。S2：way 比较与 PMP 范围匹配、PMA 属性；S3：PMP 优先级/权限合并、数据选择、响应或 miss（PMP 不在一拍内完成全部，前端第 8 节）。
- 现有把 VA 当 PA 的位置（`:171-175`、`:245-246` 最近行命中、`:268` 同行阻塞、`:397` MSHR 行地址）一律改用 S1 之后的 PA；最近行命中缓存的键加上 `xlate_epoch` 与特权上下文，或在 epoch/特权变化时清除（实现自选）。
- VIPT：index/bank 位须在页内偏移 12 位以内（`icache.sv:143` 已有断言）。
- 取指 page fault（12）、access fault（1，PMP/PMA 或 L2 错误）作为 `icache_resp.exc_*` 交付；`tval` = 出错半字所在地址：普通情形为指令 PC，D34 edge 后半字跨页出错时为区域基址 `B`（`ifu_f0.sv:106` 已按 D34 处理）。
- ITLB miss：该请求不发 L2，等待 PTW；同一时间只挂一个取指 miss（取指本来顺序）。

### 5.2 数据访存（`load_store_unit.sv`）

- 地址生成后查 DTLB，DTLB 命中后对 PA 做 PMP（按有效特权、load=R/store=W、访问字节范围）与 PMA 检查，全部通过才发 DCache（B06：TLB 命中不等于许可）。替换 `:179` 的临时访问错误检查与 `:330` 的直通。
- load 异常：page fault 13 / access fault 5，`tval` = 出错 VA（B06：VA 与 PA 分开保存）。store：15 / 7。
- store 的 SQ 项保存 PA（`store_queue.sv:148` 不再自行用 VA）；store 翻译与权限在地址执行时完成，与现有 SQ 地址写入同拍或晚一拍（实现自选）。
- **两次翻译接口（B49）**：DTLB 的请求/响应与 LSU 的挂起状态按“请求”而非“指令”记账，一条访存可先后发起两次翻译；L10 不实现跨 line 拆分（L8），但接口和挂起状态不得假定一条指令只有一个页。
- MMIO：L10 无 MMIO 区（PMA 只有主存与 DTCM，第 10 节），不处理。

### 5.3 DTCM

- DTCM（`0x1100_0000`，256 KiB）按 PMA 为可读写、不可执行、可缓存=否；经 MMU 翻译后的 PA 落在 DTCM 时走现有 DTCM 路径。

### 5.4 DCache 的 PTW 读口（`dcache.sv:74-78`）

- 实现现有端口：PTW 读按物理地址查 L1D，命中返回 8 字节；miss 按现有单 MSHR 流程回填后返回。与 CPU 请求仲裁时 PTW 优先（PTW 读不被 kill，B07 前进性：CPU 请求不得因等待翻译而占满唯一 MSHR——现状 load 只有一个在途且 TLB miss 的 load 不占 MSHR，满足）。
- 端口语义与 Breeze `PtwMemIO` 相同：每个请求恰好一个响应。

## 6. 系统同步：SFENCE.VMA、satp、PMP（B24、D26～D28）

### 6.1 SFENCE.VMA（`commit_ctrl` 队头串行）

1. 合法性检查（2.4）。
2. 等已提交 SQ 全部写入 DCache（B24：写完成确认，非仅接受）。
3. 等 PTW `idle`（X8，单 walker、PTW 读不被 kill，等待有界）。
4. 向 ITLB、DTLB、walk cache 发 `sfence_req_t`（4.4 范围），1 拍；`xlate_epoch++`。
5. 前端同步：`frontend_sync_ctrl` 按 `kind=SFENCE` 只做“停取指、丢弃在途取指、重新取指”，**不**失效 ICache（物理 tag，B24）。
6. 指令退休，`flush_all` 重定向到后继（`SYS_SFENCE`）。
- 清 LR/SC reservation（B35，L10 无 reservation，接口保留）。

### 6.2 satp 写入（D27）

- CSR 写 `satp` 生效后（B22 队头），`csr_resp.needs_refetch=1, refetch_kind=SATP`：`xlate_epoch++`、本条退休后 `flush_all` 重定向到后继（`SYS_SATP`）。**不清 TLB**（条目按 ASID/G 匹配）；在途 PTW 不等待，旧 epoch 的返回被丢弃（4.5）。
- MODE 在 Bare/Sv39 之间切换同样处理。

### 6.3 PMP 写入（D28）

- 有效的 `pmpcfg/pmpaddr` 写入：`needs_refetch=1, refetch_kind=PMP`，更新 PMP 派生状态，本条退休后 `flush_all` 重定向（`SYS_PMP`）；ICache 数据保留，命中仍重新检查 PMP。PMP 结果不缓存在 TLB 中（每次访问都检查），所以 TLB 不需清除。

### 6.4 其他

- `mstatus` 中影响翻译的位（SUM、MXR、MPRV、MPP）只影响数据访问，且 CSR 指令 `block_younger`，年轻访存尚未 rename，不需额外同步；特权变化只经 trap/xRET（flush 型重定向）。

## 7. 前端同步控制（`frontend_sync_ctrl.sv`）

- 按 `sync_req_i.kind` 区分：`FENCE_I` 走现有流程；`SFENCE`、`SATP`、`PMP`：停取指与预取、等在途取指完成或作废（复用现有 WAIT_IDLE），不发 `inv_all`；`SFENCE` 额外向 ITLB 转发 `sfence_o` 并等 `sfence_done_i`。
- 预取翻译缓存（`prefetch_xlate_cache.sv`）：预取器当前未启用（`icache.sv:451-452`），L10 不接入（第 12 节）。

## 8. 硬件 A/D（B36，Svadu，X9、X10）

### 8.1 A 位（推测路径可做）

- PTW 得到叶子且 `A=0`（取指、load、store 都适用），在交付翻译前由 `pte_ad_updater` 原子置 A：向 DCache `pte_ad` 口发 `{pte_paddr, expected_pte, set_a}`，DCache 读该 PTE、**完整 64 位比较**，相等则写入 `expected | A` 并返回成功；不等返回失败，PTW 重新遍历该 VA（不是报错，B36）。
- 成功后以新 PTE 回填 TLB、交付翻译。

### 8.2 D 位（只在队头非推测做）

- store 的 DTLB 命中且 `W=1` 但 `D=0`：不报错，返回 `perm_d=0`；LSU 照常完成地址/数据写入 SQ，但该 store 标记 `needs_D`，其 ROB 项不 complete（或 complete 但带 `needs_D` 标志，实现自选）。
- 该 store 到达 ROB 队头时，`commit_ctrl` 串行执行：`pte_ad_updater` 对该 VA 重新遍历（可走 walk cache），得到叶子后检查权限仍允许写，原子比较并置 `A|D`，成功后失效 DTLB 中该 VA 的旧项（或直接以新 PTE 回填），然后 store 正常退休。比较失败则重新遍历；遍历得到 page fault/access fault 则该 store 按 B26 报异常（归属原指令）。
- 排序：`needs_D` store 之后更年轻的访存不得越过它进入 DCache（B36 “阻止年轻访存越过”）。L10 实现：LSU 在存在未处理的 `needs_D` store 时，对其后的 load 判为等待（`LDW_AD_ORDER`），到该 store 处理完再放行。L10 访存本来近乎串行，性能影响可接受。
- 取消、`satp` 写、SFENCE 使 epoch 变化后，`pte_ad_updater` 不得为旧 epoch 发起新的 PTE 写（B36）。
- **A/D 写的物理检查（Q3）**：PTE 的原子读—比较—条件写按 S 模式、8 字节检查 PMP（须 R 与 W 都允许）与 PMA（须为可放页表的可缓存主存），在发往 DCache 前完成。失败则不写 PTE，向原访问交付 access fault：取指 1、load 5、store 7；`tval` = 原 VA。队头 D 更新失败归属原 store（cause 7）。

### 8.3 DCache `pte_ad` 口（`dcache.sv:99-104`）

- 在现有 L3 DCache 上实现一个原子“读—比较—条件写”操作：占用 DCache 串行处理该行（命中直接做；miss 先回填再做），期间同一行的 CPU 请求等待。这是 L10 的功能实现；L8 按 B50 在新 L1D 上重新提供同语义入口。
- PTE 写入是普通数据写，DMA/一致性在 L8 之后由协议保证。

### 8.4 `menvcfg.ADUE`（X10）

- ADUE=1：上述硬件 A/D；ADUE=0：Svade 行为，A=0 或 store D=0 直接报 page fault（即 Breeze 新 MMU 的行为，实现代价很小）。
- 规范（Machine-Level ISA 1.13，menvcfg）：实现 Svadu 时 ADUE **必须可写**；ADUE=0 时表现为 Svade。规范未规定复位值。O3 复位 ADUE=1（与 QEMU“只声明 svadu”配置一致）；L11 设备树只声明 `svadu`、不声明 `svade`，Linux 据此认为启动时硬件 A/D 已开启。

## 9. PMP 与 PMA（X11、X12）

### 9.1 PMP（`pmp_checker.sv`）

- 条目数 `pmp_entries`：见 X11。CSR `pmpcfg0`、`pmpcfg2` 与 `pmpaddr0～15` 均可访问；超出条目数的部分读 0、写忽略。
- 粒度 G=0（4 字节），支持 OFF/TOR/NA4/NAPOT；`pmpaddr` 54 位；cfg 的 [6:5] 写 0；`W=1,R=0` 写为 `W=0`（同 Breeze）；L 位锁定 cfg 与 addr（TOR 时下一项的 L 也锁本项 addr）。
- 检查：编号最小的匹配项决定结果，访问字节须全部落在该项内，否则失败；无匹配时 M 允许、S/U 拒绝；M 模式仅在匹配项 L=1 时受限。
- 三处使用：取指（ICache S2/S3，eff=priv，X）、数据（LSU，eff 按 MPRV，R/W，访问字节数）、PTW 读（S 模式、8 字节、R）。

### 9.2 PMA（`pma_checker.sv`，X12）

| 区域 | 属性 |
| --- | --- |
| 主存 `[0x8000_0000, 0x1_0000_0000)` | 存在、可缓存、可执行、可读写、可放页表 |
| DTCM `[0x1100_0000, +256 KiB)` | 存在、不可缓存、不可执行、可读写、不可放页表 |
| 其他（含 ≥ 2^32） | 不存在：访问 → access fault |

- 参数化于 `o3_cfg_pkg`，L11 加入 MMIO 区（CLINT、PLIC、UART、SPI）。与 B50 的“≥2^32 判不存在”倾向一致；`paddr_bits` 保持 56。
- 仿真 AXI RAM 只有 2 MiB：超出部分 PMA 判存在，但 AXI 返回 SLVERR → access fault（现有行为）。

## 10. 观测与性能事件

- 按 B48 把 L10 事件加入编号表：ITLB miss、DTLB miss、PTW walk（已有 `BE_PTW_WALK=0x12`）、walk cache 命中（`0x13`）、A 更新次数、D 更新次数、SFENCE 次数。事件号接续现有表，报告写明。
- `retire_info` 不增加特权/翻译字段（Spike 比对推迟到 FPGA）。

## 11. 类型、端口与配置汇总

- `o3_isa_pkg`：中断 cause（1 SSI、3 MSI、5 STI、7 MTI、9 SEI、11 MEI、13 LCOFI）、`PRIV_U/S/M`。
- `o3_types_pkg`：`SV39_VPN_W=27`；Sv39 PTE 结构；`tlb_resp_t` 加 `perm_g`；`trap_update` 区分 MRET/SRET；`fe_csr_t`、`dmmu_csr_t` 补 `priv_eff`/`mprv`/`mpp`/`sum`/`mxr`/`adue`；`sfence_req_t` 已有。
- `o3_core`：新增 `mtime_i`；中断脚接通。
- `o3_cfg_pkg`：TLB/walk cache/PTW/PMP/PMA 参数（4.2、9.1、9.2），“待定”注释改为本 spec。
- `rtl.f`：加入 `dtlb`、`ptw`、`walk_cache`、`pte_ad_updater`、`pmp_checker`、`pma_checker`、`wfi_ctrl`（`itlb` 已在）。
- 删除 `backend.sv:2192` 的 PMP 永不更新断言；相关 tie-off 改为真实连线，每个仍 tie-off 的端口注释原因。
- 头注释中 B31“跨 line 报异常”的过期表述（`dtlb.sv:14-15`、`load_store_unit.sv:15-16` 等，见 `LOOP.md` 第 4 节）在本级触及时改为 B49。

## 12. 不做

- H 扩展、Svpbmt、Svnapot、Svinval、Smstateen、Sscofpmf 以外的新计数器扩展；N/PBMT 位非零即 page fault。
- 多 walker、L2 TLB、预取翻译缓存与预取器（D19 预取部分）。
- 跨 line/跨页非对齐拆分（B49，L8）；LR/SC reservation 与 AMO（L8）；FENCE.I 的 L1D 清理（L8）。
- CLINT/PLIC、MMIO、`mtime` 跨时钟域（L11）；Debug Mode；fatal（L11）。
- Spike 比对、特权测试套件、riscv-tests p/v（FPGA 后）；综合。
- 访存类 cocotb 仍不跑（`dcache`、`l2_cache`、`load_queue`、`store_queue`、`load_store_unit`、`load_store_unit_l5`），除非本级改动直接使其失效需要更新；整核程序覆盖访存功能。

## 13. 验收（少量定向用例）

### 13.1 模块 cocotb

| 位置 | 用例 |
| --- | --- |
| `csr_file`（改） | S CSR 读写与 WARL（mstatus/sstatus 视图、medeleg/mideleg 掩码、sie/sip 视图、satp MODE 非法写忽略）；委托进 S 与进 M；MRET/SRET 特权与 MPRV；TSR/TVM 非法；计数器 counteren 门控；Sstc：STCE=1 时 STIP 跟随比较、STCE=0 时可写；中断优先级与全局使能各一例；scountovf |
| `hpm_counters`（改） | *INH 过滤一例；回绕置 OF 与 LCOFIP 一例 |
| `mmu`（新，含 ITLB/DTLB/PTW/walk cache，Python 页表遍历器参考模型） | 翻译 Breeze T1～T17 中适用者：Bare/M 直通、非规范 VA、三级遍历、walk cache 两级捷径、2M/1G 大页、大页未对齐、保留位、PTE 读 access fault、权限矩阵（含 SUM/MXR/U）、ASID/G、四种 SFENCE 范围（含 walk cache 在 rs1≠x0 时保留、x0/rs2 时保留 G 项）、非叶子 G 累计（含 walk cache 捷径恢复）、A/D 写 PMP 拒绝报 access fault、kill 前/后、轮转仲裁、随机遍历对照；**新增**：miss 期间其他 VPN 命中仍返回（非阻塞）、epoch 变化丢弃迟到返回、A=0 触发 A 更新并以新 PTE 回填、比较失败重新遍历 |
| `pmp_checker`（新） | OFF/TOR/NA4/NAPOT、优先级、部分覆盖失败、M 模式与 L 位、锁定写忽略 |
| `commit_ctrl`（改） | SRET/MRET 重定向 kind；SFENCE 序列（SQ 空 → PTW idle → sfence → 前端同步 → 退休）；satp/PMP needs_refetch；中断在指令边界接受、`epc=committed_next_pc`；WFI 睡眠/同拍不睡/唤醒；needs_D store 队头处理 |
| `frontend_sync_ctrl`（改） | SFENCE kind 不发 `inv_all`；FENCE.I 原用例保留 |
| 回归 | L7a/L7b/L9 全部 cocotb 与受影响的非访存 cocotb；`scripts/lint.sh` 0 errors |

### 13.2 testbench 改动（`sim/o3`）

- `o3_tandem_top.sv`：`mtime_i` 由每拍加 1 的计数器驱动；四个中断脚默认 0，可由 plusarg 在指定周期置位（例如 `+irq_m_soft_at=<cycle>`），实现自选。
- 整核程序使用 `l7_predict.ld` 布局；页表放在数据区，由 M 模式代码在运行时建立。

### 13.3 整核程序（tohost 自查，均不带 `--spike`，带 `+L7_CHECK`）

| 目标 | 内容 |
| --- | --- |
| `run-l10-priv` | M→S（MRET）→U（SRET）；U 的 ECALL 委托到 S（scause=8）、S 的 ECALL 到 M（9）；U 访问 S CSR 非法；TSR/TW/TVM 各一例非法；Sstc：S 模式设 `stimecmp` 后 WFI，被 STI 唤醒并进入 S trap；SSIP 软件中断委托到 S；`time` 在 U 模式按 counteren 允许/禁止；LCOFI 一例 |
| `run-l10-vm` | Bare 下 M 建立三级页表 → S 模式开 Sv39：4K 页与 2M 大页访问；U 页从 S 访问（SUM=0 page fault 13，SUM=1 通过）；不可执行页取指 page fault 12（委托到 S，stval=VA）；只读页 store page fault 15；A=0、D=0 页由硬件置位（读回内存中的 PTE 检查 A/D）；ADUE=0 时 A=0 报 page fault；satp 换 ASID 后旧映射不命中、新映射生效；改 PTE 后 SFENCE.VMA（rs1≠x0）生效；PMP 禁止某区域后 S 访问 access fault 5/7 |
| 回归 | `run-smoke`、`run-rv64i-instructions`、`run-l3-branch-dense`、`run-l7-predict`、`run-l7b-rvc`、`run-l9-fp-smoke`、`run-l9-fp`、`run-replay-order`（M 模式 Bare，行为不得改变） |

- trap 处理程序只用 MRET/SRET 返回且路径简单；若触发 L5 已知的 MRET 问题，报告首个失败点并停下（不在本级修 L5 问题，除非根因就在本级改动）。

## 14. 审阅决定（X1～X16 已确认，正文为实施依据）

| 编号 | 问题 | 推荐（已写入正文） | 理由 / 备选 |
| --- | --- | --- | --- |
| X1 | MMU 来源与验证 | 以 Breeze 新 Sv39 MMU 为机制来源，按 4.1 修改；不做 B47 等价检查，改为翻译其 T1～T17 用例 | 要做非阻塞、硬件 A/D、精确 walk cache 失效，结构已不等价。与 B50 对访存的处理一致 |
| X2 | TLB miss 是否阻塞 | 非阻塞：miss 期间其他请求命中照常返回；同 VPN 合并；PTW 仍 1 个 walker | 按 B49“硬件最优”与 B04（miss 的 load 让出流水线）。多 walker 等 L8 多 MSHR 后再看收益 |
| X3 | 中断在 L10 还是 L11 | L10 实现核内中断判定、委托与提交，平台脚由 testbench 驱动；L11 只接 CLINT/PLIC | WFI、Sstc、LCOFI 都在 L10，不能交付中断就测不了；中断是核内逻辑 |
| X4 | TLB/walk cache 容量 | 取 Breeze 默认：各 8×4 + 4 项大页，walk cache 1×4 + 2×4，ASID 16 位 | 与现有 cfg（32 项 4 路）一致；L11 综合后再调 |
| X5 | walk cache 的 SFENCE 失效 | 按 4.4 表精确失效，`rs1≠x0` 时保留 | 规范允许；Breeze 全清违反 B07“不得退化为全清” |
| X6 | ITLB/DTLB 争用 PTW | 轮转 | Breeze 固定 D 优先可能饿死取指；旧 Breeze 是 I 优先。轮转最简单且无饿死 |
| X7 | PTW 返回 fault 如何交付 | 不回填 TLB；在该 VPN 下一次查询时交付一次（Breeze pending fault 方式），kill 清除 | 不缓存 fault 符合规范；挂起的访存重新查询时自然拿到 |
| X8 | SFENCE 时在途 PTW | 等 PTW idle | D26 允许“等待或取消”；单 walker、PTW 读不被 kill，等待有界，比取消简单。satp 仍按 D27 用 epoch，不等待 |
| X9 | D 位更新方式 | 队头串行：重新遍历 + 原子比较置位，期间阻止年轻 load 越过 | 规范不允许推测置 D（B36 已定）；首次写一页才发生，频率低 |
| X10 | `menvcfg.ADUE` | 可写；复位为 1（默认硬件 A/D）；=0 时 Svade 行为 | 规范要求实现 Svadu 时 ADUE 可写，不能只读为 1；复位值规范未定，取 1 符合 B49。L11 设备树只声明 `svadu`（Linux 视为启动即硬件 A/D）。OpenSBI 的 FWFT 开关需同时声明 svade+svadu，首版不需要 |
| X11 | PMP 条目数 | 16 | 规范上限内最多，cfg 已是 16；OpenSBI 通常只用 3～5 项。备选 8（Breeze，省三处并行比较器的面积）。面积留 L11 综合核对 |
| X12 | PMA 地址图 | 主存 `0x8000_0000～0xFFFF_FFFF`、DTCM、其余不存在 | 与 B50 倾向一致；L11 加 MMIO 区 |
| X13 | `senvcfg` | 实现为全 0 只读 | 按 B49 不让 Linux 访问时 trap；Breeze 未实现 |
| X14 | WFI 在 S/U 的非法判定 | U 立即非法；S 且 TW=1 立即非法（不设超时） | 规范允许超时后非法也允许立即；立即最简单 |
| X15 | 任务拆分 | T08a 特权/CSR/中断/WFI/计数器/time/Sstc/PMP（Bare 下即可测）→ T08b MMU（ITLB/DTLB/PTW/walk cache、satp、SFENCE、page fault、Svade 模式）→ T08c 硬件 A/D（DCache `pte_ad` 口、A/D 更新、`needs_D`），连续执行 | T08a 不依赖翻译；T08b 先用 Svade 打通翻译，再在 T08c 加硬件 A/D，便于定位 |
| X16 | 页表遍历与 load/store 共享唯一 MSHR 的前进性 | PTW 读优先；TLB miss 的 load 不占 MSHR | 满足 B07 前进性；L8 多 MSHR 时按 B07 预留份额 |

### 14.1 实施中补充决定（2026-10-07，Codex 提问，用户确认）

| 编号 | 问题 | 决定 | 正文位置 |
| --- | --- | --- | --- |
| Q1 | `mcause/scause` 合法集合与非法写 | 异常码 {0～9,11,12,13,15}、中断码 {1,3,5,7,9,11,13}，其余位 0；非法写整次忽略、保留旧值（规范为 WLRL，只保证保存支持的编码） | 2.2 |
| Q2 | 非叶子 PTE 的 G | 路径累计 G（取或）；walk cache 增加累计 G，G=1 项跨 ASID 命中；SFENCE x0/rs2 时 walk cache 保留 G 项。覆盖 4.2 原“walk cache 不带 G” | 4.2、4.3、4.4、4.5 |
| Q3 | A/D 条件写的物理检查与失败归属 | S 模式、8 字节、PMP R/W 均允许、PMA 可放页表；失败不写，交付原访问类型的 access fault 1/5/7，tval=原 VA | 8.2 |
