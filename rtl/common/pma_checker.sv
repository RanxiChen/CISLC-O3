/** L8b complete-range PMA; two adjacent regions never combine authorization. */
module pma_checker import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
)(input logic [63:0] paddr_i,input logic [6:0] bytes_i,
  output logic exec_ok_o,cacheable_o,exists_o,read_ok_o,write_ok_o,io_o,amo_ok_o,rsrv_ok_o);
    assign cacheable_o=pma_main(paddr_i,int'(bytes_i));
    assign io_o=pma_io(paddr_i,int'(bytes_i));
    assign exec_ok_o=cacheable_o;
    assign exists_o=cacheable_o || io_o;
    assign read_ok_o=exists_o; assign write_ok_o=exists_o;
    assign amo_ok_o=cacheable_o; assign rsrv_ok_o=cacheable_o;
endmodule
