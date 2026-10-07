// L10 PTE atomic entry integration harness, not the deferred L8 cache suite.
module pte_cache_tb_top import o3_types_pkg::*; (
    input logic clk,rst,
    input logic read_i,store_i,ad_i,input logic[55:0] addr_i,input logic[63:0] data_i,expected_i,
    input logic set_a_i,set_d_i,input logic[7:0] req_epoch_i,epoch_i,
    output logic read_ready_o,store_ready_o,ad_ready_o,read_valid_o,store_valid_o,ad_valid_o,
    output logic[63:0] read_data_o,output logic updated_o,mismatch_o,af_o,
    output logic l2_req_o,input logic l2_ready_i,output logic[55:0] l2_addr_o,
    input logic l2_valid_i,l2_last_i,l2_fault_i,input logic[127:0] l2_data_i,
    output logic l2_resp_ready_o,wb_o,input logic wb_ready_i,output logic[55:0] wb_addr_o,
    output logic[511:0] wb_data_o,output logic idle_o
);
    logic ld_valid[2],ld_ready[2];dcache_req_t ld_req[2],st_req,ptw_req;l2_req_t l2_req;l2_resp_t l2_resp;
    dcache_resp_t ld_resp[2],st_resp,ptw_resp;pte_ad_req_t ad_req;pte_ad_resp_t ad_resp;
    always_comb begin
        ld_valid[0]=0;ld_valid[1]=0;ld_req[0]='0;ld_req[1]='0;
        ptw_req='{src:DC_SRC_PTW,paddr:addr_i,size:2'd3,amo_op:AMO_LR,default:'0};
        st_req='{src:DC_SRC_STORE_DRAIN,paddr:addr_i,size:2'd3,write:1'b1,wdata:data_i,wmask:8'hff,amo_op:AMO_LR,default:'0};
        ad_req='{pte_paddr:addr_i,expected_pte:expected_i,set_a:set_a_i,set_d:set_d_i,epoch:xlate_epoch_t'(req_epoch_i)};
        l2_resp='{valid:l2_valid_i,data:l2_data_i,last:l2_last_i,error:l2_fault_i,default:'0};
    end
    dcache #(.CFG(o3_cfg_pkg::O3_CFG.be)) cache(.clk(clk),.rst(rst),
        .ld_req_valid_i(ld_valid),.ld_req_ready_o(ld_ready),.ld_req_i(ld_req),.ld_resp_o(ld_resp),
        .st_req_valid_i(store_i),.st_req_ready_o(store_ready_o),.st_req_i(st_req),.st_resp_o(st_resp),
        .ptw_req_valid_i(read_i),.ptw_req_ready_o(read_ready_o),.ptw_req_i(ptw_req),.ptw_resp_o(ptw_resp),
        .amo_req_valid_i(1'b0),.amo_req_i('0),.amo_req_ready_o(),.amo_resp_o(),
        .pf_req_valid_i(1'b0),.pf_req_i('0),.pf_req_ready_o(),.wake_o(),
        .probe_valid_i(1'b0),.probe_i('0),.probe_ready_o(),.probe_resp_o(),
        .clean_all_req_i(1'b0),.clean_all_done_o(),.clean_all_busy_o(),
        .pte_ad_req_valid_i(ad_i),.pte_ad_req_ready_o(ad_ready_o),.pte_ad_req_i(ad_req),.pte_ad_resp_o(ad_resp),
        .cur_epoch_i(xlate_epoch_t'(epoch_i)),.rsv_clear_valid_i(1'b0),.rsv_clear_reason_i(RSV_CLR_SC),.rsv_pte_ad_conflict_i('0),
        .l2_req_valid_o(l2_req_o),.l2_req_ready_i(l2_ready_i),.l2_req_o(l2_req),.l2_resp_i(l2_resp),.l2_resp_ready_o(l2_resp_ready_o),
        .l2_wb_valid_o(wb_o),.l2_wb_ready_i(wb_ready_i),.l2_wb_line_paddr_o(wb_addr_o),.l2_wb_data_o(wb_data_o),.l2_wb_error_i(1'b0),
        .idle_o(idle_o),.fatal_o(),.perf_o());
    assign l2_addr_o=l2_req.line_paddr;assign read_valid_o=ptw_resp.valid;assign read_data_o=ptw_resp.rdata;
    assign store_valid_o=st_resp.valid;assign ad_valid_o=ad_resp.valid;assign updated_o=ad_resp.updated;
    assign mismatch_o=ad_resp.mismatch;assign af_o=ad_resp.access_fault;
endmodule
