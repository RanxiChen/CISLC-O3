module dcache_mshr_tb_top import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG=o3_cfg_pkg::O3_CFG.be,localparam int N=CFG.dcache.mshrs
)(input logic clk,rst,input logic alloc_i,input dc_line_txn_t alloc_txn_i,
    output logic free_o,output coh_id_t free_id_o,output logic [$clog2(N+1)-1:0] free_count_o,
    output dc_mshr_state_e state_o[N],output dc_line_meta_t txn_o[N],
    input logic wb_read_done_i,input coh_id_t wb_read_id_i,
    output logic req_valid_o,input logic req_ready_i,output coh_req_t req_o,
    input logic rsp_valid_i,input coh_rsp_down_t rsp_i,
    output logic install_valid_o,output coh_id_t install_id_o,output dc_line_txn_t install_o,
    input logic install_issue_i,input logic install_done_i,input coh_id_t install_done_id_i,
    output logic mshr_free_o,
    output dc_line_txn_t fmt_alloc_line_addr,
    output dc_line_txn_t fmt_alloc_is_getm,
    output dc_line_txn_t fmt_alloc_wb_wait,
    output dc_line_txn_t fmt_alloc_wb_id,
    output dc_line_txn_t fmt_alloc_refill,
    output coh_rsp_down_t fmt_rsp_op,
    output coh_rsp_down_t fmt_rsp_id,
    output coh_rsp_down_t fmt_rsp_error,
    output coh_rsp_down_t fmt_rsp_data,
    output coh_req_t fmt_request_op,
    output coh_req_t fmt_request_addr,
    output coh_req_t fmt_request_id,
    output dc_line_txn_t fmt_install_line_addr,
    output dc_line_txn_t fmt_install_refill,
    output dc_line_txn_t fmt_install_err,
    output dc_line_meta_t fmt_meta_line_addr,
    output dc_line_meta_t fmt_meta_err,
    output logic [31:0] cfg_n_o,cfg_datae_o,cfg_getm_o,cfg_gets_o);
    assign cfg_n_o=N;assign cfg_datae_o=COH_DATAE;assign cfg_getm_o=COH_GETM;assign cfg_gets_o=COH_GETS;
    always_comb begin
        fmt_alloc_line_addr='0;fmt_alloc_line_addr.line_addr='1;
        fmt_alloc_is_getm='0;fmt_alloc_is_getm.is_getm='1;
        fmt_alloc_wb_wait='0;fmt_alloc_wb_wait.wb_wait='1;
        fmt_alloc_wb_id='0;fmt_alloc_wb_id.wb_id='1;
        fmt_alloc_refill='0;fmt_alloc_refill.refill='1;
        fmt_rsp_op='0;fmt_rsp_op.op=coh_down_op_e'('1);
        fmt_rsp_id='0;fmt_rsp_id.id='1;
        fmt_rsp_error='0;fmt_rsp_error.error='1;
        fmt_rsp_data='0;fmt_rsp_data.data='1;
        fmt_request_op='0;fmt_request_op.op=coh_req_op_e'('1);
        fmt_request_addr='0;fmt_request_addr.addr='1;
        fmt_request_id='0;fmt_request_id.id='1;
        fmt_install_line_addr='0;fmt_install_line_addr.line_addr='1;
        fmt_install_refill='0;fmt_install_refill.refill='1;
        fmt_install_err='0;fmt_install_err.err='1;
        fmt_meta_line_addr='0;fmt_meta_line_addr.line_addr='1;
        fmt_meta_err='0;fmt_meta_err.err='1;
    end
    dcache_mshr #(.CFG(CFG)) dut(.*);
endmodule
