# CISLC-O3

`CISLC-O3` 是一个用 SystemVerilog 编写的 RV64G OoO core 实验仓库。当前重点不是整机 SoC 集成，而是把 `frontend + backend + o3_core` 这条最小真实主链路逐步接通，并用 Verilator 回归把每一段行为固定下来。

## 当前做到哪里

当前仓库已经有一条可运行的 core 级最小路径：

- Frontend: `BPU -> FTQ -> IFU -> ICache -> fetch_buffer -> frontend output`
- Backend: `fetch/decode -> decode queue -> rename -> ROB alloc -> issue -> regread -> execute -> writeback -> retire`
- Core: [`rtl/core/o3_core.sv`](/home/chen/FUN/CISLC-O3/rtl/core/o3_core.sv) 已经把真实 frontend 输出接到真实 backend 输入，并透出 ICache refill request/response 给仿真内存模型驱动

当前主线已经覆盖：

- 顺序取指与最小前端 cache refill 流程
- RV64I 整数 R/I 算术主链路
- 物理寄存器重命名、ROB、整数 issue queue
- 3 条整数 ALU 管线
- branch retire 元信息导出
- 第一版 branch mispredict redirect/flush/recovery 主路径

当前还不是完整处理器，仍有明显边界：

- `rtl/O3.sv` 和 `rtl/Tile.sv` 还是占位顶层
- 还没有完整的 store/LSU/异常/CSR/通用恢复框架
- 前端暂时没有 L2 和更下层的真实内存层级；当前只有 ICache，并由仿真 testbench 直接驱动 refill request/response
- redirect 主路径已经接通，但 backend recovery 还有两个已知缺陷正在收尾

## 新手怎么上手

如果你第一次改这个库，建议按下面的顺序进入，避免一上来就埋进某个 RTL 文件里。

1. 先读这个 `README`

先建立三个基本事实：

- 当前主入口是 `o3_core`
- 当前验证方式主要依赖 `sim/*` 下的 Verilator 回归
- 当前项目重点是把最小主链路和恢复路径一点点钉死，不是一次性做完整 SoC

2. 再读实现状态文档

- [`doc/CISLC_O3.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3.md)
- [`doc/CISLC_O3_frontend.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3_frontend.md)

这两份文档比代码更适合先建立全局图：现在做到了什么、哪些是最小实现、哪些是明确还没做。

3. 从 core 顶层往两边展开

建议从 [`rtl/core/o3_core.sv`](/home/chen/FUN/CISLC-O3/rtl/core/o3_core.sv) 开始，再分别进入：

- `rtl/frontend/frontend.sv`
- `rtl/backend/backend.sv`

这样你会先看清接口边界，再深入局部模块，不容易把 standalone 逻辑和真实集成路径混在一起。

4. 先跑最小回归，再改代码

推荐最先跑这两个：

```bash
cd sim/frontend
make test TEST=frontend_basic

cd ../core_single_inst
make test
```

如果你改的是 branch/redirect/recovery，再继续跑：

```bash
cd sim/core_three_alu
make test TEST=three_alu_branch
make test TEST=three_alu_redirect
make test TEST=three_alu_checkpoint_snapshot
make test TEST=three_alu_p0_release
```

5. 改动时的经验规则

- 改 frontend：先确认 `frontend_basic` 还通，再看 redirect 相关测试
- 改 backend rename/recovery：优先看 `three_alu_redirect`、`three_alu_checkpoint_snapshot`、`three_alu_p0_release`
- 改公共类型或 core 接口：至少补跑 frontend smoke 和 core smoke

## 前端架构

当前前端采用“取指组织”和“分支预测来源”分离的结构，主链路是：

`BPU -> FTQ -> IFU -> ICache -> fetch_buffer -> frontend output`

几个关键点：

- 当前前端只有 ICache，没有 L2，也没有更下层的真实 memory hierarchy
- ICache 当前是 `4-way set-associative`，`64B line`，前端每次按 `16B fetch window` 取回一组指令
- ICache 下层不是完整内存系统，而是由仿真 testbench 根据 `refill_req_*` 直接返回 cache line
- BPU 当前是第一版 sequential-only 设计，不做真实 BTB/BHT/RAS 预测
- 默认控制流模型是“顺序前进 / 默认 not-taken”；真正遇到 backend 解析出的 taken branch，再通过 redirect 把前端拉回正确目标

FTQ 在这里承担的是“取指窗口组织器”角色，而不是预测器本体：

- BPU 负责给出下一段 fetch block 的起点
- FTQ 负责保存这些 block，向 IFU 提供待取指窗口
- IFU/ICache/fetch_buffer 负责把窗口真正变成 `fetch_entry_t` 指令流

也就是说，当前设计里“预测从哪里开始取”和“真正把哪些 block 保存在前端窗口里”是分开的。这一点对后续做 redirect repair、younger invalidate、rewind 很重要。

当前前端已经接通的 redirect 行为包括：

- backend 通过 `branch_redirect_t` 经 `o3_core` 把 redirect 送回 frontend
- BPU 收到 redirect 后用 `redirect_pc` 重新种子化后续顺序取指
- FTQ 修复 branch 所在 block，并清掉 younger wrong-path entries
- IFU / fetch_buffer 清除暂存中的 wrong-path 瞬态状态
- ICache redirect 时只清控制态，不主动清 tag/data array 内容

## 后端流水线

当前 backend 的最小整数主流水线是：

`fetch/decode -> decoded uop queue -> rename/ROB alloc -> issue queue wakeup/select -> issue reg -> regread -> execute -> execute result reg -> writeback/ROB complete -> retire/free-list release`

按职责拆开看：

1. `Fetch/Decode`

接收 frontend 发来的 `fetch_entry_t` 组，提取 RV64I 整数 R/I 算术和 branch 所需的基本字段。

2. `Decoded Uop Queue`

在 decode 和 rename 之间做一层成组缓冲，隔离前后级背压。

3. `Rename / ROB Alloc`

这里的模型是“完全物理寄存器重命名”，不是“执行时再回读架构寄存器”那种结构：

- 架构寄存器只是逻辑名字
- 真正进入流水线流动的是 physical register 编号
- `rename_map_table` 维护 `xN -> pM` 的当前映射
- `free_list` 为需要写回的目的寄存器分配新的 physical register
- `old_dst_preg` 被保存到 ROB，供后续 retire 时释放

也就是说，rename 之后 backend 主流水线里依赖关系靠 `preg` 传递，不再直接依赖架构寄存器值。

4. `Issue Queue / Wakeup / Select`

rename 完成后的整数 uop 进入压缩式 issue queue。队列根据 `preg_ready` 判断源操作数是否 ready，并把最老的 ready uop 发给编号更小的 ALU。

当前没有做同拍写回广播直通，写回结果在下一拍才会对 wakeup 可见。

5. `Issue Reg / Regread / Execute`

- issue reg 保存已选中的 uop
- regread 阶段根据 physical register 编号真正去读 `physical_regfile`
- execute 阶段当前主要覆盖整数 ALU，branch 走独立的 `branch_execute_unit`

6. `Writeback / ROB Complete / Retire`

- 执行结果先进入 result reg
- 然后写回物理寄存器文件，同时按 `rob_idx` 标记 ROB complete
- ROB 从队头按序 retire，当前最多支持每拍 retire 3 条
- retire 时再把旧的 physical register 还给 free list

当前 backend 的分支恢复也是围绕这套物理寄存器模型展开的：

- branch rename 时分配 checkpoint
- checkpoint 保存 rename map 和 free list 状态
- branch resolve 且发现 `pred not-taken / actual taken` 时，同拍做 younger squash 和 checkpoint restore

这也是为什么最近的两个缺陷都集中在：

- checkpoint 抓取时机是否反映了 rename 后的真实物理寄存器映射
- `p0` 是否被错误释放回 free list

## 测试现状

下面这一节只区分两类东西：

- 已跑通的固定回归
- 最近新增、正在用于定位缺陷的定向测试

### 已跑通的固定回归

1. `sim/frontend/tests/frontend_basic.cpp`

前端 smoke/regression，验证 `BPU -> FTQ -> IFU -> ICache -> fetch_buffer` 这条最小链路能持续工作，检查 frontend 输出的 `pc/instruction` 顺序以及 refill 基本行为。

```bash
cd sim/frontend
make clean-test TEST=frontend_basic
make test TEST=frontend_basic
```

2. `sim/core_single_inst/tests/single_addi.cpp`

core 级单指令 smoke test。测试内存只提供 `0x0: addi x1, x0, 1`，其余地址返回 `0xffffffff`。这个测试证明真实 `frontend + backend + o3_core` 可以把一条指令从取指一路跑到 retire，并检查 `retire_info_o` 中 `x1=1`。

```bash
cd sim/core_single_inst
make test
```

3. `sim/core_three_alu/tests/three_alu_branch.cpp`

core 级 branch 元信息回归。程序是 `addi/addi/add/bne` 的最小组合，重点检查 branch 指令 retire 时的 `taken / mispredict / target / fallthrough` 元信息是否正确。

```bash
cd sim/core_three_alu
make test TEST=three_alu_branch
```

### 最近在跑的定向测试

1. `sim/core_three_alu/tests/three_alu_redirect.cpp`

这是当前 redirect 主路径的核心定向回归。它验证：

- 分支在 backend 解析为 taken 后，frontend 能从 `redirect_pc=0x1c` 重新取指
- wrong-path `0x10/0x14/0x18` 不会 retire
- branch retire 的 redirect 元信息正确

当前它已经证明 redirect transport、FTQ repair、BPU reseed、IFU/fetch-buffer flush 这条链路是通的；但它也稳定暴露一个 backend recovery 缺陷：最后一条 redirect-target 指令 `add x8, x7, x1` 的 `rd_wdata` 仍然不对。

```bash
cd sim/core_three_alu
make test TEST=three_alu_redirect
```

2. `sim/core_three_alu/tests/three_alu_checkpoint_snapshot.cpp`

这个测试是最近补上的定向复现，用来单独钉住 checkpoint snapshot 时机问题。它把 branch 放在 rename group 的 lane 3，验证 recovery 后是否保留同组更老 lane 对 rename map 的同拍更新。

```bash
cd sim/core_three_alu
make test TEST=three_alu_checkpoint_snapshot
```

3. `sim/core_three_alu/tests/three_alu_p0_release.cpp`

这个测试也是最近补上的定向复现，用来单独钉住 branch retire 把 `p0` 误释放回 free list 的问题，检查 redirect 之后的新目的寄存器分配不会污染到 `p0`。

```bash
cd sim/core_three_alu
make test TEST=three_alu_p0_release
```

## 当前已知问题

当前 branch mispredict recovery 还剩两个明确问题，最近的定向测试就是围绕它们在跑：

1. checkpoint snapshot 抓的是 branch rename 当拍“周期开始前”的 rename map / free list 状态，没有包含同一个 rename group 内更老 lane 的同拍更新
2. branch retire 会把 `p0` 写回 free list，后续可能把 `p0` 错分配成真实目的寄存器

更完整的分析记录在：

- [`doc/CISLC_O3.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3.md)
- [`doc/CISLC_O3_frontend.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3_frontend.md)
- [`docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md`](/home/chen/FUN/CISLC-O3/docs/superpowers/plans/2026-05-09-branch-mispredict-flush.md)

## 当前默认配置

当前固定默认值集中在 [`rtl/common/o3_pkg.sv`](/home/chen/FUN/CISLC-O3/rtl/common/o3_pkg.sv)。

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CORE_FETCH_WIDTH` | `4` | frontend 每拍向 backend 提供的 lane 数 |
| `BACKEND_MACHINE_WIDTH` | `4` | backend 每拍可并行接收/rename 的 uop 数 |
| `BACKEND_NUM_INT_ALUS` | `3` | 整数 ALU 管线数量 |
| `NUM_PHYS_REGS` | `64` | 物理整数寄存器数量 |
| `NUM_ARCH_REGS` | `32` | 架构整数寄存器数量 |
| `NUM_ROB_ENTRIES` | `64` | ROB 深度 |
| `DECODE_QUEUE_DEPTH` | `2` | decode queue 深度 |
| `INT_ISSUE_QUEUE_DEPTH` | `16` | 整数 issue queue 深度 |

## 仓库结构

- `rtl/frontend/`: 前端 RTL，包括 BPU、FTQ、IFU、ICache、fetch buffer、frontend top
- `rtl/backend/`: 后端 RTL，包括 decode、rename、free list、rename map、ROB、issue queue、ALU/branch execute 等
- `rtl/core/`: core 级集成，当前主入口是 `o3_core.sv`
- `rtl/common/`: 跨模块共享类型和常量定义
- `tb/`: SystemVerilog testharness 包装
- `sim/frontend/`: 前端 Verilator 仿真
- `sim/core_single_inst/`: core 单指令 smoke test
- `sim/core_three_alu/`: core 级多指令/branch/redirect 定向测试
- `doc/`: 当前实现状态和设计笔记

## 建议阅读顺序

如果你是第一次看这个仓库，建议按这个顺序进入：

1. 先读这个 `README`
2. 再看 [`doc/CISLC_O3.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3.md) 和 [`doc/CISLC_O3_frontend.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3_frontend.md)
3. 然后从 [`rtl/core/o3_core.sv`](/home/chen/FUN/CISLC-O3/rtl/core/o3_core.sv) 往 frontend/backend 两边展开
4. 最后根据你改动的模块跑对应的 `sim/*` 回归
