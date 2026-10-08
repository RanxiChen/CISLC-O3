module mmio_axil_master_tb_top import o3_types_pkg::*;
(input logic clk,rst,req_valid_i,output logic req_ready_o,input logic write_i,
 input paddr_t paddr_i,input vaddr_t vaddr_i,input logic [1:0] size_i,input logic signed_i,flw_i,
 input logic [63:0] data_i,input logic [7:0] mask_i,
 output logic resp_valid_o,input logic resp_ready_i,output logic [63:0] rdata_o,
 output logic error_o,output exc_info_t exc_o,output logic irreversible_o,
 output logic m_axil_awvalid,input logic m_axil_awready,output logic [31:0] m_axil_awaddr,output logic [2:0] m_axil_awprot,
 output logic m_axil_wvalid,input logic m_axil_wready,output logic [63:0] m_axil_wdata,output logic [7:0] m_axil_wstrb,
 input logic m_axil_bvalid,output logic m_axil_bready,input logic [1:0] m_axil_bresp,
 output logic m_axil_arvalid,input logic m_axil_arready,output logic [31:0] m_axil_araddr,output logic [2:0] m_axil_arprot,
 input logic m_axil_rvalid,output logic m_axil_rready,input logic [63:0] m_axil_rdata,input logic [1:0] m_axil_rresp);
 dcache_req_t req_i;dcache_resp_t resp_o;
 always_comb begin
  req_i='0;req_i.write=write_i;req_i.paddr=paddr_i;req_i.vaddr=vaddr_i;req_i.size=size_i;
  req_i.is_signed=signed_i;req_i.is_flw=flw_i;req_i.wdata=data_i;req_i.wmask=mask_i;
 end
 assign rdata_o=resp_o.rdata;assign error_o=resp_o.status==DC_ERROR;assign exc_o=resp_o.exc;
 mmio_axil_master #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.*);
endmodule
