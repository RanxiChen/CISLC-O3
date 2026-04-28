/**
* There are single port srams in the design
*/

module o3_sram #(
    parameter int DATA_WIDTH = 32,
    parameter int SRAM_ENTRIES = 256
`ifdef O3_SIM
    ,
    parameter string INIT_FILE = ""
`endif
)(
    input logic clk_i,
    input logic rst_i,
    input logic we_i,
    output logic [DATA_WIDTH-1:0] data_o,
    input logic [DATA_WIDTH-1:0] data_i,
    input logic [$clog2(SRAM_ENTRIES)-1:0] addr_i
);
`ifdef O3_SIM
logic [DATA_WIDTH-1:0] SRAM_MEM [0:SRAM_ENTRIES-1];
`else
(* ram_style = "block" *) logic [DATA_WIDTH-1:0] SRAM_MEM [0:SRAM_ENTRIES-1];
`endif

`ifdef O3_SIM
initial begin
    if (INIT_FILE != "") begin
        $readmemh(INIT_FILE, SRAM_MEM);
    end else begin
        for (int i = 0; i < SRAM_ENTRIES; i++) begin
            SRAM_MEM[i] = '0;
        end
    end
end
`endif

always_ff @(posedge clk_i) begin
    if (we_i) begin
        SRAM_MEM[addr_i] <= data_i;
    end
    data_o <= SRAM_MEM[addr_i];
end
endmodule
