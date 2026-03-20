module physical_regfile_force_consistent
    import o3_pkg::*;
#(
    parameter int NUM_READ_PORTS  = 8,
    parameter int NUM_WRITE_PORTS = 4,
    parameter int NUM_ENTRIES     = 64,
    parameter int DATA_WIDTH      = 64
)(
    input  logic clk,
    input  logic rst,
    input  logic [$clog2(NUM_ENTRIES)-1:0] rd_addr_i [NUM_READ_PORTS],
    output logic [DATA_WIDTH-1:0]          rd_data_o [NUM_READ_PORTS],
    input  logic                           wr_en_i   [NUM_WRITE_PORTS],
    input  logic [$clog2(NUM_ENTRIES)-1:0] wr_addr_i [NUM_WRITE_PORTS],
    input  logic [DATA_WIDTH-1:0]          wr_data_i [NUM_WRITE_PORTS]
);
    physical_regfile #(
        .NUM_READ_PORTS(NUM_READ_PORTS),
        .NUM_WRITE_PORTS(NUM_WRITE_PORTS),
        .NUM_ENTRIES(NUM_ENTRIES),
        .DATA_WIDTH(DATA_WIDTH),
        .USE_BANK_LATEST_TAG(1'b0)
    ) u_physical_regfile (
        .clk(clk),
        .rst(rst),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(rd_data_o),
        .wr_en_i(wr_en_i),
        .wr_addr_i(wr_addr_i),
        .wr_data_i(wr_data_i)
    );
endmodule

module physical_regfile_latest_tag
    import o3_pkg::*;
#(
    parameter int NUM_READ_PORTS  = 8,
    parameter int NUM_WRITE_PORTS = 4,
    parameter int NUM_ENTRIES     = 64,
    parameter int DATA_WIDTH      = 64
)(
    input  logic clk,
    input  logic rst,
    input  logic [$clog2(NUM_ENTRIES)-1:0] rd_addr_i [NUM_READ_PORTS],
    output logic [DATA_WIDTH-1:0]          rd_data_o [NUM_READ_PORTS],
    input  logic                           wr_en_i   [NUM_WRITE_PORTS],
    input  logic [$clog2(NUM_ENTRIES)-1:0] wr_addr_i [NUM_WRITE_PORTS],
    input  logic [DATA_WIDTH-1:0]          wr_data_i [NUM_WRITE_PORTS]
);
    physical_regfile #(
        .NUM_READ_PORTS(NUM_READ_PORTS),
        .NUM_WRITE_PORTS(NUM_WRITE_PORTS),
        .NUM_ENTRIES(NUM_ENTRIES),
        .DATA_WIDTH(DATA_WIDTH),
        .USE_BANK_LATEST_TAG(1'b1)
    ) u_physical_regfile (
        .clk(clk),
        .rst(rst),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(rd_data_o),
        .wr_en_i(wr_en_i),
        .wr_addr_i(wr_addr_i),
        .wr_data_i(wr_data_i)
    );
endmodule
