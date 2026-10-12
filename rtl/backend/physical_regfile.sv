/**
 * Domain-parametric multiport physical register file (B15).
 * INT p0 reads zero and ignores writes. FP p0 is writable. Read/write port counts come from CFG;
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
        if (NUM_WRITE_PORTS==1) begin : gen_single_write
            // A single writer needs no latest-tag bank dimension. Each generated
            // read replica is a one-dimensional, single-write distributed RAM.
            // No data reset: matches the existing FPGA storage contract.
            for(genvar rp=0;rp<NUM_READ_PORTS;rp++) begin : g_read_replica
                (* ram_style="distributed" *) logic [DATA_WIDTH-1:0] mem [NUM_ENTRIES];
                always_ff @(posedge clk) if(!rst && wr_en_i[0] && !is_zero_preg(wr_addr_i[0]))
                    mem[wr_addr_i[0]]<=wr_data_i[0];
                always_comb begin
                    if(is_zero_preg(rd_addr_i[rp])) rd_data_o[rp]='0;
                    else if(wr_en_i[0] && !is_zero_preg(wr_addr_i[0]) && wr_addr_i[0]==rd_addr_i[rp])
                        rd_data_o[rp]=wr_data_i[0];
                    else rd_data_o[rp]=mem[rd_addr_i[rp]];
                end
            end
        end else if (USE_NO_BANK_FLAT_CFG) begin : gen_impl_no_bank_flat
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
            logic [BANK_SEL_WIDTH-1:0] latest_bank [NUM_ENTRIES];
            logic [DATA_WIDTH-1:0] bank_read [NUM_READ_PORTS][NUM_WRITE_PORTS];
            // Each bank/replica is structurally a single-writer one-dimensional
            // RAM, including a non-power-of-two number of writers. No data reset.
            for(genvar wb=0;wb<NUM_WRITE_PORTS;wb++) begin : g_bank
                for(genvar rp=0;rp<NUM_READ_PORTS;rp++) begin : g_replica
                    (* ram_style="distributed" *) logic [DATA_WIDTH-1:0] mem[NUM_ENTRIES];
                    always_ff @(posedge clk)
                        if(!rst && wr_en_i[wb] && !is_zero_preg(wr_addr_i[wb]))
                            mem[wr_addr_i[wb]]<=wr_data_i[wb];
                    assign bank_read[rp][wb]=mem[rd_addr_i[rp]];
                end
            end
            for(genvar row=0;row<NUM_ENTRIES;row++) begin : g_latest
                always_ff @(posedge clk) begin
                    if(rst) latest_bank[row]<='0;
                    else for(int wb=0;wb<NUM_WRITE_PORTS;wb++)
                        if(wr_en_i[wb] && !is_zero_preg(wr_addr_i[wb]) && wr_addr_i[wb]==ADDR_WIDTH'(row))
                            latest_bank[row]<=BANK_SEL_WIDTH'(wb);
                end
            end
            for(genvar rp=0;rp<NUM_READ_PORTS;rp++) begin : g_read
                logic bypass_valid;
                logic [DATA_WIDTH-1:0] stored,bypass_data;
                always_comb begin
                    stored='0;bypass_data='0;bypass_valid=0;
                    for(int wb=0;wb<NUM_WRITE_PORTS;wb++) begin
                        stored|=bank_read[rp][wb] &
                            {DATA_WIDTH{latest_bank[rd_addr_i[rp]]==BANK_SEL_WIDTH'(wb)}};
                        if(wr_en_i[wb] && !is_zero_preg(wr_addr_i[wb]) && wr_addr_i[wb]==rd_addr_i[rp]) begin
                            bypass_valid=1;bypass_data=wr_data_i[wb];
                        end
                    end
                    rd_data_o[rp]=is_zero_preg(rd_addr_i[rp]) ? '0 : bypass_valid ? bypass_data:stored;
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
