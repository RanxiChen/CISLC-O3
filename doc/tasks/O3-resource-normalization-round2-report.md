# O3 四发射实现资源优化：第二轮

本轮继续按用户授权修复实现成本，保留四发射、原容量、全部 uop 字段、接口周期和冻结行为。最终整 SoC **457,704 LUT**，相对上一轮 482,284 LUT 减少 **5.1%**，相对原版 856,499 LUT 减少 **46.6%**。占 KCU105 LUT 容量的 **188.8%**；仍超出器件容量。 综合 WNS **-50.531 ns**，最差路径 **190 级逻辑**，时序未闭合。这是未放置的估计，不是实际布线时序。

## 源码与执行范围

- cwd `/home/chen/work/CISLC-O3`，分支 `feat/l11a-litex-soc`，父提交 `a0a9fc0fb39ce722092d2c98b2d18be52a10a53b`。
- 当前 12 个修改 RTL 文件尚未提交，父提交不能表示最终源码。`build/evidence/o3-resource-normalization-round2-20261009/source-final.json` 逐项绑定 SHA256；其中 8 个文件沿用第一轮，第二轮修改 Free List、Rename Map 和 INT/FP Writeback 四个文件。
- 冻结对照 `78db9574b175383603b46238533335ad3eaa58df`。第一轮证据仍按其当时 10 个文件绑定，见 `O3-resource-normalization-report.md`，不作为当前四个已变更文件的最终验证。
- 仿真每批启动前重读共享主机配置、先预检并使用 cloud_chen；Vivado 在 Alan 使用 2022.2、`xcku040-ffva1156-2-e`。
- 配置包、平台 JSON、原测试/期望、种子、规模、断言和 100 MHz 约束未改变；没有删字段、增加流水周期或选择新 FPGA。preg_ready_table 的试验改写收益很小，已恢复原样。

## 实现改动及实测取舍

Free List 用平衡优先编码树选择最小可用物理寄存器，按 lane 排除此前真正接受的选择；空闲计数改为平衡归约。分配的目的寄存器先统一译码，再由各 checkpoint 固定 bit 复用，避免每个 tag 复制比较器。保留稀疏请求、原分配顺序、同拍释放不提前借用、checkpoint 创建/分配/恢复/flush 优先级及 INT p0 约束。提交位图使用原始 packed-index 更新语句，保持 FP 域共享索引宽度下的旧语义。

Rename Map 每个 lane 的快照只计算一次，包含较老 lane 和自身，排除较年轻 lane；各固定 checkpoint 行选择对应快照，重复 tag 时保留原 lane 优先级。speculative/committed 映射按固定行更新，flush 仍包含同拍真正提交，FP f0 可写规则保持。

Writeback 使用并行年龄排名，每个候选统计比自身更老的有效候选；端口直接选择排名等于端口号的项，消除端口间串行选赢家的依赖。INT 原无符号年龄和 FP 原有符号比较分别保留，相同年龄按原 source 顺序决定。全数据在选定源后读取；kill、x0、consume、complete、fflags 和无效公开输出保持。

完整端口独立 OOC 综合使用相同器件、100 MHz、flatten none、无 retiming。组合模块使用相同虚拟时钟及零 I/O delay；这些结果不代表整核或实际布线时序。

| 实例 | 上轮 LUT | 本轮 LUT | 上轮 FF | 本轮 FF | 最差逻辑层数 | 本轮 OOC slack ns |
|---|---:|---:|---:|---:|---:|---:|
| INT Free List | 7,936 | 5,849 | 1,710 | 1,710 | 27 → 22 | +0.703 |
| FP Free List | 4,688 | 3,909 | 1,152 | 1,152 | 16 → 20 | +1.674 |
| INT Rename Map | 22,696 | 11,196 | 4,025 | 4,032 | 5 → 4 | +8.898 |
| FP Rename Map | 23,991 | 10,829 | 4,032 | 4,032 | 5 → 4 | +8.594 |
| INT Writeback | 1,627 | 2,267 | 0 | 0 | 51 → 10 | +6.158 |
| FP Writeback | 796 | 861 | 0 | 0 | 25 → 10 | +6.763 |

六项均 exit=0、0 latch，源码与当前文件哈希一致。两个 Free List 合计 12,624 → 9,758 LUT，减少 22.7%；两个 Rename Map 合计 46,687 → 22,025，减少 52.8%。INT/FP Writeback 合计增加 705 LUT，换取 51/25 → 10/10 级逻辑。FP Free List 的独立最差层数 16 → 20、slack +3.790 → +1.674 ns，不能把所有局部变化称为时序改善。六项合计是独立测量，不是整机估计；跨模块优化后的层次归属也不能直接当作模块成本。各 cwd、实际命令、UTC 起止、exit、模块及报告哈希在 `build/evidence/o3-resource-normalization-round2-20261009/modules.json`。

## 最终行为验证

实际执行主机 cloud_chen。源码 `/home/cloud_chen/work/o3-resource-round2-20261009-r4`，完整证据 `/home/cloud_chen/evidence/o3-resource-round2-20261009-final-r4`。完整回归 UTC 2026-10-09T13:15:32Z 至 2026-10-09T13:25:56Z，所有 runner exit=0。本地核验摘要 `build/evidence/o3-resource-normalization-round2-20261009/local-final-audit.json`，原始日志/XML/命令位于 `build/evidence/o3-resource-normalization-round2-20261009/functional/`。

- 608 个源码、脚本和清单输入在远端执行后重验，并逐一匹配本地；平台 JSON 和 7 个已有 expected JSON 另与冻结提交逐项匹配。
- 461 个正常模块测试 PASS；97 阶段 exit=0，0 failure/error/skip。SRAM 禁止碰撞负向门观察到规定断言终止，单独记录，不计为正常 PASS。
- 6 个平台定向测试 PASS；9 阶段 exit=0。Lint 0 errors、355 warnings，没有新增豁免。
- 原整核两套参数：MEM_PIPES=2/MSHRS=4 的 14 个目标、MEM_PIPES=1/MSHRS=1 的 13 个目标全部通过；未改 FPGA 默认配置。
- BIOS SoC selftest PASS，断言启用，memtest 65,536 bytes，867.745 秒，原 1,800 秒门限保持。BIOS SHA256 `de7f83478ec7c563311d6a2fbc43fe46e9061aaf345c38c8cb7d0125e3afccbe`，runner exit=0；成功后按约定停止子进程，child_exit=-15。UTC 2026-10-09T13:15:33.541606+00:00 至 2026-10-09T13:30:01.286778+00:00。
- 当前四个改动模块的所有公开输出与冻结参考逐周期比较，包括无效输出。Rename Map 和 Free List 各 INT/FP × 3 个种子 × 12,000 周期；INT/FP Writeback 各 3 个种子 × 6,000 周期。共 18 组、180,000 周期全部 PASS，种子 1、7、29 保持。原 Free List、Rename Map、wb_alu_kill 测试也通过。

这是有限仿真与周期对照，未做形式等价证明。第一轮 unchanged 模块的定向证据保留；最终全回归统一绑定全部 12 个修改 RTL 文件。

## 未采用的候选和执行修正

R1 用前缀排名分配寄存器，INT LUT 膨胀；FP 对照发现提交位图与旧 packed-index 语义不同。保留失败日志并恢复原提交索引操作，随后对照通过。R2 的 Free List 固定 checkpoint 并使用前缀选择，收益不足；R3 平衡选择后发现每个 checkpoint 重复目的寄存器比较器；R4 共享译码后才达到最终面积。ready table 仅数百 LUT，候选收益不足，已恢复原源码。

R4 定向控制器在对照全部通过后，调用不存在的 `sim/cocotb/writeback_arbiter` 路径而 exit=2；这是执行路径错误，不能写作该控制器整体 exit=0。已改用已有 `wb_alu_kill`，种子 1/7/29 的 XML PASS；7/29 的实际命令及 exit 在 `corrected-original-test-results.json`，完整模块回归也覆盖此测试。失败调用和候选失败均保留。

## 同条件整 SoC 综合

沿用原生成 SoC Verilog、ROM/SRAM init、XDC、器件和综合参数。脚本只替换 source/output 路径、停止在综合后并添加最差路径报告。255 个综合源文件在执行后重新核验；generated input 哈希与第一轮相同，详见 `build/evidence/o3-resource-normalization-round2-20261009/soc-input-audit.json`。实际 cwd `/home/chen/FUN/CISLC-O3-runs/resource-round2-20261009-r4/evidence/soc`，命令 `vivado -mode batch -source soc_area.tcl`，UTC 2026-10-09T13:15:34.923108+00:00 至 2026-10-09T13:56:04.693736+00:00，exit=0；Vivado 无运行时限。Vivado 综合日志记录 0 errors、0 critical warnings、203,207 warnings；原始日志完整保留，此数量与仿真 lint 的 355 warnings 分开记录。

| 版本 | LUT | FF | BRAM tiles | DSP | 综合 WNS ns | 最差逻辑层数 |
|---|---:|---:|---:|---:|---:|---:|
| 原版 | 856,499 | 231,102 | 251 | 38 | -84.920 | 279 |
| 第一轮 p19 | 482,284 | 200,871 | 251 | 38 | -61.651 | 221 |
| 第二轮 R4 | 457,704 | 200,919 | 251 | 38 | -50.531 | 190 |

本轮 LUTRAM 5,400、SRL 53、latch 0。最差路径 source `o3_litex_top/u_core/u_backend/u_dcache/ps_resp_q_reg[paddr][6]/C`，destination `o3_litex_top/u_core/u_backend/u_div_execute_unit/u_data/remainder_o_reg[63]/D`，60.367ns  (logic 14.705ns (24.359%)  route 45.662ns (75.641%))。TNS -2292174.25 ns，WHS -0.252 ns。原始报告在 `build/evidence/o3-resource-normalization-round2-20261009/area/r4/evidence/soc/`，解析结果和 top30 层次统计在 `build/evidence/o3-resource-normalization-round2-20261009/soc-final.json`；原始 DCP 留在 Alan。

原版 placement 因 LUT 容量 DRC 失败；本轮未运行 placement、route、bitstream 或上板。综合 exit=0 不证明 FPGA fit，也不证明时序闭合。

## 后续边界

第二轮验证了 Free List/checkpoint 的重复逻辑和写回串行优先链可以继续优化；仍不能断言剩余资源全部合理或四发射必然超标。后续按实际逻辑锥继续查重写成本及长链，器件或配置选择仍待实现成本稳定后再决定。若需新增流水周期，须先明确恢复/完成/退休/访存取消的周期约定。

PRF 的通用/FPGA 分支和 reset 语义可作为后续核查方向，目前未修改或宣称收益。已有 LiteX SD DMA 非 DDR err/ack 限制未由本轮处理，测试 PASS 不等于所有错误路径均无无限等待。

为回归腾出空间，只删除已完成、确认无活动任务的 `.gch` 编译缓存；源码、生成头、对象、二进制、日志和结果保留。两批逐文件清单和删除结果保存在 `functional/o3-resource-round2-20261009-cache-prune/` 和最终回归的 `compiler-cache-prune-completed-stages/`。
