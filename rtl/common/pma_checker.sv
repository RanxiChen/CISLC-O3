/** L10 X12: combinational attributes for the complete physical byte range.
 * Keep 64 input bits: Bare VA high bits must fault, rather than truncate.
 * Current implementation: target implementation. L11 adds MMIO to the map.
 */
module pma_checker import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
)(input logic [63:0] paddr_i,input logic [6:0] bytes_i,
  output logic exec_ok_o,cacheable_o,exists_o,read_ok_o,write_ok_o);
    assign cacheable_o=pma_main(paddr_i,int'(bytes_i));
    assign exec_ok_o=cacheable_o;
    assign exists_o=cacheable_o || pma_dtcm(paddr_i,int'(bytes_i));
    assign read_ok_o=exists_o;
    assign write_ok_o=exists_o;
endmodule
