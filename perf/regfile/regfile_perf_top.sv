module regfile_perf_top #(
    parameter int NUM_READ_PORTS  = 8,
    parameter int NUM_WRITE_PORTS = 4,
    parameter int NUM_ENTRIES     = 64,
    parameter int DATA_WIDTH      = 64
)(
    input  logic clk_i,
    input  logic rst_i,
    output logic [31:0] signature_consistent_o,
    output logic [31:0] signature_latest_o,
    output logic [31:0] mismatch_count_o
);
    localparam int ADDR_WIDTH = $clog2(NUM_ENTRIES);

    logic [ADDR_WIDTH-1:0] rd_addr   [NUM_READ_PORTS];
    logic [DATA_WIDTH-1:0] rd_data_a [NUM_READ_PORTS];
    logic [DATA_WIDTH-1:0] rd_data_b [NUM_READ_PORTS];

    logic                  wr_en     [NUM_WRITE_PORTS];
    logic [ADDR_WIDTH-1:0] wr_addr   [NUM_WRITE_PORTS];
    logic [DATA_WIDTH-1:0] wr_data   [NUM_WRITE_PORTS];

    logic [31:0] lfsr_q;
    logic [31:0] sig_a_q;
    logic [31:0] sig_b_q;
    logic [31:0] mismatch_q;

    (* DONT_TOUCH = "true", KEEP_HIERARCHY = "yes" *)
    perf_physical_regfile_force_consistent #(
        .NUM_READ_PORTS(NUM_READ_PORTS),
        .NUM_WRITE_PORTS(NUM_WRITE_PORTS),
        .NUM_ENTRIES(NUM_ENTRIES),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_force_consistent (
        .clk(clk_i),
        .rst(rst_i),
        .rd_addr_i(rd_addr),
        .rd_data_o(rd_data_a),
        .wr_en_i(wr_en),
        .wr_addr_i(wr_addr),
        .wr_data_i(wr_data)
    );

    (* DONT_TOUCH = "true", KEEP_HIERARCHY = "yes" *)
    perf_physical_regfile_latest_tag #(
        .NUM_READ_PORTS(NUM_READ_PORTS),
        .NUM_WRITE_PORTS(NUM_WRITE_PORTS),
        .NUM_ENTRIES(NUM_ENTRIES),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_latest_tag (
        .clk(clk_i),
        .rst(rst_i),
        .rd_addr_i(rd_addr),
        .rd_data_o(rd_data_b),
        .wr_en_i(wr_en),
        .wr_addr_i(wr_addr),
        .wr_data_i(wr_data)
    );

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            lfsr_q <= 32'h1;
        end else begin
            lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
        end
    end

    always_comb begin
        for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
            wr_en[wp]   = lfsr_q[wp] | lfsr_q[wp + 8];
            wr_addr[wp] = ADDR_WIDTH'((lfsr_q ^ (32'(wp) * 32'h9e3779b9)));
            wr_data[wp] = DATA_WIDTH'({lfsr_q, lfsr_q} ^ (64'(wp) * 64'h1f123bb5a5a5a5a5));
        end
        for (int rp = 0; rp < NUM_READ_PORTS; rp++) begin
            rd_addr[rp] = ADDR_WIDTH'((lfsr_q >> (rp % 16)) ^ (32'(rp) * 32'h45d9f3b));
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            sig_a_q    <= 32'h0;
            sig_b_q    <= 32'h0;
            mismatch_q <= 32'h0;
        end else begin
            logic [31:0] fold_a;
            logic [31:0] fold_b;
            fold_a = 32'h0;
            fold_b = 32'h0;
            for (int rp = 0; rp < NUM_READ_PORTS; rp++) begin
                fold_a ^= rd_data_a[rp][31:0] ^ rd_data_a[rp][63:32] ^ (32'(rp) * 32'h10001);
                fold_b ^= rd_data_b[rp][31:0] ^ rd_data_b[rp][63:32] ^ (32'(rp) * 32'h20001);
            end
            sig_a_q <= sig_a_q ^ fold_a ^ lfsr_q;
            sig_b_q <= sig_b_q ^ fold_b ^ {lfsr_q[15:0], lfsr_q[31:16]};
            if (fold_a != fold_b) begin
                mismatch_q <= mismatch_q + 1'b1;
            end
        end
    end

    (* DONT_TOUCH = "true" *) assign signature_consistent_o = sig_a_q;
    (* DONT_TOUCH = "true" *) assign signature_latest_o     = sig_b_q;
    (* DONT_TOUCH = "true" *) assign mismatch_count_o       = mismatch_q;

endmodule
