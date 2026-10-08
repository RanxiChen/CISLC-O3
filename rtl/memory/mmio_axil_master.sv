/** Single transaction. AW/W complete independently; results persist until consumed. */
module mmio_axil_master import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(input logic clk,rst,input logic req_valid_i,output logic req_ready_o,input dcache_req_t req_i,
  output logic resp_valid_o,input logic resp_ready_i,output dcache_resp_t resp_o,
  output logic irreversible_o,
  output logic m_axil_awvalid,input logic m_axil_awready,output logic [31:0] m_axil_awaddr,output logic [2:0] m_axil_awprot,
  output logic m_axil_wvalid,input logic m_axil_wready,output logic [63:0] m_axil_wdata,output logic [7:0] m_axil_wstrb,
  input logic m_axil_bvalid,output logic m_axil_bready,input logic [1:0] m_axil_bresp,
  output logic m_axil_arvalid,input logic m_axil_arready,output logic [31:0] m_axil_araddr,output logic [2:0] m_axil_arprot,
  input logic m_axil_rvalid,output logic m_axil_rready,input logic [63:0] m_axil_rdata,input logic [1:0] m_axil_rresp);
    typedef enum logic [1:0] {IDLE,ISSUE,WAIT,RESP} state_t;
    state_t state_q; dcache_req_t req_q; dcache_resp_t resp_q; logic aw_q,w_q;
    assign req_ready_o=state_q==IDLE;
    assign m_axil_arvalid=state_q==ISSUE && !req_q.write;
    assign m_axil_awvalid=state_q==ISSUE && req_q.write && !aw_q;
    assign m_axil_wvalid=state_q==ISSUE && req_q.write && !w_q;
    assign m_axil_araddr=req_q.paddr[31:0];assign m_axil_awaddr=req_q.paddr[31:0];
    assign m_axil_arprot=0;assign m_axil_awprot=0;
    assign m_axil_wdata=req_q.wdata<<(8*int'(req_q.paddr[2:0]));
    assign m_axil_wstrb=req_q.wmask<<int'(req_q.paddr[2:0]);
    assign m_axil_rready=state_q==WAIT && !req_q.write;
    assign m_axil_bready=state_q==WAIT && req_q.write;
    assign irreversible_o=state_q!=IDLE;
    assign resp_valid_o=state_q==RESP;
    always_comb begin resp_o=resp_q;resp_o.valid=resp_valid_o;end
    always_ff @(posedge clk) begin
        if(rst) begin state_q<=IDLE;req_q<='0;resp_q<='0;aw_q<=0;w_q<=0;end
        else case(state_q)
            IDLE:if(req_valid_i) begin req_q<=req_i;aw_q<=0;w_q<=0;state_q<=ISSUE;end
            ISSUE:begin
                if(m_axil_awvalid && m_axil_awready) aw_q<=1;
                if(m_axil_wvalid && m_axil_wready) w_q<=1;
                if((m_axil_arvalid && m_axil_arready) || (req_q.write &&
                    (aw_q || m_axil_awready) && (w_q || m_axil_wready))) state_q<=WAIT;
            end
            WAIT:if((m_axil_bvalid && m_axil_bready) || (m_axil_rvalid && m_axil_rready)) begin
                resp_q<='0;resp_q.valid<=1;resp_q.paddr<=req_q.paddr;
                resp_q.rdata<=mem_format(m_axil_rdata>>(8*int'(req_q.paddr[2:0])),req_q.size,req_q.is_signed,req_q.is_flw);
                if((req_q.write ? m_axil_bresp:m_axil_rresp)!=0) begin
                    resp_q.status<=DC_ERROR;
                    resp_q.exc<='{valid:1'b1,cause:(req_q.write ? EXCEPTION_CAUSE_STORE_ACCESS_FAULT:EXCEPTION_CAUSE_LOAD_ACCESS_FAULT),tval:req_q.vaddr};
                end
                state_q<=RESP;
            end
            RESP:if(resp_ready_i) state_q<=IDLE;
            default:state_q<=IDLE;
        endcase
    end
endmodule
