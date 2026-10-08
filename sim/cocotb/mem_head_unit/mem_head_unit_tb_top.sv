module mem_head_unit_tb_top import o3_types_pkg::*; (
 input logic clk,rst,start_valid_i,sq_empty_i,flush_i,
 output logic start_ready_o,input heu_req_t start_i,input rob_idx_t rob_head_i,
 output logic dc_valid_o,input logic dc_ready_i,output dcache_req_t dc_req_o,input dcache_resp_t dc_resp_i,
 input dc_wake_t wake_i,input logic tlb_wake_i,
 output logic d_valid_o,input logic d_ready_i,output vaddr_t d_va_o,output sq_idx_t d_sq_o,
 input logic d_done_i,input exc_info_t d_exc_i,
 output sfence_req_t sfence_o,input logic sfence_done_i,
 output logic mmio_valid_o,input logic mmio_ready_i,output dcache_req_t mmio_req_o,input dcache_resp_t mmio_resp_i,
 input logic cache_irreversible_i,mmio_irreversible_i,output logic irreversible_o,
 output wb_req_t result_o,input logic result_ready_i,
 output logic exc_valid_o,input logic exc_ready_i,output exc_info_t exc_o,output rob_idx_t exc_idx_o,
 output logic done_o,output rob_idx_t done_idx_o,output be_perf_t perf_o, 
    output heu_req_t fmt_start_tag_rob_idx,
    output heu_req_t fmt_start_tag_dst_write_en,
    output heu_req_t fmt_start_tag_dst_dom,
    output heu_req_t fmt_start_tag_dst_preg,
    output heu_req_t fmt_start_kind,
    output heu_req_t fmt_start_va,
    output heu_req_t fmt_start_data,
    output heu_req_t fmt_start_size,
    output heu_req_t fmt_start_write,
    output heu_req_t fmt_start_is_signed,
    output heu_req_t fmt_start_is_flw,
    output heu_req_t fmt_start_amo_op, 
    output dcache_resp_t fmt_response_valid,
    output dcache_resp_t fmt_response_status,
    output dcache_resp_t fmt_response_reason,
    output dcache_resp_t fmt_response_paddr,
    output dcache_resp_t fmt_response_rdata,
    output dcache_resp_t fmt_response_io,
    output dcache_resp_t fmt_response_need_d,
    output dcache_resp_t fmt_response_exc, 
    output dcache_req_t fmt_request_vaddr,
    output dcache_req_t fmt_request_paddr,
    output dcache_req_t fmt_request_check_only,
    output dcache_req_t fmt_request_write,
    output dcache_req_t fmt_request_wdata,
    output dcache_req_t fmt_request_bytes,
    output dcache_req_t fmt_request_split, 
    output wb_req_t fmt_result_valid,
    output wb_req_t fmt_result_data,
    output wb_req_t fmt_result_tag_rob_idx);
 mem_head_unit #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(.*);

    always_comb begin
        fmt_start_tag_rob_idx='0;fmt_start_tag_rob_idx.tag.rob_idx='1;
        fmt_start_tag_dst_write_en='0;fmt_start_tag_dst_write_en.tag.dst_write_en='1;
        fmt_start_tag_dst_dom='0;fmt_start_tag_dst_dom.tag.dst_dom=reg_domain_e'('1);
        fmt_start_tag_dst_preg='0;fmt_start_tag_dst_preg.tag.dst_preg='1;
        fmt_start_kind='0;fmt_start_kind.kind=sq_kind_e'('1);
        fmt_start_va='0;fmt_start_va.va='1;
        fmt_start_data='0;fmt_start_data.data='1;
        fmt_start_size='0;fmt_start_size.size='1;
        fmt_start_write='0;fmt_start_write.write='1;
        fmt_start_is_signed='0;fmt_start_is_signed.is_signed='1;
        fmt_start_is_flw='0;fmt_start_is_flw.is_flw='1;
        fmt_start_amo_op='0;fmt_start_amo_op.amo_op=amo_op_e'('1);
    end

    always_comb begin
        fmt_response_valid='0;fmt_response_valid.valid='1;
        fmt_response_status='0;fmt_response_status.status=dc_status_e'('1);
        fmt_response_reason='0;fmt_response_reason.reason=ld_wait_e'('1);
        fmt_response_paddr='0;fmt_response_paddr.paddr='1;
        fmt_response_rdata='0;fmt_response_rdata.rdata='1;
        fmt_response_io='0;fmt_response_io.io='1;
        fmt_response_need_d='0;fmt_response_need_d.need_d='1;
        fmt_response_exc='0;fmt_response_exc.exc='1;
    end

    always_comb begin
        fmt_request_vaddr='0;fmt_request_vaddr.vaddr='1;
        fmt_request_paddr='0;fmt_request_paddr.paddr='1;
        fmt_request_check_only='0;fmt_request_check_only.check_only='1;
        fmt_request_write='0;fmt_request_write.write='1;
        fmt_request_wdata='0;fmt_request_wdata.wdata='1;
        fmt_request_bytes='0;fmt_request_bytes.bytes='1;
        fmt_request_split='0;fmt_request_split.split='1;
    end

    always_comb begin
        fmt_result_valid='0;fmt_result_valid.valid='1;
        fmt_result_data='0;fmt_result_data.data='1;
        fmt_result_tag_rob_idx='0;fmt_result_tag_rob_idx.tag.rob_idx='1;
    end
endmodule
