# O3-T09：L8a RTL 实施记录

日期：2026-10-07。本次交付对应用户的“实现 RTL”请求，范围为任务书第 1 步。M1～M6 留待后续逐层验证；本文不是 L8a 总验收声明。

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

这些修复有静态证据，尚没有 M1～M6 的功能回归证据。

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

## 后续阶段、已知问题与证据边界

- M1/M2/M3/M4/M5/M6 均未开始，没有相应 `test(memsys)` 通过提交，也没有第 12.8 节同 SHA 功能总门禁。
- 没有 M5→M6 周期对比或运行所得的 MSHR 平均占用、RFO 有用次数、bank 冲突统计；RTL 事件入口已加入，但其功能与统计准确性仍需分层测试。
- `run-l10-vm` 本次未运行，未声称 T08 的已知首个失败点变化或消失。整核回归、既有模块功能套件与 C++ 主程序编译均未运行。
- DMA、AMO、MMIO、litmus、Spike、ACT4、formal、综合、PPA、FPGA/运行时均未验证。没有执行这些被本任务排除的验证，也没有据展开结果声称协议或架构正确性。
- 静态告警尚存；最终分类与计数见门禁记录。不能据 0 errors 声称 0 warnings、无组合环或时序收敛。
- 未更新 LOOP 为 L8 已验收，未推送到 origin；本次停在用户请求的 RTL 阶段，下一步应从 M1 开始，按任务书顺序推进。
- 原有未跟踪 `AGENTS.md`、BPU 结果 XML 与 `sim/o3/__pycache__/` 保留，不纳入提交。
