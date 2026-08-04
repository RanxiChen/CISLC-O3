/**
 * Simulation-only request generator for the standalone AXI memory boundary.
 *
 * Sequence:
 * 1. Read and check the initialized first 64-bit main-RAM word.
 * 2. Write a known value to the following word.
 * 3. Read that word back and check it.
 *
 * This module is not part of o3_core and is not an LSU or cache. FPGA targets
 * must instantiate axi_master behind the real memory system instead.
 */
module axi_memory_smoke_top #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 64,
    parameter int ID_WIDTH   = 4,
    parameter logic [ADDR_WIDTH-1:0] MAIN_RAM_BASE = 32'h8000_0000,
    parameter logic [DATA_WIDTH-1:0] EXPECTED_INIT_DATA = 64'h1122_3344_5566_7788,
    parameter logic [DATA_WIDTH-1:0] WRITE_DATA = 64'h0123_4567_89ab_cdef
) (
    input  logic clk_i,
    input  logic rst_i,

    output logic       smoke_done_o,
    output logic       smoke_pass_o,
    output logic [3:0] smoke_error_o,

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

    localparam int DATA_BYTES = DATA_WIDTH/8;
    localparam logic [2:0] FULL_BEAT_SIZE = 3'($clog2(DATA_BYTES));

    typedef enum logic [3:0] {
        INIT_READ_REQUEST,
        INIT_READ_RESPONSE,
        WRITE_REQUEST,
        WRITE_RESPONSE,
        READBACK_REQUEST,
        READBACK_RESPONSE,
        FINISHED
    } smoke_state_t;

    smoke_state_t state_q;
    logic req_valid;
    logic req_ready;
    logic req_write;
    logic [ADDR_WIDTH-1:0] req_addr;
    logic [DATA_WIDTH-1:0] req_wdata;
    logic [DATA_BYTES-1:0] req_wstrb;
    logic resp_valid;
    logic [DATA_WIDTH-1:0] resp_rdata;
    logic [1:0] resp_code;
    logic resp_error;

    always_comb begin
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr  = MAIN_RAM_BASE;
        req_wdata = WRITE_DATA;
        req_wstrb = '1;

        case (state_q)
            INIT_READ_REQUEST: begin
                req_valid = 1'b1;
                req_addr  = MAIN_RAM_BASE;
            end
            WRITE_REQUEST: begin
                req_valid = 1'b1;
                req_write = 1'b1;
                req_addr  = MAIN_RAM_BASE + ADDR_WIDTH'(DATA_BYTES);
            end
            READBACK_REQUEST: begin
                req_valid = 1'b1;
                req_addr  = MAIN_RAM_BASE + ADDR_WIDTH'(DATA_BYTES);
            end
            default: begin
            end
        endcase
    end

    assign smoke_done_o = (state_q == FINISHED);
    assign smoke_pass_o = smoke_done_o && (smoke_error_o == 4'd0);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q       <= INIT_READ_REQUEST;
            smoke_error_o <= 4'd0;
        end else begin
            case (state_q)
                INIT_READ_REQUEST: begin
                    if (req_valid && req_ready) state_q <= INIT_READ_RESPONSE;
                end
                INIT_READ_RESPONSE: begin
                    if (resp_valid) begin
                        if (resp_error) begin
                            smoke_error_o <= 4'd1;
                            state_q <= FINISHED;
                        end else if (resp_rdata != EXPECTED_INIT_DATA) begin
                            smoke_error_o <= 4'd2;
                            state_q <= FINISHED;
                        end else begin
                            state_q <= WRITE_REQUEST;
                        end
                    end
                end
                WRITE_REQUEST: begin
                    if (req_valid && req_ready) state_q <= WRITE_RESPONSE;
                end
                WRITE_RESPONSE: begin
                    if (resp_valid) begin
                        if (resp_error) begin
                            smoke_error_o <= 4'd3;
                            state_q <= FINISHED;
                        end else begin
                            state_q <= READBACK_REQUEST;
                        end
                    end
                end
                READBACK_REQUEST: begin
                    if (req_valid && req_ready) state_q <= READBACK_RESPONSE;
                end
                READBACK_RESPONSE: begin
                    if (resp_valid) begin
                        if (resp_error || (resp_rdata != WRITE_DATA)) begin
                            smoke_error_o <= 4'd4;
                        end
                        state_q <= FINISHED;
                    end
                end
                FINISHED: state_q <= FINISHED;
                default: state_q <= INIT_READ_REQUEST;
            endcase
        end
    end

    logic unused_resp_code;
    assign unused_resp_code = ^resp_code;

    axi_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH  (ID_WIDTH)
    ) u_axi_master (
        .clk_i,
        .rst_i,
        .req_valid_i (req_valid),
        .req_ready_o (req_ready),
        .req_write_i (req_write),
        .req_addr_i  (req_addr),
        .req_size_i  (FULL_BEAT_SIZE),
        .req_wdata_i (req_wdata),
        .req_wstrb_i (req_wstrb),
        .resp_valid_o(resp_valid),
        .resp_ready_i(1'b1),
        .resp_rdata_o(resp_rdata),
        .resp_code_o (resp_code),
        .resp_error_o(resp_error),
        .m_axi_awid_o,
        .m_axi_awaddr_o,
        .m_axi_awlen_o,
        .m_axi_awsize_o,
        .m_axi_awburst_o,
        .m_axi_awlock_o,
        .m_axi_awcache_o,
        .m_axi_awprot_o,
        .m_axi_awqos_o,
        .m_axi_awregion_o,
        .m_axi_awvalid_o,
        .m_axi_awready_i,
        .m_axi_wdata_o,
        .m_axi_wstrb_o,
        .m_axi_wlast_o,
        .m_axi_wvalid_o,
        .m_axi_wready_i,
        .m_axi_bid_i,
        .m_axi_bresp_i,
        .m_axi_bvalid_i,
        .m_axi_bready_o,
        .m_axi_arid_o,
        .m_axi_araddr_o,
        .m_axi_arlen_o,
        .m_axi_arsize_o,
        .m_axi_arburst_o,
        .m_axi_arlock_o,
        .m_axi_arcache_o,
        .m_axi_arprot_o,
        .m_axi_arqos_o,
        .m_axi_arregion_o,
        .m_axi_arvalid_o,
        .m_axi_arready_i,
        .m_axi_rid_i,
        .m_axi_rdata_i,
        .m_axi_rresp_i,
        .m_axi_rlast_i,
        .m_axi_rvalid_i,
        .m_axi_rready_o
    );

endmodule
