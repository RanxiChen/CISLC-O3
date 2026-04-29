# backend_testharness_json

这个目录提供一个新的后端 Verilator 仿真入口，指令流完全由 C++ testbench 从 JSON 文件加载。

## JSON 结构

顶层是一个对象，包含 `meta` 和 `instruction`：

```json
{
  "meta": { "name": "sample" },
  "instruction": [
    ["0x00100093", "0x00200113", "0x00300193", "0x00400213"],
    ["0x00000013", "0x00108093"]
  ]
}
```

- `instruction` 是一个 list，每个元素是一组指令。
- 每组最多 `MACHINE_WIDTH` 条指令（默认 4）。
- 指令可以是 **整数** 或 **字符串**（支持 `0x` 十六进制）。
- 如果某组不足 4 条，会自动用 `addi x0, x0, 0` 的 NOP 填充。

## 构建与运行

```bash
cd /home/chen/FUN/CISLC-O3/sim/backend_testharness_json
make run INPUT=program.json
```

## Kanata 日志

默认输出旧日志；如果要输出 Kanata：

```bash
make run KANATA=1 INPUT=program.json
```

## 改变宽度

```bash
make run MACHINE_WIDTH=6 INPUT=program.json
```
