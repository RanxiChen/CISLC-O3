/** One head instruction, two checked halves, held WB. No speculative external effects. */
module mem_head_unit import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(input logic clk,rst,input logic start_valid_i,output logic start_ready_o,input heu_req_t start_i,
  input logic sq_empty_i,flush_i,input rob_idx_t rob_head_i,
  output logic dc_valid_o,input logic dc_ready_i,output dcache_req_t dc_req_o,input dcache_resp_t dc_resp_i,
  input dc_wake_t wake_i,input logic tlb_wake_i,
  output logic d_valid_o,input logic d_ready_i,output vaddr_t d_va_o,output sq_idx_t d_sq_o,
  input logic d_done_i,input exc_info_t d_exc_i,
  output sfence_req_t sfence_o,input logic sfence_done_i,
  output logic mmio_valid_o,input logic mmio_ready_i,output dcache_req_t mmio_req_o,input dcache_resp_t mmio_resp_i,
  input logic cache_irreversible_i,mmio_irreversible_i,output logic irreversible_o,
  output wb_req_t result_o,input logic result_ready_i,
  output logic exc_valid_o,input logic exc_ready_i,output exc_info_t exc_o,output rob_idx_t exc_idx_o,
  output logic done_o,output rob_idx_t done_idx_o,output be_perf_t perf_o);
    typedef enum logic [3:0] {IDLE,CHECK,SEND_WAIT,ACCESS,RETRY,DREQ,DWAIT,SFENCE,SFWAIT,MMIO,MMWAIT,RESULT,EXCEPTION,DONE} state_t;
    state_t state_q,return_q,retry_q;heu_req_t req_q;logic half_q,split_q,irreversible_q;
    logic [3:0] lo_bytes_q,hi_bytes_q;vaddr_t hi_va_q; paddr_t pa_q[2];logic io_q;
    logic [63:0] lo_q,result_q;exc_info_t exc_q;ld_wait_e reason_q;coh_id_t mshr_q;
    function automatic exc_info_t access_fault(input vaddr_t va);
        return '{valid:1'b1,cause:(req_q.write ? EXCEPTION_CAUSE_STORE_ACCESS_FAULT:EXCEPTION_CAUSE_LOAD_ACCESS_FAULT),tval:va};
    endfunction
    assign start_ready_o=state_q==IDLE && sq_empty_i && !flush_i && start_i.tag.rob_idx==rob_head_i;
    assign irreversible_o=irreversible_q || cache_irreversible_i || mmio_irreversible_i;
    assign dc_valid_o=(state_q==CHECK || state_q==ACCESS) && !flush_i;
    always_comb begin
        dc_req_o='0;dc_req_o.head=1;dc_req_o.is_rob_head=1;
        dc_req_o.src=req_q.kind==SQ_ATOMIC ? DC_SRC_AMO:DC_SRC_LOAD;
        dc_req_o.vaddr=half_q ? hi_va_q:req_q.va;dc_req_o.paddr=pa_q[half_q];
        dc_req_o.size=req_q.size;dc_req_o.bytes=split_q ? (half_q ? hi_bytes_q:lo_bytes_q):4'(1<<int'(req_q.size));
        dc_req_o.write=req_q.write;dc_req_o.amo_op=req_q.amo_op;
        dc_req_o.check_only=state_q==CHECK;dc_req_o.split=split_q;dc_req_o.raw=split_q;
        dc_req_o.is_signed=req_q.is_signed;dc_req_o.is_flw=req_q.is_flw;
        dc_req_o.wdata=half_q ? req_q.data>>(8*int'(lo_bytes_q)):req_q.data;
        dc_req_o.wmask=8'((9'b1<<int'(dc_req_o.bytes))-1);
        dc_req_o.rob_idx=req_q.tag.rob_idx;dc_req_o.sq_idx=req_q.sq_idx;dc_req_o.lq_tag=req_q.lq_tag;
        mmio_req_o=dc_req_o;mmio_req_o.paddr=pa_q[0];mmio_req_o.check_only=0;
        result_o='{valid:state_q==RESULT,tag:req_q.tag,data:result_q,fflags:'0};
        d_va_o=dc_req_o.vaddr;d_sq_o=req_q.sq_idx;
        d_valid_o=state_q==DREQ && !flush_i;
        sfence_o='{valid:state_q==SFENCE,rs1_is_x0:1'b0,rs2_is_x0:1'b1,vaddr:d_va_o,asid:'0};
        mmio_valid_o=state_q==MMIO && !flush_i;
        exc_valid_o=state_q==EXCEPTION;exc_o=exc_q;exc_idx_o=req_q.tag.rob_idx;
        done_o=state_q==DONE;done_idx_o=req_q.tag.rob_idx;
        perf_o='0;
        perf_o[BE_MMIO_READ]=BE_PERF_INC_W'(mmio_valid_o && mmio_ready_i && !req_q.write);
        perf_o[BE_MMIO_WRITE]=BE_PERF_INC_W'(mmio_valid_o && mmio_ready_i && req_q.write);
    end
    always_ff @(posedge clk) begin
        if(rst) begin state_q<=IDLE;return_q<=CHECK;retry_q<=CHECK;req_q<='0;half_q<=0;split_q<=0;
            irreversible_q<=0;lo_bytes_q<=0;hi_bytes_q<=0;hi_va_q<=0;pa_q<='{default:0};io_q<=0;
            lo_q<=0;result_q<=0;exc_q<='0;reason_q<=LDW_NONE;mshr_q<=0;end
        else if(flush_i && !irreversible_o) begin state_q<=IDLE;irreversible_q<=0;end
        else begin
            if(cache_irreversible_i || mmio_irreversible_i) irreversible_q<=1;
            case(state_q)
                IDLE:if(start_valid_i && start_ready_o) begin
                    req_q<=start_i;half_q<=0;io_q<=0;irreversible_q<=0;exc_q<='0;
                    split_q<=start_i.kind==SQ_SPLIT;
                    lo_bytes_q<=4'(64-int'(start_i.va[5:0]));
                    hi_bytes_q<=4'((1<<int'(start_i.size))-(64-int'(start_i.va[5:0])));
                    hi_va_q<=(start_i.va & ~64'd63)+64;state_q<=CHECK;
                end
                CHECK,ACCESS:if(dc_valid_o && dc_ready_i) begin return_q<=state_q;state_q<=SEND_WAIT;end
                SEND_WAIT:if(dc_resp_i.valid) begin
                    if(dc_resp_i.status==DC_ERROR) begin exc_q<=dc_resp_i.exc;state_q<=EXCEPTION;end
                    else if(dc_resp_i.status!=DC_OK) begin
                        reason_q<=dc_resp_i.reason;mshr_q<=dc_resp_i.mshr_id;retry_q<=return_q;state_q<=RETRY;
                        if(dc_resp_i.reason==LDW_MSHR && wake_i.valid && wake_i.mshr_id==dc_resp_i.mshr_id) begin
                            if(wake_i.err) begin exc_q<=access_fault(dc_req_o.vaddr);state_q<=EXCEPTION;end
                            else state_q<=return_q;
                        end
                    end else if(return_q==CHECK) begin
                        pa_q[half_q]<=dc_resp_i.paddr;io_q<=dc_resp_i.io;
                        if(req_q.write && dc_resp_i.need_d) state_q<=DREQ;
                        else if(split_q && !half_q) begin half_q<=1;state_q<=CHECK;end
                        else begin half_q<=0;state_q<=dc_resp_i.io ? MMIO:ACCESS;end
                    end else if(split_q && !half_q) begin lo_q<=dc_resp_i.rdata;half_q<=1;state_q<=ACCESS;end
                    else begin
                        result_q<=split_q ? mem_format(lo_q | (dc_resp_i.rdata<<(8*int'(lo_bytes_q))),req_q.size,req_q.is_signed,req_q.is_flw):dc_resp_i.rdata;
                        state_q<=req_q.tag.dst_write_en ? RESULT:DONE;
                    end
                end
                RETRY:case(reason_q)
                    LDW_MSHR:if(wake_i.valid && wake_i.mshr_id==mshr_q) begin
                        if(wake_i.err) begin exc_q<=access_fault(dc_req_o.vaddr);state_q<=EXCEPTION;end
                        else state_q<=retry_q;
                    end
                    LDW_TLB_MISS:if(tlb_wake_i) state_q<=retry_q;
                    LDW_MSHR_FULL:if(wake_i.mshr_free) state_q<=retry_q;
                    LDW_WB_LINE:if(wake_i.wb_free) state_q<=retry_q;
                    default:state_q<=retry_q;
                endcase
                DREQ:if(d_ready_i) state_q<=DWAIT;
                DWAIT:if(d_done_i) begin
                    if(d_exc_i.valid) begin exc_q<=d_exc_i;state_q<=EXCEPTION;end
                    else state_q<=SFENCE;
                end
                SFENCE:state_q<=SFWAIT;
                SFWAIT:if(sfence_done_i) state_q<=CHECK;
                MMIO:if(mmio_ready_i) begin state_q<=MMWAIT;irreversible_q<=1;end
                MMWAIT:if(mmio_resp_i.valid) begin
                    if(mmio_resp_i.status==DC_ERROR) begin exc_q<=mmio_resp_i.exc;state_q<=EXCEPTION;end
                    else begin result_q<=mmio_resp_i.rdata;state_q<=req_q.tag.dst_write_en ? RESULT:DONE;end
                end
                RESULT:if(result_ready_i) begin state_q<=IDLE;irreversible_q<=0;end
                DONE:begin state_q<=IDLE;irreversible_q<=0;end
                EXCEPTION:if(exc_ready_i) begin state_q<=IDLE;irreversible_q<=0;end
                default:state_q<=IDLE;
            endcase
        end
    end
endmodule
