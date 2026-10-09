module platform_pma_tb_top (
    input logic [63:0] paddr_i,
    input logic [6:0] bytes_i,
    output logic exists_o, read_ok_o, write_ok_o, exec_ok_o,
    output logic cacheable_o, io_o, amo_ok_o, rsrv_ok_o
);
    pma_checker #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut (.*);
endmodule
