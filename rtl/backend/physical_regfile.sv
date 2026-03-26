/**
 * 物理寄存器文件 (Physical Register File)
 *
 * 功能：为乱序执行提供物理寄存器存储
 *
 * 当前已经实现的功能：
 * - 支持参数化的多读端口、多写端口物理寄存器文件
 * - 支持同拍写后读旁路，避免本拍读到旧值
 * - reset 后把所有物理寄存器清零，保证当前阶段日志和最小执行链路可预测
 * - 在 `FPGA_TARGET` 下保留原来的 FPGA 优化实现
 * - 在未定义 `FPGA_TARGET` 时提供一个行为等价的通用实现，便于当前阶段 backend 集成和静态检查
 *
 * 当前没有实现的功能：
 * - 不区分架构零寄存器；是否把 p0 当作常零由上层协议保证
 * - 不负责 rename / free list / writeback 仲裁
 * - 不实现 ASIC 工艺下的真多端口寄存器堆优化
 * - 当前阶段不附带测试代码和仿真代码，只先搭功能与注释
 *
 * 参数说明：
 * - NUM_READ_PORTS:  读端口数量（默认8，支持4发射×2操作数）
 * - NUM_WRITE_PORTS: 写端口数量（默认4，支持4发射写回）
 * - NUM_ENTRIES:     物理寄存器数量（默认64）
 * - DATA_WIDTH:      数据宽度（默认64位）
 *
 * 时序行为：
 * - 周期 N 组合阶段：
 *   1) 读端口根据 rd_addr_i 直接返回当前寄存器值
 *   2) 若同拍存在 wr_en_i 且写地址命中某个读端口，则 rd_data_o 优先返回本拍 wr_data_i
 * - 周期 N 上升沿：
 *   1) 若 rst=1，则所有物理寄存器清零
 *   2) 否则把所有 wr_en_i=1 的写端口数据写入对应物理寄存器
 * - 周期 N+1：
 *   1) 可从读端口读到更新后的寄存器内容
 */


module physical_regfile
    import o3_pkg::*;
#(
    parameter int NUM_READ_PORTS  = 8,   // 读端口数量
    parameter int NUM_WRITE_PORTS = 4,   // 写端口数量
    parameter int NUM_ENTRIES     = 64,  // 物理寄存器数量
    parameter int DATA_WIDTH      = 64,  // 数据宽度
    parameter bit USE_BANK_LATEST_TAG = 1'b1, // 0: 强制bank一致, 1: bank+latest-tag
    parameter bit USE_NO_BANK_FLAT = 1'b0 // 1: 单数组不分bank（后写端口覆盖前写端口）
)(
    input  logic clk,
    input  logic rst,

    // 读端口接口
    input  logic [$clog2(NUM_ENTRIES)-1:0] rd_addr_i [NUM_READ_PORTS],
    output logic [DATA_WIDTH-1:0]          rd_data_o [NUM_READ_PORTS],

    // 写端口接口
    input  logic                           wr_en_i   [NUM_WRITE_PORTS],
    input  logic [$clog2(NUM_ENTRIES)-1:0] wr_addr_i [NUM_WRITE_PORTS],
    input  logic [DATA_WIDTH-1:0]          wr_data_i [NUM_WRITE_PORTS]
);

    // 地址宽度
    localparam int ADDR_WIDTH = $clog2(NUM_ENTRIES);
    localparam int BANK_SEL_WIDTH = (NUM_WRITE_PORTS > 1) ? $clog2(NUM_WRITE_PORTS) : 1;
`ifdef PRF_USE_BANK_LATEST_TAG
    localparam bit USE_BANK_LATEST_TAG_CFG = 1'b1;
`else
    localparam bit USE_BANK_LATEST_TAG_CFG = USE_BANK_LATEST_TAG;
`endif
`ifdef PRF_USE_NO_BANK_FLAT
    localparam bit USE_NO_BANK_FLAT_CFG = 1'b1;
`else
    localparam bit USE_NO_BANK_FLAT_CFG = USE_NO_BANK_FLAT;
`endif
    `ifdef FPGA_TARGET

    // ========================================================================
    // FPGA实现：使用复制的RAM块实现多端口
    // ========================================================================
    // 通过参数选择三种方案：
    // 0) USE_NO_BANK_FLAT=1：单数组不分bank，多写同址后写端口覆盖前写端口
    // 1) USE_NO_BANK_FLAT=0 && USE_BANK_LATEST_TAG=0：强制bank一致
    // 2) USE_NO_BANK_FLAT=0 && USE_BANK_LATEST_TAG=1：bank+latest-tag
    // ========================================================================

    // 每个写端口对应一个RAM bank
    logic [DATA_WIDTH-1:0] ram_banks [NUM_WRITE_PORTS][NUM_ENTRIES];

    generate
        if (USE_NO_BANK_FLAT_CFG) begin : gen_impl_no_bank_flat
            logic [DATA_WIDTH-1:0] mem_flat [NUM_ENTRIES];

            always_ff @(posedge clk) begin
                if (rst) begin
                    // 可选清零
                end else begin
                    // 同地址多写时，端口号大的写端口最终生效
                    for (int i = 0; i < NUM_WRITE_PORTS; i++) begin
                        if (wr_en_i[i]) begin
                            mem_flat[wr_addr_i[i]] <= wr_data_i[i];
                        end
                    end
                end
            end

            genvar rp;
            for (rp = 0; rp < NUM_READ_PORTS; rp++) begin : gen_read_ports_flat
                logic [NUM_WRITE_PORTS-1:0] bypass_match;
                logic [DATA_WIDTH-1:0]      bypass_data;
                logic                       bypass_valid;

                genvar bp;
                for (bp = 0; bp < NUM_WRITE_PORTS; bp++) begin : gen_bypass_check
                    assign bypass_match[bp] = wr_en_i[bp] && (wr_addr_i[bp] == rd_addr_i[rp]);
                end

                always_comb begin
                    bypass_valid = 1'b0;
                    bypass_data  = '0;
                    for (int i = NUM_WRITE_PORTS-1; i >= 0; i--) begin
                        if (!bypass_valid && bypass_match[i]) begin
                            bypass_valid = 1'b1;
                            bypass_data  = wr_data_i[i];
                        end
                    end
                end

                always_comb begin
                    if (bypass_valid) begin
                        rd_data_o[rp] = bypass_data;
                    end else begin
                        rd_data_o[rp] = mem_flat[rd_addr_i[rp]];
                    end
                end
            end
        end else if (!USE_BANK_LATEST_TAG_CFG) begin : gen_impl_force_consistent
            // --------------------------------------------------------------------
            // 方案A：强制bank一致
            // --------------------------------------------------------------------
            genvar wb;
            for (wb = 0; wb < NUM_WRITE_PORTS; wb++) begin : gen_write_banks
                always_ff @(posedge clk) begin
                    if (rst) begin
                        // 可选清零
                    end else begin
                        // 同地址多写时，端口号大的写端口最终生效
                        for (int i = 0; i < NUM_WRITE_PORTS; i++) begin
                            if (wr_en_i[i]) begin
                                ram_banks[wb][wr_addr_i[i]] <= wr_data_i[i];
                            end
                        end
                    end
                end
            end

            genvar rp;
            for (rp = 0; rp < NUM_READ_PORTS; rp++) begin : gen_read_ports_consistent
                logic [DATA_WIDTH-1:0] bank_data [NUM_WRITE_PORTS];
                logic [NUM_WRITE_PORTS-1:0] bypass_match;
                logic [DATA_WIDTH-1:0]      bypass_data;
                logic                       bypass_valid;

                genvar bp;
                for (bp = 0; bp < NUM_WRITE_PORTS; bp++) begin : gen_bank_read
                    assign bank_data[bp] = ram_banks[bp][rd_addr_i[rp]];
                end

                for (bp = 0; bp < NUM_WRITE_PORTS; bp++) begin : gen_bypass_check
                    assign bypass_match[bp] = wr_en_i[bp] && (wr_addr_i[bp] == rd_addr_i[rp]);
                end

                always_comb begin
                    bypass_valid = 1'b0;
                    bypass_data  = '0;
                    for (int i = NUM_WRITE_PORTS-1; i >= 0; i--) begin
                        if (!bypass_valid && bypass_match[i]) begin
                            bypass_valid = 1'b1;
                            bypass_data  = wr_data_i[i];
                        end
                    end
                end

                always_comb begin
                    if (bypass_valid) begin
                        rd_data_o[rp] = bypass_data;
                    end else begin
                        rd_data_o[rp] = bank_data[0];
                    end
                end
            end
        end else begin : gen_impl_latest_tag
            // --------------------------------------------------------------------
            // 方案B：bank + latest-tag
            // --------------------------------------------------------------------
            logic [BANK_SEL_WIDTH-1:0] latest_bank [NUM_ENTRIES];

            always_ff @(posedge clk) begin
                if (rst) begin
                    for (int e = 0; e < NUM_ENTRIES; e++) begin
                        latest_bank[e] <= '0;
                    end
                end else begin
                    // 每个写端口仅写本bank，并更新latest tag
                    // 同地址多写时，端口号大的写端口最终生效
                    for (int i = 0; i < NUM_WRITE_PORTS; i++) begin
                        if (wr_en_i[i]) begin
                            ram_banks[i][wr_addr_i[i]] <= wr_data_i[i];
                            latest_bank[wr_addr_i[i]] <= BANK_SEL_WIDTH'(i);
                        end
                    end
                end
            end

            genvar rp;
            for (rp = 0; rp < NUM_READ_PORTS; rp++) begin : gen_read_ports_latest
                logic [DATA_WIDTH-1:0] bank_data [NUM_WRITE_PORTS];
                logic [NUM_WRITE_PORTS-1:0] bypass_match;
                logic [DATA_WIDTH-1:0]      bypass_data;
                logic                       bypass_valid;
                logic [BANK_SEL_WIDTH-1:0]  selected_bank;
                logic [DATA_WIDTH-1:0]      selected_bank_data;

                genvar bp;
                for (bp = 0; bp < NUM_WRITE_PORTS; bp++) begin : gen_bank_read
                    assign bank_data[bp] = ram_banks[bp][rd_addr_i[rp]];
                end

                assign selected_bank = latest_bank[rd_addr_i[rp]];

                always_comb begin
                    selected_bank_data = '0;
                    for (int i = 0; i < NUM_WRITE_PORTS; i++) begin
                        if (selected_bank == BANK_SEL_WIDTH'(i)) begin
                            selected_bank_data = bank_data[i];
                        end
                    end
                end

                for (bp = 0; bp < NUM_WRITE_PORTS; bp++) begin : gen_bypass_check
                    assign bypass_match[bp] = wr_en_i[bp] && (wr_addr_i[bp] == rd_addr_i[rp]);
                end

                always_comb begin
                    bypass_valid = 1'b0;
                    bypass_data  = '0;
                    for (int i = NUM_WRITE_PORTS-1; i >= 0; i--) begin
                        if (!bypass_valid && bypass_match[i]) begin
                            bypass_valid = 1'b1;
                            bypass_data  = wr_data_i[i];
                        end
                    end
                end

                always_comb begin
                    if (bypass_valid) begin
                        rd_data_o[rp] = bypass_data;
                    end else begin
                        rd_data_o[rp] = selected_bank_data;
                    end
                end
            end
        end
    endgenerate
    `endif

    `ifndef FPGA_TARGET
    logic [DATA_WIDTH-1:0] mem_generic [NUM_ENTRIES];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int entry = 0; entry < NUM_ENTRIES; entry++) begin
                mem_generic[entry] <= '0;
            end
        end else begin
            for (int i = 0; i < NUM_WRITE_PORTS; i++) begin
                if (wr_en_i[i]) begin
                    mem_generic[wr_addr_i[i]] <= wr_data_i[i];
                end
            end
        end
    end

    genvar rp_generic;
    generate
        for (rp_generic = 0; rp_generic < NUM_READ_PORTS; rp_generic++) begin : gen_generic_read
            always_comb begin
                rd_data_o[rp_generic] = mem_generic[rd_addr_i[rp_generic]];

                for (int i = 0; i < NUM_WRITE_PORTS; i++) begin
                    if (wr_en_i[i] && (wr_addr_i[i] == rd_addr_i[rp_generic])) begin
                        rd_data_o[rp_generic] = wr_data_i[i];
                    end
                end
            end
        end
    endgenerate
    `endif

endmodule
