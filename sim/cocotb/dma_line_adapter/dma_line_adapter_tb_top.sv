module dma_line_adapter_tb_top import o3_types_pkg::*;
(input logic clk,rst,req_valid_i,output logic req_ready_o,input logic write_i,
 input paddr_t paddr_i,input logic [511:0] data_i,input logic [63:0] mask_i,
 output logic resp_valid_o,input logic resp_ready_i,output logic error_o,output logic [511:0] rdata_o,
 output logic coh_req_valid_o,input logic coh_req_ready_i,output coh_req_t coh_req_o,
 input logic coh_resp_valid_i,output logic coh_resp_ready_o,input coh_rsp_down_t coh_resp_i,
 output logic [1:0] op_o,output coh_addr_t line_o,output coh_id_t id_o,
 output logic [511:0] data_o,output logic [63:0] mask_o);
 dma_req_t req_i;dma_resp_t resp_o;
 assign req_i='{write:write_i,line_paddr:paddr_i,wdata:data_i,wmask:mask_i};
 assign error_o=resp_o.error;assign rdata_o=resp_o.rdata;
 assign op_o=coh_req_o.op;assign line_o=coh_req_o.addr;assign id_o=coh_req_o.id;
 assign data_o=coh_req_o.data;assign mask_o=coh_req_o.mask;
 dma_line_adapter #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.*);
endmodule
