# CISLC_O3 Frontend Notes

## 文档定位
- 本文件保留为“前端当前实现状态 + 代码索引 + 时序入口”文档。
- 面向后续 agent / 协作者的执行规则、注释规范、阶段边界，统一遵循 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md)。
- 与后端主文档 [`doc/CISLC_O3.md`](/home/chen/FUN/CISLC-O3/doc/CISLC_O3.md) 的分工：
  - `doc/CISLC_O3.md` 记录后端现状和后端主链路。
  - 本文件记录前端现状和前端后续开发入口。
- 使用顺序建议：
  1. 先读本文件，确认当前前端实现边界与受影响模块。
  2. 再读相关 frontend RTL 和顶层连接文件。
  3. 最后按 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md) 中的规则落修改。

## 当前实现状态
- `frontend` 目前只有一个最小顺序取指骨架，还没有接入真实前端主链路。
- 当前 `frontend` 通过本地 `o3_sram` 按 `pc_q` 顺序读取 32 位指令。
- 当前 `frontend` 对外只提供单条 `inst_addr_o/inst_o/inst_valid_o/inst_ready_i` 接口，不是和 backend 对接的 fetch group 接口。
- 当前 `frontend` 的 `inst_valid_o` 固定为 1，只要后级 `inst_ready_i=1`，PC 就前进一条。
- 当前 `frontend` 没有实现分支预测、redirect、flush、异常重启、icache、TLB、多条并行取指和成组输出。
- `rtl/O3.sv` 目前仍是早期占位顶层，尚未把 `frontend` 和 `backend` 真正连起来。
- `rtl/Tile.sv` 目前也仍是占位系统封装，状态输出与真实处理器前端无关。
- 仓库中虽然存在 `tb/frontend_testharness.sv` 和 `sim/frontend_testharness/`，但当前阶段按协作约束不扩展仿真，只把它们视为历史骨架或后续接入口。

## 当前前端数据流
- 当前数据流是：`pc_q -> o3_sram -> inst_o`。
- 当前地址流是：`pc_q -> inst_addr_o`。
- 当前握手语义是：`inst_valid_o` 固定有效，`inst_ready_i` 表示后级是否接受当前单条指令。
- 当前前进一步条件是：`inst_fire = inst_valid_o && inst_ready_i`。
- 当前 `inst_fire` 成交后只做顺序 `pc_q + 1`，没有 next-pc 选择器、预测重定向或异常恢复路径。

## 受影响模块
### frontend
- 职责：作为前端实现入口，后续承载顺序取指、预测、redirect 和对 backend 的 fetch 输出。
- 当前实现：本地 SRAM 顺序读指令 + 单条 ready/valid 握手 + 单一顺序 PC。
- 当前未做：BTB/BHT/RAS、分支重定向、取指队列、I-Cache、TLB、异常/flush 恢复、与 backend 的成组接口。

### O3
- 职责：O3 核心顶层连接入口。
- 当前实现：仍为占位模块，当前只连接 `flow_led`，没有挂接 frontend/backend。
- 当前未做：前后端集成、跨模块握手、系统级 flush/redirect 传播。

### Tile
- 职责：更上层系统封装入口。
- 当前实现：仍为占位封装，只基于 `flow_led` 计数结果导出一个简单状态。
- 当前未做：真实核心、存储系统和片上互联的系统封装。

## 代码索引
- `rtl/frontend/frontend.sv`
  - 当前 frontend 唯一有实际内容的 RTL 入口。
  - 后续顺序取指、next-pc 选择、预测状态和 fetch bundle 都会从这里扩展。
- `rtl/O3.sv`
  - O3 核心顶层入口；真正集成前后端时需要一起修改。
- `rtl/Tile.sv`
  - 更上层系统封装入口；前端外部可见状态最终也会经过这里对外暴露。
- `tb/frontend_testharness.sv`
  - 现有前端 testharness 骨架，当前阶段不扩展。
- `sim/frontend_testharness/`
  - 现有前端仿真目录，当前阶段不扩展。

## 关键时序行为
### frontend 周期级行为
周期 N 组合阶段：
- `pc_q` 保存当前顺序取指位置。
- `o3_sram` 以 `pc_q` 为地址输出当前 32 位指令 `inst_o`。
- `inst_addr_o` 由当前 `pc_q` 直接零扩展得到。
- `inst_valid_o` 固定为 1。
- `inst_fire` 由 `inst_ready_i` 是否接受当前指令决定。

周期 N 上升沿：
- 若 `rst_i=1`，`pc_q` 清零。
- 若 `rst_i=0` 且 `inst_fire=1`，`pc_q` 自增 1。
- 当前没有其他状态寄存器，也没有 redirect、flush 或 replay 更新。

周期 N+1：
- 可看到更新后的 `pc_q`。
- 若上一拍发生 `inst_fire`，则本拍可看到下一条顺序指令与下一条顺序地址。
- 若上一拍 `inst_ready_i=0`，则本拍仍停留在同一条指令上。

## 当前开发约束
- 当前阶段只搭前端 RTL 功能骨架，不写测试代码，不写仿真代码。
- 前端代码约束与后端一致：模块头注释、关键逻辑注释、逐周期说明都必须补齐。
- 如果后续修改影响前端接口、PC 选择、预测表、队列、握手或周期级行为，必须同步更新本文件。
- 如果后续修改同时影响协作规则、文档分工或通用执行边界，再同步更新 [`agent.md`](/home/chen/FUN/CISLC-O3/agent.md)。
