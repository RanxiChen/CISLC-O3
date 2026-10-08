# O3-T10 N4/N6 并行窗口记录

分支 `t10/n4-n6-tests`；工作区 `/home/chen/work/CISLC-O3-t10-par`。
基线 `a1e7186667c6bc851a9f09a8e5662c62405caec3`。本窗口只提交测试侧文件与本文；未修改 RTL/spec/design/任务书/主报告，未推送 origin，未声明任何 `Nk pass`。
已定期合并 `feat/L1-closure`；主窗口 `676eeca` 的报告增量和 `b6256b7` 的 backend Makefile 接线随合并进入分支，不是本窗口对报告的编辑。当前 RTL 与基线相同。

## 主机与运行目录

每个编译/仿真命令前重新读取共享 `simulation-host.md`，先预检 cloud_chen。全部实际运行在 `cloud_chen@47.96.71.231`，无需回退 Alan；没有本地仿真。
Verilator 5.050、cocotb 2.1.0、Python 3.12.12；GCC 为远端 `riscv64-unknown-elf-gcc`。首次预检可用空间 9.1G、可用内存 29GiB。
以下短 SHA 均对应目录 `/home/cloud_chen/work/20261008-t10par-<sha>/`，日志在各目录 `par-results/`，XML 同目录。按准确提交的 `git archive` 同步。

- A = `453d5802b98e50d1e587c2b8b9d575e6045adee3`。
- B = `75a94dbe09fdcb5f1932c187c8be7862b70e9956`。
- C = `d49398f7504d9fd104c1114fa8cc92b15663b833`。

整核在 B 下 `make -j4 -C sim/o3 build`，exit 0。按 pinned CVFPU `1b220f3bc89df99e246b72e3574a3a533cf87653`、common_cells `6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea` 同步源码，未动原 worktree 的 submodule。
C 只改测试刺激/程序及主窗口文档；B→C 的 RTL、整核 top/model/main.cpp/Makefile 编译输入无差异。C 在自己的独立目录复用 B 的可执行文件，并重新编译四个程序集、重新运行四个程序。不是同最终 SHA 的总门禁声明。

## N4 已写及通过项

新增 decoder 全 funct5/funct3、aq/rl、LR 保留 rs2、rd=x0 编码；SQ ATOMIC/MMIO/SPLIT 等待、完成唤醒、退休直接释放不 drain；LQ HEAD 与 DMA/PTE 两路顺序标记；LSU 全 2/4/8 字节跨行偏移及 FP、原子 AGU、Y14、高半页真实 DTLB fault；HEU 启动、两半预检查、格式化、D 更新与 sfence、异常 tval、取消、不可撤销 MMIO、WB 保持；commit 中断屏蔽/order refetch/FENCE.I；misa.A。
原 M4 用例、随机规模和 seed 1/7/29 保留。所有已有 wrapper 的接口接线可用；无旧测试冲突。

一般命令：`make -j4 -C sim/cocotb/<suite> TEST_SEED=<seed> COCOTB_RESULTS_FILE=<cwd>/par-results/<item>.xml`。下表列的是各项最新有效结果，合计 38 runs / 165 case instances，exit 全 0、failure/error/skip 全 0；分布在 A/B/C，不声称同 SHA 全量验收。

| suite | SHA | seed/参数 | 每次用例数 | exit |
| --- | --- | --- | --- | --- |
| decoder | A | 1 | 2 | 0 |
| load_queue | A | 1/7/29 | 9 | 0 |
| store_queue | A | 1/7/29 | 7 | 0 |
| load_store_unit | C | 1/7/29 | 10 | 0 |
| mem_head_unit | B | 1 | 6 | 0 |
| commit_ctrl | A | 1 | 8 | 0 |
| csr_file | A | 1 | 11 | 0 |
| load_store_unit_l5 | C | 1/7/29 | 2 | 0 |
| prf_read_arbiter | A | 1/7/29 | 1 | 0 |
| mmu | A | 1/7/29 | 7 | 0 |
| icache | A | 1/7/29 | 4 | 0 |
| backend_issue_queue | A | 1 | 3 | 0 |
| backend_issue_queue_l3 | A | KIND=0/1/2，各 seed 1/7/29 | 1 | 0 |
| mmu PTE | A | Makefile.pte，各 seed 1/7/29 | 2 | 0 |

IQ 命令另加 `KIND=<kind> SIM_BUILD=sim_build/k<kind>`；PTE 命令为 `make -j4 -C sim/cocotb/mmu -f Makefile.pte TEST_SEED=<seed> SIM_BUILD=sim_build/pte COCOTB_RESULTS_FILE=<cwd>/par-results/pte-s<seed>.xml`。
A 的 HEU 首轮 5/6、exit 2：撤下 flush 后没有等待组合输出 settle，误读 start_ready。`fbd4508` 补 settle 并按 valid 位等待结果；断言未放宽，B 重跑 6/6。此项是测试驱动错误，不是 RTL 失败。

## N6 已写及运行项

模型地址图：`0x02000000` 起 4KB RW；`+0x800` 读一次加一；`+0x808` 无副作用计数快照；`+0xf00..fff` SLVERR；`+0x900` DMA 命令、`+0x908` 行地址、`+0x910` 字节掩码、`+0x918` 重复双字样式、`+0x920` 状态、`+0xa00..a3f` 行读结果。`+0x830/+0x838` 置/清软件中断。
AW/W 独立接受、确定性反压，R/B/DMA 请求保持断言开启；副作用只在 AR 握手时累加一次。DMA 始终最多一笔在途。

四个程序均含自查与 tohost，已分别运行。默认 MEM_PIPES=2/MSHRS=4/RFO=1，Y13/RTL 断言开启；未执行 Spike/ACT4/litmus/综合。
C 下命令为 `make -C sim/o3 run-l8b-<name>`，用例数每个 1 个程序；trace 在 `<cwd>/sim/o3/build/l8b_<name>.jsonl`。

| name | SHA | exit | 自查 | 周期 | trace 事件数（含截止同拍尾部） |
| --- | --- | --- | --- | --- | --- |
| amo | C | 0 | tohost=1 | 42937 | 7802 |
| mmio | C | 2，runner=3 | 未到 tohost，timeout | 1580366 | 250000 |
| misalign | C | 0 | tohost=1 | 18941 | 7048 |
| dma | C | 0 | tohost=1 | 12762 | 3346 |

AMO：9 种 × W 偏移 0/4 和 D × 4 组边界操作数；另一半字不变；LR/SC 1000 次循环；不同地址/大小/夹 trap 的 SC 失败；rd=x0；AMO 非对齐；misa.A。
MMIO：全部 1/2/4/8 字节选通；慢 DIV 与交替分支；逐读返回 0..95、快照 64/96 的精确检查；中断恰好 1 次；SLVERR 5/7、非对齐 4/6、IO 取指 1、IO AMO 7；FENCE 与主存/DMA 顺序。后半内容因下述 RTL 疑似问题未执行到，断言与程序均保留。
拆分：全部跨行偏移逐字节比对及 FP；跨页 load/store 第二页未映射检查 cause/tval、低半不写；第二页 D=0 后置 D；退休拆分计数自查为 55。初版 B 的 HPM selector 写成 0x24（无 BE 来源字节）而读出 0，属于测试错误；按接口改成 0x224，C 全部自查通过，不改黄金值。
DMA：脏行读、整行写、稀疏 mask、LR 后同行 DMA 写使 SC 失败、128 次写/CPU load 交替只接受完整双字值。

事件记录（未列事件均为 0，仅记录，不设阈值）：
- amo：amo_exec=109，lr_exec=1003，sc_fail=3。
- mmio（失败运行）：mmio_read=95，mmio_write=41537，side_reads=64。
- misalign：misaligned_crossline_split=55。
- dma：lr_exec=1，sc_fail=1，rsv_probe_hold_cycle=62，mmio_read=274，mmio_write=266，ld_order_flush=3，dma_read=1，dma_write=131。

## 因 RTL 疑似问题失败的项与复现

`run-l8b-mmio`：C 的第一异常边界为 cycle 3054 / trace order 955，PC `0x800006a0`，instruction `0x00533023`（程序第 159 行：向 `0x02000830` 写 1 触发 MSI）。该写已产生外部 IRQ，但尚未退休；mcause 读回 `0x8000000000000003`，mepc 仍为这条写指令。handler 向 `0x02000838` 写 0 清中断并 mret 后，重做触发写，再次 MSI。共 20754 次 trap、20753 次退休清 IRQ 写；到 250000 trace events 截止，runner timeout。正常预期是这条已产生外部效果的 MMIO 写先退休，再受理中断，程序完成 96 次副作用读与全部异常/排序检查。

怀疑位置：`rtl/backend/mem_head_unit.sv:106-107` 在 RESULT/DONE→IDLE 清不可撤销位；`rtl/backend/backend.sv:153-154,305` 的 HEU complete/commit 连线；`rtl/system/commit_ctrl.sv:148-149` 在不可撤销位撤下后立即接收 IRQ，缺少“已完成 HEU 外部操作待退休”保护。尚未修 RTL，也不通过延迟模型 IRQ、修改 mepc 或减少循环掩盖失败。

复现（cloud_chen 激活 O3 环境后）：
```sh
cd /home/cloud_chen/work/20261008-t10par-d49398f7
make -C sim/o3 run-l8b-mmio
```
日志 `par-results/l8b-mmio.log`，trace `sim/o3/build/l8b_mmio.jsonl`。独立重新构建可在本分支准确 SHA 同步源码和 pinned submodules 后执行 `make -j4 -C sim/o3 build` 再运行同目标。

最重要的证据边界：误预测阶段 64 次副作用读逐次返回正确，计数快照为 64；含中断的 96 次完整检查尚未到达，因此不能宣称“含中断每条 MMIO load 恰好一次”通过。N4 的独立 HEU MMIO 响应/WB 反压保持用例通过，不能替代整核退休边界。

## 待用户批准的旧测试冲突

无。没有迁移与冻结 spec 冲突的旧测试，没有放宽断言、黄金值、规模或种子，没有删除用例。

## 提交与停止边界

本窗口提交：`453d580`、`fbd4508`、`75a94db`、`77d13a0`、`d49398f`，均为 test(n4)/test(n6) 前缀；另有本文的 test(n6) 记录提交。主窗口合并及其报告/Makefile 提交不算本窗口修改。
N4/N6 用例与程序均已写好并运行；MMIO 疑似 RTL 失败保留。到此停止，交由主窗口修 RTL、按 N 顺序声明层通过及执行最终总门禁。
