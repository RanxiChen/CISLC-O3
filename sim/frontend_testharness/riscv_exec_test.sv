/**
 * RISC-V 执行模型测试示例
 *
 * 这个文件展示如何在 SystemVerilog 中使用 DPI-C 执行模型
 */

module riscv_exec_test;

    // 时钟和复位
    logic clk;
    logic rst;

    // 测试计数器
    int test_count = 0;

    // 解码结果
    logic is_branch;
    logic is_jump;
    logic [7:0] funct3;
    logic [63:0] imm;

    // 导入 DPI-C 函数（如果需要独立测试）
    import "DPI-C" function void dpi_decode_instruction(
        input int unsigned inst,
        output bit out_is_branch,
        output bit out_is_jump,
        output byte unsigned out_funct3,
        output longint unsigned out_imm
    );

    import "DPI-C" function bit dpi_execute_branch(
        input longint unsigned pc,
        input int unsigned inst,
        input longint unsigned rs1_val,
        input longint unsigned rs2_val
    );

    import "DPI-C" function void dpi_print_branch_stats();
    import "DPI-C" function void dpi_reset_exec_state();
    import "DPI-C" function void dpi_set_register(input int unsigned reg_num, input longint unsigned value);

    // 生成时钟
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // 测试流程
    initial begin
        // 初始化
        rst = 1;
        #20;
        rst = 0;

        $display("========================================");
        $display("RISC-V Execution Model Test");
        $display("========================================\n");

        // 测试 1: BEQ (相等分支)
        test_beq();

        // 测试 2: BNE (不等分支)
        test_bne();

        // 测试 3: BLT (小于分支)
        test_blt();

        // 测试 4: BGE (大于等于分支)
        test_bge();

        // 测试 5: BLTU (无符号小于)
        test_bltu();

        // 测试 6: BGEU (无符号大于等于)
        test_bgeu();

        #20;

        // 打印最终统计
        $display("\n========================================");
        $display("Final Statistics:");
        $display("========================================");
        dpi_print_branch_stats();

        $display("\nAll tests completed!");
        $finish;
    end

    // ========================================================================
    // 测试用例
    // ========================================================================

    task test_beq();
        logic taken;
        $display("\n[TEST %0d] BEQ - Branch if Equal", test_count++);

        // BEQ x1, x2, 8  (如果 x1 == x2，跳转到 PC+8)
        // 编码: 000000 00010 00001 000 01000 1100011
        // Hex: 0x00208463

        // 测试用例 1: 相等，应该跳转
        $display("  Case 1: x1=0x10, x2=0x10 (应该跳转)");
        dpi_decode_instruction(32'h00208463, is_branch, is_jump, funct3, imm);
        $display("    Decoded: is_branch=%b, funct3=%0d, imm=%0d", is_branch, funct3, imm);

        taken = dpi_execute_branch(64'h80000000, 32'h00208463, 64'h10, 64'h10);
        $display("    Result: taken=%b (expected=1)\n", taken);

        // 测试用例 2: 不等，不应该跳转
        $display("  Case 2: x1=0x10, x2=0x20 (不应该跳转)");
        taken = dpi_execute_branch(64'h80000004, 32'h00208463, 64'h10, 64'h20);
        $display("    Result: taken=%b (expected=0)\n", taken);
    endtask

    task test_bne();
        logic taken;
        $display("\n[TEST %0d] BNE - Branch if Not Equal", test_count++);

        // BNE x3, x4, 12
        // Encoding: imm[12|10:5]=0 | rs2=x4 | rs1=x3 | 001 | imm[4:1|11]=6 | 1100011
        // Hex: 0x00419663

        $display("  Case 1: x3=0x10, x4=0x20 (应该跳转)");
        taken = dpi_execute_branch(64'h80000000, 32'h00419663, 64'h10, 64'h20);
        $display("    Result: taken=%b (expected=1)\n", taken);

        $display("  Case 2: x3=0x10, x4=0x10 (不应该跳转)");
        taken = dpi_execute_branch(64'h80000004, 32'h00419663, 64'h10, 64'h10);
        $display("    Result: taken=%b (expected=0)\n", taken);
    endtask

    task test_blt();
        logic taken;
        $display("\n[TEST %0d] BLT - Branch if Less Than (Signed)", test_count++);

        // BLT x5, x6, 16
        // Encoding: funct3=100
        // Hex: 0x0062c863

        $display("  Case 1: x5=0x10, x6=0x20 (应该跳转)");
        taken = dpi_execute_branch(64'h80000000, 32'h0062c863, 64'h10, 64'h20);
        $display("    Result: taken=%b (expected=1)\n", taken);

        $display("  Case 2: x5=0x20, x6=0x10 (不应该跳转)");
        taken = dpi_execute_branch(64'h80000004, 32'h0062c863, 64'h20, 64'h10);
        $display("    Result: taken=%b (expected=0)\n", taken);

        // 测试负数
        $display("  Case 3: x5=-10 (0xFFFFFFF6), x6=10 (应该跳转)");
        taken = dpi_execute_branch(64'h80000008, 32'h0062c863,
                                   64'hFFFFFFFFFFFFFFF6, 64'h0A);
        $display("    Result: taken=%b (expected=1)\n", taken);
    endtask

    task test_bge();
        logic taken;
        $display("\n[TEST %0d] BGE - Branch if Greater or Equal (Signed)", test_count++);

        // BGE x7, x8, 20
        // Encoding: funct3=101
        // Hex: 0x0083da63

        $display("  Case 1: x7=0x20, x8=0x10 (应该跳转)");
        taken = dpi_execute_branch(64'h80000000, 32'h0083da63, 64'h20, 64'h10);
        $display("    Result: taken=%b (expected=1)\n", taken);

        $display("  Case 2: x7=0x10, x8=0x10 (相等，应该跳转)");
        taken = dpi_execute_branch(64'h80000004, 32'h0083da63, 64'h10, 64'h10);
        $display("    Result: taken=%b (expected=1)\n", taken);

        $display("  Case 3: x7=0x10, x8=0x20 (不应该跳转)");
        taken = dpi_execute_branch(64'h80000008, 32'h0083da63, 64'h10, 64'h20);
        $display("    Result: taken=%b (expected=0)\n", taken);
    endtask

    task test_bltu();
        logic taken;
        $display("\n[TEST %0d] BLTU - Branch if Less Than (Unsigned)", test_count++);

        // BLTU x9, x10, 24
        // Encoding: funct3=110
        // Hex: 0x00a4ec63

        $display("  Case 1: x9=0x10, x10=0x20 (应该跳转)");
        taken = dpi_execute_branch(64'h80000000, 32'h00a4ec63, 64'h10, 64'h20);
        $display("    Result: taken=%b (expected=1)\n", taken);

        // 无符号比较：0xFFFFFFF0 > 0x10
        $display("  Case 2: x9=0xFFFFFFF0, x10=0x10 (无符号大，不应该跳转)");
        taken = dpi_execute_branch(64'h80000004, 32'h00a4ec63,
                                   64'hFFFFFFFFFFFFFFF0, 64'h10);
        $display("    Result: taken=%b (expected=0)\n", taken);
    endtask

    task test_bgeu();
        logic taken;
        $display("\n[TEST %0d] BGEU - Branch if Greater or Equal (Unsigned)", test_count++);

        // BGEU x11, x12, 28
        // Encoding: funct3=111
        // Hex: 0x00c5fe63

        $display("  Case 1: x11=0x20, x12=0x10 (应该跳转)");
        taken = dpi_execute_branch(64'h80000000, 32'h00c5fe63, 64'h20, 64'h10);
        $display("    Result: taken=%b (expected=1)\n", taken);

        // 无符号比较：0xFFFFFFF0 > 0x10
        $display("  Case 2: x11=0xFFFFFFF0, x12=0x10 (无符号大，应该跳转)");
        taken = dpi_execute_branch(64'h80000004, 32'h00c5fe63,
                                   64'hFFFFFFFFFFFFFFF0, 64'h10);
        $display("    Result: taken=%b (expected=1)\n", taken);

        $display("  Case 3: x11=0x10, x12=0x20 (不应该跳转)");
        taken = dpi_execute_branch(64'h80000008, 32'h00c5fe63, 64'h10, 64'h20);
        $display("    Result: taken=%b (expected=0)\n", taken);
    endtask

endmodule
