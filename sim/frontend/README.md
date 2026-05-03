# Frontend Verilator Simulation

这个目录用于前端 RTL 的 Verilator 仿真。当前第一版只搭建长期可扩展的测试入口，默认测试对象是 `rtl/frontend/frontend.sv`。

## 目录结构

```text
sim/frontend/
├── Makefile
├── README.md
├── build/
└── tests/
    └── frontend_basic.cpp
```

## Makefile 入口

```bash
make list
make build TEST=frontend_basic
make run TEST=frontend_basic
make test TEST=frontend_basic
make clean-test TEST=frontend_basic
make clean
```

- `make list`：列出 `tests/*.cpp` 中已有测试。
- `make build TEST=...`：删除该测试对应的 build 目录，重新 Verilator 编译。
- `make run TEST=...`：运行已编译出的二进制，不重新编译。
- `make test TEST=...`：先删 build，再编译，再运行。
- `make clean-test TEST=...`：删除某个测试的 build 目录。
- `make clean`：删除整个 `sim/frontend/build`。

## 当前测试列表

### `frontend_basic`

- 源文件：`tests/frontend_basic.cpp`
- 仿真对象：`frontend`
- 运行命令：`make test TEST=frontend_basic`
- 当前行为：
  - 手动 reset 后释放前端。
  - 默认 `fetch_ready_i=1`，后端方向一直可以接收 fetch group。
  - 默认 `flush_i=0`。
  - 观察 `refill_req_valid_o/refill_req_pc_o`。
  - 用 C++ 内部 memory model 延迟固定 6 个周期返回 refill response。
  - 每周期打印 refill request、refill response 和 fetch buffer 出队的有效指令。
- 当前用途：
  - 验证 `FTQ -> IFU -> ICache -> IFU -> fetch_buffer -> frontend output` 这条最小链路可以跑起来。
  - 作为后续前端测试的 Makefile 和 C++ testbench 模板。

## 当前 basic 测试语义

`tests/frontend_basic.cpp` 当前实现：

- 手动 reset。
- `step()` 是最小时间单位，每次包含完整上升沿和下降沿。
- 默认 `fetch_ready_i=1`，后端方向始终可以接收 fetch group。
- 默认 `flush_i=0`。
- 每个周期 `step()` 后观察 `refill_req_valid_o/refill_req_pc_o`。
- 看到 refill request 后记录地址，等待源文件内固定的 6 个周期。
- 到期后在下一次 `step()` 前打一拍 `refill_resp_valid_i`，返回 64B cache line。
- C++ 内部用 `std::map<uint64_t, uint32_t>` 保存 32-bit 对齐地址到指令的映射。
- 未定义地址默认返回 `0xffffffff`。
- 每周期打印 frontend 出队的有效指令 lane。

当前不做 backend 接入、不做随机 ready、不做 checker 判定。
