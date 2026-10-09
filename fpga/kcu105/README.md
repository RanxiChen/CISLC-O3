# O3 KCU105 完整 SoC

首版代码包含 O3/L1/L2、DDR4（LiteDRAM）、ROM/SRAM、CLINT/PLIC、UART、LiteSDCard 双向一致性 DMA。Breeze 代码复制到本仓库并记录来源，没有跨仓库构建依赖。

本轮按用户要求先写代码，功能测试随后补充。生成硬件、lint 或编译设备树均不代表 SoC、SD 实卡、Linux 或 FPGA 已验收。

## 入口

- `target.py`：LiteX SoC 与板级构建入口。
- `../../litex_wrapper/o3/core.py`：CPU 注册、SV 实例端口及总线。
- `../../rtl/platform/o3_litex_top.sv`：稳定平台包装，内部连接核和 SD DMA 桥。
- `../../rtl/platform/sd_dma_bridge.sv`：Wishbone 64-bit → O3 一致性行事务。
- `../../config/o3_platform.json`：地址、属性、CSR 页与中断号唯一来源。
- `../../scripts/gen_platform_pkg.py`：生成 RTL 平台包，`--check` 检查一致性。

## 主机与构建

每次编译/RTL 生成前重新读取 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`；先预检 cloud_chen，必要时 Alan。Vivado 只在 Alan。以下命令在选定主机、准确源码目录中执行。

硬件生成（空 BIOS ROM，仅作结构检查）：

```sh
python scripts/gen_platform_pkg.py --check
python fpga/kcu105/target.py --no-compile-software --output-dir /absolute/fresh/output
python fpga/kcu105/target.py --debug --no-compile-software --output-dir /absolute/fresh/debug-output
```

默认入口会先编译 BIOS，再生成工程。需要 LiteX、Migen、LiteDRAM、LiteSDCard、litex-boards、RISC-V 工具链，以及当前 LiteX 所需的软件依赖（如 pythondata-software-picolibc/compiler-rt）。

```sh
python fpga/kcu105/target.py --output-dir /absolute/fresh/output
```

后续授权进入 FPGA 构建阶段时，在 Alan 上加 `--build`。脚本不调用板卡下载，不写 SD 卡；`--build` 与空 BIOS 选项不能组合。

## 地址和 DMA

BIOS 起点 `0x10010000`，SRAM `0x11000000`，DDR `[0x80000000, 0x100000000)`。UART CSR `0x12001000`，SD CSR `0x12006000`；PLIC ID：UART 10、SD 11、LiteX 辅助 timer0 12。核的时间与软件/定时中断由 CLINT 提供。

CPU 内存 AXI 直接接 LiteDRAM；CPU MMIO 和低速 ROM/SRAM 走 LiteX 主总线。两个 SD DMA master 走独立 DMA bus，终点是 O3 的一致性入口。构建检查禁止主总线旁路直写 DDR。CSR 窗口为 `[0x12000000, 0x12100000)`（1MiB），18 位 CSR word 地址参数从 JSON 推导，整个窗口由 CSR 桥覆盖；窗口外访问由核 PMA 拒绝。LiteX 桥不传播 Wishbone ERR，不使用 ERR slave 补洞。

构建检查全部七个 PMA 区域与实际 LiteX 译码及属性一致，独立计算 DDR 几何容量，并拒绝过期的生成包。`address-map.json` 导出实际区域，`memory-paths.json` 导出 CSR 地址位数、DDR 容量和隔离路径。这些是结构检查，行为仍需功能测试。

DMA 桥只允许 DDR，部分写保持字节掩码；ACK/ERR 必须在真实一致性响应后返回。已接受事务被上游撤销时继续排空响应，不回假 ACK。BIOS 的 SRAM/未对齐缓冲区用 DDR bounce buffer；最后 4KiB DDR 为 BIOS SD scratch，设备树保留。软件适配写到构建目录 `software-source`，安装的 LiteX 不变。

已知限制：DMA 的非法地址或一致性错误只返回 ERR，而 LiteSDCard DMA 只等待 ACK，可能停滞；Linux 阶段需要补错误观测/恢复或地址寄存器检查。当前每个 8B 字独立进行 64B 行事务，无行缓存/写合并，SD 提速后的吞吐需测量。

## SD 启动准备

从实际生成的寄存器表生成设备树（含 Sv39、Sstc、Sscofpmf、CLINT/PLIC、UART、SD 与 dma-coherent）：

```sh
python fpga/kcu105/gen_dts.py --csr-json /output/csr.json --output /output/o3-kcu105.dts
dtc -I dts -O dtb -o /output/o3-kcu105.dtb /output/o3-kcu105.dts
```

使用已为本平台构建的 OpenSBI `fw_jump.bin`（下一阶段地址 `0x80200000`）、Linux `Image` 和 DTB 打包：

```sh
python fpga/kcu105/prepare_sd_boot.py --opensbi /images/fw_jump.bin \
  --kernel /images/Image --dtb /output/o3-kcu105.dtb --output /absolute/fresh/fat-files
```

该命令编译启动跳板并产出 `boot.json` 与哈希清单，只创建普通文件。OpenSBI、DTB、Image 分别装入 `0x80000000`、`0x80100000`、`0x80200000`，跳板在 `0x80080000` 设置 hart/DTB 参数，执行 FENCE/FENCE.I 后进入 OpenSBI。

软件镜像、Linux MMC 驱动与真实 SD 通信尚未验证；不能用 Breeze 的历史镜像或结果作为 O3 启动证据。后续测试覆盖见 `doc/tasks/O3-T11a-report.md`。
