/**
 * 一个统一的后端，后面将会将代码进行拆分
 *
 * 当前已经实现的功能：
 * - 维护一个简单的 fetch-entry buffer，用于承接 frontend 输入
 * - 对 buffer 中的指令做基础解码
 * - 接入 free list 与 rename map table，打通最小 rename 数据流
 * - 支持按 MACHINE_WIDTH 参数化并行处理多个 lane
 *
 * 当前没有实现的功能：
 * - 不处理组内依赖、组内覆盖、分支恢复、checkpoint、commit
 * - 不驱动执行队列、ROB、调度队列、回写网络
 * - done 仍然只是占位信号
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 时序行为：
 * - 周期 N 开始时，fetch_entry_q / fetch_entry_valid_q 保存“上一拍已经接住”的指令组
 * - 周期 N 内：
 *   1) decoder 组合地产生 rs1/rs2/rd 与最小读写语义
 *   2) backend 组合地产生 alloc_req
 *   3) free list 组合地产生本拍候选新物理寄存器
 *   4) rename map table 组合地产生源操作数物理寄存器和 old_dst_preg
 * - 周期 N 上升沿：
 *   1) 若 rename_fire=1，则当前 buffer 中这组指令完成本版 rename
 *   2) 若 fetch_fire=1，则同时把 frontend 新送来的指令写入 fetch_entry_q
 * - 周期 N+1：
 *   看到的是更新后的 rename map / free list 状态，以及新 buffer 中的指令
 */

module backend
    import o3_pkg::*;
    #(
        parameter int MACHINE_WIDTH = 1,  // 机器宽度（每周期并行处理指令数量）
        parameter int NUM_PHYS_REGS = 64, // 物理寄存器数量
        parameter int NUM_ARCH_REGS = 32  // 架构寄存器数量
    )
(
    input  logic clk,
    input  logic rst,

    // Frontend -> Backend 接口
    input  fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry_i,
    input  logic                             fetch_valid_i,
    output logic                             fetch_ready_o,

    output logic done
);

    localparam int PREG_IDX_WIDTH = $clog2(NUM_PHYS_REGS);

    // 存放 fetch_entry 的寄存器。
    // fetch_entry_valid_q 表示当前 buffer 中是否真的有一组待 rename 的指令。
    fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry_q;
    logic                            fetch_entry_valid_q;

    // 从寄存器输出连接到解码器
    decode_in_t  [MACHINE_WIDTH-1:0] decode_in;
    decode_out_t [MACHINE_WIDTH-1:0] decode_out;

    // rename 阶段内部信号。
    logic                            decode_valid;
    logic                            rename_ready;
    logic                            rename_fire;
    logic                            alloc_valid;
    logic                            alloc_ready;
    logic                            fetch_fire;
    logic                            alloc_req [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0]       rs1_addr   [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0]       rs2_addr   [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0]       rd_addr    [MACHINE_WIDTH-1:0];
    logic                            rs1_read_en [MACHINE_WIDTH-1:0];
    logic                            rs2_read_en [MACHINE_WIDTH-1:0];
    logic                            rd_write_en [MACHINE_WIDTH-1:0];
    logic [PREG_IDX_WIDTH-1:0]       dst_new_preg [MACHINE_WIDTH-1:0];
    /* verilator lint_off UNUSEDSIGNAL */
    // 这些信号当前只是在 backend 内部被正确地产生出来，供后续接入 issue / dispatch / ROB 时继续使用。
    // 本阶段还没有继续向后传，因此对 lint 来说会表现为“已生成但尚未被消费”。
    logic [PREG_IDX_WIDTH-1:0]       src1_preg    [MACHINE_WIDTH-1:0];
    logic [PREG_IDX_WIDTH-1:0]       src2_preg    [MACHINE_WIDTH-1:0];
    logic [PREG_IDX_WIDTH-1:0]       dst_old_preg [MACHINE_WIDTH-1:0];
    /* verilator lint_on UNUSEDSIGNAL */

    assign decode_valid = fetch_entry_valid_q;

    // 将fetch_entry_q的instruction字段提取给解码器
    genvar i;
    generate
        for (i = 0; i < MACHINE_WIDTH; i++) begin : decode_input_assign
            assign decode_in[i].instruction = fetch_entry_q[i].instruction;
        end
    endgenerate

    // 实例化多个解码器
    generate
        for (i = 0; i < MACHINE_WIDTH; i++) begin : decoder_array
            decoder u_decoder (
                .decode_i(decode_in[i]),
                .decode_o(decode_out[i])
            );
        end
    endgenerate

    generate
        for (i = 0; i < MACHINE_WIDTH; i++) begin : rename_req_assign
            assign rs1_addr[i]    = decode_out[i].rs1;
            assign rs2_addr[i]    = decode_out[i].rs2;
            assign rd_addr[i]     = decode_out[i].rd;
            assign rs1_read_en[i] = decode_out[i].rs1_read_en;
            assign rs2_read_en[i] = decode_out[i].rs2_read_en;
            assign rd_write_en[i] = decode_out[i].rd_write_en;

            // 当前版本只有“真的写 rd 且 rd!=0”的指令才向 free list 申请新物理寄存器。
            assign alloc_req[i] = rd_write_en[i] && (rd_addr[i] != REG_ADDR_WIDTH'(0));
        end
    endgenerate

    // 当前 buffer 中有待 rename 指令时，rename_ready 取决于是否有足够的空闲物理寄存器。
    // 如果当前 buffer 为空，则这一拍天然 ready，可以接收 frontend 新输入。
    assign rename_ready = (!decode_valid) || alloc_valid;
    assign alloc_ready  = decode_valid;
    assign fetch_ready_o = (!fetch_entry_valid_q) || rename_ready;
    assign fetch_fire    = fetch_valid_i && fetch_ready_o;
    assign rename_fire   = decode_valid && rename_ready;
    assign done          = 1'b0;

    free_list #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_PHYS_REGS(NUM_PHYS_REGS),
        .NUM_ARCH_REGS(NUM_ARCH_REGS)
    ) u_free_list (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(alloc_req),
        .alloc_ready_i(alloc_ready),
        .alloc_valid_o(alloc_valid),
        .alloc_preg_o(dst_new_preg)
    );

    rename_map_table #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_ARCH_REGS(NUM_ARCH_REGS),
        .NUM_PHYS_REGS(NUM_PHYS_REGS)
    ) u_rename_map_table (
        .clk(clk),
        .rst(rst),
        .rename_fire_i(rename_fire),
        .rs1_addr_i(rs1_addr),
        .rs2_addr_i(rs2_addr),
        .rd_addr_i(rd_addr),
        .rs1_read_en_i(rs1_read_en),
        .rs2_read_en_i(rs2_read_en),
        .rd_write_en_i(rd_write_en),
        .new_dst_preg_i(dst_new_preg),
        .src1_preg_o(src1_preg),
        .src2_preg_o(src2_preg),
        .old_dst_preg_o(dst_old_preg)
    );

    // buffer 寄存器逻辑。
    // 这一级的目标只是先把“当前一组待 rename 指令”稳住，不实现更深的流水线。
    always_ff @(posedge clk) begin
        if (rst) begin
            fetch_entry_q       <= '0;
            fetch_entry_valid_q <= 1'b0;
        end else begin
            if (fetch_fire) begin
                fetch_entry_q       <= fetch_entry_i;
                fetch_entry_valid_q <= 1'b1;
            end else if (rename_fire) begin
                // 当前 buffer 被消费，且这拍没有新输入顶上来，因此清空 valid。
                fetch_entry_valid_q <= 1'b0;
            end
        end
    end

endmodule
