# O3-T11a：LiteX 平台修复与验证记录

代码验证提交 `78db9574b175383603b46238533335ad3eaa58df`（实现 `ab08bea`、测试 `5f7e34d`、调试观察补齐 `78db957`），尚未推送。CSR/PMA同源、IRQ导出及32位MMIO读lane均已修复；用户批准的两项旧地址表期望已更新，原探针、种子、规模保持。最终同提交一遍模块461/461、平台补充6/6、整核27目标、SoC S1/S2、15类挂死原因定向检查全部通过，lint0 errors/357 warnings。见[功能证据](O3-T11a-functional-evidence.json)。

Alan生产/调试/S2 BIOS及工程生成exit0。生产Vivado使用原新输入 `l11a-mmio-20261009-b36bd1b2` 继续构建；当前正常版重生成的去注释Verilog与原生成结果一致，XDC/ROM init原始字节相同。补齐观察器的调试版输入位于 `l11a-final-78db957`，只在生产exit0后启动。综合/时序/bitstream尚未验收，L11a整体未完成；SD实卡、物理DDR训练、OpenSBI/Linux及上板未验证。

下文保留各阶段当时的状态与失败证据；历史“未提交/未测试/未编译BIOS”只描述原代码阶段，当前结论以上述状态及后续验证记录为准。

## 历史：原代码阶段

2026-10-09 用户要求首版包含 SD/一致性 DMA，随后指定先写代码、再补充测试。分支 `feat/l11a-litex-soc` 从 `c522369c11b88b819e2ca9192f491e266bd16cee` 派生；本轮代码尚未提交。原有未提交文档保留。以下仅为代码和静态构建结果，不是同 SHA 功能验收。

## 实现内容

- 平台 JSON 替换旧仿真 ITCM/DTCM 配置；生成 `o3_platform_pkg.sv`，按完整访问范围判定区域与 R/W/X/cacheable/AMO/reservation 属性。ICache 支持 ROM/SRAM 取指，PTW 区分 PTE 读与 A/D 写，DCache 加独立 PMA 读写许可及只读写入断言。
- `o3_litex_top.sv` 展开核端口，连接 `sd_dma_bridge.sv`。桥保留一个 64-bit Wishbone 字事务，转换为 64B 一致性行读/MaskWrite；仅 DDR、保持 sel、真实完成后 ACK/ERR、撤销后排空。
- 复制 Breeze `ec899c7` 的 CLINT/PLIC SV、Python 包装和 CPU 启动支持文件，文件头注明来源；不 fork、不加 Breeze 子模块、无跨仓库 import。已有 CVFPU 子模块不变。
- O3 LiteX CPU 类、128-bit AXI 地址路由、KCU105 CRG/target，一次接齐 DDR、ROM/SRAM、CLINT/PLIC、UART、双向 SD DMA 和 ILA 调试选项。
- `cpu.dma_bus` 触发 LiteX 的隔离 DMA 接法，两个 SD master 仅能经 O3 一致性入口访问 DDR。构建检查主总线没有 DDR slave，主设备列表与 DMA slave 终点一致。
- UART/SD/timer0 的 PLIC ID 为 10/11/12，核时间由 CLINT 的 1MHz mtime 提供。SD 控制寄存器在 `0x12006000` 单页聚合。
- BIOS 使用本构建目录的软件适配：正确 PLIC ID、lp64d FS 初始化与陷阱 FP 保存；SRAM/未对齐 SD 缓冲用预留 DDR bounce buffer。上游软件包不修改，保存原文件 SHA256。
- 增加基于实际 CSR 表的设备树生成器、启动跳板和 SD 文件打包脚本；不编译或启动 OpenSBI/Linux，不写 SD 卡。
- 53 个既有构建清单仅增加生成平台包的编译依赖；没有修改测试内容、golden、断言、种子或规模。

## 静态检查与主机

实际主机 `cloud_chen@47.96.71.231`；每次编译/生成前重新读取共享配置并确认 SSH/环境。cwd `/home/cloud_chen/work/o3-soc-20261009-code`，证据 `/home/cloud_chen/evidence/o3-soc-20261009-code`。Verilator 5.050。源码为未提交工作树快照，不能把父 SHA 当本次代码 SHA。

- `TOP=o3_litex_top bash scripts/lint.sh`：最终exit0，0 errors/357 warnings；结果在 `final-rtl-lint.log/.exit`，警告不升级为功能结论。
- 修正 CSR 空洞覆盖后，普通版 `python fpga/kcu105/target.py --no-compile-software --output-dir .../build/final-standard2`：exit0，生成完整 Verilog/Vivado 工程、CSR JSON/CSV、平台表与 `memory-paths.json`。该输出 BIOS ROM 为空，仅用于结构检查。
- 前一版实际 CSR 表生成设备树并经 `dtc` 编译：exit0；不算 Linux 验收。
- 本地 Python AST 解析、`git diff --check`：通过。
- 调试版 `--debug --no-compile-software` 硬件生成：exit0，ILA配置与宏写入Vivado工程；打开 `ENABLE_RETIRE_INFO` 的独立RTL lint亦exit0、0 errors/357 warnings，仅代码生成与静态解析，不算Vivado编译或布线通过。

## 遇到的问题与处理

1. 云端缺 LiteSDCard：在独立任务依赖目录通过已配置的代理获取官方源，提交 `b68dfded8a76c74aea718d9a8914cf8c2bf3f26c`；PYTHONPATH 仅用于本任务。未更改全局环境。
2. 上游 KCU105 target 导入未安装的 PCIe 包：只迁移其必要 CRG，删除无关 PCIe/Ethernet import；CRG 保留上游版权和接法。
3. Breeze 路由只接受最大8B AXI beat：按实际128-bit master计算 AxSIZE 上限与 burst 范围，支持16B beat。
4. BIOS 官方 SD 缓冲位于 SRAM且可能不满足8B对齐，与仅DDR DMA合同不符：使用最后4KiB DDR scratch/bounce；不扩大 DMA 权限。
5. 官方 PLIC 默认初始化前8个源，与10/11/12接线不符：BIOS header 使用原始 PLIC ID，按平台mask初始化优先级/使能。
6. 软件适配最初误匹配了 PLIC 的前置声明段；改为匹配明确的 `#if defined(__riscv_plic__)` 实现段。
7. 硬件生成路径发现云端缺 `pythondata-software-picolibc`：硬件-only生成独立于BIOS依赖；默认BIOS编译尚未执行完成，仍需准备匹配的picolibc/compiler-rt环境。
8. 导出CSR的上游函数带新增soc首参数：改用关键字参数调用。
9. 旧版16MiB平台设备窗口与LiteX默认64KiB CSR译码不一致。曾用ERR slave补洞，普通版生成exit0仅证明结构生成；此前“无无限等待”的结论错误，予以撤回。LiteX AXI-Lite→Wishbone桥只等待ACK且RESP固定OKAY，ERR-only从设备无法完成请求。2026-10-09审核修复采用1MiB CSR窗口，地址位数从JSON推导为18，删除ERR补洞；新证据另行记录，旧生成日志不作为修复后验证。
10. 调试宏打开后的RTL解析发现退休指令字段名为 `instruction`，包装误写为 `inst`；已修正，独立宏解析结果记录于 `debug-rtl-lint2.log/.exit`。

## 原代码阶段边界及下一阶段

按用户要求，未新增/运行功能测试，没有 SoC BIOS 冒烟、SD 读写/一致性、OpenSBI/Linux、Vivado 综合/布线或上板通过结论。默认 BIOS 编译依赖尚待补齐；生产/调试 bitstream 未产出。FASE/PMU/perf 优化保持后续范围。

后续补充 DMA 桥部分写/背压/错误/撤销/复位、平台ROM/洞/跨区域/PTW A-D、路由128-bit burst/错误/保序、真实SD并发DMA与缓存可见性、中断与BIOS启动测试，随后按授权范围进行原回归与完整SoC验证。

## 2026-10-09 审核修复：CSR 与 PMA 同源

用户要求优先修 SoC，完整回归允许后置，不作为修复前置条件。本次将 `litex_mmio` 改为 `[0x12000000, 0x12100000)`（1MiB），保持七个已用 CSR 页地址。18 位 CSR word 地址从 JSON 窗口大小推导，删除 ERR 补洞及其错误的完成保证。平台加载拒绝非 2 的幂或未对齐区域；构建前拒绝过期 PMA 包，CSR 桥建立时检查全部七个区域的实际译码大小、属性和从设备，在后端运行前阻断不一致；最终导出 `address-map.json`。

DDR 容量由 LiteDRAM 几何、rank 数和 PHY 位宽计算，再与 JSON 及实际 `main_ram` 区域比较。本次普通/调试输出均为 `2147483648` 字节（2GiB），BIOS scratch `[0xfffff000, 0x100000000)` 在范围内；没有 DDR 训练或实板读写结论。

### 本次定向证据

实际主机 `cloud_chen@47.96.71.231`，cwd `/home/cloud_chen/work/o3-soc-csr-fix-20261009`，证据根 `/home/cloud_chen/evidence/o3-soc-csr-fix-20261009`。编译/仿真/生成前重读共享主机配置并预检。环境使用 `activate-o3.sh` 加本任务 PYTHONPATH；未修改安装的 LiteX/Breeze。Verilator 5.050、cocotb 2.1.0。

源码仍是未提交工作树，父 SHA `c522369c11b88b819e2ca9192f491e266bd16cee` **不是本次测试源码 SHA**。修复及定向测试源码清单 SHA256 `393ad7e9beb4824ab5a6cc01c3ca344f23a64e53693628178ec8e6cf31166a0e`，已逐文件核对远端与本地一致；JSON SHA256 `b82edabbaf28fd545680030801e1fd5f1ab163ae72c0ad5d93a36173c4be6e30`。上游依赖为安装快照，另存 Python 源文件 hash 清单，不虚构 Git SHA。[机器可读证据](O3-T11a-csr-fix-evidence.json) 保存每步 command、cwd、host、开始/结束时间、exit、日志及源码/依赖清单 hash。

| 检查 | 结果 | 证据（相对本次根目录） |
| --- | --- | --- |
| `python scripts/gen_platform_pkg.py` 及 `--check` | 两步 exit0，生成包与 JSON 相符 | `generate-pma.*`、`check-pma.*` |
| `make -C sim/cocotb/platform_pma sim` | exit0；1/1 测试通过，389 个地址/大小/属性组合；独立固定期望，含 CSR 新上界、跨区、ROM/SRAM、洞及高地址 | `platform-pma.log/xml` |
| `python sim/litex/check_csr_window.py` | exit0；真实 LiteX 64-bit Wishbone→32-bit CSR 转换/桥完成 516 次读写，含全部 256 页及末尾高32-bit lane；四个窗口外地址未选中 CSR | `csr-bus-v3.*` |
| 构建门禁负向检查 | exit0；9 项检查通过，含16MiB/非幂/错对齐拒绝、不同配置的CSR索引、译码扩大/缺应答设备/错误属性/禁用译码拒绝、DDR几何容量不足拒绝 | `guardrails.py/log/exit` |
| `TOP=o3_litex_top bash scripts/lint.sh` | exit0，0 errors / 357 warnings | `lint.*` |
| 普通版、调试版 `target.py --no-compile-software` | 各 exit0；CSR 大小及 decoder size 同为1MiB，地址位数18，DDR独立容量2GiB；全部七区及DMA隔离检查通过 | `standard.*`、`debug.*`、`build/{standard,debug}/{address-map,memory-paths}.json` |

CSR 仿真夹具前两次分别漏设 IO region、向 decoder 传错对象，旧失败日志与非零 exit 保留；修复夹具配置/API后通过，不改变测试判据或上游代码。最初 runner 总 exit1 保留；最终各定向门禁的结果见 `summary.json`，aggregate exit0。本地证据归档 `build/evidence/o3-soc-csr-fix-20261009/evidence.tar.gz`，SHA256 `bc2a0d7e2fb0e263ea4e0450d6efd85aeb642b876619e2590995e982801d43ff`。

### 保留限制与后续

- 本次只验证 PMA 组合判定与 CSR 桥/译码，二者分别执行；未证明 CPU→LiteX 整条路径的精确异常及请求抑制。普通/调试生成均为空 BIOS ROM，exit0 仅为结构生成证据。
- SD DMA 的非 DDR 地址或一致性错误只返回 ERR；LiteSDCard DMA 只等 ACK，仍可能停滞。规格第16节记录此限制，Linux阶段再决定可观测错误恢复/地址寄存器检查。本次未改 DMA 错误语义，也未扩大权限。
- 每8B字独立发64B一致性事务，无行缓存/写合并，SD提速后的吞吐需实测；未来合并/缓存仍须满足一致性合同。
- 完整旧回归未启动，既有测试内容/期望值/golden/断言/种子/规模未改。新增独立 `platform_pma` 与 CSR桥定向测试不代替完整回归。已知 ICache 旧DTCM不可执行期望及PMP/PMA宽IO模型待后置回归逐条分类，更新旧期望值等用户批准；不以本次定向通过宣布原回归通过。
- 没有 SoC BIOS 冒烟、SD 功能、OpenSBI/Linux、Vivado 综合/布线或上板验收；未提交、未推送、未启动下一阶段构建。


## 2026-10-09 用户授权：Alan 编译 BIOS，Vivado 与云端验证并行

用户批准在 SoC 修复后并行进行 Alan FPGA 构建、cloud_chen 回归与 SoC 仿真，并明确 BIOS 使用 Alan 完整 LiteX 环境。旧 ICache/PMA 期望的两项地址表更新另获明确批准；不扩大其他期望值变更范围。本节为进行中的验证记录，不是最终同 SHA 总门禁或上板验收。

### Alan BIOS 与 FPGA 输入

实际主机 `chen@localhost:2286`（跳板 `clawbot`），环境 `source /home/chen/miniforge3/bin/activate flow`，GCC `riscv64-unknown-elf-gcc 13.2.0`，Vivado 2022.2。独立任务根 `/home/chen/FUN/CISLC-O3-runs/l11a-bios-20261009-d99928e2`；板级 cwd 为其中的 `source`，证据位于 `evidence`，输出 `build/{standard,debug}`。源码仍为父 `c522369c` 上的未提交快照，输入源码归档 SHA256 `d99928e258e45d76dd86766a5efec1acc644ea30e61fccc9aa37f366781555ed`，不能将父提交称为验证后的源码提交。

- 生产 BIOS：`python fpga/kcu105/target.py --output-dir .../build/standard`，exit0，2026-10-09T03:11:44Z～03:11:49Z。入口 `0x10010000`、lp64d，`bios.bin` 40732 字节，SHA256 `b6affa12aac15347b95b2d79da64d2a6ad2c1dbcef32b15b61b0c58dda7b0457`；ROM 已填入 BIOS，使用约39.77KiB，SRAM约3.23KiB。
- 调试 BIOS 与硬件生成：同一板级源码快照，`target.py --debug --output-dir .../build/debug`，exit0。生产/调试保留100MHz约束与原核配置。
- 生产 Vivado 于2026-10-09T03:20:58Z启动：gateware cwd 中执行 `timeout 10800 vivado -mode batch -source xilinx_kcu105.tcl`。调试版排队，只在生产版 exit0 后启动；每版上限3小时。未关闭或修改 Alan 上其他任务。
- Vivado 尚未完成；WNS/TNS/WHS、资源、最差十条路径、bitstream/.ltx 均待最终日志。BIOS编译和工程生成不证明综合、时序或板上行为。

### cloud_chen 回归与分类

主机 `cloud_chen@47.96.71.231`，cwd `/home/cloud_chen/work/o3-soc-csr-fix-20261009`。使用 `activate-o3.sh`；每次启动前读取共享主机配置并预检。旧全部模块回归以 `EVIDENCE_DIR=.../o3-l11a-regression-20261009 bash scripts/run-l7c-modules.sh` 执行96个阶段，初始 aggregate exit1；完整失败日志/XML保留。

| 初始失败类别 | 根因与处理 | 重跑证据 |
| --- | --- | --- |
| DCache / memsys 大批行为失败 | `dc_permission_t` 已扩为8位，共享CPU请求打包仍保留6位，造成前面字段错位。仅修正 `l8a_agents.py` 的接口宽度，不改断言/黄金值 | `o3-l11a-regression-20261009-fixtures`：六阶段 exit0，102/102 |
| PTE cache 编译失败 | `Makefile.pte` 漏列 `o3_platform_pkg.sv`，补齐依赖 | 同上：2/2，已计入102 |
| ICache 三种子失败 | 原DTCM `0x11000000` 现为可执行SRAM。获批把原拒绝探针迁到SRAM上界洞 `0x11010000`，另加SRAM refill与cached-hit成功用例 | `o3-l11a-approved-platform-20261009`：seed1/7/29 各7/7 |
| PMP/PMA 三种子失败 | 原宽IO区间模型已过期。获批改为规格的七个精确区域及独立属性；原探针、随机序列、种子和规模保留 | 同上：seed1/7/29 各3/3 |

以原完整执行的未受影响结果与上述受影响重跑合并，既有runner的有效用例457/457通过；预期触发的SRAM禁止碰撞负向门禁另计并通过。该统计不是全部测试在最终提交上一遍重跑的总门禁。

整核证据 `/home/cloud_chen/evidence/o3-l11a-core-20261009`，2026-10-09T03:27:48Z～03:33:18Z，aggregate exit0。`core2` 使用MEM_PIPES=2/MSHRS=4，`core1` 使用MEM_PIPES=1/MSHRS=1，独立构建；两配置串行执行以免共用trace文件冲突。共27个目标exit0，含L7c frontend、smoke、DCache data/replay、branch、predict、FP、priv、`run-l10-vm VM_AD=1` 及四个L8b程序；双端口配置另含 `run-l8a-mem` 与退休trace比较。无golden/约束/规模降低。

新增 `sd_dma_bridge` 联合真实 `dma_line_adapter` 测试4/4通过，证据为approved-platform目录中的 `sd-dma.log/xml`。覆盖8个字槽×256种写mask及8次读（2056个WB事务）、最高DDR字地址、只读/设备/洞地址拒绝、请求/响应背压、真实一致性错误、握手前撤销、握手后撤销排空、四阶段复位。此层模拟L2响应端，未验证真实SD卡、LiteSDCard DMA错误恢复或完整缓存一致性。

### S1 SoC BIOS 冒烟

仿真入口 `sim/litex/o3_sim.py` 复用板级 `O3KCU105SoC` 构造器，以显式依赖替换注入时钟、UART仿真接口、完整2GiB几何DDR模型及SD模型；CPU、路由、CLINT/PLIC、CSR窗口、双DMA隔离接线共用。板级构造器默认硬件路径不变。模型没有物理DDR delay-training CSR，ddrphy页在CSR桥中保留；不得称模型冒烟验证了USDDRPHY训练或板级管脚。

仿真BIOS在Alan独立 `sim-source` 编译，不改板级冻结输入；ROM约31.59KiB。`bios.bin` SHA256 `3178797ee13c85b7c59b3a744ecea07141a0ff81a0a0dd6a4740f385b5d222c8`。只在仿真BIOS设MEMTEST_DATA_SIZE/MEMTEST_ADDR_SIZE=65536及CONFIG_BIOS_NO_BOOT。

- cloud cwd `/home/cloud_chen/work/o3-l11a-simulation-20261009`；命令 `python sim/litex/run_soc_smoke.py --bios bios-sim.bin --evidence-dir /home/cloud_chen/evidence/o3-l11a-s1-v2-20261009`，runner exit0、PASS。2026-10-09T03:29:04.292316Z～03:32:21.245185Z，196.95秒（含编译）。按真实串口横幅、`Memtest OK`、`litex>` 判成功，并要求真实首个AXI fetch=0x10010000与SRAM读。完成后runner主动终止持续运行的控制台，child exit -15为正常收尾，不伪装成模拟器自主exit0。
- Verilator `--assert` 明确开启，沿用仓库既有CVFPU配置；被动监视core fatal/inclusion error。每百万周期输出计数：2,000,000周期时退休1,626,386，ROM读506、SRAM读59、DDR读1024。DDR模型及缓存参与，但缓存内memtest不证明实际板级DDR写回/训练。
- 首次仿真编译因LiteX编译所有sim modules而缺libevent headers失败，保留 `o3-l11a-s1-20261009`；第二次加任务私有sysroot的CPATH/LIBRARY_PATH/LD_LIBRARY_PATH后通过，没有修改安装包或关闭RTL断言。
- Alan第一次模型BIOS编译给模型添加了伪PHY CSR，触发上游对物理training宏的假设而失败；删除伪CSR，固定页面保留，按SDRAMPHYModel实际软件接口构建。失败日志保留于 `bios-sim.log`。

S2（mtime/MTIP、UART PLIC claim/complete、洞load 5及ROM store 7）正在验证，尚不宣称通过。SD卡端到端、OpenSBI/Linux、最终同SHA总门禁及上板均未验证。


新增平台定向测试补充：`test_platform_mmu.py` 2/2通过，覆盖两块ROM中的三层页表、fetch/load/store、A/D已置的正常翻译、A缺失和store提交阶段D缺失的access fault；缺写权限时无CAS请求、页表未变化，设备/洞PTE地址在读取前拒绝。证据 `o3-l11a-p1-directed-20261009/mmu.log/xml`。`test_platform_dcache.py` 在MSHRS=4/1各2/2通过，覆盖两块ROM的load miss/hit、STA/AMO/SC写拒绝7、物理PTE CAS访问拒绝且无A写广播、设备区转LDW_HEAD与洞返回5且无一致性请求；证据 `o3-l11a-p1-directed-20261009-v3`。前两次新DCache测试误把普通设备load当作L1D完成、误读head位语义，夹具检查改为规格要求的LDW_HEAD路由原因；失败保留，旧golden未改。此次新增测试累计6/6，仅证明相应模块路径。

S2初次运行输入已被仿真串口模块接收，但无命令输出；为增加退休PC/IRQ/MMIO诊断于484.75秒主动结束，runner FAIL保留于 `o3-l11a-s2-20261009`，不是超时，也不是S2通过。监视器的周期输出此前受stdio缓冲，已加入刷新及观察信号，按相同BIOS重跑；只增加仿真观测，未改核行为。

云端回归与S1原始日志/XML/时间元数据已归档到本地 `build/evidence/o3-l11a-20261009/tests.tar.gz`，SHA256 `46fbcff94bbfdc7a78df10e9769514a3276087ac8aed9e4f1239bf52e8c9b426`。该归档不包含大型C++构建目录及后续S2/平台定向补充，相关日志仍在各自远端证据根。


### S2 发现并修复 IRQ 软件元数据不一致（之前 BIOS 不可作为上板通过依据）

被动观测确认：输入13字节进入UART，RX FIFO非空、UART IRQ=1、PLIC pending=0x400、源10优先级1；PLIC使能为0、MEIP=0。生成的 `soc.h` 却为UART_INTERRUPT=0、TIMER0_INTERRUPT=1、SDCARD_INTERRUPT=2，与实际硬件接线10/12/11矛盾。根因是SoC类使用 `irq_map` 属性，而当前LiteX SoCCore读取 `interrupt_map`。BIOS `irq_setmask` 又按固定PLIC mask过滤，于是尝试使能源0被过滤，RX中断永远不能进入核。

修复 `target.py` 属性名为 `interrupt_map`，仍从平台JSON生成；新增实际IRQ分配、生成BIOS中断常量与JSON的一致性检查。没有更改核RTL、PLIC行为、中断号或规格。S2前三次失败/诊断停止均保留，最完整根因日志为 `/home/cloud_chen/evidence/o3-l11a-s2-v3-20261009`。

旧Alan生产构建输入包含这份错误BIOS，因此主动终止本任务的timeout进程组405544，保留取消原因与日志。旧调试构建自动跳过，不能继续把错误BIOS用于FPGA输出；其他Alan任务未操作。旧BIOS编译exit0与S1 memtest PASS仍代表其实际检查范围，不能作为IRQ正确证据。修复后在Alan重编S2 BIOS，验证通过后再生成新的生产/调试输入快照。


旧生产 Vivado 2026-10-09T03:20:58Z～03:58:53Z，主动取消exit143（2275秒）；调试状态 `SKIPPED_STANDARD_FAILED`，没有启动旧调试综合。原因是BIOS IRQ输入不符合既定硬件，不能当作Vivado自身失败或时序失败。取消后确认进程组405544已无成员。

Alan重编S2 BIOS exit0，生成UART/SD/timer0常量已为10/11/12，ROM约32.61KiB，SRAM约3.06KiB。新的 `bios-s2-irqfix.bin` SHA256 `de7f83478ec7c563311d6a2fbc43fe46e9061aaf345c38c8cb7d0125e3afccbe`。修复后的S2仍在验证；新增 `check_platform_irqs.py` 用真实LiteX分配/最终常量检查，并负向注入错误的分配号及BIOS常量，要求构建检查拒绝。


IRQ构建负向测试最终通过：`o3-l11a-irq-guards-v2-20261009.log/.exit`，exit0；真实分配/生成常量为10/11/12，错误分配和错误常量两项均拒绝。第一次 guard 在LiteX最终化后误以为常量仍为SoCConstant对象，触发AttributeError；构建检查改为同时接受最终化前对象及最终化后的int表示，原失败保留。该修复不改变导出的IRQ数值。

Alan BIOS证据原快照归档已复制至 `build/evidence/o3-l11a-20261009/bios.tar.gz`，SHA256 `824e36ad30c826501f4c73b9461a17d87f5af73b7e2cb42c1e112475816cd31c`。它包含原生产/调试及S1/S2 BIOS、ELF、ROM init、生成地址表、编译日志/时间元数据，含已识别错误IRQ的历史输入；不包含修复后S2 BIOS或Vivado输出，不能误用为修复后的上板镜像。


### MMIO 32位寄存器读 lane 修复

IRQ编号修复后的 S2 于2026-10-09T04:02:56.934Z～04:10:20.435Z运行，443.50秒，诊断后主动结束，runner FAIL。核进入了真实UART ISR，但RX FIFO未清空。当前LiteX实际CSR桥为64位Wishbone到32位CSR，读时按sel选择一个槽；上游AXI-Lite→Wishbone读sel恒为0xff，因而总选择低槽。访问UART ev_enable高半字得到0，ISR反复claim却不处理RX。PLIC threshold低半字读也会因sel[4]被置位而产生相邻claim副作用。

新增 `litex_wrapper/o3/mmio_bridge.py`：继续例化上游AXILite2Wishbone，仅在CSR/PLIC区读时由AR byte address[2]选择0x0f/0xf0；写strb原样保留，CLINT读sel保留0xff。区域边界从同一JSON读取，不改变核RTL、地址权限或ERR语义。CPU包装向LiteX暴露该Wishbone出口，两个主总线master及隔离DMA检查仍保留。

`check_mmio_read_lanes.py` 用真实64位Wishbone/32位CSRBank验证不同上下半字数据、写入、R/B背压，同时检查PLIC lane与CLINT完整64位数据。原始全sel基线失败保留 `o3-l11a-mmio-baseline-20261009.log/.exit`；修复版PASS于 `o3-l11a-mmio-lanes-v2-20261009.log/.exit`。首次新测试的PLIC组合ACK夹具在LiteX注册译码生效前应答，读回0；改为注册ACK，失败日志保留。早期临时32位桥探针错误地使用组合CSR dat_r，不代表真实CSRBank读数据，应以本入口为准。

窗口测试也改为与实际SoC一致的64位Wishbone桥；此前516请求证明地址/完成范围，不证明寄存器读值。新S2正在用同一修复后BIOS重跑，尚无通过结论。


修复lane后S1+S2 PASS：cloud_chen `/home/cloud_chen/evidence/o3-l11a-s2-lanes-20261009`，2026-10-09T04:12:36.100Z～04:15:51.706Z，195.61秒（含编译），runner exit0、正常收尾child=-15。相同IRQ修复后的Alan BIOS SHA256 `de7f83478ec7c563311d6a2fbc43fe46e9061aaf345c38c8cb7d0125e3afccbe`；真实串口输入命令成功执行，mtime、MTIP M-trap、UART PLIC claim=10/complete、hole load cause5/mtval12100000、ROM store cause7/数据不变均有PASS日志。Verilator断言开启，无fatal/inclusion/越界请求断言。该层仍不证明物理DDR训练、实际SD卡或板上行为。

实际64位Wishbone CSR桥的整个1MiB窗口测试也PASS：`o3-l11a-csr-wide-20261009.log/.exit`，516读写及四个窗口外探针，exit0。此前32位桥测试保留为历史证据，新证据对应实际桥宽度。

### 修复后 Alan 板级输入

新独立根 `/home/chen/FUN/CISLC-O3-runs/l11a-mmio-20261009-b36bd1b2`，source为890文件快照，输入归档SHA256 `b36bd1b2391fea2fd356a7c5f33edcd68f87e73e11f41621f30f58f3593a0cad`，逐文件manifest校验通过，包含CVFPU及common_cells子模块，不含git元数据。原错误输入独立保留。

生产/调试BIOS及硬件生成均exit0；两份BIOS SHA256均为 `2cb33d00c913f1d61f2f5949de5575598c44ee7a810e9b4881395e80103badb2`，UART/SD/timer0=10/11/12，生产ROM约39.79KiB、SRAM3.31KiB。CPU包装含本次read-lane修复，PMA/JSON与仿真相同。新的生产Vivado已安排，调试版只在生产exit0后启动，每版timeout10800秒，100MHz及约束不变。尚无综合/实现/bitstream通过结论。


### 最终源码与一遍总门禁（进行中）

实现提交 `ab08bea`，测试提交 `5f7e34d0c236f08ba092001b27e87555f8d258bf`；仅提交L11相关文件，其他已有文档修改保留，未推送。最终提交git archive加现有CVFPU/common_cells源码，共877文件，归档SHA256 `8eff54cede45559eeaa5af6343c93495709ffef9d432626d9717d7563ebc653a`。Alan板级输入的334个RTL/子模块/平台JSON/构建源码与最终提交逐文件一致，后续测试/报告提交不改变板级输入。

cloud cwd `/home/cloud_chen/work/o3-l11a-final-5f7e34d`，证据 `/home/cloud_chen/evidence/o3-l11a-final-5f7e34d`。主runner `run.sh` 在独立源码快照并行执行完整模块runner与整核两配置27目标；模块结束后执行平台MMU/DCache两MSHR配置、lint、包一致性、实际CSR桥窗口、MMIO lane及IRQ guards。所有原随机种子/规模与断言保留，SRAM禁止碰撞负向门禁单列。最终S2同提交重跑另行附加。当前不能宣称最终总门禁已通过。

新生产Vivado真实启动2026-10-09T04:16:51Z，Alan启动脚本PID438440，调试排队脚本PID438441；每版上限3小时。没有触碰其他任务。


最终源码总门禁的模块/整核/定向部分PASS：2026-10-09T04:19:53Z～04:25:10Z，317秒，主runner aggregate exit0。完整模块97阶段exit0，其中SRAM禁止碰撞预期assert负向门禁独立通过，正常XML为461/461，无skip；平台MMU/DCache补充XML6/6；两种整核配置27目标exit0；包一致性、真实CSR窗口、MMIO lanes、IRQ guards均exit0，lint0 errors/357 warnings。这次统计来自最终提交的一遍执行，不与前次重跑合并。

最终提交的S2 BIOS重新在Alan编译，exit0，二进制仍为 `de7f83478ec7c563311d6a2fbc43fe46e9061aaf345c38c8cb7d0125e3afccbe`，实际源码根 `/home/chen/FUN/CISLC-O3-runs/l11a-final-5f7e34d/source`。云端独立S2重跑保存在同总门禁证据根。

依赖审计：两机327个LiteX、共同48个Migen、56个LiteDRAM Python源文件hash相同；Alan另外有88个Migen Python文件。LiteSDCard版本不同，四个Python文件hash不一致。Alan工作树clean，commit `5429f5d7ef57f7e0a4802087033dbde8f1b7a4d5`；云端原为独立的 `b68dfded`。将Alan实际用于板级构建的整个LiteSDCard包复制到云端任务私有依赖目录 `/home/cloud_chen/work/o3-l11a-final-5f7e34d-deps`，归档SHA256 `abafcdfcdc5b52431c88333c7319bbe0d1f1202c9da322f31999e8f09fa85559`，不修改安装包。最终SoC再以该包运行 `s2-alan-deps`，同环境IRQ负向门禁已PASS；旧依赖S2保留原有检查范围。该版本对齐不影响纯O3 RTL的模块/整核回归。


`5f7e34d` 的最终同源依赖S1/S2 PASS：2026-10-09T04:26:01.813Z～04:29:20.833Z，199.02秒含编译，断言开启，runner0/child-15。共用442个依赖Python源文件与Alan hash一致。源码877文件manifest及全部日志/XML检查通过，机器可读功能证据已保存 `O3-T11a-functional-evidence.json`，明确 `functional_gate_passed=true`、`l11a_complete=false`、FPGA结果未知。最终功能归档 `build/evidence/o3-l11a-final-5f7e34d/tests.tar.gz` SHA256 `8629de6fbc2f85e73bd5819de890b5ad1a19e6b02ebc089ac5b55ff5ba934b45`；修复后Alan BIOS归档同目录 `bios.tar.gz` SHA256 `dda8dfaed8626c2af11e72117e4e4cc7d6f78decec138d732e69850b70ccf359`。

### 调试观察补齐（78db957，最终门禁重跑中）

交付核对发现原ILA只有退休及部分内存握手，尚不满足spec§9的MMIO、mtime、完整AXI元数据与H1～H3。新增被动watchdog：默认100MHz的10000000系统周期阈值、饱和计数、最后退休PC/指令、seen_retire；无退休、十个通道连续背压、四种已接受请求响应超时共15个粘滞原因，hang接debug LED。观察逻辑不驱动任一握手；26组探针覆盖完整内存/MMIO五通道、路由在途、原因及计数；ILA map保持原list结构，并在原因probe附bit名字、hang probe附阈值，生成 `o3_ila.ltx`。

定向 `check_debug_watchdog.py` 在cloud通过：15类原因、生成短阈值的触发/饱和/粘滞性、退休最高有效lane、非last R不释放/last R完成不误报、完整probe/.ltx导出检查。证据 `o3-l11a-debug-watchdog-20261009.log/.exit`。只改 `ila.py`、debug LED接线和新增定向测试；未改核RTL/正常版握手或任何旧测试判据。

主动终止原debug排队脚本438441（未启动旧debug Vivado），状态 `REPLACED_INCOMPLETE_ILA_INPUT`。新Alan根 `/home/chen/FUN/CISLC-O3-runs/l11a-final-78db957`，878文件源码包SHA256 `6582844bf9a303af0c237b62ba0409533f9d71cfe8e5ed307086a421941378eb`。新normal/debug BIOS/硬件生成均exit0。初次严格字节cmp失败仅因自动生成日期及层级注释中无语义的顺序差异；删除Verilog注释后逐字节一致，normalized SHA256 `530dc4e541b4743cd65b87f210eb73ad6134447b5cdac322b6f55a6c0c25f2ed`，XDC及ROM init原始字节完全一致。独立 `standard-input-identity.json` 保存三项结果。因此原生产Vivado继续使用等价输入，不额外重启；新debug使用当前输入，排队脚本444538仅在生产exit0后执行。

78db957的完整模块/整核/平台/正常SoC/观察器门禁在cloud独立根 `/home/cloud_chen/{work,evidence}/o3-l11a-final-78db957` 重跑。最终S2 BIOS再次在Alan编译，二进制仍为de7f8347；采用Alan同版本LiteSDCard私有包。最后这批结果尚未宣称通过。


### 78db957 最终功能门禁 PASS，P4等待结果

cloud_chen完整模块/整核/补充阶段2026-10-09T04:39:07Z～04:43:57Z，290秒，aggregate0；正常模块XML461/461、平台补充XML6/6，无skip；97模块阶段（含预期assert的SRAM负向门禁）、9补充阶段、core2/core1分别14/13目标，均exit0。新watchdog在此提交重跑通过，所有878源码文件manifest核对一致。

同提交、Alan同版本依赖S1/S2于2026-10-09T04:42:07.285Z～04:45:20.522Z通过，193.24秒含编译，runner0、正常收尾child-15，断言开启。mtime/MTIP、UART PLIC10 claim/complete、CSR洞load5及ROM store7均有真实串口PASS；CPU未向MMIO发洞地址。最终[功能证据](O3-T11a-functional-evidence.json)将回归阶段结束时间与SoC仿真结束时间分别记录，`l11a_complete=false`、`fpga_gate_passed=null`。

本地最终证据 `build/evidence/o3-l11a-final-78db957/tests.tar.gz` SHA256 `a6356f9fb875c3089502ac2dba2ef60facf6be4414c202d85fc468f9dace9ca5`；旧5f7e及诊断失败证据独立保留，不覆盖。新Alan BIOS/ILA map/等价输入证据也复制到同目录。

生产Vivado仍执行其唯一的修复后尝试，debug排队PID444538；无降频、无放宽约束、无自动重试、无上板动作。只读结果收集器PID444843在两版结束后生成Alan `l11a-final-78db957/evidence/fpga-result.json`，保存退出状态、时序表、错误行、bit/.ltx路径和hash，不启动任何构建。实际P4结果须另行核对，不能从当前功能门禁推导。

新Alan BIOS、ILA map及生产输入等价检查归档 `build/evidence/o3-l11a-final-78db957/bios.tar.gz` SHA256 `68b9ca0f55ac935a3a1aa3314402d1c0509af1fbdf1fcee37c274432c6a74217`。当前没有.bit/.ltx完成证据；该归档只含BIOS、导出表、工程生成及输入一致性。
