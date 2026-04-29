# backend_testharness_json

## 目标

新增一个基于 JSON 的后端仿真入口：指令流完全由 C++ testbench 从 JSON 文件读取，
并通过 Makefile 宏切换日志格式（旧日志 / Kanata）。

## JSON 格式

顶层是一个对象，包含 `meta` 与 `instruction`：

```json
{
  "meta": { "name": "sample" },
  "instruction": [
    ["0x00100093", "0x00200113", "0x00300193", "0x00400213"],
    ["0x00000013", "0x00108093"]
  ]
}
```

- `instruction` 为 list；每个元素是一组指令。
- 每组最多 `MACHINE_WIDTH` 条（默认 4）。
- 指令可以是 **整数** 或 **字符串**（支持 `0x` 十六进制）。
- 不足宽度的 lane 会自动填充 NOP（`addi x0,x0,0`）。

## 构建与运行

```bash
cd /home/chen/FUN/CISLC-O3/sim/backend_testharness_json
make run INPUT=program.json
```

### Kanata 日志

默认输出旧日志；启用 Kanata：

```bash
make run KANATA=1 INPUT=program.json
```

当 `KANATA=1` 时，输出文件为 `backend_testharness_json.log`，
并符合 Kanata v4 规范（`Kanata 0004 / C= / C / I / L / S / R`）。

### 参数化宽度

```bash
make run MACHINE_WIDTH=6 INPUT=program.json
```

## 结束条件

该仿真结束条件为：**已退休指令数 >= 输入指令总数**。

> 说明：当前实现的“输入指令总数”按 `total_groups * MACHINE_WIDTH` 计算，
> 即包含 JSON 中被 NOP 填充的 lane。

## 与旧 backend_testharness 的区别

1. **指令来源**  
   - 旧：C++ 内部硬编码固定 RV64I 指令流。  
   - 新：从 JSON 文件读取指令流。

2. **日志输出**  
   - 旧：只输出原来的逐周期后端日志。  
   - 新：可通过 `KANATA=1` 输出 Kanata 格式日志（并落盘 `.log`）。

3. **结束条件**  
   - 旧：送完指令后固定 drain 窗口结束。  
   - 新：按退休指令数达到输入指令总数结束。
