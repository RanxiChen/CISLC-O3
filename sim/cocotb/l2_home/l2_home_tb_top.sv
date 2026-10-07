// M1 functional harness. Production ports are preserved; monitors are read-only.
module l2_home_tb_top import o3_types_pkg::*; #(
    parameter int SETS=2, WAYS=2, SLOTS=2,
    localparam int ID_W=o3_cfg_pkg::O3_CFG.be.l2.axi_id_bits,
    localparam int DATA_W=o3_cfg_pkg::O3_CFG.be.l2.axi_data_bits
)(input logic clk,rst,
    input logic l1d_req_valid_i,output logic l1d_req_ready_o,input coh_req_t l1d_req_i,
    output logic l1d_resp_valid_o,input logic l1d_resp_ready_i,output coh_rsp_down_t l1d_resp_o,
    input logic l1i_req_valid_i,output logic l1i_req_ready_o,input coh_req_t l1i_req_i,
    output logic l1i_resp_valid_o,input logic l1i_resp_ready_i,output coh_rsp_down_t l1i_resp_o,
    input logic dma_req_valid_i,output logic dma_req_ready_o,input coh_req_t dma_req_i,
    output logic dma_resp_valid_o,input logic dma_resp_ready_i,output coh_rsp_down_t dma_resp_o,
    input logic rsp_up_valid_i,output logic rsp_up_ready_o,input coh_rsp_up_t rsp_up_i,
    output logic snp_valid_o,input logic snp_ready_i,output coh_snp_t snp_o,
    output fatal_evt_t fatal_o,output be_perf_t perf_o,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [ID_W-1:0]   m_axi_awid,
    output logic [PADDR_W-1:0]    m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [DATA_W-1:0] m_axi_wdata,
    output logic [DATA_W/8-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [ID_W-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [ID_W-1:0]   m_axi_arid,
    output logic [PADDR_W-1:0]    m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [ID_W-1:0]   m_axi_rid,
    input  logic [DATA_W-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    output logic init_done,
    output logic [SETS*WAYS-1:0] mon_valid, mon_sharer,
    output logic [SETS*WAYS*2-1:0] mon_state,
    output logic [SETS*WAYS*26-1:0] mon_addr,
    output logic [SLOTS-1:0] mon_slot_busy,
    output logic mon_slot_full
);
    function automatic o3_cfg_pkg::backend_cfg_t test_config();
        o3_cfg_pkg::backend_cfg_t c;c=o3_cfg_pkg::O3_CFG.be;
        c.l2.sets=SETS;c.l2.ways=WAYS;c.l2.slots=SLOTS;return c;
    endfunction
    localparam o3_cfg_pkg::backend_cfg_t CFG=test_config();
    l2_home #(.CFG(CFG)) dut (.*);
    assign init_done=dut.init_done_q;
    assign mon_slot_full=dut.reject_req;
    for(genvar s=0;s<SETS;s++) for(genvar w=0;w<WAYS;w++) begin
        localparam int K=s*WAYS+w;
        assign mon_valid[K]=dut.meta_q[s][w].valid;
        assign mon_sharer[K]=dut.meta_q[s][w].sharer;
        assign mon_state[K*2+:2]=dut.meta_q[s][w].state;
        assign mon_addr[K*26+:26]=26'({dut.meta_q[s][w].tag,$clog2(SETS)'(s)});
    end
    for(genvar n=0;n<SLOTS;n++) assign mon_slot_busy[n]=dut.protected_set_valid[n];
endmodule
