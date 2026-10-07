/**
 * Domain-parametric multiport physical register file (B15).
 * INT p0 reads zero and ignores writes. FP p0 is writable. FP uses CFG 7R/2W;
 * every granted write participates in the existing same-cycle write/read bypass.
 * Generic implementation resets data to zero; FPGA bank/latest-tag variants are retained.
 * 当前实现状态：闭环简化（L9）；lint/测试未运行，no PPA/FPGA inference claim.
 * N: read stored values with granted-write bypass. N edge: write granted data;
 * generic reset clears entries. N+1: registered contents reflect those writes.
 */
module physical_regfile
    import o3_pkg::*;
#(
    parameter  o3_cfg_pkg::backend_cfg_t CFG,
    parameter  o3_types_pkg::reg_domain_e DOMAIN,     // RD_INT / RD_FP，无默认值
    localparam int NUM_READ_PORTS  = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.exec.fp_prf_read_ports
                                                                     : CFG.exec.int_prf_read_ports,
    localparam int NUM_WRITE_PORTS = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.exec.fp_prf_write_ports
                                                                     : CFG.exec.int_prf_write_ports,
    localparam int NUM_ENTRIES     = (DOMAIN == o3_types_pkg::RD_FP) ? CFG.rename.fp_phys_regs
                                                                     : CFG.rename.int_phys_regs,
    localparam int DATA_WIDTH      = XLEN,
    // FPGA 实现选择开关，现状沿用（非微架构参数）。
    localparam bit USE_BANK_LATEST_TAG = 1'b1, // 0: 强制bank一致, 1: bank+latest-tag
    localparam bit USE_NO_BANK_FLAT = 1'b0,    // 1: 单数组不分bank（后写端口覆盖前写端口）
    // 整数域 p0 读恒 0、写忽略；FP 域没有恒零寄存器（B15）。
    localparam bit HAS_ZERO_REG = (DOMAIN == o3_types_pkg::RD_INT)
)(
    input  logic clk,
    input  logic rst,

    // 读端口接口
    input  logic [PREG_IDX_WIDTH-1:0] rd_addr_i [NUM_READ_PORTS],
    output logic [DATA_WIDTH-1:0]          rd_data_o [NUM_READ_PORTS],

    // 写端口接口
    input  logic                           wr_en_i   [NUM_WRITE_PORTS],
    input  logic [PREG_IDX_WIDTH-1:0] wr_addr_i [NUM_WRITE_PORTS],
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

    function automatic logic is_zero_preg(input logic [ADDR_WIDTH-1:0] preg_idx);
        begin
            is_zero_preg = HAS_ZERO_REG && (preg_idx == ADDR_WIDTH'(0));
        end
    endfunction

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
                            if (wr_en_i[i] && !is_zero_preg(wr_addr_i[i])) begin
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
                    assign bypass_match[bp] = wr_en_i[bp] && !is_zero_preg(wr_addr_i[bp]) && (wr_addr_i[bp] == rd_addr_i[rp]);
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
                    if (is_zero_preg(rd_addr_i[rp])) begin
                        rd_data_o[rp] = '0;
                    end else if (bypass_valid) begin
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
                            if (wr_en_i[i] && !is_zero_preg(wr_addr_i[i])) begin
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
                    assign bypass_match[bp] = wr_en_i[bp] && !is_zero_preg(wr_addr_i[bp]) && (wr_addr_i[bp] == rd_addr_i[rp]);
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
                    if (is_zero_preg(rd_addr_i[rp])) begin
                        rd_data_o[rp] = '0;
                    end else if (bypass_valid) begin
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
                        if (wr_en_i[i] && !is_zero_preg(wr_addr_i[i])) begin
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
                    assign bypass_match[bp] = wr_en_i[bp] && !is_zero_preg(wr_addr_i[bp]) && (wr_addr_i[bp] == rd_addr_i[rp]);
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
                    if (is_zero_preg(rd_addr_i[rp])) begin
                        rd_data_o[rp] = '0;
                    end else if (bypass_valid) begin
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
                if (wr_en_i[i] && !is_zero_preg(wr_addr_i[i])) begin
                    mem_generic[wr_addr_i[i]] <= wr_data_i[i];
                end
            end
        end
    end

    genvar rp_generic;
    generate
        for (rp_generic = 0; rp_generic < NUM_READ_PORTS; rp_generic++) begin : gen_generic_read
            always_comb begin
                rd_data_o[rp_generic] = is_zero_preg(rd_addr_i[rp_generic]) ? '0 : mem_generic[rd_addr_i[rp_generic]];

                for (int i = 0; i < NUM_WRITE_PORTS; i++) begin
                    if (wr_en_i[i] && !is_zero_preg(wr_addr_i[i]) && (wr_addr_i[i] == rd_addr_i[rp_generic])) begin
                        rd_data_o[rp_generic] = wr_data_i[i];
                    end
                end
            end
        end
    endgenerate
    `endif

endmodule
