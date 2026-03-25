/**
 * 一个统一的后端，后面将会将代码进行拆分
 *
 * 当前已经实现的功能：
 * - 维护一个 fetch-entry buffer，用于承接 frontend 输入
 * - 对 fetch-entry buffer 中的指令做基础解码，并组装成 decoded uop
 * - 接入 decode 后、rename 前的 uop queue，形成前两拍骨架
 * - 在 rename 阶段接入 free list、rename map table 和最小 ROB
 * - 产出一组 rename 完成的 uop，并暂存在 backend 内部供后续 issue / dispatch 扩展
 * - 支持按 MACHINE_WIDTH 参数化并行处理多个 lane
 * - 在 `O3_SIM` 宏下新增逐周期文本日志，按周期块展示 lane0 在 decode/rename 两级的当前处理对象
 * - 在 `O3_SIM` 宏下可通过 DPI-C 调用 RV64I 反汇编 helper，把 rename 阶段指令显示成汇编字符串
 * - 在 backend 内部为每条被接收的指令生成调试用 instruction_id
 *   - 高位表示“第几批被 backend 接收的 fetch group”
 *   - 低位表示“该组内的 lane 编号”
 *
 * 当前没有实现的功能：
 * - 不处理组内依赖、组内覆盖、分支恢复、checkpoint、commit
 * - ROB 当前只做 entry 编号分配与 exception 存储，不做提交、回收、恢复
 * - 不驱动执行队列、调度队列、回写网络
 * - done 仍然只是占位信号
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 时序行为：
 * - 周期 N 开始时：
 *   1) fetch_entry_q / fetch_entry_valid_q 保存“上一拍已经接住”的 fetch 组
 *   2) uop_queue 若非空，则队头保存“上一拍已经解码完成、待 rename”的一组 uop
 * - 周期 N 内：
 *   1) decoder 组合地产生 rs1/rs2/rd、立即数和最小 uop 语义
 *   2) 若 uop_queue 可接收，则当前 fetch 组在本拍完成 decode 并入队
 *   3) rename 阶段从 uop_queue 队头组合读取 alloc_req / rob_req
 *   4) free list 组合地产生本拍候选新物理寄存器
 *   5) rename map table 组合地产生源操作数物理寄存器和 old_dst_preg
 *   6) rob 组合地产生本拍候选 ROB entry 编号
 * - 周期 N 上升沿：
 *   1) 若 decode_fire=1，则当前 fetch 组以 decoded uop 形式进入 uop_queue
 *   2) 若 rename_fire=1，则当前 uop_queue 队头这组 uop 完成本版 rename
 *   3) 若 fetch_fire=1，则同时把 frontend 新送来的指令写入 fetch_entry_q
 *   4) 在 `O3_SIM` 下按固定两行打印 lane0 的 decode/rename 当前处理指令
 * - 周期 N+1：
 *   看到的是更新后的 uop_queue / rename map / free list / rob 状态，以及新的 fetch 组
 *   在 `O3_SIM` 下会看到 lane0 的 decode/rename 两行切换到下一批 instruction_id
 */

`ifdef O3_SIM
`include "dpi_functions.svh"
`endif

module backend
    import o3_pkg::*;
    #(
        parameter int MACHINE_WIDTH = 1,  // 机器宽度（每周期并行处理指令数量）
        parameter int NUM_PHYS_REGS = 64, // 物理寄存器数量
        parameter int NUM_ARCH_REGS = 32, // 架构寄存器数量
        parameter int NUM_ROB_ENTRIES = 64,
        parameter int DECODE_QUEUE_DEPTH = 2
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
    localparam int ROB_IDX_WIDTH  = $clog2(NUM_ROB_ENTRIES);
    localparam int INST_ID_LANE_BITS = (MACHINE_WIDTH <= 1) ? 1 : $clog2(MACHINE_WIDTH);

    // 存放 fetch_entry 的寄存器。
    // fetch_entry_valid_q 表示当前 buffer 中是否真的有一组待 decode 的指令。
    fetch_entry_t [MACHINE_WIDTH-1:0] fetch_entry_q;
    logic                            fetch_entry_valid_q;
    logic [INST_ID_WIDTH-1:0]        fetch_instruction_id_q [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]        fetch_instruction_id_d [MACHINE_WIDTH-1:0];
    logic [INST_ID_WIDTH-1:0]        fetch_group_seq_q;

    // 从寄存器输出连接到解码器
    decode_in_t  [MACHINE_WIDTH-1:0] decode_in;
    decode_out_t [MACHINE_WIDTH-1:0] decode_out;
    decoded_uop_t [MACHINE_WIDTH-1:0] decoded_uop;
    decoded_uop_t [MACHINE_WIDTH-1:0] rename_uop_head;
    // decode 阶段内部信号。
    logic                            decode_valid;
    logic                            decode_ready;
    logic                            decode_fire;

    // rename 阶段内部信号。
    logic                            rename_valid;
    logic                            rename_ready;
    logic                            rename_fire;
    logic                            alloc_valid;
    logic                            alloc_ready;
    logic                            rob_valid;
    logic                            rob_ready;
    logic                            uopq_enq_ready;
    logic                            uopq_deq_valid;
    logic                            fetch_fire;
    logic                            alloc_req [MACHINE_WIDTH-1:0];
    logic                            rob_req   [MACHINE_WIDTH-1:0];
    logic                            rob_exception [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0]       rename_rs1_addr    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0]       rename_rs2_addr    [MACHINE_WIDTH-1:0];
    logic [REG_ADDR_WIDTH-1:0]       rename_rd_addr     [MACHINE_WIDTH-1:0];
    logic                            rename_rs1_read_en [MACHINE_WIDTH-1:0];
    logic                            rename_rs2_read_en [MACHINE_WIDTH-1:0];
    logic                            rename_rd_write_en [MACHINE_WIDTH-1:0];
    /* verilator lint_off UNUSEDSIGNAL */
    logic [PREG_IDX_WIDTH-1:0]       dst_new_preg [MACHINE_WIDTH-1:0];
    logic [ROB_IDX_WIDTH-1:0]        rob_idx      [MACHINE_WIDTH-1:0];
    logic                            renamed_uop_valid_q;
    // 这些信号当前只是在 backend 内部被正确地产生出来，供后续接入 issue / dispatch / ROB 时继续使用。
    // 本阶段还没有继续向后传，因此对 lint 来说会表现为“已生成但尚未被消费”。
    logic [PREG_IDX_WIDTH-1:0]       src1_preg    [MACHINE_WIDTH-1:0];
    logic [PREG_IDX_WIDTH-1:0]       src2_preg    [MACHINE_WIDTH-1:0];
    logic [PREG_IDX_WIDTH-1:0]       dst_old_preg [MACHINE_WIDTH-1:0];
    renamed_uop_t [MACHINE_WIDTH-1:0] renamed_uop_q;
    /* verilator lint_on UNUSEDSIGNAL */

`ifdef O3_SIM
    localparam int O3_SIM_TRACK_LANE = 0;
    logic [63:0]                    sim_cycle_q;
`endif

    function automatic logic [INST_ID_WIDTH-1:0] make_instruction_id(
        input logic [INST_ID_WIDTH-1:0] fetch_group_seq,
        input int unsigned              lane_idx
    );
        logic [INST_ID_WIDTH-1:0] instruction_id;
        begin
            instruction_id      = (fetch_group_seq << INST_ID_LANE_BITS);
            instruction_id      = instruction_id | INST_ID_WIDTH'(lane_idx);
            make_instruction_id = instruction_id;
        end
    endfunction

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
        for (i = 0; i < MACHINE_WIDTH; i++) begin : decoded_uop_assign
            assign decoded_uop[i].valid       = decode_valid;
            assign decoded_uop[i].instruction_id = fetch_instruction_id_q[i];
            assign decoded_uop[i].pc          = fetch_entry_q[i].pc;
            assign decoded_uop[i].instruction = fetch_entry_q[i].instruction;
            assign decoded_uop[i].exception   = fetch_entry_q[i].exception;
            assign decoded_uop[i].rs1         = decode_out[i].rs1;
            assign decoded_uop[i].rs2         = decode_out[i].rs2;
            assign decoded_uop[i].rd          = decode_out[i].rd;
            assign decoded_uop[i].rs1_read_en = decode_out[i].rs1_read_en;
            assign decoded_uop[i].rs2_read_en = decode_out[i].rs2_read_en;
            assign decoded_uop[i].rd_write_en = decode_out[i].rd_write_en;
            assign decoded_uop[i].imm_value   = decode_out[i].imm_value;
            assign decoded_uop[i].is_int_uop  = decode_out[i].is_int_uop;
        end
    endgenerate

    generate
        for (i = 0; i < MACHINE_WIDTH; i++) begin : rename_req_assign
            assign fetch_instruction_id_d[i] = make_instruction_id(fetch_group_seq_q, i);
            assign rename_rs1_addr[i]    = rename_uop_head[i].rs1;
            assign rename_rs2_addr[i]    = rename_uop_head[i].rs2;
            assign rename_rd_addr[i]     = rename_uop_head[i].rd;
            assign rename_rs1_read_en[i] = rename_uop_head[i].rs1_read_en;
            assign rename_rs2_read_en[i] = rename_uop_head[i].rs2_read_en;
            assign rename_rd_write_en[i] = rename_uop_head[i].rd_write_en;

            // 当前版本只有“真的写 rd 且 rd!=0”的指令才向 free list 申请新物理寄存器。
            assign alloc_req[i] = rename_uop_head[i].valid
                               && rename_uop_head[i].rd_write_en
                               && (rename_uop_head[i].rd != REG_ADDR_WIDTH'(0));

            // 当前每条真正有效的 uop 都先申请一个 ROB entry。
            assign rob_req[i] = rename_uop_head[i].valid;
            assign rob_exception[i] = rename_uop_head[i].exception;
        end
    endgenerate

    // decode queue 有空间时，本拍 decode 结果可以入队。
    // 如果 fetch buffer 为空，则这一拍天然 ready，可以接收 frontend 新输入。
    assign decode_ready  = uopq_enq_ready;
    assign decode_fire   = decode_valid && decode_ready;
    assign fetch_ready_o = (!fetch_entry_valid_q) || decode_ready;
    assign fetch_fire    = fetch_valid_i && fetch_ready_o;

    assign rename_valid  = uopq_deq_valid;
    assign rename_ready  = alloc_valid && rob_valid;
    assign rename_fire   = rename_valid && rename_ready;
    assign alloc_ready   = rename_valid && rob_valid;
    assign rob_ready     = rename_valid && alloc_valid;
    assign done          = 1'b0;

    uop_queue #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .DEPTH(DECODE_QUEUE_DEPTH)
    ) u_decode_queue (
        .clk(clk),
        .rst(rst),
        .enq_uop_i(decoded_uop),
        .enq_valid_i(decode_valid),
        .enq_ready_o(uopq_enq_ready),
        .deq_uop_o(rename_uop_head),
        .deq_valid_o(uopq_deq_valid),
        .deq_ready_i(rename_ready)
    );

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

    rob #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_ROB_ENTRIES(NUM_ROB_ENTRIES)
    ) u_rob (
        .clk(clk),
        .rst(rst),
        .alloc_req_i(rob_req),
        .alloc_exception_i(rob_exception),
        .alloc_ready_i(rob_ready),
        .alloc_valid_o(rob_valid),
        .alloc_idx_o(rob_idx)
    );

    rename_map_table #(
        .MACHINE_WIDTH(MACHINE_WIDTH),
        .NUM_ARCH_REGS(NUM_ARCH_REGS),
        .NUM_PHYS_REGS(NUM_PHYS_REGS)
    ) u_rename_map_table (
        .clk(clk),
        .rst(rst),
        .rename_fire_i(rename_fire),
        .rs1_addr_i(rename_rs1_addr),
        .rs2_addr_i(rename_rs2_addr),
        .rd_addr_i(rename_rd_addr),
        .rs1_read_en_i(rename_rs1_read_en),
        .rs2_read_en_i(rename_rs2_read_en),
        .rd_write_en_i(rename_rd_write_en),
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
            fetch_instruction_id_q <= '{default: '0};
            fetch_group_seq_q   <= '0;
            renamed_uop_q       <= '0;
            renamed_uop_valid_q <= 1'b0;
`ifdef O3_SIM
            sim_cycle_q         <= 64'd0;
`endif
        end else begin
`ifdef O3_SIM
            $display("[O3_SIM][backend][cycle=%0d][lane0] ----------------", sim_cycle_q);
            if (fetch_entry_valid_q) begin
                $display("[O3_SIM][backend][cycle=%0d][lane0] DECODE id=0x%0h pc=0x%0h inst=0x%08h",
                         sim_cycle_q,
                         fetch_instruction_id_q[O3_SIM_TRACK_LANE],
                         fetch_entry_q[O3_SIM_TRACK_LANE].pc,
                         fetch_entry_q[O3_SIM_TRACK_LANE].instruction);
            end else begin
                $display("[O3_SIM][backend][cycle=%0d][lane0] DECODE empty",
                         sim_cycle_q);
            end

            if (rename_valid && rename_uop_head[O3_SIM_TRACK_LANE].valid) begin
                $display("[O3_SIM][backend][cycle=%0d][lane0] RENAME id=0x%0h asm=%s src1:x%0d->p%0d src2:x%0d->p%0d rd:x%0d old:p%0d new:p%0d rob:%0d",
                         sim_cycle_q,
                         rename_uop_head[O3_SIM_TRACK_LANE].instruction_id,
                         dpi_backend_disasm_rv64i(rename_uop_head[O3_SIM_TRACK_LANE].instruction),
                         rename_uop_head[O3_SIM_TRACK_LANE].rs1, src1_preg[O3_SIM_TRACK_LANE],
                         rename_uop_head[O3_SIM_TRACK_LANE].rs2, src2_preg[O3_SIM_TRACK_LANE],
                         rename_uop_head[O3_SIM_TRACK_LANE].rd, dst_old_preg[O3_SIM_TRACK_LANE], dst_new_preg[O3_SIM_TRACK_LANE],
                         rob_idx[O3_SIM_TRACK_LANE]);
            end else begin
                $display("[O3_SIM][backend][cycle=%0d][lane0] RENAME empty",
                         sim_cycle_q);
            end
            $display("[O3_SIM][backend][cycle=%0d][lane0] ----------------", sim_cycle_q);
`endif

            if (rename_fire) begin
                for (int lane = 0; lane < MACHINE_WIDTH; lane++) begin
                    renamed_uop_q[lane].valid        <= rename_uop_head[lane].valid;
                    renamed_uop_q[lane].instruction_id <= rename_uop_head[lane].instruction_id;
                    renamed_uop_q[lane].pc           <= rename_uop_head[lane].pc;
                    renamed_uop_q[lane].instruction  <= rename_uop_head[lane].instruction;
                    renamed_uop_q[lane].exception    <= rename_uop_head[lane].exception;
                    renamed_uop_q[lane].rs1          <= rename_uop_head[lane].rs1;
                    renamed_uop_q[lane].rs2          <= rename_uop_head[lane].rs2;
                    renamed_uop_q[lane].rd           <= rename_uop_head[lane].rd;
                    renamed_uop_q[lane].rs1_read_en  <= rename_uop_head[lane].rs1_read_en;
                    renamed_uop_q[lane].rs2_read_en  <= rename_uop_head[lane].rs2_read_en;
                    renamed_uop_q[lane].rd_write_en  <= rename_uop_head[lane].rd_write_en;
                    renamed_uop_q[lane].imm_value    <= rename_uop_head[lane].imm_value;
                    renamed_uop_q[lane].is_int_uop   <= rename_uop_head[lane].is_int_uop;
                    renamed_uop_q[lane].src1_preg    <= src1_preg[lane];
                    renamed_uop_q[lane].src2_preg    <= src2_preg[lane];
                    renamed_uop_q[lane].dst_preg     <= dst_new_preg[lane];
                    renamed_uop_q[lane].old_dst_preg <= dst_old_preg[lane];
                    renamed_uop_q[lane].rob_idx      <= rob_idx[lane];
                end
                renamed_uop_valid_q <= 1'b1;
            end

            if (fetch_fire) begin
                fetch_entry_q       <= fetch_entry_i;
                fetch_entry_valid_q <= 1'b1;
                fetch_instruction_id_q <= fetch_instruction_id_d;
                fetch_group_seq_q   <= fetch_group_seq_q + INST_ID_WIDTH'(1);
            end else if (decode_fire) begin
                // 当前 fetch buffer 已完成 decode 并入队，且这拍没有新输入顶上来，因此清空 valid。
                fetch_entry_valid_q <= 1'b0;
            end
`ifdef O3_SIM
            sim_cycle_q <= sim_cycle_q + 64'd1;
`endif
        end
    end

endmodule
