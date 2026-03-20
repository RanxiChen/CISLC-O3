# RISC-V 执行模型使用说明

## 概述

这是一个简化的 RISC-V 执行模型，专注于分支指令的解码和执行。支持 RV64I 指令集中的所有分支和跳转指令。

## 支持的指令

### 分支指令 (B-type)
- **BEQ** (Branch if Equal) - funct3 = 0b000
- **BNE** (Branch if Not Equal) - funct3 = 0b001
- **BLT** (Branch if Less Than, 有符号) - funct3 = 0b100
- **BGE** (Branch if Greater or Equal, 有符号) - funct3 = 0b101
- **BLTU** (Branch if Less Than, 无符号) - funct3 = 0b110
- **BGEU** (Branch if Greater or Equal, 无符号) - funct3 = 0b111

### 跳转指令
- **JAL** (Jump and Link) - opcode = 0x6F
- **JALR** (Jump and Link Register) - opcode = 0x67

## DPI-C 函数接口

### 1. 指令解码
```systemverilog
dpi_decode_instruction(
    input int unsigned inst,              // 32位指令
    output bit out_is_branch,            // 是否为分支指令
    output bit out_is_jump,              // 是否为跳转指令
    output byte unsigned out_funct3,     // funct3 字段
    output longint unsigned out_imm      // 立即数
);
```

**功能**: 解码 RISC-V 指令，识别分支和跳转指令

**示例**:
```systemverilog
logic is_branch, is_jump;
logic [7:0] funct3;
logic [63:0] imm;

dpi_decode_instruction(32'h00208063, is_branch, is_jump, funct3, imm);
// 解码 BEQ x1, x2, 8
```

### 2. 分支执行
```systemverilog
bit dpi_execute_branch(
    input longint unsigned pc,           // 当前 PC
    input int unsigned inst,             // 指令
    input longint unsigned rs1_val,      // rs1 寄存器值
    input longint unsigned rs2_val       // rs2 寄存器值
);
```

**功能**: 执行分支指令，返回是否跳转 (1=taken, 0=not taken)

**示例**:
```systemverilog
logic taken;
taken = dpi_execute_branch(64'h80000000, 32'h00208063, 64'h10, 64'h10);
// 执行 BEQ，rs1=rs2=0x10，结果应该是 taken=1
```

### 3. 分支预测
```systemverilog
bit dpi_predict_branch(
    input longint unsigned pc,           // 当前 PC
    input int unsigned inst              // 指令
);
```

**功能**: 使用简单的 1-bit 预测器预测分支方向

**说明**: 基于最近一次分支的结果进行预测

### 4. JAL 执行
```systemverilog
longint unsigned dpi_execute_jal(
    input longint unsigned pc,           // 当前 PC
    input int unsigned inst              // JAL 指令
);
```

**功能**: 执行 JAL 指令，返回跳转目标地址

### 5. JALR 执行
```systemverilog
longint unsigned dpi_execute_jalr(
    input longint unsigned pc,           // 当前 PC
    input int unsigned inst,             // JALR 指令
    input longint unsigned rs1_val       // rs1 寄存器值
);
```

**功能**: 执行 JALR 指令，返回跳转目标地址

### 6. 辅助函数

#### 打印统计信息
```systemverilog
dpi_print_branch_stats();
```
打印分支统计：总分支数、跳转次数、跳转率等

#### 重置执行状态
```systemverilog
dpi_reset_exec_state();
```
重置 PC、寄存器、统计计数器等

#### 寄存器操作
```systemverilog
// 设置寄存器值（用于测试）
dpi_set_register(5, 64'h12345678);  // x5 = 0x12345678

// 读取寄存器值
logic [63:0] val;
val = dpi_get_register(5);
```

## 使用示例

### 完整的分支指令处理流程

```systemverilog
always @(posedge clk) begin
    if (inst_valid && inst_ready) begin
        // 1. 解码指令
        logic is_branch, is_jump;
        logic [7:0] funct3;
        logic [63:0] imm;

        dpi_decode_instruction(inst, is_branch, is_jump, funct3, imm);

        // 2. 如果是分支指令
        if (is_branch) begin
            // 2a. 预测分支方向
            logic predicted = dpi_predict_branch(pc, inst);

            // 2b. 执行分支（获取实际结果）
            logic taken = dpi_execute_branch(
                pc,
                inst,
                reg_file[rs1],  // 从寄存器文件读取
                reg_file[rs2]
            );

            // 2c. 检查预测是否正确
            if (predicted != taken) begin
                $display("Branch mispredicted!");
            end
        end

        // 3. 如果是 JAL/JALR
        if (is_jump) begin
            logic [63:0] target;
            if (inst[6:0] == 7'h6F) begin
                target = dpi_execute_jal(pc, inst);
            end else begin
                target = dpi_execute_jalr(pc, inst, reg_file[rs1]);
            end
            $display("Jump to 0x%h", target);
        end
    end
end
```

### 定期打印统计信息

```systemverilog
always @(posedge clk) begin
    if (cycle_count % 1000 == 0) begin
        dpi_print_branch_stats();
    end
end
```

## 指令编码参考

### BEQ 示例
```
BEQ x1, x2, offset
Encoding: imm[12|10:5] | rs2 | rs1 | 000 | imm[4:1|11] | 1100011
```

### JAL 示例
```
JAL x1, offset
Encoding: imm[20|10:1|11|19:12] | rd | 1101111
```

## 内部状态

执行模型维护以下状态：
- **g_pc**: 当前程序计数器 (初始值: 0x80000000)
- **g_regs[32]**: 32 个通用寄存器 (x0 始终为 0)
- **g_branch_count**: 分支指令总数
- **g_branch_taken_count**: 分支跳转次数
- **g_branch_history**: 分支历史（用于预测）

## 限制

1. 只实现了分支和跳转指令的解码/执行
2. 寄存器值需要从外部提供（或使用 `dpi_set_register` 设置）
3. 预测器非常简单（1-bit 预测器）
4. 不包含内存操作
5. 不包含算术/逻辑运算

## 编译说明

在 Verilator 或其他仿真器中编译时，需要包含这个文件：

```bash
verilator --cc --exe \
    --trace \
    frontend_testharness.sv \
    riscv_exec_model.cpp \
    dpi_logger.cpp \
    main.cpp
```

## 调试输出示例

```
[DECODE] PC=0x80000000 Inst=0x208063 Type=BRANCH Funct3=0 Imm=8
[PREDICT] PC=0x80000000 Prediction=NOT_TAKEN History=0x0
[EXEC] PC=0x80000000 Funct3=0 RS1=0x10 RS2=0x10 Imm=8 Taken=YES NextPC=0x80000008
========================================
[STATS] Branch Statistics:
  Total Branches: 100
  Branches Taken: 67
  Taken Rate: 67.00%
  Current PC: 0x80000400
========================================
```

## 扩展建议

如果需要更完整的功能，可以添加：
1. 2-bit 饱和预测器
2. 分支目标缓冲 (BTB)
3. 返回地址栈 (RAS)
4. 完整的寄存器文件管理
5. 内存模型
6. 性能计数器

