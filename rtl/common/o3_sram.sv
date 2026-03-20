/**
* There are single port srams in the design
*/

module o3_sram #(
    parameter int DATA_WIDTH = 32,
    parameter int SRAM_ENTRIES = 256,
    parameter string INIT_FILE = ""
)(
    input logic clk_i,
    input logic rst_i,
    input logic we_i,
    output logic [DATA_WIDTH-1:0] data_o,
    input logic [DATA_WIDTH-1:0] data_i,
    input logic [$clog2(SRAM_ENTRIES)-1:0] addr_i
);
// core struct
logic [DATA_WIDTH-1:0] SRAM_MEM [0:SRAM_ENTRIES-1];

`ifndef O3_SIM
// Force a compile-time error unless O3_SIM is defined.
O3_SIM_IS_REQUIRED__DEFINE_O3_SIM u_o3_sim_is_required();
`endif

always_ff @(posedge clk_i) begin
    if (rst_i) begin
        // reset logic if needed
`ifdef O3_SIM
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, SRAM_MEM);
        end else begin
            for (int i = 0; i < SRAM_ENTRIES; i++) begin
                SRAM_MEM[i] <= '0;
            end
        end
`else
        for (int i = 0; i < SRAM_ENTRIES; i++) begin
            SRAM_MEM[i] <= '0;
        end
`endif
    end else if (we_i) begin
        SRAM_MEM[addr_i] <= data_i;
    end
    data_o <= SRAM_MEM[addr_i];
end
endmodule
