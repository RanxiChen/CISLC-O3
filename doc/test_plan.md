# CISLC-O3 Test Plan

## 当前固定回归

### Frontend Smoke

```bash
cd sim/frontend
make clean-test TEST=frontend_basic
make test TEST=frontend_basic
```

- 目的：保证当前 `BPU -> FTQ -> IFU -> ICache -> fetch_buffer` 前端最小链路仍能运行。
- 当前检查：FTQ 向 IFU 成功出队 4 个 block；已经从 frontend output 出队的有效 lane 必须保持 PC 和 instruction 顺序递增。
- 说明：这是后续检查已有前端功能时的默认必跑项。

### Backend Harness

```bash
cd sim/backend_testharness
# 具体构建命令见 sim/backend_testharness/README.md
```

- 目的：用 DPI-C 虚拟前端驱动 backend 主链路，观察 decode/rename/issue/regread/execute/writeback/retire 日志。

### Backend JSON Harness

```bash
cd sim/backend_testharness_json
make run INPUT=program.json
```

- 目的：从 JSON 指令流驱动 backend，并以退休指令数作为结束条件。

## 下一阶段新增测试

### Minimal Core Integration

下一步需要新增一个 core-level smoke test，用于验证真实 frontend 和真实 backend 已经在 `O3` 或专用 core test top 中接通。

最小验收目标：

1. reset PC 从 0 开始。
2. 测试内存提供至少一条简单 RV64I 整数指令，例如 `addi x1, x0, 1`。
3. frontend 成功取出该指令并送入 backend。
4. backend 完成 decode/rename/issue/regread/execute/writeback/retire。
5. `retired_inst_count_o >= 1` 后测试通过。

该测试暂不要求：

- 完整 ISA 覆盖。
- 分支预测或 redirect。
- 长程序运行。
- 外部总线或真实内存层级。

## 长期测试类别

1. 单元测试：单模块行为，例如 ICache、LFSR、regfile。
2. 集成测试：多个 RTL 模块协同，例如 frontend smoke、backend harness、未来 core smoke。
3. 功能测试：指令集实现正确性，后续可接 riscv-tests。
4. 随机测试：使用参考模型做对比。
5. 压力测试：队列满/空、backpressure、refill、flush 等边界。
6. 性能测试：后续可考虑 CoreMark/SPEC 类 workload。
7. 形式化验证：关键队列、free list、rename map、ROB 指针安全性。
8. 综合/时序测试：FPGA/ASIC 目标下的综合、时序和面积检查。
