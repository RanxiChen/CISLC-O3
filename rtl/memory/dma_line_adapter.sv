/** One retained line request and one retained response. Invalid PA never reaches L2. */
module dma_line_adapter import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(input logic clk,rst,input logic req_valid_i,output logic req_ready_o,input dma_req_t req_i,
  output logic resp_valid_o,input logic resp_ready_i,output dma_resp_t resp_o,
  output logic coh_req_valid_o,input logic coh_req_ready_i,output coh_req_t coh_req_o,
  input logic coh_resp_valid_i,output logic coh_resp_ready_o,input coh_rsp_down_t coh_resp_i);
    typedef enum logic [1:0] {IDLE,SEND,WAIT,RESP} state_t;
    state_t state_q; dma_req_t req_q; dma_resp_t resp_q;
    assign req_ready_o=state_q==IDLE;
    assign coh_req_valid_o=state_q==SEND;
    assign coh_req_o='{op:(req_q.write ? COH_MASKWRITE:COH_READ),addr:coh_addr_t'(req_q.line_paddr>>6),
        id:'0,data:req_q.wdata,mask:req_q.wmask};
    assign coh_resp_ready_o=state_q==WAIT;
    assign resp_valid_o=state_q==RESP;
    always_comb begin resp_o=resp_q;resp_o.valid=resp_valid_o;end
    always_ff @(posedge clk) begin
        if(rst) begin state_q<=IDLE;req_q<='0;resp_q<='0;end
        else case(state_q)
            IDLE:if(req_valid_i) begin
                req_q<=req_i;resp_q<='0;
                if(!pma_main(64'(req_i.line_paddr & ~paddr_t'(63)),64)) begin
                    resp_q.valid<=1;resp_q.error<=1;state_q<=RESP;
                end else state_q<=SEND;
            end
            SEND:if(coh_req_ready_i) state_q<=WAIT;
            WAIT:if(coh_resp_valid_i) begin
                assert(coh_resp_i.id==0 && coh_resp_i.op==(req_q.write ? COH_WRITEACK:COH_READDATA));
                resp_q<='{valid:1'b1,error:coh_resp_i.error,rdata:coh_resp_i.data};state_q<=RESP;
            end
            RESP:if(resp_ready_i) state_q<=IDLE;
            default:state_q<=IDLE;
        endcase
    end
endmodule
