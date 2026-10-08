module pmp_checker_tb_top import o3_types_pkg::*;(
 input logic clk,rst,valid_i,stall_i,
 input logic [55:0] addr_i,input logic [6:0] bytes_i,
 input logic rd_i,wr_i,ex_i,input logic [1:0] priv_i,
 input logic [127:0] cfg_i,input logic [863:0] pmpaddr_i,
 input logic [63:0] pma_addr_i,
 output logic pma_io_o,pma_amo_o,pma_rsrv_o,
 output logic pma_exec_o,pma_cache_o,pma_exists_o,pma_read_o,pma_write_o,
 output logic valid_o,allow_o,fault_o,
 output logic [7:0] entries_o,
 output logic decode_equal_o,allow_dec_o,allow_ref_o);
 pmp_state_t cfg;
 assign decode_equal_o=cfg.dec==pmp_decode_ref(cfg.entries);
 assign allow_dec_o=pmp_allow_dec(cfg.dec,addr_i,int'(bytes_i),priv_i,rd_i,wr_i,ex_i);
 assign allow_ref_o=pmp_allow(cfg,addr_i,int'(bytes_i),priv_i,rd_i,wr_i,ex_i);
 assign entries_o=8'(PMP_N);
 always_comb begin
  cfg='0;
  for(int n=0;n<PMP_N;n++) begin cfg.entries[n].cfg=cfg_i[n*8+:8];cfg.entries[n].addr=pmpaddr_i[n*54+:54];end
        cfg.dec=pmp_decode(cfg.entries);
 end
 pmp_checker #(.CFG(o3_cfg_pkg::O3_CFG.fe)) dut(.clk_i(clk),.rst_i(rst),.s2_valid_i(valid_i),
  .s2_paddr_i(addr_i),.stall_i(stall_i),.bytes_i(bytes_i),.read_i(rd_i),.write_i(wr_i),.exec_i(ex_i),
 .s3_valid_o(valid_o),.s3_allow_o(allow_o),.s3_fault_o(fault_o),.cfg_i(cfg),.priv_i(priv_i),.cfg_update_done_o());
 pma_checker #(.CFG(o3_cfg_pkg::O3_CFG.fe)) pma(.paddr_i(pma_addr_i),.bytes_i(bytes_i),
  .exec_ok_o(pma_exec_o),.cacheable_o(pma_cache_o),.exists_o(pma_exists_o),
  .read_ok_o(pma_read_o),.write_ok_o(pma_write_o),.io_o(pma_io_o),.amo_ok_o(pma_amo_o),.rsrv_ok_o(pma_rsrv_o));
endmodule
