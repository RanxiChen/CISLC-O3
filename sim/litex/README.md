# O3 LiteX 仿真

执行前重读共享的 [主机配置](/home/chen/leisure/flow/docs/cross-project/simulation-host.md) 并预检。BIOS 按用户授权在 Alan 的完整 LiteX 环境编译；Verilator 编译/仿真在 cloud_chen，Vivado 在 Alan。

`o3_sim.py` 复用 KCU105 SoC 构造器，保持核、地址路由、CSR 窗口、CLINT/PLIC 及隔离双 DMA 的接线。替换项为上电复位/时钟、UART stream pins、完整容量 SDRAMPHYModel 和 SD emulator。模型没有物理 delay-training CSR，固定 ddrphy 页留在 CSR 窗口内。模型仿真不验证实际 DDR 训练、板级管脚或真实 SD 卡。

Alan 上生成仿真专用 BIOS（不调用 Verilator）：

```sh
python sim/litex/o3_sim.py --output-dir /absolute/task/build/sim-bios
# S2 的 BIOS 命令只加入仿真软件副本。
python sim/litex/o3_sim.py --selftest --output-dir /absolute/task/build/s2-bios
```

将相应 `software/bios/bios.bin` 复制到 cloud_chen 的相同源码快照。激活 O3 环境并为本任务配置 LiteX/Migen/LiteDRAM/LiteSDCard、pythondata 包及 libevent/json-c/pcap 头文件和库路径；不修改安装的上游软件。随后执行：

```sh
python sim/litex/run_soc_smoke.py --bios /absolute/bios.bin --evidence-dir /absolute/evidence/s1
python sim/litex/run_soc_smoke.py --bios /absolute/s2-bios.bin --selftest --evidence-dir /absolute/evidence/s2
```

runner 的编译加运行总墙钟上限为30分钟，超时失败。它明确开启 `--assert`、`ENABLE_RETIRE_INFO` 和仓库已有 CVFPU 配置，保存原始 UART/构建日志、BIOS hash、命令、开始/结束时间与退出状态。S1 要求真实横幅、64KiB memtest、控制台、首个 AXI 取指地址和 SRAM 访问。S2 在控制台发送 `soc_selftest`，检查实际 CLINT timer trap、UART PLIC 源10 claim/complete、CSR 上界洞 load fault 5、ROM store fault 7 与 ROM 数据不变。被动监视器额外拒绝该洞请求出现在 MMIO 总线上。成功后 runner 终止常驻控制台，child 的信号退出与 runner 的验收退出分开记录。

`soc_selftest.c` 是测试固件，故意使用冻结地址作为独立判据；不加入板级 BIOS。异常指令强制32位编码，trap handler 记录 mcause/mtval，再继续执行检查。周期诊断包含退休数、最后退休 PC、IRQ 与 MMIO 状态，主动刷新输出，便于区分核停滞与日志缓冲。

独立定向入口：`check_csr_window.py` 验证真实 LiteX CSR 桥整个窗口；`sim/cocotb/platform_pma` 验证独立区域属性表；`sd_dma_bridge` 联合真实行适配器验证字槽、mask、背压、错误及撤销/复位；`test_platform_{dcache,mmu}.py` 验证 ROM 权限、页表 A/D 及洞/设备分类。结果均只代表各自测试层级。

`check_mmio_read_lanes.py` 使用上游 AXI-Lite 桥、64位 Wishbone/32位 CSRBank，检查相邻寄存器不同数据、读写与响应背压；另查 PLIC 阈值读不选择 claim 半字、CLINT 保持完整64位读取。`--baseline` 可复现原始全字节选择错误。O3 包装只补充 CSR/PLIC 的32位读 lane 选择，仍复用上游桥的握手与响应语义。`check_platform_irqs.py` 检查实际 LiteX 分配和导出的 BIOS 中断号，并注入两类错误验证构建拒绝。
