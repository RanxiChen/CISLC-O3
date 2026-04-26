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
    input logic clk,
    input logic rst,
    input logic [ADDR_WIDTH-1:0] addr
    
);
    
endmodule