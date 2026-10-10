# PMP 范围预解码

执行 RTL SHA：`10235be8c09ae8f2f8820ff6519ec6e81e8f6962`；起点 `2e2b0fcf3e3a4906094f724157d9ef5ce20e666b`。原有 T10/RAM 报告和冻结文档修改未纳入实现提交。

CSR 保存原始 PMP 项，同时在相同沿更新范围派生状态。NAPOT 用 54 位 `e ^ (e + 1)` 解码，57 位排他上界保留全物理地址空间；访问路径只读取派生范围并选择最低编号匹配项。原解码/allow 函数保留为独立参照。CSR 带旧模型等价断言；PMP/权限接口节拍和 N+1 生效规则不变。测试适配器根据原始项计算派生状态，保持既有 Python 原始 CSR 编码。

## 功能证据

主机 cloud_chen，cwd `/home/cloud_chen/work/l7c-pmp`，证据根 `/home/cloud_chen/evidence/o3-l7c/pmp`。启动前重新读取共享主机文档并验证 SSH、环境和空间。Verilator 5.050 / cocotb 2.1.0。各任务 `run.sh` 保留命令，`run.log` 保留输出，`status.txt` 保留 exit 和耗时，三种子使用独立 XML。

| 门禁/命令 | 结果 | 证据 |
|---|---|---|
| `bash scripts/lint.sh` | exit0，0 errors / 357 warnings | decode/run.log |
| `make -C sim/cocotb/pmp_checker sim TEST_SEED={1,7,29}` | 每种子3/3；16项×OFF/TOR/NAPOT×尾1数量0..54；各10k随机项组和allow对照 | seeds/run.log，pmp-{1,7,29}.xml |
| csr_file；frontend_sync_ctrl；mmu | 11/11、3/3、7/7，exit0 | modules/run.log |
| icache seed1/7/29 | 各4/4，exit0 | seeds/run.log，icache-{1,7,29}.xml |
| dcache MSHR4（含N2）、MSHR1基础 | 49/49、26/26，exit0 | dcache-full/run.log，dcache{4,1}.xml |
| dcache MSHR1 N2全部（含生成的9个AMO用例） | 20/20，exit0 | n2full/run.log，dcache1-n2-complete.xml |
| `make -C sim/o3 build MEM_PIPES=2` + 原13项目标 | exit0，161秒（含构建/程序）；未运行Spike/ACT4 | core2/{run.log,status.txt} |
| `make -C sim/o3 build MEM_PIPES=1 BUILD_DIR=.../build1` + 原12项目标 | exit0，154秒（含构建/程序） | core1/{run.log,status.txt} |

原13项：smoke、dcache-data、dcache-replay、l3-branch-dense、l7-predict（A/B）、l8a-mem、l9-fp、l10-priv、l10-vm、l8b-amo/mmio/misalign/dma。MSHRS=1的12項排除任务明确不要求的l8a-mem。priv/VM仍为4047周期/437退休、17534周期/6434退休，与改动前报告一致。

开发时第一轮用SV保留字`matches`命名导致解析失败，已改为`match_bits`。重复`make sim`会复用XML，最终每种子独立XML重新执行；未把复用或只过滤11项N2的中间结果当全部通过。

## Alan L1D OOC

主机 Alan (`chen-System-Product-Name`)；Vivado2022.2；cwd `/home/chen/FUN/l7c-pmp-10235be`；证据 `/home/chen/FUN/CISLC-O3-runs/l7c-pmp/10235be`。沿用原`mem_preview.tcl`、wrapper、10ns约束、xcku040-ffva1156-2-e、无retiming；补充报告同一`internal_launch_q[0].permission.pmp_ok`端点。

命令：`timeout 2700 vivado -mode batch -source scripts/vivado/pmp_endpoint.tcl -tclargs /home/chen/FUN/CISLC-O3-runs/l7c-pmp/10235be`。exit0，总508秒，综合468.729秒。

原失败端点当前最差来自probe地址，余量 **+2.290ns**，25级，数据路径7.734ns；原30级、10.097ns、−0.073ns的原始PMP地址解码已不在访问路径。全模块最差路径已转为PLRU→reservation reset，WNS **+1.376ns**，TNS0。26579 LUT（较原32600减少6021），21560 FF（较原19635增加1925，含新增派生状态边界寄存器），数据RAM仍64 RAMB36。

全局 hold WHS −0.143ns、THS −862.999ns、6020 个失败端点；沿用零延迟外部边界，未掩盖这部分失败。独立寄存器到寄存器 hold 报告 `internal_hold20.rpt` 最差 +0.094ns。以上为综合后估计，尚非布局布线、整核、SoC或FPGA时序证明；未加 false path/multicycle 或额外访问流水。本次 OOC 对应 PMP 阶段 SHA，不作为最终 L7c SHA 的物理证明。

补充端点脚本保存在上述 Alan cwd 的 `scripts/vivado/pmp_endpoint.tcl`（不属于仓库提交）；可复现内容如下：

```tcl
set argv [list [lindex $argv 0] dcache 0]
source scripts/vivado/mem_preview.tcl
set ends [get_pins -hier -filter {NAME =~ *internal_launch_q*permission*pmp_ok*/D}]
if {![llength $ends]} {set ends [get_pins -hier -filter {NAME =~ *internal_launch_q_reg*/D}]}
report_timing -delay_type max -max_paths 5 -to $ends -input_pins -nets -file [file join $out_dir pmp_endpoint.rpt]
dump_paths [get_timing_paths -delay_type max -max_paths 5 -to $ends] [file join $out_dir pmp_endpoint.tsv]
```
