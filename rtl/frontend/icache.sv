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
    output logic                      dbg_out_hit,
    output logic [1:0]                dbg_state,
    output logic [FETCH_BYTES*8-1:0]  dbg_done_data,
    output logic [ADDR_WIDTH-1:0]     dbg_miss_pc,
    output logic [ADDR_WIDTH-1:0]     dbg_miss_refill_pc
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
    localparam int WAY_INDEX_BITS = (ICACHE_WAYS > 1) ? $clog2(ICACHE_WAYS) : 1;

    typedef enum logic [1:0] {
        ICACHE_WORK,
        ICACHE_REQ,
        ICACHE_WAIT,
        ICACHE_DONE
    } icache_state_e;

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
    logic                               work_miss;
    logic                               replay_fire;
    logic                               lookup_fire;
    logic [ADDR_WIDTH-1:0]              lookup_pc;
    logic [SET_INDEX_BITS-1:0]          lookup_set_idx;
    logic [BANK_INDEX_BITS-1:0]         lookup_bank_idx;
    logic [TAG_WIDTH-1:0]               lookup_tag;
    icache_state_e                      state_q;
    logic [ADDR_WIDTH-1:0]              miss_pc_q;
    logic [ADDR_WIDTH-1:0]              miss_refill_pc_q;
    logic [SET_INDEX_BITS-1:0]          miss_set_idx_q;
    logic [BANK_INDEX_BITS-1:0]         miss_bank_idx_q;
    logic [TAG_WIDTH-1:0]               miss_tag_q;
    logic [WAY_INDEX_BITS-1:0]          miss_victim_way_q;
    logic                               refill_discard_q;
    logic [DATA_BANK_WIDTH-1:0]         done_data_q;
    logic                               done_error_q;
    logic                               replay_valid_q;
    logic [ADDR_WIDTH-1:0]              replay_pc_q;
    logic [WAY_INDEX_BITS-1:0]          selected_victim_way;
    logic [15:0]                        lfsr_out;
    logic                               lfsr_enable;

    function automatic logic [SET_INDEX_BITS-1:0] get_set_index(input logic [ADDR_WIDTH-1:0] pc);
        return pc[SET_INDEX_LSB +: SET_INDEX_BITS];
    endfunction

    function automatic logic [BANK_INDEX_BITS-1:0] get_bank_index(input logic [ADDR_WIDTH-1:0] pc);
        return pc[BANK_INDEX_LSB +: BANK_INDEX_BITS];
    endfunction

    function automatic logic [TAG_WIDTH-1:0] get_tag(input logic [ADDR_WIDTH-1:0] pc);
        return pc[TAG_LSB +: TAG_WIDTH];
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] get_line_pc(input logic [ADDR_WIDTH-1:0] pc);
        return {pc[ADDR_WIDTH-1:SET_INDEX_LSB], {SET_INDEX_LSB{1'b0}}};
    endfunction

    function automatic logic [DATA_BANK_WIDTH-1:0] get_refill_bank(
        input logic [ICACHE_BLOCK_SIZE_BYTES*8-1:0] line,
        input logic [BANK_INDEX_BITS-1:0] bank_idx
    );
        return line[bank_idx * DATA_BANK_WIDTH +: DATA_BANK_WIDTH];
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

        assert (ICACHE_WAYS > 0)
            else $fatal(1, "ICache: ICACHE_WAYS (%0d) must be greater than 0", ICACHE_WAYS);

        // 当前实现仅支持每周期取 4 条指令（4 * 4B = 16B），详见 doc/icache.md
        assert (FETCH_BYTES == 16)
            else $fatal(1, "ICache: only FETCH_BYTES == 16 (4 instructions per fetch) is supported, got %0d", FETCH_BYTES);
    end

    assign s0_ready = (state_q == ICACHE_WORK);
    assign s0_fire = s0_valid && s0_ready;
    assign replay_fire = (state_q == ICACHE_DONE) && replay_valid_q && !flush;
    assign lookup_fire = s0_fire || replay_fire;
    assign lookup_pc = replay_fire ? replay_pc_q : s0_pc;
    assign lookup_set_idx = get_set_index(lookup_pc);
    assign lookup_bank_idx = get_bank_index(lookup_pc);
    assign lookup_tag = get_tag(lookup_pc);

    assign refill_req_valid = (state_q == ICACHE_REQ) && !refill_discard_q;
    assign refill_req_pc = miss_refill_pc_q;

    assign out_hit = (state_q == ICACHE_WORK) && s1_hit;
    assign out_valid = ((state_q == ICACHE_WORK) && s1_valid_q && s1_hit && !flush) ||
                       ((state_q == ICACHE_DONE) && !refill_discard_q && !flush);
    assign out_pc = (state_q == ICACHE_DONE) ? miss_pc_q : s1_pc_q;
    assign out_data = (state_q == ICACHE_DONE) ? done_data_q : s1_selected_data;
    assign out_error = (state_q == ICACHE_DONE) ? done_error_q : 1'b0;
    assign work_miss = (state_q == ICACHE_WORK) && s1_valid_q && !s1_hit && !flush;
    assign lfsr_enable = (state_q == ICACHE_DONE);
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
    assign dbg_state = state_q;
    assign dbg_done_data = done_data_q;
    assign dbg_miss_pc = miss_pc_q;
    assign dbg_miss_refill_pc = miss_refill_pc_q;
`endif

    always_comb begin
        selected_victim_way = WAY_INDEX_BITS'(int'(lfsr_out) % ICACHE_WAYS);

        for (int way = 0; way < ICACHE_WAYS; way++) begin
            for (int bank = 0; bank < NUM_BANKS; bank++) begin
                data_bank_we[way][bank]    = 1'b0;
                data_bank_addr[way][bank]  = lookup_set_idx;
                data_bank_wdata[way][bank] = '0;
            end

            tag_array_we[way]    = 1'b0;
            tag_array_addr[way]  = lookup_set_idx;
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

        for (int way = ICACHE_WAYS - 1; way >= 0; way--) begin
            if (!valid_array_q[way][s1_set_idx_q]) begin
                selected_victim_way = WAY_INDEX_BITS'(way);
            end
        end

        if ((state_q == ICACHE_WAIT) && refill_resp_valid && !refill_resp_error && !refill_discard_q) begin
            for (int bank = 0; bank < NUM_BANKS; bank++) begin
                data_bank_we[miss_victim_way_q][bank]    = 1'b1;
                data_bank_addr[miss_victim_way_q][bank]  = miss_set_idx_q;
                data_bank_wdata[miss_victim_way_q][bank] = get_refill_bank(refill_resp_data, bank[BANK_INDEX_BITS-1:0]);
            end

            tag_array_we[miss_victim_way_q]    = 1'b1;
            tag_array_addr[miss_victim_way_q]  = miss_set_idx_q;
            tag_array_wdata[miss_victim_way_q] = miss_tag_q;
            valid_array_d[miss_victim_way_q][miss_set_idx_q] = 1'b1;
        end
    end

    assign s1_hit = |s1_way_hit;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ICACHE_WORK;
            s1_valid_q <= 1'b0;
            s1_pc_q <= '0;
            s1_set_idx_q <= '0;
            s1_bank_idx_q <= '0;
            s1_tag_q <= '0;
            miss_pc_q <= '0;
            miss_refill_pc_q <= '0;
            miss_set_idx_q <= '0;
            miss_bank_idx_q <= '0;
            miss_tag_q <= '0;
            miss_victim_way_q <= '0;
            refill_discard_q <= 1'b0;
            done_data_q <= '0;
            done_error_q <= 1'b0;
            replay_valid_q <= 1'b0;
            replay_pc_q <= '0;

            for (int way = 0; way < ICACHE_WAYS; way++) begin
                for (int set = 0; set < NUM_SETS; set++) begin
                    `ifdef O3_ICACHE_WAY0_VALID
                    valid_array_q[way][set] <= (way == 0) ? valid_array_q[way][set] : 1'b0;
                    `else
                    valid_array_q[way][set] <= 1'b0;
                    `endif
                end
            end
        end else if (flush) begin
            s1_valid_q <= 1'b0;
            s1_pc_q <= '0;
            s1_set_idx_q <= '0;
            s1_bank_idx_q <= '0;
            s1_tag_q <= '0;
            replay_valid_q <= 1'b0;
            replay_pc_q <= '0;

            unique case (state_q)
                ICACHE_REQ: begin
                    state_q <= ICACHE_WAIT;
                    refill_discard_q <= 1'b1;
                end
                ICACHE_WAIT: begin
                    state_q <= refill_resp_valid ? ICACHE_WORK : ICACHE_WAIT;
                    refill_discard_q <= refill_resp_valid ? 1'b0 : 1'b1;
                end
                default: begin
                    state_q <= ICACHE_WORK;
                    refill_discard_q <= 1'b0;
                end
            endcase

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
            s1_valid_q <= 1'b0;

            unique case (state_q)
                ICACHE_WORK: begin
                    if (work_miss) begin
                        state_q <= ICACHE_REQ;
                        miss_pc_q <= s1_pc_q;
                        miss_refill_pc_q <= get_line_pc(s1_pc_q);
                        miss_set_idx_q <= s1_set_idx_q;
                        miss_bank_idx_q <= s1_bank_idx_q;
                        miss_tag_q <= s1_tag_q;
                        miss_victim_way_q <= selected_victim_way;
                        refill_discard_q <= 1'b0;
                        replay_valid_q <= s0_fire;
                        if (s0_fire) begin
                            replay_pc_q <= s0_pc;
                        end
                    end else begin
                        state_q <= ICACHE_WORK;
                        s1_valid_q <= lookup_fire;
                        if (lookup_fire) begin
                            s1_pc_q <= lookup_pc;
                            s1_set_idx_q <= lookup_set_idx;
                            s1_bank_idx_q <= lookup_bank_idx;
                            s1_tag_q <= lookup_tag;
                        end
                    end
                end

                ICACHE_REQ: begin
                    state_q <= ICACHE_WAIT;
                end

                ICACHE_WAIT: begin
                    if (refill_resp_valid) begin
                        assert (refill_resp_pc == miss_refill_pc_q)
                            else $fatal(1, "ICache: refill response PC mismatch");
                        if (refill_discard_q) begin
                            state_q <= ICACHE_WORK;
                            refill_discard_q <= 1'b0;
                        end else begin
                            state_q <= ICACHE_DONE;
                            done_error_q <= refill_resp_error;
                            done_data_q <= refill_resp_error ?
                                           {DATA_BANK_WIDTH{1'b1}} :
                                           get_refill_bank(refill_resp_data, miss_bank_idx_q);
                        end
                    end
                end

                ICACHE_DONE: begin
                    state_q <= ICACHE_WORK;
                    refill_discard_q <= 1'b0;
                    replay_valid_q <= 1'b0;
                    s1_valid_q <= replay_fire;
                    if (replay_fire) begin
                        s1_pc_q <= lookup_pc;
                        s1_set_idx_q <= lookup_set_idx;
                        s1_bank_idx_q <= lookup_bank_idx;
                        s1_tag_q <= lookup_tag;
                    end
                end

                default: begin
                    state_q <= ICACHE_WORK;
                end
            endcase

            for (int way = 0; way < ICACHE_WAYS; way++) begin
                for (int set = 0; set < NUM_SETS; set++) begin
                    valid_array_q[way][set] <= valid_array_d[way][set];
                end
            end
        end
    end

    lfsr u_replacement_lfsr (
        .clk      (clk),
        .rst      (rst),
        .enable   (lfsr_enable),
        .lfsr_out (lfsr_out)
    );

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
