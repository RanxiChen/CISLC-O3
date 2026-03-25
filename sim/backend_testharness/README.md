# backend_testharness

这个目录是一次性使用的后端 Verilator 仿真环境，不改变仓库长期的协作边界。

## 目录职责

- `main.cpp`
  - Verilator 主循环，负责时钟、复位、trace 和 `done_o` 退出。
- `backend_instruction_stream.cpp`
  - DPI-C 虚拟前端。
  - 当前每次向后端提供 1 个 4-lane fetch group。
  - 每个 lane 都是一条固定的、彼此无关的 RV64I 整形运算指令。
- `dpi_compat_stubs.cpp`
  - 本地补齐共享 `dpi_functions.svh` 里但本仿真并不真正使用的 DPI 符号。
  - 目的是让后端仿真环境独立链接，不依赖前端仿真目录里的实现。
- `CMakeLists.txt`
  - 只拉起后端最小 rename 链路相关 RTL 与 testharness。

## 当前模型说明

- 当前 PC 从 `0` 开始。
- 每个 fetch group 固定包含 4 条 32-bit 指令，所以组内 PC 分别是：
  - lane0: `base + 0`
  - lane1: `base + 4`
  - lane2: `base + 8`
  - lane3: `base + 12`
- 下一组 PC 基址在前一组基础上加 `16`。
- 当前指令流是硬编码常量，不从内存读取。
- 当前指令只覆盖 RV64I 整形运算，且故意避免组内依赖，目的是先驱动 backend 的 decode / free_list / rename_map_table。

## 构建与运行

```bash
cd /home/chen/FUN/CISLC-O3/sim/backend_testharness
mkdir -p build
cd build
cmake ..
make
./sim_backend_testharness
```

## 后续扩展入口

- 如果后面要更贴近真实处理器，可以把 `backend_instruction_stream.cpp` 改成：
  - 从内存镜像按 PC 取指
  - 或者从更真实的前端模型按拍提供 fetch group
- 若需要观测更多后端内部信号，优先在 `tb/backend_testharness.sv` 增加只读日志，不改 `backend` 公共接口。
