/**
 * One synchronous read and one synchronous write port. The caller must
 * exclude same-address read/write; FPGA read-during-write behavior varies.
 *
 * Cycle N: read_en_i samples read_addr_i at the edge.
 * Cycle N+1: read_data_o holds that word until the next enabled read.
 *
 * 当前实现状态：目标实现
 * - 为 ICache 实现独立读/写地址；同址同拍访问由调用方禁止并断言。
 * - 测试：sim/cocotb/o3_sram_1r1w/
 */
module o3_sram_1r1w #(
    parameter int DATA_WIDTH = 128,
    parameter int ENTRIES = 128,
    parameter bit ALLOW_COLLISION = 0
) (
    input  logic clk_i,
    input  logic read_en_i,
    input  logic [$clog2(ENTRIES)-1:0] read_addr_i,
    output logic [DATA_WIDTH-1:0] read_data_o,
    input  logic write_en_i,
    input  logic [$clog2(ENTRIES)-1:0] write_addr_i,
    input  logic [DATA_WIDTH-1:0] write_data_i
);
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [0:ENTRIES-1];

    always_ff @(posedge clk_i) begin
        if (read_en_i) begin
            read_data_o <= mem[read_addr_i];
`ifndef SYNTHESIS
            if(ALLOW_COLLISION && write_en_i && read_addr_i==write_addr_i)
                read_data_o <= ~mem[read_addr_i];
`endif
        end
        if (write_en_i) begin
            mem[write_addr_i] <= write_data_i;
        end
        assert (ALLOW_COLLISION || !(read_en_i && write_en_i && read_addr_i == write_addr_i))
            else $error("o3_sram_1r1w: same-address read/write");
    end
endmodule
