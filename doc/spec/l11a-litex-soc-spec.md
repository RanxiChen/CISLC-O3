# O3-T11a：L11a LiteX SoC 接入、平台 PMA 与 KCU105 首次上板 spec（已冻结）

日期：2026-10-08。分支：`feat/L1-closure`。审计快照：`b539547`（L8b 冻结提交 `70425b1` 之上只多 B52 文档）。行号均指该快照。

依据：[v1 计划](../O3-v1-plan.md) 第 3 节 L11；[后端基线](../design/CISLC-O3-BACKEND-DESIGN-BASELINE.md) **B52**（L11 改用 LiteX）、B28/B29（平台范围、CLINT/PLIC 语义、定时器路线，保留部分）、B39、B48、B49；[L8b spec](l8b-atomic-mmio-dma-spec.md) 第 6.1 节与 Y7（IO 区“L11 按 SoC 地址图细化”）、Y8（DMA AXI/总线从口转换在 L11）。

机制参考：Breeze `/home/chen/leisure/flow` 提交 `ec899c7`（分支 `feat/pcie-fase-20260920`），以下文件在该提交中均已核实存在：
- 边界与流程：`docs/cluster-soc-rtl-spec.md`（**CS**）、`docs/tasks/SOC-axi-fpga-bringup-report.md`；
- LiteX 胶合：`litex_wrapper/flow/{core.py,axi_router.py,clint_verilog.py,plic_verilog.py,ila.py}`、`litex_wrapper/flow/rtl/{FlowClint,FlowPlic}.sv`；
- 板级：`fpga/kcu105/target.py`；平台表：`config/breeze_mcu_platform.json`（**PJ**）；
- 冒烟仿真：`sim/litex/`；
- 留给 L11b：`fpga/kcu105/sd-bringup.md`（SD 与旧一致性 DMA 入口）、`software/breeze-linux/`、README 中 2026-09-18 Linux 6.18.7 启动包。

**原则**：先完成后完美；复用 Breeze 已在 KCU105 上跑通的 LiteX/AXI 接法，O3 只换核与 PMA；不改核内 L1D/L2/后端行为来适配 SoC（同 CS C1）；能由硬件做的不交给软件（B49）。

**状态：已冻结（2026-10-08，用户确认第 14 节 Z1～Z10 全部按推荐实施）。**

---

## 0. 任务书

```
目标：L11a —— O3 单核接入 LiteX，在 KCU105 上跑出 LiteX BIOS：
      平台地址图沿用 Breeze（Rocket 风格），O3 PMA 按平台表精确实现（新增 ROM/SRAM，洞 → 不存在）；
      O3 LiteX CPU 包装 + AXI 路由（内存口直连 LiteDRAM）+ CLINT/PLIC/LiteUART；
      分钟级 LiteX 冒烟仿真；Alan 上生产版与调试版 bitstream。
涉及文件（允许改动）：
  rtl/common/{o3_cfg_pkg,o3_types_pkg,pma_checker}.sv；新增 rtl/common/o3_platform_pkg.sv（生成）
  rtl/frontend/icache.sv；rtl/lsu/{dcache,ptw,pte_ad_updater}.sv；rtl/memory/dma_line_adapter.sv；rtl/rtl.f
  新增 rtl/platform/{o3_litex_top.sv,FlowClint.sv,FlowPlic.sv}
  新增 config/o3_platform.json；新增 scripts/gen_platform_pkg.py
  新增 litex_wrapper/o3/*；新增 fpga/kcu105/*；新增 sim/litex/*
  对应 sim/cocotb/*（PMA、dcache、ptw、icache、dma_line_adapter 套件）
实施：第 12 节 P1～P4 顺序
不做：第 13 节
验收：第 12.5 节
```

## 1. 现状（`b539547` 源码核实）

| 位置 | 现状 | L11a 要做 |
| --- | --- | --- |
| `o3_cfg_pkg.sv:44-46` | `PMA_IO_BASE=0x0200_0000`、`PMA_MAIN_BASE=0x8000_0000`、`PMA_MAIN_END=2^32` | 改为由平台表生成的区域常量（第 3 节） |
| `o3_types_pkg.sv:580-588` | `pma_main`：`[0x8000_0000,2^32)`；`pma_io`：`[0x0200_0000,0x8000_0000)` 整段 | 按区域精确判定；新增可执行/可写/可缓存分类 |
| `pma_checker.sv:6-11` | `exec_ok=cacheable`、`read_ok=write_ok=exists`、`amo_ok=rsrv_ok=cacheable` | 各属性按区域取（第 3 节表） |
| `o3_types_pkg.sv:1036-1040`（`dc_permissions`） | `exists:main\|\|io`，`amo_ok/rsrv_ok:main`，无独立写权限 | 增加写权限位，ROM 写/AMO/SC → access fault |
| `icache.sv:122,154,156` | 取指与预取只认 `pma_main` | 改为“可执行且可缓存” |
| `ptw.sv:38-39,59,89` | PTE 读与 A/D 更新只认 `pma_main`；A/D 不允许时已不发请求并报 af | 读：可缓存可读；A/D：可缓存可写（第 4 节） |
| `dma_line_adapter.sv:22` | 只认 `pma_main` | 保持只允许 `main_ram`（第 3 节） |
| `o3_core.sv:15-80` | AXI4 内存主口（`axi_data_bits=128`、`axi_id_bits=4`）、AXI4-Lite MMIO 主口（64 位，1 笔在途）、行粒度 DMA 口、`mtime_i`、`irq_{m_ext,m_timer,m_soft,s_ext}_i`、`fatal_o`、`retire_info_o`（`ENABLE_RETIRE_INFO`） | 不改；新增 LiteX 顶层包装例化它 |
| 仓库 | 没有 LiteX 胶合、平台表、板级脚本 | 第 5～9 节 |
| `sim/o3/o3_mmio_model.sv` | N6 用 `0x0200_0000` 起 4KB 作 MMIO 测试设备 | 该地址在新表中属 `machine_timer`（设备区），仿真顶层保持可用，不迁移 |

## 2. 参数

| 参数 | 值 | 说明 |
| --- | --- | --- |
| 系统时钟 | 100 MHz 单时钟域（核、LiteX 总线、LiteDRAM 用户侧同频） | 同 Breeze `target.py:25`；见 Z6 |
| `mtime` 频率 | 1 MHz | 同 PJ `machineTimer.mtimeFrequencyHz` |
| 内存口位宽 | 保持 `axi_data_bits=128`，LiteX 自带 AXI 位宽转换接 LiteDRAM native 口 | 不改 L2（Z2） |
| hart 数 | 1 | B28 |
| DDR | LiteDRAM USDDRPHY，DDR4 `EDY4016A`，1:4，`main_ram` 2 GiB | 同 Breeze `target.py:66-69` |

## 3. 平台地址图与 PMA（取代 L8b 6.1 表）

### 3.1 单一来源

- 新增 `config/o3_platform.json`，结构与 PJ 相同（`schemaVersion`、`regions`、`machineTimer`、`mmioPages`、`externalInterrupts`），区域内容逐项取 PJ（Z1），`platform` 字段改为 `o3-kcu105-v1`。
- `scripts/gen_platform_pkg.py` 由该文件生成 `rtl/common/o3_platform_pkg.sv`（区域起止、属性位常量）。RTL 只引用生成包，不手写第二份地址；LiteX 侧（第 6 节）同样只读该 JSON。门禁检查生成包与 JSON 一致（重新生成后 `git diff` 为空）。
- `reset_pc` 由 LiteX 赋给的 `reset_address` 驱动（= `linux_boot_rom` 起点，同 Breeze）。

### 3.2 区域与属性

| 区域 | 起点 / 大小 | R | W | X | 可缓存 | 设备 | AMO PMA | Reservability | O3 路径 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `machine_timer`（CLINT） | `0x0200_0000` / 64 KiB | ✓ | ✓ | – | – | ✓ | AMONone | RsrvNone | HEU MMIO |
| `plic` | `0x0C00_0000` / 64 MiB | ✓ | ✓ | – | – | ✓ | AMONone | RsrvNone | HEU MMIO |
| `boot_rom` | `0x1000_0000` / 64 KiB | ✓ | – | ✓ | ✓ | – | AMONone | RsrvNone | L1I/L1D → L2 → 路由低速口 |
| `linux_boot_rom`（LiteX BIOS） | `0x1001_0000` / 64 KiB | ✓ | – | ✓ | ✓ | – | AMONone | RsrvNone | 同上 |
| `sram` | `0x1100_0000` / 64 KiB | ✓ | ✓ | ✓ | ✓ | – | AMOArithmetic | RsrvEventual | 同上 |
| `litex_mmio`（LiteX CSR） | `0x1200_0000` / 16 MiB | ✓ | ✓ | – | – | ✓ | AMONone | RsrvNone | HEU MMIO |
| `main_ram` | `0x8000_0000` / 2 GiB | ✓ | ✓ | ✓ | ✓ | – | AMOArithmetic | RsrvEventual | L2 → 路由 DRAM 口 |
| 其余（洞、≥2^32） | — | 不存在 | | | | | | | 一律 access fault，不发总线访问 |

- 判定规则沿用 L8b 6.1：访问的每个字节都必须落在同一区域；跨区域 → 不存在（同 Breeze `PMAChecker`）。
- **洞必须拒绝**：LiteX 主总线 `bus_timeout=None`（Breeze `target.py:61`），访问未映射地址会永久挂死。L8b 的“`[0x0200_0000,0x8000_0000)` 整段为 IO”在本级收窄为上表三个设备区。
- O3 只实现两档原子能力（AMOArithmetic+RsrvEventual，或 AMONone+RsrvNone），与上表一致；不实现 AMOSwap/AMOLogical 中间档（Z4）。
- `boot_rom` 在 Breeze 为“未激活”零响应 ROM（`add_inactive_boot_rom`），O3 沿用。

### 3.3 各访问类型的判定与异常

| 访问 | 允许条件 | 不允许时 |
| --- | --- | --- |
| 取指（含 ICache 预取） | X 且可缓存 | 取指 access fault（1）；预取直接丢弃 |
| load | R | load access fault（5） |
| store / SC | W | store/AMO access fault（7） |
| AMO | W 且 AMOArithmetic | 7 |
| LR | R 且 RsrvEventual | 沿用 L8b 对 IO 区 LR 的现有异常码，不另定 |
| RFO / 数据预取 | 可缓存且 W（RFO）/ 可缓存（预取） | 静默放弃，不报异常 |
| PTW 读 PTE | 可缓存且 R | 原始访问类型的 access fault（1/5/7），同 L10 现有处理 |
| PTW 的 A/D 更新 | 可缓存且 W | **不发写请求**；原始访问类型的 access fault（1/5/7）（第 4 节） |
| DMA 行请求 | 仅 `main_ram` | `error=1`，不发出（L8b 第 8 节不变） |
| 设备区 | 自然对齐（L8b 不变） | 4/6 |

- 断言（仿真）：L1D 中属于 ROM 区域的行永不进入 M 态；L2 不向内存口对 ROM 区域发写。

## 4. PTW 与 ROM 中的页表

依据 RISC-V 特权规范：PTE 读是隐式读，要过 PMA/PMP；硬件 A/D 更新必须对整条 PTE 原子进行，若对 PTE 的写会违反 PMA/PMP，报**原始访问类型**的 access fault。

- 页表可放在 ROM（可缓存只读）：A/D 已为所需值时正常翻译（Breeze BL 7.2“ROM 可读”）。
- 需要置 A 或 D 而 PTE 在不可写区：`ptw.sv:39` 的 `ad_physical_ok` 改用“可缓存且 W”。为假时的处理已在 `ptw.sv:59,89` 实现（不发 A/D 请求、置 `af` 返回），只改判定条件；异常码须为原始访问类型。已批准的 B36 A 更新广播只在实际成功写入时发生，此处没有写入，因此不触发 `order_flush`。
- 页表在设备区：读即 access fault（不变）。

## 5. LiteX 顶层包装（`rtl/platform/o3_litex_top.sv`）

- 例化 `o3_core`，端口按 LiteX `Instance` 需要命名并保持稳定：AXI4 内存主口（128 位、ID 4 位、32 位地址）、AXI4-Lite 主口（64 位）、`mtime[63:0]`、`msip/mtip/meip/seip`、`reset_pc`、`fatal`。
- `irq_m_soft_i←msip`、`irq_m_timer_i←mtip`、`irq_m_ext_i←meip`、`irq_s_ext_i←seip`、`mtime_i←CLINT mtime`。
- DMA 口本级 tie-off：`dma_req_valid_i=0`、`dma_resp_ready_i=1`（L11b 接 SD）。
- 生产版与调试版由参数区分；调试版另引出第 9 节探针。生产版不带空探针（同 CS 第 2 节）。
- 仅包装与接线，不含协议转换逻辑。

## 6. LiteX CPU 类与 SoC（`litex_wrapper/o3/`、`fpga/kcu105/target.py`）

以 Breeze `core.py:90-130,255-300` 与 `target.py:44-96` 为模板改写：

- CPU 类 `O3`（单 hart，`gcc_arch = rv64imafdc_zicsr_zifencei`、`lp64d`）；`memory_bus` 为 AXI4（数据 128 位）只接 AXI 路由器；`mmio_bus` 为 AXI-Lite 64 位，挂 LiteX 主总线（`periph_buses`）；`io_regions` 与 `mem_map` 只从 `config/o3_platform.json` 读取。
- AXI 路由器：复制 Breeze `axi_router.py` 到 `litex_wrapper/o3/`，位宽随 master。必须满足 CS R1～R4：R 按 AR 接受顺序返回（跨两路也如此），B 按 AW 顺序；W 随其 AW 去向；resp 原样回传；按 burst 首地址路由，跨区域返回错误；地址表只读 JSON。`main_ram → LiteDRAM` 的 AXI 端口（保留 INCR burst），`boot_rom/linux_boot_rom/sram →` LiteX 主总线（AXI→Wishbone），其余 → 本地 DECERR。
- O3 L2 的 AXI 读回填按 ID 区分（`l2_mem_engine`），路由器的保序性比 O3 所需更强，保留不改。
- **只有 O3 能写 `main_ram`**：除路由器 DRAM 口外，LiteX 主总线不得有任何其他主设备可达 `main_ram`；构建脚本检查 LiteX 生成的地址译码并在报告中列出 `main_ram` 的全部主设备（L11b 的 SD DMA 必须经 O3 一致性 DMA 口，见第 13 节）。
- CLINT/PLIC：复制 Breeze `FlowClint.sv`、`FlowPlic.sv` 到 `rtl/platform/`，`clint_verilog.py`、`plic_verilog.py` 到 `litex_wrapper/o3/`，作为 LiteX 主总线上的 Wishbone 从设备（与 Breeze 完全相同，不另做 AXI-Lite 包装，取代计划 §4 的“换 AXI-Lite 包装”）。偏移取 JSON `machineTimer`；PLIC 源号沿用 PJ `externalInterrupts`（UART=10）。
- UART：LiteX 自带 LiteUART，地址取 `mmioPages.uart`（`0x1200_1000`），中断接 PLIC 源 10。
- 其他：`with_ctrl`、`with_timer`、`csr_paging=0x1000` 等 SoCCore 参数沿用 Breeze `target.py:57-63`。
- 环境：LiteX/LiteDRAM 用所选主机 `simulation-host.md` 的 `breeze_rvv_environment`（Breeze 已验证），O3 RTL 工具用 `o3_environment`；两者都要在报告中写明版本。若 O3 环境已含 LiteX，可只用 O3 环境。

## 7. 冒烟仿真（上板前，分钟级）

目的只查连线：地址映射、AXI 位宽/ID、复位、路由保序、中断线。不跑 OpenSBI/Linux（同 CS 第 5 节）。

- 主机按 `simulation-host.md`（先 cloud_chen，不可用再 Alan）。Verilator 跑 LiteX 仿真：与 FPGA 相同的 CPU 包装和路由，DRAM 用 LiteDRAM `SDRAMPHYModel`。O3 的 RTL 断言（含 Y13）开启。
- **S1**：BIOS 横幅出现在 UART；BIOS 从 `linux_boot_rom` 取指、以 `sram` 作栈；`main_ram` memtest ≥ 64 KiB 通过。
- **S2**：BIOS 侧自查程序（`sim/litex/` 新增，链接到 `main_ram` 由 BIOS 跳入或作为 BIOS 命令）：读 CLINT `mtime` 递增；写 `mtimecmp` 触发 MTIP 进入 M 态 trap；UART 中断经 PLIC 源 10 claim/complete；访问一个地址洞得到 load access fault（5）而不挂死；对 `linux_boot_rom` 的 store 得到 7。
- **S3**：每次仿真墙钟上限 30 min；超时视为失败并保留日志，不加长时间凑通过。
- 核内断言触发视为失败，按 CS C1 定位修复（单独提交），不在 SoC 侧绕开。

## 8. FPGA 构建（Alan，Vivado）

- 顺序：O3 生产版 100 MHz → O3 调试版 100 MHz。
- 每次记录：SHA、命令、输出目录、WNS/TNS/WHS、LUT/FF/LUTRAM/BRAM/DSP 利用率、最差 10 条路径起止点、bitstream 与 `.ltx` 路径。
- WNS < 0 不算构建失败，但必须列出最差路径；只有落在本任务新增胶合逻辑（路由器、包装、挂死检测）时在本任务内修，核内路径只报告（同 CS 第 6 节）。是否以违例 bitstream 上板由用户决定（Z6）。
- 上板由用户本人进行；执行者停在 bitstream 产出。板上期望：S1 的横幅与 memtest。

## 9. 调试（ILA）

沿用 CS 第 4 节结构，探针换成 O3 信号：
- 退休：`retire_info_o` 各 lane 的 valid/PC/指令、最后退休 PC、`seen_retire`、饱和 `no_retire_cycles`；
- `fatal_o`、`inclusion_err_o`、低位 `mtime`；
- AXI 内存口五通道 valid/ready、AR/AW addr/id/len、R/B id/resp/last、W strb/last、R/W 数据低 64 位；路由器两路读写在途计数；
- AXI-Lite 五通道握手、地址、数据、resp；
- 挂死检测 H1～H3 同 CS（只观察，不改握手；阈值按 100 MHz 约 0.1 s；接板上 LED）。
- `ila-probes.json` 与 `.ltx` 同次生成。

## 10. 性能事件

本级不新增事件。报告记录 S1 运行的周期数与既有 L2/MSHR 事件计数（只记录）。

## 11. 对既有测试的影响

- PMA 收窄后，使用 `[0x0200_0000,0x8000_0000)` 中现已为洞或 ROM 的地址作 IO 的 cocotb 用例：**预先批准**把地址移到同类别的设备区（如 `0x1200_0000` 段），断言、期望异常码与规模不变；在报告中逐条列出。其他与本 spec 冲突的旧测试仍按 L8b 规则停下申请。
- 整核 `sim/o3` 程序与 `o3_mmio_model.sv`（`0x0200_0000`）保持不变并须继续通过。

## 12. 实施顺序与门禁

证据规则沿用 T10 加速修订（`doc/tasks/O3-T10-l8b-tasks.md` 末节）：中间层只记 SHA/主机/命令/exit/用例数；完整同 SHA 审计只在 12.5 做一次。

### 12.1 P1：平台表与 PMA（RTL）

- `config/o3_platform.json`、生成脚本与 `o3_platform_pkg.sv`；第 3、4 节 RTL 修改；lint 0 errors。
- 测试：`pma_checker` 每区域 × 每访问类型 1 例（含跨区域、洞、≥2^32）；dcache：ROM store/AMO/SC → 7、ROM load 命中/miss 正常、ROM 行不进入 M（断言）、设备区与洞的区分；ptw：页表在 ROM 且 A/D 已置 → 翻译成功；A=0 → 原始类型 access fault 且无 CAS 发出、无 `order_flush`；icache：ROM 取指正常、设备区取指 → 1；dma_line_adapter：`sram`/ROM 地址 → `error=1`。
- 回归：L8b N5 冒烟（`run-l10-vm` VM_AD=1 + L8a M6 全部目标）与 N6 四个程序。
- 提交：`feat(pma): exact platform regions with ROM/SRAM` 与 `test(pma): L11a layer P1 pass`。

### 12.2 P2：LiteX 包装与 SoC

- 第 5、6 节全部；LiteX 能生成 Verilog 并通过 Vivado/Verilator elaborate；`main_ram` 主设备检查通过。
- 提交：`feat(soc): O3 LiteX CPU wrapper, AXI router, CLINT/PLIC/UART`。

### 12.3 P3：冒烟仿真

- 第 7 节 S1～S3 通过。提交：`test(soc): L11a layer P3 pass`。

### 12.4 P4：FPGA 构建

- 第 8、9 节；两份 bitstream 产出。提交报告后停下等用户上板。

### 12.5 L11a 总门禁

最终 SHA 上：P1 测试、L8b 12.8 总门禁（N1～N6 + L8a M1～M6 + 既有非访存 cocotb）同 SHA 重跑通过；P3 冒烟通过；lint 0 errors；生成包一致性检查通过；`doc/LOOP.md` 的 L11 行更新；报告写清自行决定、已知问题与证据边界。

## 13. 不做（L11b/L11c）

- **L11b**：SD 卡（LiteSDCard，`add_sdcard`）及其 DMA。LiteSDCard 的 DMA 是 Wishbone 主设备，必须经新增“Wishbone 从口 → O3 行粒度 DMA 口”转换进入 L2 Home（Breeze 旧版 `coherent-dma` 入口同此做法，见 `sd-bringup.md`），不得直接写 LiteDRAM；BIOS 从 SD 装载（`boot.json`）、启动跳板、OpenSBI、设备树（含 `rv64imafdc`、Sstc、Sscofpmf、`riscv,sv39`）、Linux（以 Breeze 6.18.7 启动包为起点）；板上启动到 shell。
- **L11c**：FASE、OpenSBI PMU 与 Linux perf（B48）、fatal 隔离的板级观测、内存口改 512 位、DDR 控制器改 MIG 的评估。
- 本级不做：OpenSBI/Linux 全系统仿真；多 hart；PCIe；频率优化。

## 14. 待确认的决定

| # | 问题 | 推荐 | 其他选项 |
| --- | --- | --- | --- |
| Z1 | 地址图 | **已定（用户 2026-10-08）**：沿用 Breeze/Rocket 风格 PJ | 香山地址图：外设地址全改，收益小 |
| Z2 | 内存口位宽 | 首版保持 128 位，LiteX 自带位宽转换到 LiteDRAM native 口；改 512 位放 L11c | 现在改 512：一行一拍，但要动 L2 内存引擎与仿真模型 |
| Z3 | CLINT/PLIC 接法 | 原样作为 LiteX Wishbone 从设备（同 Breeze），O3 MMIO 经 LiteX 自带 AXI-Lite→Wishbone 到达 | 另写 AXI-Lite 包装：计划 §4 原写法，在 LiteX 下无收益 |
| Z4 | AMO PMA 档位 | 只实现两档（全部 / 无），设备区 AMONone | 设备区 AMOLogical（规范建议）：AXI-Lite 无原子事务，需在 SoC 侧做读改写，Linux 驱动不需要 |
| Z5 | ROM 是否可缓存 | 可缓存（同 Breeze），PTW 可读 ROM 页表 | 不可缓存：BIOS 取指走 MMIO，极慢；PTW 不能读 ROM |
| Z6 | 时钟与时序不收敛 | 100 MHz 单时钟域；WNS<0 先报告，由用户决定是否上板；时序数据参考并行的 OOC 预览（`ooc/mem-preview`） | 核单独降频 + 跨时钟域：USDDRPHY 要求系统时钟约 100 MHz，核另起时钟要在内存口与 MMIO 口加 CDC，首版复杂度高 |
| Z7 | 平台表来源 | O3 仓库自有 `config/o3_platform.json`（内容取自 PJ），RTL 包由脚本生成 | 直接引用 Breeze 仓库的 PJ：跨仓库依赖、版本漂移 |
| Z8 | LiteX 胶合代码 | 复制 Breeze 的 router/CLINT/PLIC/ILA 到 O3 仓库并记录来源 SHA | 跨仓库 import：省复制，但两边同时演进会互相破坏 |
| Z9 | 冒烟内容 | S1（BIOS 横幅+memtest）+ S2（CLINT/PLIC/UART 中断、洞与 ROM 写的异常） | 只做 S1（同 Breeze）：中断线接错要到 L11b 上 Linux 才发现 |
| Z10 | L11 拆分 | L11a（本文）→ L11b（SD+Linux）→ L11c（FASE/perf/优化）；L8c 排在 L11 之后 | 一次做完 L11：单个任务过大，失败难定位 |
