/** L11 platform PMA: complete access must fit a single JSON-defined region.
 * 当前实现状态：目标实现；功能测试待补充。 */
module pma_checker import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::frontend_cfg_t CFG
)(input logic [63:0] paddr_i,input logic [6:0] bytes_i,
  output logic exec_ok_o,cacheable_o,exists_o,read_ok_o,write_ok_o,io_o,amo_ok_o,rsrv_ok_o);
    o3_platform_pkg::pma_attr_t attr;
    assign attr=o3_platform_pkg::lookup(paddr_i,int'(bytes_i));
    assign cacheable_o=attr.cacheable;
    assign io_o=attr.device;
    assign exec_ok_o=attr.executable;
    assign exists_o=attr.exists;
    assign read_ok_o=attr.readable; assign write_ok_o=attr.writable;
    assign amo_ok_o=attr.amo; assign rsrv_ok_o=attr.rsrv;
endmodule
