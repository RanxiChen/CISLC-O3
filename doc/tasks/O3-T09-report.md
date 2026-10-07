# O3-T09：L8a 实施与分层验证记录

日期：2026-10-07。第 1 步 RTL 静态门禁已完成；M1 已通过；M2 的冻结等待契约冲突已由用户批准 X11（eb1432c）解决，继续分层验证。前半部分保留第 1 步历史记录，第 2 步结果见文末；本文不是 L8a 总验收声明。

## 基线与源码

- 分支：`feat/L1-closure`；实施前 HEAD：`0e241e3477b6b61e3a149ef60e40b708b01c3338`。
- 唯一行为依据：`doc/spec/l8a-nonblocking-mem-spec.md`；执行依据：`doc/tasks/O3-T09-l8a-tasks.md`。未改冻结 spec、`doc/design/` 或 `doc/LOOP.md`。
- Breeze 参考固定为 `/home/chen/leisure/flow @ a304cc2`，阅读该提交的两份协议规格及 coherence/l1d/l1i/l2 Scala 源码；未修改 Breeze，也未以其当前工作树代替固定参考。
- RTL 提交：`0611b5c912369913c6833a33a17aebfd5ebdf55b`，标题 `feat(memsys): implement L8a non-blocking memory RTL (untested)`。
- RTL 提交 tree：`fe8ec1122255135b215c254de165234029653a9d`。候选对象先在远端完成门禁，全部通过后才接受到本地实施分支。报告单独提交，不改变 RTL。
- CVFPU：`1b220f3bc89df99e246b72e3574a3a533cf87653`；common_cells：`6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea`；fpu_div_sqrt_mvp：`86e1f558b3c95e91577c41b2fc452c86b04e85ac`；flexfloat：`28be2d4fbf41b38fc37763bb6e90a1c88f6aaa61`。首次候选通过代理初始化递归依赖，后续独立目录复用该固定源码。

## 已实现的 RTL

| 范围 | 变更 |
| --- | --- |
| 配置、协议与物理地址 | 架构 PA 保持 56 位，内部访存 PA 固定 32 位，高位在截断前检查；四条 whole-line 协议链路；新增 Replay 原因、MSHR/wake 身份和性能事件；删除 DTCM 路径 |
| L2 | 新增 `l2_home/l2_slots/l2_probe_engine/l2_mem_engine`；默认 512 组 × 8 路、8 慢槽、2 Put 槽、2 内存写回槽；S0/S1/S2、组保护、单写端口、D 目录、I Read 的 Down 最新值路径、替换 Inv、AXI 分 ID 读装配与保留至 B 的写回 |
| L1D | 64 组 × 8 路、8 个字 bank、4 个只保存行事务的 MSHR、2 WB；两路不保持 S2 的访问流水；同拍冲突与 snapshot 重放；一拍整行 install/probe/WB；ROB 队头/PTW 资源保留、可选 STA RFO、SQ drain GetM 与 PS 更新 |
| 等待与后端 | LQ 保存原 VA、uop、generation、等待原因与 MSHR ID；install/error/free/TLB/SQ/A-D 唤醒；SQ 两路地址执行与转发查询；两路 IS→RR→AG→S0→S1→S2→WB；每路深度 2 结果 FIFO，IS 计入在途预留；INT 3 写口、FP 2 写口；删除旧按序 load 发射门控 |
| 翻译与 A/D | 双查询共享 DTLB 数组、单 PTW miss 通路；PTW/PTE A/D/SQ drain 内部来源占用规定管道；needs_D 保存 store 身份并阻塞年轻访存，完成后刷新翻译再重放；保留精确原 VA 异常 |
| L1I 与整核 | ICache 改为 Read/ReadData 一拍整行、4 MSHR、按物理行合并、独立等待请求；不进入目录、不接收 IRecall；整核连接新 L2；FENCE.I 数据侧 clean 请求下一拍完成、busy=0，不扫描 DCache |
| 仿真接口 | 更新 tandem 顶层、初始化与被动性能观察点；新增仅用于参数展开的 `sim/cocotb/memsys/l8a_elab_top.sv`，无功能刺激；移除 `rtl.f` 中三个旧 L2 模块及不再使用的 DTCM SRAM 编译项 |

删除 `l2_cache.sv`、`l2_recall_ctrl.sv`、`dma_line_coord.sv`。旧 DMA 外部兼容端口暂时返回 inactive，实际 DMA 留待 L8b。

## 执行主机与预检

每次编译或 RTL 模型生成前重新读取 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`，按当时的首选配置预检。全部实际执行都在 `cloud_chen@47.111.104.2:22`；没有使用 Alan 或在本地运行仿真。

- 免密 SSH：`BatchMode=yes`、`ConnectTimeout=8`，成功。
- 环境：`source /home/cloud_chen/setup/activate-o3.sh`，成功。
- hostname：`iZbp16rhtg91v96m32vggjZ`。
- Verilator：`5.050 2026-07-01 rev vUNKNOWN-built20261007`；cocotb：`2.1.0`。
- 各次预检磁盘约 130～138 GiB 可用、内存约 25～29 GiB available，可支撑每批两个单线程展开任务。
- 首次依赖下载前验证远端 `http://127.0.0.1:18897` 代理访问 GitHub HTTP 200；后续无外网下载。源码以 Git SSH 传送准确提交对象到专用临时 bare 仓库，再独立 clone；没有使用 Git bundle，没有发布到 origin。

最终 RTL 工作目录：`/home/cloud_chen/work/20261007-t09-0611b5c`。

最终证据目录：`/home/cloud_chen/evidence/t09/0611b5c`。每项保存 `<name>.preflight.log`、`<name>.sha`、`<name>.exit`、`<name>.log`；`manifest.json` 列出准确 SHA、主机、cwd、完整命令和退出码。`*-cc/` 保留生成模型。

## 第 1 步同 SHA 门禁

执行 SHA：`0611b5c912369913c6833a33a17aebfd5ebdf55b`。全部 22 项 exit 0；最终 SHA 已在上述实际主机完整重跑。lint 为 0 errors、356 warnings。

| 检查 | 组合/项数 | exit | 证据 |
| --- | --- | --- | --- |
| `scripts/lint.sh`，top=`o3_core` | 1 | 0 | `lint.log` |
| 整核参数化模型生成 | `mem_pipes∈{1,2}` × `mshrs∈{1,2,3,4}` × `rfo_enable∈{0,1}`，16 | 0 | `p<p>-m<m>-r<r>.log` |
| 压力几何模型生成 | D 2 组 × 2 路、2 MSHR、1 WB；L2 2 组 × 2 路、2 慢槽；pipes 1/2 × RFO 0/1，4 | 0 | `pressure-p<p>-r<r>.log` |
| 现有整核仿真顶层模型生成 | `o3_tandem_top` + `ENABLE_RETIRE_INFO`，1 | 0 | `tandem.log` |

参数组合完整命令模板（替换 p、m、r、pressure、name；准确实例另见 manifest）：

```bash
source /home/cloud_chen/setup/activate-o3.sh
cd /home/cloud_chen/work/20261007-t09-0611b5c
scripts/lint.sh
verilator --cc --assert -Wno-fatal -f rtl/rtl.f \
  --top-module l8a_elab_top sim/cocotb/memsys/l8a_elab_top.sv \
  -GMEM_PIPES=<p> -GMSHRS=<m> -GRFO_ENABLE=<r> -GPRESSURE=<pressure> \
  --Mdir /home/cloud_chen/evidence/t09/0611b5c/<name>-cc
verilator --cc --assert -Wno-fatal -f rtl/rtl.f \
  --top-module o3_tandem_top -DENABLE_RETIRE_INFO sim/o3/o3_tandem_top.sv \
  --Mdir /home/cloud_chen/evidence/t09/0611b5c/tandem-cc
```

最终原始日志没有 LATCH、MULTIDRIVEN、SELRANGE 或 IMPLICIT 告警。默认完整模型有 381 条告警（PINMISSING 52、WIDTHTRUNC 76、WIDTHEXPAND 127、ASCRANGE 112、ALWCOMBORDER 3、UNSIGNED 2、SYMRSVDWORD 1、UNOPTFLAT 8）；压力默认模型 414 条，tandem 模型 357 条。分类原件为 `warning-summary.json`；剩余告警未 suppress，仍不构成无组合环或功能正确的证明。

这是解析和 C++ 模型生成，未编译/执行 C++ 仿真器；功能用例数、周期数、退休数均为 N/A，不能把 22 个编译检查计为 22 个功能用例。`-Wno-fatal` 沿用门禁的 0 errors 标准，保留告警，没有新增 suppression pragma。

## 失败与修复记录

全部远端候选均有独立 `/home/cloud_chen/work/20261007-t09-<sha7>` 与 `/home/cloud_chen/evidence/t09/<sha7>`。失败属于 RTL/静态检查，不触发换主机。

| 候选 SHA | 现象与根因 | 修复与随后结果 |
| --- | --- | --- |
| `05f6d1c2518f6024bf977799e282e8b1abb6f44a` | lint 失败；struct 字段使用 SV 保留字 `task`，导致解析级联错误 | `o3_types_pkg.sv` 及 L2 引用改为 `task_kind`；下一候选越过此错误 |
| `6220d30ecc5b8499204ea52a84c685af8e5445d9` | lint 失败；SQ 仍引用已删除的 DTCM 配置字段 | 清理 `store_queue.sv` 的 DTCM 特例；下一候选 lint 0 errors |
| `7d166385386446b61e3d92bf612f392453ee9fc8` | lint/default --cc exit 0，但原始告警暴露新组合块未完整默认赋值 | 补全默认赋值并拆分依赖；下一候选默认模型无 LATCH/MULTIDRIVEN/SELRANGE 告警 |
| `16b309cbfe6eff3dff9976864a3da94b9b4dc6b1` | lint/default --cc exit 0；继续检查流水保留、翻译与等待唤醒路径 | 修复流水/等待细节，候选 `c41f4a0` 完整 22 项 exit 0 |
| `c41f4a04bc01ed6e2d2c6ce7976398004b8968e3` | 22 项 exit 0；提交前发现相邻 needs_D store 的身份覆盖窗口，以及结构阻塞误记 MSHR_FULL 后可能没有唤醒 | LSU 在 S1 提前保留 D store 身份；DCache 区分立即结构重放与 WB/MSHR 资源等待，并保护 probe tag snapshot；候选 `d18188f` 重跑 |
| `d18188f252122d76cc2efbd502f513db9847f44d` | 22 项 exit 0；检查原始告警发现基线 SFENCE 完成信号隐式声明及 ICache MSHR 分配/性能记账同块导致组合环告警 | backend 显式声明 `t_sfence_done`；ICache MSHR 的性能计算独立组合块；最终 SHA 重新执行全部 22 项 |

第 1 步交付时，这些修复只有静态证据，尚没有 M1～M6 的功能回归证据。

候选 `695ae65a323d60eab9973db4ccdf7304fde98ae2` 在上述最后两项修正后也通过全部 22 项（日志目录 `695ae65/`）；暂存差异检查随后清理 `backend.sv` 一行尾随空白，候选 `3e18252109d80d23e5fe7e412021283aa0542550` 完整 22 项 exit 0。原始告警复查显示 ICache 上层仍把事件汇总与分配放在同块，造成 `alloc_valid → mshr_perf → alloc_valid` 的块依赖；再拆分 `icache.sv` 的事件汇总块，最终 RTL SHA 完整重跑，保持证据与接受提交一致。

## 自行决定

| 问题 | 决定、依据 | 文件 |
| --- | --- | --- |
| 事务与等待者身份编码 | 协议行地址采用 26 位、整行数据 512 位、L1 ID 2 位；LQ generation 8 位；MSHR 只保存行元数据，uop/VA 留在 LQ/SQ。依据 spec 3、5、6 节 | `o3_types_pkg.sv`、`o3_pkg.sv`、MSHR/LQ/SQ |
| L2 同拍工作组织 | 内部任务采用 `task_kind` enum/struct；慢槽保留任务与组所有权；Put、慢任务、客户端请求依规范优先级推进，响应缓冲按客户端信用上限组织。依据 spec 4 节 | 四个 `l2_*.sv` |
| 两路结果与资源预留 | 每路结果 FIFO 保守计入全部在途访存，避免 unstalled S2 到达时溢出；INT/FP 各按年龄选择 FIFO 头。依据 spec 7 节 | LSU、backend、写回仲裁 |
| DTLB 双查询实现 | 从现有 Sv39 查询/填充机制构造双查询共享数组，保留单 PTW miss 仲裁，复用 epoch/fault/sfence 规则。依据 spec 7.2 节 | `dtlb.sv` |
| ICache 请求等待 | 四个行 MSHR 之外使用请求等待槽保存需求身份，回填错误唤醒需求而不安装；重定向杀需求，已接受行事务仍完成。依据 spec 8 节 | `icache.sv`、`icache_mshr.sv` |
| 旧端口与编译清单 | core 的旧 DMA 外部端口保留形状但 inactive；旧 ICache 兼容输出保持接口适配；未使用 DTCM SRAM 源文件不在 `rtl.f` 中编译，不越界修改它。依据 L8a/L8b 边界与文件 allowlist | `o3_core.sv`、`icache.sv`、`rtl.f` |
| 参数展开方式 | 编译专用 wrapper 从 O3_CFG 构造参数配置，覆盖全部 1～4 MSHR 及压力几何；所有生产逻辑仍由 CFG 控制。依据 spec 2、12.1 节 | `sim/cocotb/memsys/l8a_elab_top.sv` |
| 被动观察点迁移 | tandem 监视器改接新流水/队列与 L2 性能源；事件观察入口从五个扩为六个，原断言保留。依据 spec 11 节 | `o3_tandem_top.sv`、`l10_event_checks.sv` |

## 第 1 步交付时的后续阶段、已知问题与证据边界

- M1/M2/M3/M4/M5/M6 均未开始，没有相应 `test(memsys)` 通过提交，也没有第 12.8 节同 SHA 功能总门禁。
- 没有 M5→M6 周期对比或运行所得的 MSHR 平均占用、RFO 有用次数、bank 冲突统计；RTL 事件入口已加入，但其功能与统计准确性仍需分层测试。
- `run-l10-vm` 本次未运行，未声称 T08 的已知首个失败点变化或消失。整核回归、既有模块功能套件与 C++ 主程序编译均未运行。
- DMA、AMO、MMIO、litmus、Spike、ACT4、formal、综合、PPA、FPGA/运行时均未验证。没有执行这些被本任务排除的验证，也没有据展开结果声称协议或架构正确性。
- 静态告警尚存；最终分类与计数见门禁记录。不能据 0 errors 声称 0 warnings、无组合环或时序收敛。
- 未更新 LOOP 为 L8 已验收，未推送到 origin；本次停在用户请求的 RTL 阶段，下一步应从 M1 开始，按任务书顺序推进。
- 原有未跟踪 `AGENTS.md`、BPU 结果 XML 与 `sim/o3/__pycache__/` 保留，不纳入提交。

## 第 2 步分层执行（2026-10-07 续）

续作基线 `c7f712c6d268cb24e781ea0d13fda4b67c69342e`，分支 `feat/L1-closure`。
用户本轮要求覆盖任务书的推送措辞：全部提交只留本地，不推 origin。

### M1：已通过

提交 `9457476bc0c63c7878730e65098e6e778a41bf69`，`test(memsys): L8a test layer M1 pass`。
无 RTL 修复。按用户明确授权删除 `sim/cocotb/l2_cache/` 的七个跟踪文件，
由 `sim/cocotb/l2_home/` 的新协议测试接替；其残留 XML/pycache 移到本地
`/tmp/t09-retired-l2-cache-artifacts/`，未纳入提交，其他旧套件保留。

每次执行前重新读取共享配置，首选 cloud_chen 的 SSH/环境/工具/资源均可用，
无需 Alan。实际主机 `cloud_chen@47.111.104.2:22`，hostname
`iZbp16rhtg91v96m32vggjZ`，Verilator 5.050、cocotb 2.1.0、Python 3.12.12；
预检可用磁盘 122～126 GiB、available 内存 23～27 GiB。无外网下载。
准确提交对象通过专用 SSH transfer bare 仓库同步，不推 origin、不使用 bundle。

M1 同 SHA cwd：`/home/cloud_chen/work/20261007-t09-9457476b`；证据根：
`/home/cloud_chen/evidence/t09/9457476b/`。每项包含完整命令/实际主机/SHA/cwd/
预检的 `manifest.json`、`run.log`、`exit`、`results.xml` 与生成模型 `build/`。

| 项目 | 命令（cwd 为上述根目录） | exit | 用例数 | 证据子目录 |
| --- | --- | --- | --- | --- |
| 压力几何（2组/2路/2槽） | `make -C sim/cocotb/l2_home` | 0 | 12/12 | `m1-final-pressure` |
| 慢槽满/恢复辅助几何 | `make -C sim/cocotb/l2_home SETS=4 WAYS=2 SLOTS=2 COCOTB_TESTCASE=slot_full_backpressure_and_resume` | 0 | 1/1 | `m1-final-slot-full` |
| 默认 L2 几何（额外验证） | `make -C sim/cocotb/l2_home SETS=512 WAYS=8 SLOTS=8` | 0 | 10/10 | `m1-final-default` |

表中各命令还带有指向对应证据子目录的 `SIM_BUILD=<root>/<item>/build` 和
`COCOTB_RESULTS_FILE=<root>/<item>/results.xml`，准确全文见 manifest。
13 个不同功能用例，默认几何重复 10 个；没有 skip。非整核测试，退休数 N/A。
种子 51/52 各完成 2000 笔已握手 D Get/Put + 500 笔并发 I Read，再逐行读取全部
已写行并精确比对。种子 51：67402 拍，AXI 2165 次读/1060 次写；种子 52：
66680 拍，AXI 2154 次读/1028 次写。最终逐行验证另增每种子 16 笔 I Read。

M1 自行决定：
- 独立 architectural golden 和 AXI backing RAM；D 代理只在 E/M 本地写，
  随 Put/probe 撤销或降级权限。I Read 并发写时检查返回值曾存在于请求区间，
  流量结束后的逐行回读使用精确黄金值。参考 Breeze a304cc2 机制。
- monitor 以四链路握手重建单 D 客户端权限，每拍检查目录结构/重复 tag，
  静止时检查目录与持有副本精确一致；I 不计入目录。wrapper 观察点只读。
- 用 4组/2路/2槽辅助配置测试 slot-full，因为 2组/2槽压力配置的每槽组保护
  使第三个不同组请求不可出现；保持压力随机几何与默认生产配置不变。
- 2000 笔按已握手 D Get/Put 计数，另加 500 I Read，不把本地命中空操作算作事务。

M1 开发失败/处理：首次 Makefile 缺少 ISA 包（候选 `7e8b77e8`，exit 2），
补齐依赖；cocotb Makefile 不给复杂 TEST_FILTER shell 引号（`c9526bf9`，exit 2），
使用明确的 COCOTB_TESTCASE 列表。两者均为测试基础设施问题，不改变 RTL/golden。
本地临时 index 并发冲突在同步/编译前发生，改为每调用独立 index。
旧套件删除后忽略规则消失，候选 `071f00ef` 的范围核对发现残留生成物进入候选树；
该候选没有接受到本地分支，清理候选范围后在 `9457476b` 完整重跑上述三项。
环境自动审批拒绝 `rm -rf` 残留产物（要求更安全方式），使用移动保留产物完成移除。

### M2：X11 批准后继续

失败用例快照提交 `e4b4882746c9ab257571288bc2f31e0fe54800a9`，
`test(dcache): record blocked L8a M2 writeback capacity regression`。
该提交保留测试与复现，不声明 M2 通过；没有保留生产 RTL 改动。
现有 DCache 的三个用例全部迁移到新接口并保留；新增 23 项 L8a 用例。
先以 1 MSHR 开发基础覆盖，再以 4 MSHR 增加并发、资源与 RFO 覆盖。
此前遇到下面的冻结行为冲突而停止。用户随后批准 X11（eb1432c）：WB 满判 WB_LINE、等 wb_free；MSHR_FULL 仍只等待 mshr_free。以下失败表与诊断记录按历史原样保留。

所有运行仍在 `cloud_chen@47.111.104.2:22`，hostname、工具版本同 M1；
每次重新读取主机配置并预检成功，available 磁盘 116～120 GiB、内存 23～27 GiB。
没有因为测试失败更换主机。以下每项 cwd 为
`/home/cloud_chen/work/20261007-t09-<sha8>`，日志为
`/home/cloud_chen/evidence/t09/<sha8>/<item>/`；完整 SHA 和完整命令、预检保存在 manifest。
表中 make 命令都另带该目录的 `SIM_BUILD=.../build` 与
`COCOTB_RESULTS_FILE=.../results.xml`。全部模块测试的整核退休数为 N/A。

| 源码 SHA | 命令 | exit | 通过/总数 | item |
| --- | --- | --- | --- | --- |
| `c332035294a73717d1fbc237f959c1e32f7d14fe` | `make -C sim/cocotb/dcache MSHRS=1` | 0 | 16/16（开发子集） | `m2-one-mshr` |
| `0393833fde31327c3b44bb7058e4cfdce4e21d31` | `make -C sim/cocotb/dcache MSHRS=4` | 0 | 25/25（新增阻塞用例前） | `m2-four-mshr` |
| `49331087fa838947ade1b2ba5ca702e9a9817e11` | `make -C sim/cocotb/dcache MSHRS=4 COCOTB_TESTCASE=wb_capacity_full_wait_contract` | 2 | 0/1 | `m2-wb-capacity-baseline` |
| `a3ee7fd789856f170549029e95ea3c87e104348e` | 同上，诊断性原因修正 | 2 | 0/1 | `m2-wb-capacity-reason-fix` |
| `e4b4882746c9ab257571288bc2f31e0fe54800a9` | `make -C sim/cocotb/dcache MSHRS=4` | 2 | 25/26，0 skip | `m2-stop-snapshot-full` |

#### X11 批准前的首个失败点与诊断（历史证据）

用例 `wb_capacity_full_wait_contract`：填满 8 路同组行；延迟两个 victim Put 的
PutAck，再依次完成两次替换 miss。INSTALL 后 MSHR 已全部释放，两个 WB 仍有效。
第三次同组替换请求在 S2 返回 REPLAY。隔离复现于 2921 ns，agent 记录 cycle=289
（采样前 S2 拍 288）：`status=2 reason=6 MSHR_busy=0 WB_busy=3`。
`reason=6` 是 `WB_LINE`；spec 5.4 明确规定 victim WB 满容量应返回 `MSHR_FULL`（5），
因此首个断言失败。停点完整套件同样只有该用例失败，重复上述 witness。

复现命令（先按共享配置重新预检并选择主机）：

```bash
source /home/cloud_chen/setup/activate-o3.sh
cd /home/cloud_chen/work/20261007-t09-e4b48827
make -C sim/cocotb/dcache MSHRS=4 COCOTB_TESTCASE=wb_capacity_full_wait_contract \
  SIM_BUILD=/home/cloud_chen/evidence/t09/e4b48827/m2-repro/build \
  COCOTB_RESULTS_FILE=/home/cloud_chen/evidence/t09/e4b48827/m2-repro/results.xml
```

已经实际运行的隔离命令及原始日志见 `49331087/m2-wb-capacity-baseline/manifest.json`
与 `run.log`；上面给出接受源码的等价复现命令，未把该额外目录声称为已运行证据。

诊断尝试只改 `rtl/lsu/dcache.sv:285`，使满 WB 返回 `LDW_MSHR_FULL`；
候选 `a3ee7fd7` 首个断言通过。但放行 PutAck 后，cycle 289/290 各出现一次
`wb_free=1, mshr_free=0`，随后观察 40 拍仍没有 mshr_free；3341 ns、cycle 331
失败于“spec 6.1 waiter never wakes”。两次 PutAck 已释放全部 WB，MSHR 始终全空。
原因修正本身不能满足等待契约。

根因：spec 5.5 允许 INSTALL 后立即释放 MSHR，而 WB 保留至 PutAck；
spec 5.4 将满 WB 归为 MSHR_FULL，spec 6.1 却只允许 mshr_free 唤醒。
实际 `rtl/backend/load_queue.sv:61,87` 与 DCache 内部等待路径
`rtl/lsu/dcache.sv:405,470` 也只以 mshr_free 唤醒 MSHR_FULL。
诊断修正已还原，当前 `dcache.sv` 与 M1 提交完全一致；未修改 spec 或 doc/design，
未修改断言/黄金值去接受 WB_LINE，也未制造假的 mshr_free 脉冲。

该结果是 DCache + 行为 L2 的等待契约反例（有限延迟 PutAck），
不是实际 L1D+L2 或整核死锁证明；尚未进入 M3/M5。需要用户确认冻结契约如何修订后继续。
建议保留 5.4 的 MSHR_FULL 分类，把 6.1 的资源唤醒扩为 `mshr_free || wb_free`，
并一致更新 LQ/内部等待者；另一可选方案是将 5.4 的 WB 满容量分类改为 WB_LINE。
两种均改变冻结行为，均未自行实施。

#### 诊断 RTL 修改后的下层回归与停点复测

诊断候选 `a3ee7fd789856f170549029e95ea3c87e104348e` 上完整重跑全部 M1；
还原诊断修改后的接受源码 `e4b4882746c9ab257571288bc2f31e0fe54800a9` 再次完整重跑。
命令与 M1 表的三项相同，实际主机同上；各项 manifest 留存完整命令/预检。

| SHA8 | item | exit | 通过/总数 |
| --- | --- | --- | --- |
| `a3ee7fd7` | `m1-after-m2-reason-fix-pressure` | 0 | 12/12 |
| `a3ee7fd7` | `m1-after-m2-reason-fix-slot-full` | 0 | 1/1 |
| `a3ee7fd7` | `m1-after-m2-reason-fix-default` | 0 | 10/10 |
| `e4b48827` | `m1-stop-snapshot-pressure` | 0 | 12/12 |
| `e4b48827` | `m1-stop-snapshot-slot-full` | 0 | 1/1 |
| `e4b48827` | `m1-stop-snapshot-default` | 0 | 10/10 |

M2 自行决定：
- wrapper 将生产 struct 接口平铺为 cocotb 可驱动总线，配置参数来自 O3_CFG，
  内部观察点只读；涉及 `dcache_tb_top.sv`、`Makefile`。
- 以独立 L2 代理、per-ID 授权、PutAck 与探测建模，并用独立 golden 比较；
  CPU 按真实 IS→S0→S1→S2 时序刺激，MISS 按 install 事件重放；涉及 `l8a_agents.py`。
- 原容量用例保留原访问行并增加行数以越过新 8 路容量；其他原值及 24 次空行 probe
  保留。新增满 WB 用例分别检查冻结 reason 与冻结 wake，不拿普通回放成功掩盖事件缺失；
  涉及 `test_dcache.py`、`test_l8a_dcache.py`。没有删除其他已有 cocotb 套件。
- 在停止条件下将失败回归单独提交以便审核，提交标题明确 blocked，未提交 M2 pass。

### X11 批准前的停止点与证据边界（历史）

停在 M2，触发任务书/用户规定的“需要改变冻结 spec 行为则停止”条件。
M1 通过；M2 未完成，M3～M6 未开始，无上层提交。没有 M5→M6 周期/退休对比、
run-l8a-mem 的 MSHR 平均占用/RFO 发出与有用次数/bank 冲突统计。
`run-l10-vm` 未运行，T08 首个失败点是否变化未知。

12.8 总门禁、既有非访存 cocotb 总回归及最终 lint 未执行；第 1 步 22 项静态门禁
不能替代该总门禁。文档提交仅补报告，未改变停点接受 SHA 的测试/RTL。
LOOP 的 L8/模块验收行未更新。DMA/AMO/MMIO、Spike/ACT4/litmus、formal、综合、
PPA、FPGA/运行时仍没有本次验证证据；没有运行被排除的目标。
全部接受提交只留本地，没有推送 origin，没有开始 L8b。
原有未跟踪 AGENTS.md、BPU XML、sim/o3/__pycache__ 保留并排除在提交外。


## X11 批准后的续作

用户批准的 X11 位于 `doc/spec/l8a-nonblocking-mem-spec.md` 第 5.4、6.1、14 节，
提交 `eb1432c07ff1dc0adcea21ea21779db6eb65a414`。指定
`wb_capacity_full_wait_contract` 改为断言 `WB_LINE`，放行 PutAck 后断言
`wb_free` 到达、没有伪造 `mshr_free`，随后重发并逐值比较完成替换。
这是跟随修订后的 spec 改期望，原失败/诊断证据未删除。其余已有用例与断言未改，
生产 RTL 未改。新增单 MSHR 真满/释放与 probe 等待 PS 写完用例补齐覆盖。

### M2 与 spec 第 12 节逐项核对

下表引用 `sim/cocotb/dcache/` 的用例函数；1/4 表示两种配置均执行，4 表示
用例前置条件明确要求四 MSHR，只在四项配置执行且没有修改其断言。
MSHR=1 的 reserve 按 spec 2/5.5 视为 0，单项补例检查普通 load 可分配唯一项。

| spec M2 行要求 | 定向用例 | MSHRS |
| --- | --- | --- |
| 两管道不同 bank 同拍命中 | dual_different_bank_hit | 1/4 |
| 同 bank 不同组 BANK | same_bank_different_set_replay | 1/4 |
| Miss(k) → install{k} | miss_install_and_replay | 1/4 |
| 同行合并、一笔 GetS | same_line_merge_one_get | 1/4 |
| 四条不同行在途 | four_lines_in_flight_and_full_wakeup | 4 |
| 真满 MSHR_FULL → mshr_free | four_lines_in_flight_and_full_wakeup / single_mshr_full_waits_on_mshr_free | 4 / 1 |
| 普通不能用预留末项、队头可以 | reserved_last_mshr_head_only | 4 |
| drain E → PS → M | drain_hit_e_ps_to_m | 1/4 |
| drain S → GetM → AckE | drain_shared_upgrade_acke | 1/4 |
| drain 未命中 GetM | drain_miss_getm | 1/4 |
| 脏 victim 带数据 Put | dirty_capacity_victim_is_written_back_before_refill（原用例） | 1/4 |
| 干净 victim 不带数据 Put | clean_victim_put_without_data | 1/4 |
| WB 同行重放、wb_free | wb_line_replay_until_ack | 1/4 |
| X11 WB 容量满重放、PutAck 唤醒后替换 | wb_capacity_full_wait_contract | 1/4 |
| Inv / Down 打在 M 行 | inv_m_dirty_response / down_m_dirty_response | 1/4 |
| probe 压住 WAIT/INSTALL、PS | probe_waits_for_grant_install / probe_waits_for_ps_write | 1/4 |
| SNAP | refill_snapshot_replay | 1/4 |
| S0 store 冲突 | s0_store_word_conflict | 1/4 |
| PTW 读命中/未命中 | ptw_read_miss_and_hit | 1/4 |
| PTE A/D 成功/mismatch | pte_ad_compare_success_and_mismatch | 1/4 |
| RFO 发出/预留拦截/同行放弃 | rfo_issue_reserve_drop_and_same_line_drop | 4 |
| refill err、行保持 I | refill_error_install_err_keeps_i | 1/4 |
| PA 高位异常、原 VA | pa_high_bits_access_fault | 1/4 |
| 取消不改 PLRU/MSHR | cancellation_keeps_plru_and_mshr | 1/4 |

另保留 empty_line_recall_pipeline 的 24 次规模与
word_banks_refill_store_probe_and_hit_under_miss 的原 byte golden、非对齐 store 值。
新增 wrapper 观察点只读，不驱动 DUT 状态；Makefile 仅按配置选择适用用例。


### M2 完整通过与提交

M2 提交 `7feffd313f6de5cf98744836b3f047252698ada7`，
`test(memsys): L8a test layer M2 pass`，生产 RTL 未改。
该准确 SHA 完整执行 M2 后重跑全部 M1；模块退休数 N/A。

本轮每项执行前重新读取共享主机配置。首选 cloud_chen SSH 在 8 秒连接超时后
返回 255（`connect to host 47.111.104.2 port 22: Connection timed out`），
退回 Alan，hostname `chen-System-Product-Name`；Verilator 5.050（conda-forge）、
cocotb 2.1.0；免密 SSH、`cislc-o3` 环境成功；可用磁盘 14～15 GiB、available
内存约 55 GiB。实际 host `chen@localhost:2286 via clawbot`。
SHA cwd `/home/chen/FUN/20261007-t09-7feffd31`，证据根
`/home/chen/FUN/cislc-o3-t09-evidence/t09/7feffd31/`，各 item 包含
manifest（主机/SSH 失败和成功预检/版本/SHA/cwd/完整命令）、exit、run.log、results.xml。
没有外网下载；Git 对象仅通过独立临时 transfer bare repo 传给执行主机，未推 origin。

| item | make 命令（另加该 item 的 SIM_BUILD / COCOTB_RESULTS_FILE） | exit | 通过/总数 |
| --- | --- | --- | --- |
| m2-x11-final-one | `make -C sim/cocotb/dcache MSHRS=1` | 0 | 25/25，0 skip |
| m2-x11-final-four | `make -C sim/cocotb/dcache MSHRS=4` | 0 | 27/27，0 skip |
| m1-x11-pressure | `make -C sim/cocotb/l2_home` | 0 | 12/12 |
| m1-x11-slot-full | `make -C sim/cocotb/l2_home SETS=4 WAYS=2 SLOTS=2 COCOTB_TESTCASE=slot_full_backpressure_and_resume` | 0 | 1/1 |
| m1-x11-default | `make -C sim/cocotb/l2_home SETS=512 WAYS=8 SLOTS=8` | 0 | 10/10 |

X11 两种配置 witness 均为 cycle 289、`status=REPLAY reason=WB_LINE MSHR_busy=0 WB_busy=3`；
PutAck 在 289/290 各产生 `wb_free=1,mshr_free=0`，重发完成并匹配 golden。
M1 压力随机保留种子 51/52，每种子 2000 已握手 D Get/Put + 500 I Read。

基础设施记录：第一次 cloud 超时后旧传输 helper 遗漏 Alan 的 `-J clawbot`，
Git 连接 localhost:2286 refused；发生于仿真前。补齐跳板并初始化独立 bare repo 后恢复。
开发候选 `a8d2c218` 的单 MSHR 24/24 通过；随后补齐 PS hold 覆盖并在接受 SHA 重跑。
