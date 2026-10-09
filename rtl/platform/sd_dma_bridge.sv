/** Wishbone 64-bit word transactions -> O3 coherent 64-byte line transactions.
 * 当前实现状态：目标实现（L11）；测试待用户指定的后续阶段补充。
 * One retained transaction; ACK/ERR only after the coherent response.
 * Aborted accepted requests drain; an abort never cancels an L2 side effect.
 * DMA is allowed only in main_ram. No line cache or write combining.
 */
module sd_dma_bridge import o3_types_pkg::*; (
    input logic clk_i, rst_i,
    input logic [28:0] wb_adr_i,
    input logic [63:0] wb_dat_w_i,
    input logic [7:0] wb_sel_i,
    input logic wb_cyc_i, wb_stb_i, wb_we_i,
    output logic [63:0] wb_dat_r_o,
    output logic wb_ack_o, wb_err_o,
    output logic dma_req_valid_o,
    input logic dma_req_ready_i,
    output dma_req_t dma_req_o,
    input logic dma_resp_valid_i,
    output logic dma_resp_ready_o,
    input dma_resp_t dma_resp_i,
    output logic busy_o
);
    typedef enum logic [1:0] {IDLE, SEND, WAIT, RESP} state_t;
    state_t state_q;
    dma_req_t req_q;
    logic [2:0] word_q;
    logic [63:0] data_q;
    logic error_q, aborted_q;
    logic [31:0] byte_addr;

    initial assert(L2_LINE_BYTES==64);
    assign byte_addr={wb_adr_i,3'b000};
    assign dma_req_o=req_q;
    assign dma_req_valid_o=state_q==SEND && wb_cyc_i;
    assign dma_resp_ready_o=state_q==WAIT;
    assign wb_dat_r_o=data_q;
    assign wb_ack_o=state_q==RESP && wb_cyc_i && wb_stb_i && !aborted_q && !error_q;
    assign wb_err_o=state_q==RESP && wb_cyc_i && wb_stb_i && !aborted_q && error_q;
    assign busy_o=state_q!=IDLE;

    always_ff @(posedge clk_i) begin
        if(rst_i) begin
            state_q<=IDLE; req_q<='0; word_q<='0; data_q<='0;
            error_q<=0; aborted_q<=0;
        end else begin
            if(state_q!=IDLE && !wb_cyc_i) aborted_q<=1;
            case(state_q)
                IDLE: if(wb_cyc_i && wb_stb_i) begin
                    req_q<='0;
                    req_q.write<=wb_we_i;
                    req_q.line_paddr<=paddr_t'({byte_addr[31:6],6'b0});
                    req_q.wdata[int'(byte_addr[5:3])*64+:64]<=wb_dat_w_i;
                    req_q.wmask[int'(byte_addr[5:3])*8+:8]<=wb_sel_i;
                    word_q<=byte_addr[5:3]; data_q<=0; aborted_q<=0;
                    error_q<=!pma_main(64'(byte_addr),8);
                    if(!pma_main(64'(byte_addr),8) || (wb_we_i && wb_sel_i==0)) state_q<=RESP;
                    else state_q<=SEND;
                end
                SEND: if(!wb_cyc_i) state_q<=IDLE;
                    else if(dma_req_ready_i) state_q<=WAIT;
                WAIT: if(dma_resp_valid_i) begin
                    data_q<=dma_resp_i.rdata[int'(word_q)*64+:64];
                    error_q<=dma_resp_i.error;
                    state_q<=RESP;
                end
                RESP: if(!wb_cyc_i || aborted_q || wb_stb_i) state_q<=IDLE;
                default: state_q<=IDLE;
            endcase
        end
    end
endmodule
