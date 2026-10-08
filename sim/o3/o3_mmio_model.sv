// N6 simulation-only 4KiB peripheral, one DMA line transaction at a time.
// Base 02000000. 000..7ff general registers; 800 read/increment; 808 count snapshot;
// 830 IRQ set, 838 IRQ clear; 900 command(1 read/2 write), 908 PA, 910 byte mask,
// 918 repeated 64-bit pattern; 920 status(1 busy/2 done/4 error); a00..a3f result;
// f00..fff SLVERR. Increment is on AR acceptance, never on RVALID or RREADY.
module o3_mmio_model import o3_types_pkg::*; (
 input logic clk_i,rst_i,
 input logic awvalid_i,output logic awready_o,input logic [31:0] awaddr_i,
 input logic wvalid_i,output logic wready_o,input logic [63:0] wdata_i,input logic [7:0] wstrb_i,
 output logic bvalid_o,input logic bready_i,output logic [1:0] bresp_o,
 input logic arvalid_i,output logic arready_o,input logic [31:0] araddr_i,
 output logic rvalid_o,input logic rready_i,output logic [63:0] rdata_o,output logic [1:0] rresp_o,
 output logic dma_req_valid_o,input logic dma_req_ready_i,output dma_req_t dma_req_o,
 input logic dma_resp_valid_i,output logic dma_resp_ready_o,input dma_resp_t dma_resp_i,
 output logic irq_soft_o,output logic [63:0] side_reads_o);
 logic [63:0] regs[512];logic aw_q,w_q;logic [31:0] addr_q;
 logic [63:0] data_q;logic [7:0] strb_q;logic [31:0] cycle_q;
 logic dma_pending_q,dma_wait_q;dma_req_t request_q;logic [63:0] status_q;logic [511:0] result_q;
 assign awready_o=!aw_q && !bvalid_o && cycle_q[1:0]!=0;
 assign wready_o=!w_q && !bvalid_o && cycle_q[1:0]!=2;
 assign arready_o=!rvalid_o && cycle_q[1:0]!=1;
 assign dma_req_valid_o=dma_pending_q;assign dma_req_o=request_q;
 assign dma_resp_ready_o=dma_wait_q;
 function automatic logic mapped(input logic [31:0] a);
     return a>=32'h02000000 && a<32'h02001000;
 endfunction
 always_ff @(posedge clk_i) begin
  if(rst_i) begin
   regs<='{default:0};aw_q<=0;w_q<=0;addr_q<=0;data_q<=0;strb_q<=0;cycle_q<=0;
   bvalid_o<=0;bresp_o<=0;rvalid_o<=0;rresp_o<=0;rdata_o<=0;side_reads_o<=0;irq_soft_o<=0;
   dma_pending_q<=0;dma_wait_q<=0;request_q<='0;status_q<=0;result_q<=0;
  end else begin
   cycle_q<=cycle_q+1;
   if(awvalid_i && awready_o) begin aw_q<=1;addr_q<=awaddr_i;end
   if(wvalid_i && wready_o) begin w_q<=1;data_q<=wdata_i;strb_q<=wstrb_i;end
   if(bvalid_o && bready_i) bvalid_o<=0;
   if(rvalid_o && rready_i) rvalid_o<=0;
   if(aw_q && w_q && !bvalid_o) begin
    aw_q<=0;w_q<=0;bvalid_o<=1;bresp_o<=!mapped(addr_q) || addr_q[11:0]>=12'hf00 ? 2'b10:2'b00;
    if(mapped(addr_q) && addr_q[11:0]<12'hf00) begin
     for(int b=0;b<8;b++) if(strb_q[b]) regs[addr_q[11:3]][b*8+:8]<=data_q[b*8+:8];
     if(addr_q[11:3]==9'h106 && strb_q[0]) irq_soft_o<=data_q[0];
     if(addr_q[11:3]==9'h107 && strb_q[0]) irq_soft_o<=0;
     if(addr_q[11:3]==9'h120 && strb_q[0] && data_q[1:0]!=0) begin
      assert(!dma_pending_q && !dma_wait_q) else $fatal(1,"N6 DMA command while busy");
      assert(data_q[1:0] inside {1,2}) else $fatal(1,"N6 DMA invalid command");
      request_q.write<=data_q[1];request_q.line_paddr<=regs[9'h121];request_q.wmask<=regs[9'h122];
      for(int w=0;w<8;w++) request_q.wdata[w*64+:64]<=regs[9'h123];
      dma_pending_q<=1;status_q<=1;
     end
    end
   end
   if(arvalid_i && arready_o) begin
    rvalid_o<=1;rresp_o<=!mapped(araddr_i) || araddr_i[11:0]>=12'hf00 ? 2'b10:0;
    rdata_o<=mapped(araddr_i) ? regs[araddr_i[11:3]]:0;
    if(mapped(araddr_i)) case(araddr_i[11:3])
      9'h100:begin rdata_o<=side_reads_o;side_reads_o<=side_reads_o+1;end
      9'h101:rdata_o<=side_reads_o;
      9'h124:rdata_o<=status_q;
      default:if(araddr_i[11:0]>=12'ha00 && araddr_i[11:0]<12'ha40)
          rdata_o<=result_q[(araddr_i[5:3])*64+:64];
    endcase
   end
   if(dma_req_valid_o && dma_req_ready_i) begin dma_pending_q<=0;dma_wait_q<=1;end
   if(dma_resp_valid_i && dma_resp_ready_o) begin
      result_q<=dma_resp_i.rdata;status_q<=dma_resp_i.error ? 6:2;dma_wait_q<=0;
   end
  end
 end
 // A response under backpressure remains stable, so reads with side effects cannot repeat.
 property held_r; @(posedge clk_i) disable iff(rst_i) rvalid_o && !rready_i |=> rvalid_o && $stable({rdata_o,rresp_o});endproperty
 property held_b; @(posedge clk_i) disable iff(rst_i) bvalid_o && !bready_i |=> bvalid_o && $stable(bresp_o);endproperty
 property held_dma; @(posedge clk_i) disable iff(rst_i) dma_req_valid_o && !dma_req_ready_i |=> dma_req_valid_o && $stable(dma_req_o);endproperty
 assert property(held_r);assert property(held_b);assert property(held_dma);
endmodule
