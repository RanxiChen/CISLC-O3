/**
* 这个文件讲用来存放使用的ICache
*/

module ICache #(
    parameter int ADDR_WIDTH = 64,
    parameter int ICACHE_WAYS = 4,
    parameter int ICACHE_BLOCK_SIZE_BYTES = 64,
    parameter int FETCH_BYTES = 16,
    parameter int NUM_SETS = 64
) (
    input  logic                      clk,
    input  logic                      rst,
    input  logic                      flush,
    input  logic                      s0_valid,
    output logic                      s0_ready,
    input  logic [ADDR_WIDTH-1:0]     s0_pc,
    output logic                      refill_req_valid,
    output logic [ADDR_WIDTH-1:0]     refill_req_pc,
    input  logic                      refill_resp_valid,
    input  logic [ADDR_WIDTH-1:0]     refill_resp_pc,
    input  logic                      refill_resp_error,
    input  logic [ICACHE_BLOCK_SIZE_BYTES*8-1:0] refill_resp_data,
    output logic                      out_valid,
    output logic                      out_hit,
    output logic [ADDR_WIDTH-1:0]     out_pc,
    output logic [FETCH_BYTES*8-1:0]  out_data,
    output logic                      out_error
`ifdef O3_ICACHE_DEBUG
    ,
    output logic                      dbg_s0_fire,
    output logic                      dbg_s1_valid,
    output logic [ADDR_WIDTH-1:0]     dbg_s1_pc,
    output logic [$clog2(NUM_SETS)-1:0] dbg_s1_set_idx,
    output logic [$clog2(ICACHE_BLOCK_SIZE_BYTES / FETCH_BYTES)-1:0] dbg_s1_bank_idx,
    output logic [ADDR_WIDTH - (2 + $clog2(FETCH_BYTES / 4) + $clog2(ICACHE_BLOCK_SIZE_BYTES / FETCH_BYTES) + $clog2(NUM_SETS)) - 1:0] dbg_s1_tag,
    output logic [ICACHE_WAYS-1:0]    dbg_s1_way_hit,
    output logic                      dbg_out_valid,
    output logic                      dbg_out_hit
`endif
);

    // 一条 cache line 按 FETCH_BYTES 横向切分得到的 bank 数
    localparam int NUM_BANKS = ICACHE_BLOCK_SIZE_BYTES / FETCH_BYTES;
    localparam int DATA_BANK_WIDTH = FETCH_BYTES * 8;
    localparam int BYTE_OFFSET_BITS = 2;
    localparam int WORD_INDEX_BITS = $clog2(FETCH_BYTES / 4);
    localparam int BANK_INDEX_BITS = $clog2(NUM_BANKS);
    localparam int SET_INDEX_BITS = $clog2(NUM_SETS);
    localparam int BANK_INDEX_LSB = BYTE_OFFSET_BITS + WORD_INDEX_BITS;
    localparam int SET_INDEX_LSB = BANK_INDEX_LSB + BANK_INDEX_BITS;
    localparam int TAG_LSB = SET_INDEX_LSB + SET_INDEX_BITS;
    localparam int TAG_WIDTH = ADDR_WIDTH - TAG_LSB;
    localparam int TAG_ARRAY_WIDTH = TAG_WIDTH;

    logic                               data_bank_we   [ICACHE_WAYS][NUM_BANKS];
    logic [$clog2(NUM_SETS)-1:0]        data_bank_addr [ICACHE_WAYS][NUM_BANKS];
    logic [DATA_BANK_WIDTH-1:0]         data_bank_wdata[ICACHE_WAYS][NUM_BANKS];
    logic [DATA_BANK_WIDTH-1:0]         data_bank_rdata[ICACHE_WAYS][NUM_BANKS];
    logic                               tag_array_we   [ICACHE_WAYS];
    logic [$clog2(NUM_SETS)-1:0]        tag_array_addr [ICACHE_WAYS];
    logic [TAG_ARRAY_WIDTH-1:0]         tag_array_wdata[ICACHE_WAYS];
    logic [TAG_ARRAY_WIDTH-1:0]         tag_array_rdata[ICACHE_WAYS];
    logic                               valid_array_q  [ICACHE_WAYS][NUM_SETS];
    logic                               valid_array_d  [ICACHE_WAYS][NUM_SETS];
    logic                               s0_fire;
    logic [SET_INDEX_BITS-1:0]          s0_set_idx;
    logic [BANK_INDEX_BITS-1:0]         s0_bank_idx;
    logic [TAG_WIDTH-1:0]               s0_tag;
    logic                               s1_valid_q;
    logic [ADDR_WIDTH-1:0]              s1_pc_q;
    logic [SET_INDEX_BITS-1:0]          s1_set_idx_q;
    logic [BANK_INDEX_BITS-1:0]         s1_bank_idx_q;
    logic [TAG_WIDTH-1:0]               s1_tag_q;
    logic [ICACHE_WAYS-1:0]             s1_way_hit;
    logic [ICACHE_WAYS-1:0]             s1_way_valid;
    logic [DATA_BANK_WIDTH-1:0]         s1_way_data [ICACHE_WAYS];
    logic [DATA_BANK_WIDTH-1:0]         s1_selected_data;
    logic                               s1_hit;

    function automatic logic [SET_INDEX_BITS-1:0] get_set_index(input logic [ADDR_WIDTH-1:0] pc);
        return pc[SET_INDEX_LSB +: SET_INDEX_BITS];
    endfunction

    function automatic logic [BANK_INDEX_BITS-1:0] get_bank_index(input logic [ADDR_WIDTH-1:0] pc);
        return pc[BANK_INDEX_LSB +: BANK_INDEX_BITS];
    endfunction

    function automatic logic [TAG_WIDTH-1:0] get_tag(input logic [ADDR_WIDTH-1:0] pc);
        return pc[TAG_LSB +: TAG_WIDTH];
    endfunction

    // ---- 参数合法性检查 ----
    initial begin
        assert (ICACHE_BLOCK_SIZE_BYTES % FETCH_BYTES == 0)
            else $fatal(1, "ICache: ICACHE_BLOCK_SIZE_BYTES (%0d) must be an integer multiple of FETCH_BYTES (%0d)",
                        ICACHE_BLOCK_SIZE_BYTES, FETCH_BYTES);

        assert ((FETCH_BYTES & (FETCH_BYTES - 1)) == 0)
            else $fatal(1, "ICache: FETCH_BYTES (%0d) must be a power of 2", FETCH_BYTES);

        assert ((ICACHE_BLOCK_SIZE_BYTES & (ICACHE_BLOCK_SIZE_BYTES - 1)) == 0)
            else $fatal(1, "ICache: ICACHE_BLOCK_SIZE_BYTES (%0d) must be a power of 2", ICACHE_BLOCK_SIZE_BYTES);

        assert ((NUM_SETS & (NUM_SETS - 1)) == 0)
            else $fatal(1, "ICache: NUM_SETS (%0d) must be a power of 2", NUM_SETS);

        // 当前实现仅支持每周期取 4 条指令（4 * 4B = 16B），详见 doc/icache.md
        assert (FETCH_BYTES == 16)
            else $fatal(1, "ICache: only FETCH_BYTES == 16 (4 instructions per fetch) is supported, got %0d", FETCH_BYTES);
    end

    assign s0_ready = 1'b1;
    assign s0_fire = s0_valid && s0_ready;
    assign s0_set_idx = get_set_index(s0_pc);
    assign s0_bank_idx = get_bank_index(s0_pc);
    assign s0_tag = get_tag(s0_pc);

    assign refill_req_valid = 1'b0;
    assign refill_req_pc = '0;

    assign out_hit = s1_hit;
    assign out_valid = s1_valid_q && s1_hit;
    assign out_pc = s1_pc_q;
    assign out_data = s1_selected_data;
    assign out_error = 1'b0;
`ifdef O3_ICACHE_DEBUG
    assign dbg_s0_fire = s0_fire;
    assign dbg_s1_valid = s1_valid_q;
    assign dbg_s1_pc = s1_pc_q;
    assign dbg_s1_set_idx = s1_set_idx_q;
    assign dbg_s1_bank_idx = s1_bank_idx_q;
    assign dbg_s1_tag = s1_tag_q;
    assign dbg_s1_way_hit = s1_way_hit;
    assign dbg_out_valid = out_valid;
    assign dbg_out_hit = out_hit;
`endif

    always_comb begin
        for (int way = 0; way < ICACHE_WAYS; way++) begin
            for (int bank = 0; bank < NUM_BANKS; bank++) begin
                data_bank_we[way][bank]    = 1'b0;
                data_bank_addr[way][bank]  = s0_set_idx;
                data_bank_wdata[way][bank] = '0;
            end

            tag_array_we[way]    = 1'b0;
            tag_array_addr[way]  = s0_set_idx;
            tag_array_wdata[way] = '0;

            for (int set = 0; set < NUM_SETS; set++) begin
                valid_array_d[way][set] = valid_array_q[way][set];
            end
        end

        for (int way = 0; way < ICACHE_WAYS; way++) begin
            s1_way_valid[way] = valid_array_q[way][s1_set_idx_q];
            s1_way_hit[way] = s1_valid_q && s1_way_valid[way] && (tag_array_rdata[way] == s1_tag_q);
            s1_way_data[way] = data_bank_rdata[way][s1_bank_idx_q];
        end

        s1_selected_data = '0;
        for (int way = 0; way < ICACHE_WAYS; way++) begin
            if (s1_way_hit[way]) begin
                s1_selected_data = s1_way_data[way];
            end
        end
    end

    assign s1_hit = |s1_way_hit;

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            s1_valid_q <= 1'b0;
            s1_pc_q <= '0;
            s1_set_idx_q <= '0;
            s1_bank_idx_q <= '0;
            s1_tag_q <= '0;

            for (int way = 0; way < ICACHE_WAYS; way++) begin
                for (int set = 0; set < NUM_SETS; set++) begin
                    `ifdef O3_ICACHE_WAY0_VALID
                    valid_array_q[way][set] <= (way == 0) ? valid_array_q[way][set] : 1'b0;
                    `else
                    valid_array_q[way][set] <= 1'b0;
                    `endif
                end
            end
        end else begin
            s1_valid_q <= s0_fire;
            if (s0_fire) begin
                s1_pc_q <= s0_pc;
                s1_set_idx_q <= s0_set_idx;
                s1_bank_idx_q <= s0_bank_idx;
                s1_tag_q <= s0_tag;
            end

            for (int way = 0; way < ICACHE_WAYS; way++) begin
                for (int set = 0; set < NUM_SETS; set++) begin
                    valid_array_q[way][set] <= valid_array_d[way][set];
                end
            end
        end
    end

    for (genvar way = 0; way < ICACHE_WAYS; way++) begin : gen_data_way
        for (genvar bank = 0; bank < NUM_BANKS; bank++) begin : gen_data_bank
            `ifdef O3_SIM
            o3_sram #(
                .DATA_WIDTH(DATA_BANK_WIDTH),
                .SRAM_ENTRIES(NUM_SETS),
                .INIT_FILE(
                    (way == 0 && bank == 0) ? "hex/data_way0_bank0.hex" :
                    (way == 0 && bank == 1) ? "hex/data_way0_bank1.hex" :
                    (way == 0 && bank == 2) ? "hex/data_way0_bank2.hex" :
                    (way == 0 && bank == 3) ? "hex/data_way0_bank3.hex" :
                    ""
                )
            ) u_data_sram (
                .clk_i  (clk),
                .rst_i  (rst),
                .we_i   (data_bank_we[way][bank]),
                .data_o (data_bank_rdata[way][bank]),
                .data_i (data_bank_wdata[way][bank]),
                .addr_i (data_bank_addr[way][bank])
            );
            `else
            o3_sram #(
                .DATA_WIDTH(DATA_BANK_WIDTH),
                .SRAM_ENTRIES(NUM_SETS)
            ) u_data_sram (
                .clk_i  (clk),
                .rst_i  (rst),
                .we_i   (data_bank_we[way][bank]),
                .data_o (data_bank_rdata[way][bank]),
                .data_i (data_bank_wdata[way][bank]),
                .addr_i (data_bank_addr[way][bank])
            );
            `endif
        end

        `ifdef O3_SIM
        o3_sram #(
            .DATA_WIDTH(TAG_ARRAY_WIDTH),
            .SRAM_ENTRIES(NUM_SETS),
            .INIT_FILE((way == 0) ? "hex/tag_way0.hex" : "")
        ) u_tag_sram (
            .clk_i  (clk),
            .rst_i  (rst),
            .we_i   (tag_array_we[way]),
            .data_o (tag_array_rdata[way]),
            .data_i (tag_array_wdata[way]),
            .addr_i (tag_array_addr[way])
        );
        `else
        o3_sram #(
            .DATA_WIDTH(TAG_ARRAY_WIDTH),
            .SRAM_ENTRIES(NUM_SETS)
        ) u_tag_sram (
            .clk_i  (clk),
            .rst_i  (rst),
            .we_i   (tag_array_we[way]),
            .data_o (tag_array_rdata[way]),
            .data_i (tag_array_wdata[way]),
            .addr_i (tag_array_addr[way])
        );
        `endif
    end

    `ifdef O3_ICACHE_WAY0_VALID
    initial begin
        for (int s = 0; s < NUM_SETS; s++) begin
            valid_array_q[0][s] = 1'b1;
        end
    end
    `endif

endmodule
