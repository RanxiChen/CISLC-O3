# 访存 RAM 映射与整核 OOC 修复

2026-10-08 用户要求同时修复，不再停留在方案讨论。分支 `fix/memory-ram-ooc-20261008`，起点 `59938310e8f09b270cc7e046d59307f13c522430`。本任务不修改冻结设计、容量、接口逐拍时序、黄金值与原有测试规模。T10 报告现有未提交修改属于此前工作，不纳入本修复提交。

## 改动与证据范围

- L2 directory：每 way 一个 packed 一维 RAM，单写口复用逐 set 初始化与运行更新，同步读保持 S0/S1/S2。
- L1D tag：每 lane/way 一个一维 LUTRAM；数据：每 bank/way 一个一维 BRAM，固定 byte enable。CPU 与 probe/WB 共用已有预约的 S0 读口，保持响应拍数；增加预约冲突断言。既有测试监视阵列只在非综合视图中保留。
- L2 AXI 行组装与 slot 更新：固定 beat/slot 切片加使能，去除动态位段写入形成的巨大选择/插入逻辑。原层级 LUT：u_mem 76171、u_slots 27478、L2 Home 自身21441；不能把全部125149 LUT都归因于meta。
- TAGE：遍历静态表范围，在循环体保留 first_longer 候选门控与原分配优先级。
- 诊断脚本与 boundary wrappers 复用 Alan OOC `42968c2`；增加 hold 最差路径和内部寄存器 hold 报告，无 false path/multicycle 豁免。
- 新增独立 byte oracle 的所有 word bank 边界掩码写/probe回读回归，以及TAGE每个provider/空候选集合定向回归。

## 原始 OOC

主机 Alan；证据 `/home/chen/FUN/20261008-ooc-42968c2/runs/`。三份相关 RTL 与本地起点 SHA256 一致。L2 no-retiming：125149 LUT、124575 FF、57 RAMB36、WNS +1.227 ns、WHS -0.143 ns、2516 hold endpoints。dcache rt：exit143/1445s；no-rt：exit124/2700s。整核 `/home/chen/FUN/20261008-ooc-02a88fe/runs/core_rt/`：TAGE Synth8-3380失败，exit1/97s。

## 开发检查

cloud_chen 首选SSH/环境成功，Verilator5.050/cocotb2.1.0。独立WIP目录 `/home/cloud_chen/work/20261008-o3-ram-fix-wip`，证据 `/home/cloud_chen/evidence/o3-ram-fix/wip`。首次传输缺CVFPU导致41个缺文件错误，补齐准确本地submodule内容后lint exit0/0 errors/357 warnings。这是WIP开发检查，尚不声明最终功能或映射通过。

## 最终验收

待同一源码提交在cloud_chen执行受影响回归，在Alan执行L2、dcache、整核OOC并记录SHA/cwd/命令/exit/资源与路径。综合估计不等于布局布线/SoC/FPGA证据。

## 首轮结果与后续修正

源码候选 `baa4441be2197adcf4f0371b94653acc0e1e5187`：cloud_chen lint0/357 warnings；dcache MSHR4共49/49、MSHR1基础26/26、MSHR1 N2原子20/20；TAGE seed1/7/29各3/3；L2 12/12（含原随机规模）；pressure N3 MSHR1/4各3/3。其他门禁仍在运行，不能提前计入通过。

Alan首轮L2 OOC完成（201.5秒）。directory已识别为LUTRAM，不再展开FF，但block属性被Vivado拒绝。进一步将RAM读结果先作为完整packed word寄存，再在RAM过程外转换为struct；初始化/运行写地址与数据在外部统一，RAM内部只留一条写表达式。该修正不改变读写拍数或优先级，WIP整核lint再次exit0/357 warnings；随后在新准确SHA复验。

## 目录 BRAM 与整核首次复验

`94ec4e27717b636a864f0b64cb3e3a881f1597fd` 的 Alan L2 OOC exit0/215.5秒：24002 LUT（9.90%）、34264 FF、57 RAMB36+8 RAMB18（61 tiles），WNS+1.709ns。directory八个way各512×22明确推断为RAMB18，属性不再不可实现。全局WHS仍-0.143ns/2516边界输入违例；内部hold另有报告，不能宣称实现时序闭合。

该候选cloud_chen默认MEM_PIPES=2整核构建exit0/220.6秒，13项既有短程序全部exit0：smoke、dcache data/replay、branch-dense、predict、l8a mem、FP、priv、VM及四项L8b。VM保持17534周期/6434退休/tohost1；AMO42937周期/7802退休、MMIO4416/1245、拆分18941/7048、DMA12762/3346。未执行Spike/ACT4或修改黄金。

Alan整核首次复验已经越过TAGE，58.8秒后在`rtl/backend/fpu/fpu_fma_fu.sv:54`报Synth8-27：条件表达式中的数组assignment pattern缺赋值上下文。修为独立显式类型localparam，再用条件表达式选择它们；所有format流水级数与unit类型逐值保持。WIP lint exit0/357 warnings。此次只变FPU参数写法，L1D/L2/TAGE及其测试源码与94ec4e27逐字节相同；既有memory证据明确归于94ec4e27，不冒充后续候选新跑。随后复跑FPU定向、整核短程序与整核OOC。
