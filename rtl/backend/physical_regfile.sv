/**
 * 物理寄存器文件 (Physical Register File)
 *
 * 功能：为乱序执行提供物理寄存器存储
 *
 * 设计说明：
 * - 当前实现为FPGA优化版本，使用分布式RAM或BRAM
 * - 读端口和写端口数量通过参数配置
 * - ASIC版本需要重新实现为真多端口寄存器堆
 *
 * 参数说明：
 * - NUM_READ_PORTS:  读端口数量（默认8，支持4发射×2操作数）
 * - NUM_WRITE_PORTS: 写端口数量（默认4，支持4发射写回）
 * - NUM_ENTRIES:     物理寄存器数量（默认64）
 * - DATA_WIDTH:      数据宽度（默认64位）
 *
 * 协作说明：
 * - 当前实现仅适用于FPGA，由全局宏 FPGA_IMPL 控制
 * - 转换为ASIC时，需要将 FPGA_IMPL 设为0，并重新实现本模块
 * - ASIC实现建议：使用标准单元库的多端口寄存器堆或寄存器阵列
 */


module physical_regfile
    import o3_pkg::*;
#(
    parameter int NUM_READ_PORTS  = 8,   // 读端口数量
    parameter int NUM_WRITE_PORTS = 4,   // 写端口数量
    parameter int NUM_ENTRIES     = 64,  // 物理寄存器数量
    parameter int DATA_WIDTH      = 64,  // 数据宽度
    parameter bit USE_BANK_LATEST_TAG = 1'b0 // 0: 强制bank一致, 1: bank+latest-tag
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
    `ifdef FPGA_TARGET

    // ========================================================================
    // FPGA实现：使用复制的RAM块实现多端口
    // ========================================================================
    // 通过 USE_BANK_LATEST_TAG 选择两种方案：
    // 0) 强制bank一致：每个bank接收所有写端口更新，读固定bank[0]
    // 1) bank+latest-tag：每个写端口只写本bank，按entry记录最新bank并据此读取
    // ========================================================================

    // 每个写端口对应一个RAM bank
    logic [DATA_WIDTH-1:0] ram_banks [NUM_WRITE_PORTS][NUM_ENTRIES];

    generate
        if (!USE_BANK_LATEST_TAG_CFG) begin : gen_impl_force_consistent
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

            genvar wp;
            for (wp = 0; wp < NUM_WRITE_PORTS; wp++) begin : gen_write_ports
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

endmodule
