/**
 * Single-outstanding AXI4 memory master.
 *
 * Implemented now:
 * - Converts one simple request at a time into a single-beat AXI4 read or write.
 * - Treats the independent AW and W handshakes independently and waits for both.
 * - Buffers the AXI response until the request-side consumer accepts it.
 * - Reports non-OKAY responses, unexpected response IDs, and a missing RLAST.
 *
 * Deliberately not implemented:
 * - Bursts, multiple outstanding requests, response reordering, atomics, or exclusives.
 * - Cache policy selection; AxCACHE/AxPROT/AxQOS/AxREGION are fixed to zero.
 * - Alignment checking. The future LSU/DCache owns request legality.
 *
 * Cycle behavior:
 * - Cycle N captures req_* when req_valid_i && req_ready_o.
 * - From N+1, the selected AXI channels hold valid and payload until handshake.
 * - AW and W may complete in different cycles; the write response is accepted
 *   only after both have completed.
 * - B/R is buffered on resp_* until resp_valid_o && resp_ready_i.
 */
module axi_master #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 64,
    parameter int ID_WIDTH   = 4,
    parameter logic [ID_WIDTH-1:0] AXI_ID = '0
) (
    input  logic                    clk_i,
    input  logic                    rst_i,

    input  logic                    req_valid_i,
    output logic                    req_ready_o,
    input  logic                    req_write_i,
    input  logic [ADDR_WIDTH-1:0]   req_addr_i,
    input  logic [2:0]              req_size_i,
    input  logic [DATA_WIDTH-1:0]   req_wdata_i,
    input  logic [DATA_WIDTH/8-1:0] req_wstrb_i,

    output logic                    resp_valid_o,
    input  logic                    resp_ready_i,
    output logic [DATA_WIDTH-1:0]   resp_rdata_o,
    output logic [1:0]              resp_code_o,
    output logic                    resp_error_o,

    output logic [ID_WIDTH-1:0]     m_axi_awid_o,
    output logic [ADDR_WIDTH-1:0]   m_axi_awaddr_o,
    output logic [7:0]              m_axi_awlen_o,
    output logic [2:0]              m_axi_awsize_o,
    output logic [1:0]              m_axi_awburst_o,
    output logic                    m_axi_awlock_o,
    output logic [3:0]              m_axi_awcache_o,
    output logic [2:0]              m_axi_awprot_o,
    output logic [3:0]              m_axi_awqos_o,
    output logic [3:0]              m_axi_awregion_o,
    output logic                    m_axi_awvalid_o,
    input  logic                    m_axi_awready_i,

    output logic [DATA_WIDTH-1:0]   m_axi_wdata_o,
    output logic [DATA_WIDTH/8-1:0] m_axi_wstrb_o,
    output logic                    m_axi_wlast_o,
    output logic                    m_axi_wvalid_o,
    input  logic                    m_axi_wready_i,

    input  logic [ID_WIDTH-1:0]     m_axi_bid_i,
    input  logic [1:0]              m_axi_bresp_i,
    input  logic                    m_axi_bvalid_i,
    output logic                    m_axi_bready_o,

    output logic [ID_WIDTH-1:0]     m_axi_arid_o,
    output logic [ADDR_WIDTH-1:0]   m_axi_araddr_o,
    output logic [7:0]              m_axi_arlen_o,
    output logic [2:0]              m_axi_arsize_o,
    output logic [1:0]              m_axi_arburst_o,
    output logic                    m_axi_arlock_o,
    output logic [3:0]              m_axi_arcache_o,
    output logic [2:0]              m_axi_arprot_o,
    output logic [3:0]              m_axi_arqos_o,
    output logic [3:0]              m_axi_arregion_o,
    output logic                    m_axi_arvalid_o,
    input  logic                    m_axi_arready_i,

    input  logic [ID_WIDTH-1:0]     m_axi_rid_i,
    input  logic [DATA_WIDTH-1:0]   m_axi_rdata_i,
    input  logic [1:0]              m_axi_rresp_i,
    input  logic                    m_axi_rlast_i,
    input  logic                    m_axi_rvalid_i,
    output logic                    m_axi_rready_o
);

    typedef enum logic [2:0] {
        IDLE,
        WRITE_SEND,
        WRITE_RESPONSE,
        READ_ADDRESS,
        READ_DATA,
        RESPONSE
    } state_t;

    state_t state_q;
    logic [ADDR_WIDTH-1:0]   req_addr_q;
    logic [2:0]              req_size_q;
    logic [DATA_WIDTH-1:0]   req_wdata_q;
    logic [DATA_WIDTH/8-1:0] req_wstrb_q;
    logic                    aw_sent_q;
    logic                    w_sent_q;
    logic [DATA_WIDTH-1:0]   resp_rdata_q;
    logic [1:0]              resp_code_q;
    logic                    resp_error_q;

    logic aw_fire;
    logic w_fire;
    logic ar_fire;
    logic b_fire;
    logic r_fire;

    assign req_ready_o  = (state_q == IDLE);
    assign resp_valid_o = (state_q == RESPONSE);
    assign resp_rdata_o = resp_rdata_q;
    assign resp_code_o  = resp_code_q;
    assign resp_error_o = resp_error_q;

    assign m_axi_awid_o     = AXI_ID;
    assign m_axi_awaddr_o   = req_addr_q;
    assign m_axi_awlen_o    = 8'd0;
    assign m_axi_awsize_o   = req_size_q;
    assign m_axi_awburst_o  = 2'b01;
    assign m_axi_awlock_o   = 1'b0;
    assign m_axi_awcache_o  = 4'b0000;
    assign m_axi_awprot_o   = 3'b000;
    assign m_axi_awqos_o    = 4'b0000;
    assign m_axi_awregion_o = 4'b0000;
    assign m_axi_awvalid_o  = (state_q == WRITE_SEND) && !aw_sent_q;

    assign m_axi_wdata_o  = req_wdata_q;
    assign m_axi_wstrb_o  = req_wstrb_q;
    assign m_axi_wlast_o  = 1'b1;
    assign m_axi_wvalid_o = (state_q == WRITE_SEND) && !w_sent_q;
    assign m_axi_bready_o = (state_q == WRITE_RESPONSE);

    assign m_axi_arid_o     = AXI_ID;
    assign m_axi_araddr_o   = req_addr_q;
    assign m_axi_arlen_o    = 8'd0;
    assign m_axi_arsize_o   = req_size_q;
    assign m_axi_arburst_o  = 2'b01;
    assign m_axi_arlock_o   = 1'b0;
    assign m_axi_arcache_o  = 4'b0000;
    assign m_axi_arprot_o   = 3'b000;
    assign m_axi_arqos_o    = 4'b0000;
    assign m_axi_arregion_o = 4'b0000;
    assign m_axi_arvalid_o  = (state_q == READ_ADDRESS);
    assign m_axi_rready_o   = (state_q == READ_DATA);

    assign aw_fire = m_axi_awvalid_o && m_axi_awready_i;
    assign w_fire  = m_axi_wvalid_o  && m_axi_wready_i;
    assign b_fire  = m_axi_bvalid_i  && m_axi_bready_o;
    assign ar_fire = m_axi_arvalid_o && m_axi_arready_i;
    assign r_fire  = m_axi_rvalid_i  && m_axi_rready_o;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q      <= IDLE;
            req_addr_q   <= '0;
            req_size_q   <= '0;
            req_wdata_q  <= '0;
            req_wstrb_q  <= '0;
            aw_sent_q    <= 1'b0;
            w_sent_q     <= 1'b0;
            resp_rdata_q <= '0;
            resp_code_q  <= 2'b00;
            resp_error_q <= 1'b0;
        end else begin
            case (state_q)
                IDLE: begin
                    aw_sent_q <= 1'b0;
                    w_sent_q  <= 1'b0;
                    if (req_valid_i && req_ready_o) begin
                        req_addr_q   <= req_addr_i;
                        req_size_q   <= req_size_i;
                        req_wdata_q  <= req_wdata_i;
                        req_wstrb_q  <= req_wstrb_i;
                        resp_rdata_q <= '0;
                        resp_code_q  <= 2'b00;
                        resp_error_q <= 1'b0;
                        state_q      <= req_write_i ? WRITE_SEND : READ_ADDRESS;
                    end
                end

                WRITE_SEND: begin
                    if (aw_fire) aw_sent_q <= 1'b1;
                    if (w_fire)  w_sent_q  <= 1'b1;
                    if ((aw_sent_q || aw_fire) && (w_sent_q || w_fire)) begin
                        state_q <= WRITE_RESPONSE;
                    end
                end

                WRITE_RESPONSE: begin
                    if (b_fire) begin
                        resp_code_q  <= m_axi_bresp_i;
                        resp_error_q <= (m_axi_bresp_i != 2'b00) ||
                                        (m_axi_bid_i != AXI_ID);
                        state_q      <= RESPONSE;
                    end
                end

                READ_ADDRESS: begin
                    if (ar_fire) state_q <= READ_DATA;
                end

                READ_DATA: begin
                    if (r_fire) begin
                        resp_rdata_q <= m_axi_rdata_i;
                        resp_code_q  <= m_axi_rresp_i;
                        resp_error_q <= (m_axi_rresp_i != 2'b00) ||
                                        (m_axi_rid_i != AXI_ID) ||
                                        !m_axi_rlast_i;
                        state_q      <= RESPONSE;
                    end
                end

                RESPONSE: begin
                    if (resp_valid_o && resp_ready_i) state_q <= IDLE;
                end

                default: state_q <= IDLE;
            endcase
        end
    end

endmodule
