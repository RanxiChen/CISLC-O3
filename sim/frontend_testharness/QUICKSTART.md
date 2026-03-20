# 快速开始指南

## 文件说明

### 新增的执行模型文件
- **riscv_exec_model.cpp** - RISC-V 执行模型实现（分支指令解码和执行）
- **riscv_exec_test.sv** - 独立的测试文件，用于验证执行模型
- **RISCV_EXEC_MODEL_README.md** - 详细的使用文档

### 现有文件（已更新）
- **dpi_logger.cpp** - 添加了全局计数器功能
- **frontend_testharness.sv** - 导入了新的 DPI-C 函数，添加了使用示例
- **CMakeLists.txt** - 更新以包含新的源文件

## 编译和运行

### 方法 1: 使用现有的测试平台

```bash
cd /home/chen/FUN/CISLC-O3/sim/frontend_testharness
mkdir -p build
cd build
cmake ..
make
./sim_frontend_testharness
```

### 方法 2: 单独测试执行模型

如果你想单独测试 RISC-V 执行模型（不依赖 frontend），可以创建一个简单的测试：

```bash
cd /home/chen/FUN/CISLC-O3/sim/frontend_testharness

# 使用 Verilator 编译测试
verilator --cc --exe \
    --trace \
    --build \
    -j 0 \
    riscv_exec_test.sv \
    riscv_exec_model.cpp \
    -o riscv_exec_test

# 运行测试
./obj_dir/riscv_exec_test
```

## 新功能使用示例

### 1. 全局计数器

在 SystemVerilog 中：

```systemverilog
// 打印当前调用次数
dpi_print_call_counter();

// 获取计数值
longint counter = dpi_get_call_counter();

// 重置计数器
dpi_reset_call_counter();
```

### 2. 指令解码

```systemverilog
logic is_branch, is_jump;
logic [7:0] funct3;
logic [63:0] imm;

// 解码一条 BEQ 指令
dpi_decode_instruction(
    32'h00208463,  // BEQ x1, x2, 8
    is_branch,
    is_jump,
    funct3,
    imm
);

$display("Is branch: %b, funct3: %0d, imm: %0d", is_branch, funct3, imm);
```

### 3. 分支执行

```systemverilog
logic taken;

// 执行 BEQ，x1=x2=0x10，应该跳转
taken = dpi_execute_branch(
    64'h80000000,  // PC
    32'h00208463,  // BEQ x1, x2, 8
    64'h10,        // x1 的值
    64'h10         // x2 的值
);

$display("Branch taken: %b", taken);
```

### 4. 分支预测

```systemverilog
logic prediction;

prediction = dpi_predict_branch(64'h80000000, 32'h00208463);
$display("Predicted: %b", prediction);
```

### 5. 定期打印统计信息

在 frontend_testharness.sv 中已经添加了示例：

```systemverilog
always @(posedge clk_i) begin
    if (!rst_i && (cycle_counter % 100 == 0)) begin
        dpi_print_call_counter();
        dpi_print_branch_stats();
    end
end
```

## 预期输出示例

运行测试后，你应该看到类似这样的输出：

```
========================================
RISC-V Execution Model Test
========================================

[TEST 0] BEQ - Branch if Equal
  Case 1: x1=0x10, x2=0x10 (应该跳转)
[DECODE] PC=0x80000000 Inst=0x208463 Type=BRANCH Funct3=0 Imm=8
    Decoded: is_branch=1, funct3=0, imm=8
[EXEC] PC=0x80000000 Funct3=0 RS1=0x10 RS2=0x10 Imm=8 Taken=YES NextPC=0x80000008
    Result: taken=1 (expected=1)

  Case 2: x1=0x10, x2=0x20 (不应该跳转)
[EXEC] PC=0x80000004 Funct3=0 RS1=0x10 RS2=0x20 Imm=8 Taken=NO NextPC=0x80000008
    Result: taken=0 (expected=0)

...

========================================
[STATS] Branch Statistics:
  Total Branches: 14
  Branches Taken: 10
  Taken Rate: 71.43%
  Current PC: 0x80000040
========================================
```

## 集成到现有测试平台

如果你想在 frontend_testharness 中使用这些功能：

1. **解码前端发出的指令**：已经在 frontend_testharness.sv 中添加了示例
2. **验证分支预测器**：比较预测结果和实际执行结果
3. **统计分支性能**：定期打印分支统计信息

## 调试技巧

1. **查看详细的解码信息**：每次解码时都会打印到控制台
2. **追踪分支历史**：分支历史存储在 `g_branch_history` 中
3. **检查寄存器状态**：使用 `dpi_get_register()` 和 `dpi_set_register()`
4. **波形调试**：配合 Verilator 的 trace 功能

## 支持的 RISC-V 指令

- **BEQ** - Branch if Equal
- **BNE** - Branch if Not Equal
- **BLT** - Branch if Less Than (signed)
- **BGE** - Branch if Greater or Equal (signed)
- **BLTU** - Branch if Less Than (unsigned)
- **BGEU** - Branch if Greater or Equal (unsigned)
- **JAL** - Jump and Link
- **JALR** - Jump and Link Register

## 常见问题

### Q: 为什么我的指令没有被正确解码？
A: 检查指令编码是否正确。可以使用 RISC-V 汇编器生成正确的机器码。

### Q: 如何修改预测器？
A: 在 `riscv_exec_model.cpp` 中修改 `dpi_predict_branch()` 函数。

### Q: 如何添加对其他指令的支持？
A: 在 `dpi_decode_instruction()` 中添加新的 opcode 判断，然后实现对应的执行函数。

### Q: 全局计数器在哪里递增？
A: 在 `dpi_log_frontend_transaction()` 函数中每次调用时递增。

## 下一步

1. 实现更复杂的分支预测器（如 2-bit 饱和计数器）
2. 添加分支目标缓冲 (BTB)
3. 实现返回地址栈 (RAS)
4. 添加性能统计（预测准确率、分支目标命中率等）
5. 集成真实的寄存器文件

## 参考资料

- **RISCV_EXEC_MODEL_README.md** - 详细的 API 文档
- **RISC-V 指令集手册** - https://riscv.org/specifications/
- **Verilator DPI-C 文档** - https://verilator.org/guide/latest/connecting.html

