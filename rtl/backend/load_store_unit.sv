/** L8a two memory lanes. IS arbitration reserves RR/AG/cache/FIFO capacity.
 * LQ/SQ replays preserve VA and skip PRF/AGU. The cache lanes never hold.
 * AG/DTLB request -> registered translation result -> S1 protection/forwarding
 * -> S2 cache return -> R registered response -> completion. Two requests overlap
 * at every stage; every wait exits the response stage into
 * its queue. Numerical/exception FIFO heads remain until WB consumes them.
 * Successful loads notify one cycle before result FIFO visibility, never on a miss
 * prediction. Only live nonexception FIFO heads bypass; requests recheck data at RR.
 * 当前实现状态：闭环简化（L8b）；本次通知/旁路尚未功能验证。 */
module load_store_unit import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,localparam int P=CFG.lsu.agu_pipes,
    localparam int DEPTH=CFG.lsu.ld_result_fifo
)(input logic clk,rst,input mem_execute_uop_t mem_uop_i[P],
    input logic atomic_i[P],
    input logic heu_valid_i,output logic heu_ready_o,input o3_types_pkg::dcache_req_t heu_req_i,
    output o3_types_pkg::dcache_resp_t heu_resp_o,
    output o3_types_pkg::sq_kind_e sq_kind_o[P],
    input logic issue_is_load_i[P],output logic issue_ready_o[P],
    input logic lq_replay_valid_i[P],input lq_replay_t lq_replay_i[P],output logic lq_replay_ready_o[P],
    input logic sq_replay_valid_i[P],input lq_replay_t sq_replay_i[P],output logic sq_replay_ready_o[P],
    output logic lq_capture_valid_o[P],sq_capture_valid_o[P],output lq_replay_t capture_o[P],
    input o3_types_pkg::lq_tag_t lq_tag_i[P],
    output logic lq_update_valid_o[P],sq_update_valid_o[P],output o3_types_pkg::dcache_resp_t update_o[P],
    output logic sq_execute_valid_o[P],output logic [SQ_IDX_WIDTH-1:0] sq_execute_idx_o[P],
    output logic [XLEN-1:0] sq_execute_addr_o[P],sq_execute_data_o[P],output logic [7:0] sq_execute_mask_o[P],
    output logic [ROB_IDX_WIDTH-1:0] sq_execute_rob_idx_o[P],output mem_size_t sq_execute_size_o[P],
    output logic [XLEN-1:0] sq_execute_va_o[P],
    output logic sq_query_valid_o[P],output logic [ROB_IDX_WIDTH-1:0] sq_query_rob_idx_o[P],
    output logic [XLEN-1:0] sq_query_addr_o[P],output logic [7:0] sq_query_mask_o[P],
    input logic sq_query_block_i[P],sq_query_forward_valid_i[P],input logic [XLEN-1:0] sq_query_forward_data_i[P],
    input logic full_line_busy_i,internal_busy_i,
    output logic dc_req_valid_o[P],input logic dc_req_ready_i[P],output o3_types_pkg::dcache_req_t dc_req_o[P],dc_s1_o[P],
    input o3_types_pkg::dcache_resp_t dc_resp_i[P],
    output logic store_complete_valid_o[P],output logic [ROB_IDX_WIDTH-1:0] store_complete_rob_idx_o[P],
    output load_result_t load_result_o[P],input logic load_result_ready_i[P],
    output o3_types_pkg::wake_promise_t wake_o[P],
    output o3_types_pkg::cpl_bypass_t bypass_o[P],
    output logic exc_valid_o[P],output logic [ROB_IDX_WIDTH-1:0] exc_rob_idx_o[P],
    output o3_types_pkg::exc_info_t exc_o[P],input logic exc_ready_i[P],
    input logic flush_all_i,resolution_valid_i,resolution_mispredict_i,input branch_tag_t resolution_tag_i,
    output logic ptw_req_valid_o,input logic ptw_req_ready_i,output o3_types_pkg::ptw_req_t ptw_req_o,
    input o3_types_pkg::ptw_resp_t ptw_resp_i,input o3_types_pkg::dmmu_csr_t csr_i,input o3_types_pkg::pmp_state_t pmp_i,
    input o3_types_pkg::sfence_req_t sfence_i,output logic sfence_done_o,
    input logic [ROB_IDX_WIDTH-1:0] rob_head_i,
    input logic d_done_i,input o3_types_pkg::exc_info_t d_exc_i,
    output logic d_mark_o,d_clear_o,output o3_types_pkg::rob_idx_t d_idx_o,
    output o3_types_pkg::vaddr_t d_va_o,output o3_types_pkg::sq_idx_t d_sq_o,
    output logic ad_wake_o,sq_ad_wake_o,output o3_types_pkg::be_perf_t perf_o);
    initial assert(CFG.lsu.cache_s0_delay==3) else $fatal(1,"LSU AG/translation pipeline requires three-cycle cache reservation");
    typedef struct packed {logic valid,replay,atomic,head;lq_replay_t r;o3_types_pkg::dcache_req_t h;} pipe_t;
    logic deferred[P];o3_types_pkg::sq_kind_e deferred_kind[P];
    o3_types_pkg::sq_kind_e kind_tx_q[P],kind_s1_q[P],kind_s3_q[P];
    pipe_t heu_rr_q;
    pipe_t replay_rr_q[P],ag_q[P],tx_q[P],s1_q[P],s2_q[P],s3_q[P];
    o3_types_pkg::sq_kind_e kind_s2_q[P];
    o3_types_pkg::lq_tag_t s2_tag_q[P];o3_types_pkg::paddr_t s2_pa_q[P];
    logic ad_block_s2_q[P],d_need_s2_q[P];
    o3_types_pkg::dcache_resp_t response_q[P];
    logic ag_req_valid[P];
    o3_types_pkg::dcache_req_t ag_req[P],tx_req_q[P],translation_req[P];
    logic tlb_valid[P],tlb_store[P],tlb_rsp_valid[P];o3_types_pkg::vaddr_t tlb_va[P];o3_types_pkg::tlb_resp_t tlb_rsp[P];
    o3_types_pkg::be_perf_t dtlb_perf;
    typedef struct packed {load_result_t load;o3_types_pkg::exc_info_t exc;} result_t;
    localparam int FIFO_COUNT_W=$clog2(DEPTH+1),FIFO_PTR_W=DEPTH>1?$clog2(DEPTH):1;
    result_t fifo_head[P];logic [FIFO_COUNT_W-1:0] count_q[P];
    logic [FIFO_PTR_W-1:0] head_q[P],tail_q[P];
    logic fifo_push[P],fifo_pop[P];result_t fifo_new[P];
    logic d_pending_q,d_reserved_q,d_refresh_q,d_fence_q;mem_execute_uop_t d_uop_q;
    logic d_fault_q;o3_types_pkg::exc_info_t d_fault_exc_q;o3_types_pkg::vaddr_t d_va_q;
    o3_types_pkg::sfence_req_t dtlb_sfence;logic dtlb_sf_done;
    logic d_needed[P],ad_block[P];int d_pick;
    function automatic logic killed(input mem_execute_uop_t u);
        return flush_all_i || (resolution_valid_i && resolution_mispredict_i && u.branch_mask[resolution_tag_i]);
    endfunction
    function automatic int age(input logic [ROB_IDX_WIDTH-1:0] idx);
        return (int'(idx)+CFG.rob.entries-int'(rob_head_i))%CFG.rob.entries;
    endfunction
    function automatic logic [7:0] size_mask(input mem_size_t sz);
        return 8'((9'b1<<(1<<int'(sz)))-1);
    endfunction
    always_comb begin
        dtlb_sfence=sfence_i;
        if(d_pending_q && d_done_i && !d_exc_i.valid) dtlb_sfence='{valid:1'b1,rs1_is_x0:1'b0,rs2_is_x0:1'b1,vaddr:d_va_o,asid:'0};
    end
    dtlb #(.CFG(CFG)) u_dtlb(.clk(clk),.rst(rst),.kill_i(flush_all_i),
        .lookup_valid_i(tlb_valid),.lookup_vaddr_i(tlb_va),.lookup_is_store_i(tlb_store),
        .resp_valid_o(tlb_rsp_valid),.resp_o(tlb_rsp),.ptw_req_valid_o(ptw_req_valid_o),.ptw_req_ready_i(ptw_req_ready_i),
        .ptw_req_o(ptw_req_o),.ptw_resp_i(ptw_resp_i),.csr_i(csr_i),.sfence_i(dtlb_sfence),.sfence_done_o(dtlb_sf_done),.perf_o(dtlb_perf));
    assign sfence_done_o=dtlb_sf_done;
    always_comb begin
        for(int p=0;p<P;p++) begin
            int inflight;logic available;
            inflight=count_q[p]+int'(mem_uop_i[p].valid)+int'(replay_rr_q[p].valid)+
                int'(ag_q[p].valid)+int'(tx_q[p].valid)+int'(s1_q[p].valid)+int'(s2_q[p].valid)+int'(s3_q[p].valid);
            available=p<CFG.lsu.mem_pipes && inflight<DEPTH && !full_line_busy_i &&
                !(p==CFG.lsu.mem_pipes-1 && (internal_busy_i || heu_valid_i || heu_rr_q.valid)) && !flush_all_i && !(resolution_valid_i && resolution_mispredict_i);
            lq_replay_ready_o[p]=available;
            sq_replay_ready_o[p]=available && !lq_replay_valid_i[p];
            issue_ready_o[p]=available && !lq_replay_valid_i[p] && !sq_replay_valid_i[p];
        end
    end
    assign heu_ready_o=!full_line_busy_i && !internal_busy_i && !flush_all_i &&
        !mem_uop_i[CFG.lsu.mem_pipes-1].valid && !replay_rr_q[CFG.lsu.mem_pipes-1].valid && !heu_rr_q.valid;
    always_comb begin
        for(int p=0;p<P;p++) begin
            deferred[p]=!ag_q[p].head && CFG.lsu.heu_enable && (ag_q[p].atomic ||
                (CFG.lsu.split_enable && int'(ag_q[p].r.va[5:0])+(1<<int'(ag_q[p].r.uop.mem_size))>64));
            deferred_kind[p]=ag_q[p].atomic ? o3_types_pkg::SQ_ATOMIC:o3_types_pkg::SQ_SPLIT;
            lq_capture_valid_o[p]=ag_q[p].valid && !ag_q[p].head && ag_q[p].r.uop.is_load && !killed(ag_q[p].r.uop);
            sq_capture_valid_o[p]=ag_q[p].valid && !ag_q[p].head && ag_q[p].r.uop.is_store && !killed(ag_q[p].r.uop);
            ag_req_valid[p]=ag_q[p].valid && !deferred[p] && !killed(ag_q[p].r.uop);
            ag_req[p]='0;ag_req[p].src=o3_types_pkg::DC_SRC_LOAD;
            ag_req[p].vaddr=ag_q[p].r.va;ag_req[p].paddr=o3_types_pkg::paddr_t'(ag_q[p].r.va);
            ag_req[p].size=2'(ag_q[p].r.uop.mem_size);ag_req[p].is_signed=!ag_q[p].r.uop.mem_unsigned;
            ag_req[p].is_flw=ag_q[p].r.uop.dst_dom==o3_types_pkg::RD_FP && ag_q[p].r.uop.mem_size==MEM_SIZE_4B;
            ag_req[p].lq_tag=lq_tag_i[p];ag_req[p].sq_idx=ag_q[p].r.uop.sq_idx;
            ag_req[p].rob_idx=ag_q[p].r.uop.rob_idx;ag_req[p].br_mask=ag_q[p].r.uop.branch_mask;
            ag_req[p].is_rob_head=ag_q[p].r.uop.rob_idx==rob_head_i;
            ag_req[p].is_sta=ag_q[p].r.uop.is_store;ag_req[p].wdata=ag_q[p].r.uop.store_value;
            ag_req[p].wmask=size_mask(ag_q[p].r.uop.mem_size);ag_req[p].exc=ag_q[p].r.exc;
            if(ag_q[p].head) ag_req[p]=ag_q[p].h;
            if(ag_q[p].atomic && !CFG.lsu.heu_enable) ag_req[p].exc='{valid:1'b1,cause:EXCEPTION_CAUSE_ILLEGAL_INSTRUCTION,tval:'0};
            tlb_valid[p]=ag_req_valid[p];tlb_va[p]=ag_q[p].r.va;tlb_store[p]=ag_q[p].head ? ag_q[p].h.write:ag_q[p].r.uop.is_store;
        end
    end
    for(genvar p=0;p<P;p++) assign capture_o[p]=ag_q[p].r;
    // T: finish translation before permission, cache lookup and forwarding.
    // Cache S0 sees the corresponding VA packet in this translation cycle;
    // its S1 data aligns with the registered physical packet next cycle.
    always_comb begin
        for(int p=0;p<P;p++) begin
            dc_req_valid_o[p]=tx_q[p].valid && kind_tx_q[p]==o3_types_pkg::SQ_NORMAL && !killed(tx_q[p].r.uop);
            dc_req_o[p]=tx_req_q[p];
            if(resolution_valid_i) dc_req_o[p].br_mask[resolution_tag_i]=0;
            translation_req[p]=tx_req_q[p];
            translation_req[p].translation_miss=!tlb_rsp_valid[p] || tlb_rsp[p].miss || d_fence_q;
            if(tlb_rsp_valid[p] && tlb_rsp[p].hit) translation_req[p].paddr=o3_types_pkg::paddr_t'(
                csr_i.satp_mode==8 && csr_i.priv_eff!=3 ? o3_types_pkg::sv39_pa(tlb_rsp[p].ppn,tx_q[p].r.va,tlb_rsp[p].level):tx_q[p].r.va);
            if(!translation_req[p].exc.valid && !translation_req[p].translation_miss) begin
                if(tlb_rsp[p].page_fault || tlb_rsp[p].access_fault ||
                    (!(csr_i.satp_mode==8 && csr_i.priv_eff!=3) && (tx_q[p].r.va>>o3_types_pkg::MEM_PADDR_W)!=0)) begin
                    translation_req[p].exc='{valid:1'b1,cause:(tlb_rsp[p].page_fault ?
                        ((translation_req[p].write || translation_req[p].is_sta) ? o3_isa_pkg::EXCEPTION_CAUSE_STORE_PAGE_FAULT:o3_isa_pkg::EXCEPTION_CAUSE_LOAD_PAGE_FAULT):
                        ((translation_req[p].write || translation_req[p].is_sta) ? o3_isa_pkg::EXCEPTION_CAUSE_STORE_ACCESS_FAULT:o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ACCESS_FAULT)),tval:tx_q[p].r.va};
                end
            end
            translation_req[p].priv=csr_i.priv_eff;
            translation_req[p].need_d=tlb_rsp_valid[p] && tlb_rsp[p].hit && !tlb_rsp[p].perm_d && csr_i.adue;
        end
    end
    o3_types_pkg::dcache_req_t translated_req[P];
    always_comb begin
        for(int p=0;p<P;p++) begin
            translated_req[p]=s1_req_q[p];
            translated_req[p].translation_miss=s1_req_q[p].translation_miss || d_fence_q;
            translated_req[p].access_valid=1;
            translated_req[p].access_write=s1_req_q[p].write || s1_req_q[p].is_sta;
            translated_req[p].access_read=!translated_req[p].access_write || (s1_req_q[p].src==o3_types_pkg::DC_SRC_AMO && !(s1_req_q[p].amo_op inside {o3_types_pkg::AMO_SC,o3_types_pkg::AMO_LR}));
            translated_req[p].priv=s1_req_q[p].priv;
            translated_req[p].permission=o3_types_pkg::dc_permissions(translated_req[p],pmp_i,s1_req_q[p].priv);
            translated_req[p].need_d=s1_req_q[p].need_d;
            sq_query_valid_o[p]=s1_q[p].valid && !s1_q[p].head && kind_s1_q[p]==o3_types_pkg::SQ_NORMAL &&
                s1_q[p].r.uop.is_load && !translated_req[p].translation_miss;
            sq_query_rob_idx_o[p]=s1_q[p].r.uop.rob_idx;sq_query_addr_o[p]=64'(translated_req[p].paddr);
            sq_query_mask_o[p]=size_mask(s1_q[p].r.uop.mem_size);
            translated_req[p].forward_valid=0;translated_req[p].forward_data=0;translated_req[p].blocked=0;
            d_needed[p]=s1_q[p].valid && !s1_q[p].head && kind_s1_q[p]==o3_types_pkg::SQ_NORMAL && s1_q[p].r.uop.is_store && s1_req_q[p].need_d && !translated_req[p].exc.valid;
            ad_block[p]=!s1_q[p].head && (d_pending_q || d_reserved_q) && age(s1_q[p].r.uop.rob_idx)>age(d_uop_q.rob_idx);
            if(ad_block[p]) begin translated_req[p].blocked=1;translated_req[p].is_sta=0;translated_req[p].is_rob_head=0;end
        end
        d_pick=-1;
        for(int p=0;p<P;p++) if(d_needed[p] && (d_pick<0 || age(s1_q[p].r.uop.rob_idx)<age(s1_q[d_pick].r.uop.rob_idx))) d_pick=p;
        if(d_pick>=0) for(int p=0;p<P;p++) if(p!=d_pick && age(s1_q[p].r.uop.rob_idx)>age(s1_q[d_pick].r.uop.rob_idx)) begin
            ad_block[p]=1;translated_req[p].blocked=1;translated_req[p].is_sta=0;
        end
    end
    always_comb for(int p=0;p<P;p++) begin
        dc_s1_o[p]=translated_req[p];dc_s1_o[p].forward_valid=sq_query_forward_valid_i[p];
        dc_s1_o[p].forward_data=sq_query_forward_data_i[p];dc_s1_o[p].blocked=translated_req[p].blocked || sq_query_block_i[p];
    end
    o3_types_pkg::dcache_req_t s1_req_q[P];logic ad_block_s3_q[P],d_need_s3_q[P];
    always_comb begin
        heu_resp_o='0;
        for(int p=0;p<P;p++) if(response_q[p].valid && response_q[p].head && s3_q[p].valid && !killed(s3_q[p].r.uop)) heu_resp_o=response_q[p];
        d_mark_o=0;d_clear_o=0;d_idx_o=d_uop_q.rob_idx;d_va_o=d_va_q;d_sq_o=d_uop_q.sq_idx;
        // The owner must revalidate after DTLB refresh. Younger LQ entries
        // remain asleep until that revalidation clears needs_D, otherwise
        // their retries can consume every result reservation ahead of SQ.
        for(int p=0;p<P;p++) begin
            update_o[p]=response_q[p];
            if(kind_s3_q[p]!=o3_types_pkg::SQ_NORMAL && !s3_q[p].head && s3_q[p].valid) begin
                update_o[p]='0;update_o[p].valid=1;update_o[p].status=o3_types_pkg::DC_REPLAY;
                update_o[p].reason=o3_types_pkg::LDW_HEAD;update_o[p].sq_idx=s3_q[p].r.uop.sq_idx;
                update_o[p].lq_tag=s3_tag_q[p];
            end
            sq_kind_o[p]=kind_s3_q[p];
            if(update_o[p].reason==o3_types_pkg::LDW_HEAD && update_o[p].io) sq_kind_o[p]=o3_types_pkg::SQ_MMIO;
            if(ad_block_s3_q[p]) begin update_o[p].status=o3_types_pkg::DC_REPLAY;update_o[p].reason=o3_types_pkg::LDW_AD_ORDER;end
            lq_update_valid_o[p]=s3_q[p].valid && !s3_q[p].head && s3_q[p].r.uop.is_load && update_o[p].valid && !killed(s3_q[p].r.uop);
            sq_update_valid_o[p]=s3_q[p].valid && !s3_q[p].head && s3_q[p].r.uop.is_store && update_o[p].valid && !killed(s3_q[p].r.uop);
            sq_execute_valid_o[p]=sq_update_valid_o[p] && (update_o[p].status==o3_types_pkg::DC_OK || update_o[p].reason==o3_types_pkg::LDW_HEAD) && !ad_block_s3_q[p];
            if(d_need_s3_q[p] && sq_execute_valid_o[p] && !d_refresh_q) begin update_o[p].status=o3_types_pkg::DC_REPLAY;update_o[p].reason=o3_types_pkg::LDW_AD_ORDER;end
            sq_execute_idx_o[p]=s3_q[p].r.uop.sq_idx;sq_execute_addr_o[p]=64'(s3_pa_q[p]);
            sq_execute_rob_idx_o[p]=s3_q[p].r.uop.rob_idx;sq_execute_size_o[p]=s3_q[p].r.uop.mem_size;sq_execute_va_o[p]=s3_q[p].r.va;
            sq_execute_data_o[p]=s3_q[p].r.uop.store_value;sq_execute_mask_o[p]=size_mask(s3_q[p].r.uop.mem_size);
            store_complete_valid_o[p]=sq_execute_valid_o[p] && update_o[p].reason!=o3_types_pkg::LDW_HEAD;
            store_complete_rob_idx_o[p]=s3_q[p].r.uop.rob_idx;
            if(sq_execute_valid_o[p] && d_need_s3_q[p] && !d_pending_q) begin d_mark_o=1;d_idx_o=s3_q[p].r.uop.rob_idx;end
            if(sq_execute_valid_o[p] && d_pending_q && s3_q[p].r.uop.rob_idx==d_uop_q.rob_idx && d_refresh_q) begin
                store_complete_valid_o[p]=1;d_clear_o=1;
            end
            fifo_push[p]=lq_update_valid_o[p] && update_o[p].status==o3_types_pkg::DC_OK;
            fifo_push[p]|=(lq_update_valid_o[p] || sq_update_valid_o[p]) && update_o[p].status==o3_types_pkg::DC_ERROR;
            fifo_new[p]='0;fifo_new[p].load.valid=1;fifo_new[p].load.instruction_id=s3_q[p].r.uop.instruction_id;
`ifdef O3_SIM
            fifo_new[p].load.kanata_id=s3_q[p].r.uop.kanata_id;
`endif
            fifo_new[p].load.rob_idx=s3_q[p].r.uop.rob_idx;fifo_new[p].load.lq_idx=s3_q[p].r.uop.lq_idx;
            fifo_new[p].load.dst_preg=s3_q[p].r.uop.dst_preg;fifo_new[p].load.dst_dom=s3_q[p].r.uop.dst_dom;
            fifo_new[p].load.result=update_o[p].rdata;fifo_new[p].load.branch_mask=s3_q[p].r.uop.branch_mask &
                ~(resolution_valid_i ? (branch_mask_t'(1)<<resolution_tag_i):'0);
            fifo_new[p].load.va=s3_q[p].r.va;fifo_new[p].load.size=s3_q[p].r.uop.mem_size;
            fifo_new[p].exc=update_o[p].exc;
            wake_o[p]='0;
            if(!rst && fifo_push[p] && s3_q[p].r.uop.is_load && !fifo_new[p].exc.valid &&
               s3_q[p].r.uop.dst_write_en) wake_o[p]='{valid:1'b1,
                dom:fifo_new[p].load.dst_dom,preg:fifo_new[p].load.dst_preg,
                br_mask:fifo_new[p].load.branch_mask};
        end
        // Idle is also a completed condition for late S2 AD_ORDER responses.
        ad_wake_o=d_clear_o || !(d_pending_q || d_reserved_q) || killed(d_uop_q);
        sq_ad_wake_o=d_refresh_q || ad_wake_o;
        perf_o=dtlb_perf;
        for(int p=0;p<P;p++) begin
            perf_o[o3_types_pkg::BE_SQ_FORWARD]+=o3_types_pkg::BE_PERF_INC_W'(sq_query_valid_o[p] && sq_query_forward_valid_i[p]);
            perf_o[o3_types_pkg::BE_SQ_WAIT]+=o3_types_pkg::BE_PERF_INC_W'(sq_query_valid_o[p] && sq_query_block_i[p]);
        end
    end
    always_comb begin
        for(int p=0;p<P;p++) begin
            load_result_o[p]=fifo_head[p].load;
            load_result_o[p].valid=count_q[p]>0 && !fifo_head[p].exc.valid && !killed_result(fifo_head[p].load);
            bypass_o[p]='{valid:(load_result_o[p].valid && !rst &&
                (load_result_o[p].dst_dom!=o3_types_pkg::RD_INT || load_result_o[p].dst_preg!=0)),
                dom:load_result_o[p].dst_dom,preg:load_result_o[p].dst_preg,data:load_result_o[p].result};
            exc_valid_o[p]=count_q[p]>0 && fifo_head[p].exc.valid && !killed_result(fifo_head[p].load);
            exc_rob_idx_o[p]=fifo_head[p].load.rob_idx;exc_o[p]=fifo_head[p].exc;

        end
        if(d_fault_q) begin
            exc_valid_o[0]=!flush_all_i;exc_rob_idx_o[0]=d_uop_q.rob_idx;exc_o[0]=d_fault_exc_q;

        end
    end
    always_comb for(int p=0;p<P;p++) begin
        fifo_pop[p]=count_q[p]>0 && (killed_result(fifo_head[p].load) ||
            (fifo_head[p].exc.valid ? (!(p==0 && d_fault_q) && exc_ready_i[p]):load_result_ready_i[p]));
    end
    o3_types_pkg::paddr_t s3_pa_q[P];o3_types_pkg::lq_tag_t s3_tag_q[P];
    function automatic logic killed_result(input load_result_t r);
        return !r.valid || flush_all_i || (resolution_valid_i && resolution_mispredict_i && r.branch_mask[resolution_tag_i]);
    endfunction
    // Per-lane single-writer data RAM. Branch cancellation mutates only narrow
    // validity/mask metadata, leaving data/identity/exception payload stationary.
    for(genvar lane=0;lane<P;lane++) begin : g_result_storage
        (* ram_style="distributed" *) logic [$bits(result_t)-1:0] mem[DEPTH];
        logic valid_q[DEPTH];branch_mask_t mask_q[DEPTH];
        result_t write_data,read_data;
        always_comb begin
            write_data=fifo_new[lane];write_data.load.branch_mask='0;
            write_data.load.valid=1;
            read_data=result_t'(mem[head_q[lane]]);
            read_data.load.valid=valid_q[head_q[lane]];
            read_data.load.branch_mask=mask_q[head_q[lane]];
        end
        // The existing interfaces address only head; retain that view without
        // creating a multiwrite two-dimensional result memory.
        for(genvar slot=0;slot<DEPTH;slot++) begin : g_metadata
            always_ff @(posedge clk) if(!rst) begin
                if(resolution_valid_i) begin
                    if(resolution_mispredict_i && mask_q[slot][resolution_tag_i]) valid_q[slot]<=0;
                    mask_q[slot][resolution_tag_i]<=0;
                end
                if(fifo_push[lane] && tail_q[lane]==slot) begin
                    valid_q[slot]<=1;mask_q[slot]<=fifo_new[lane].load.branch_mask;
                end
            end
        end
        always_ff @(posedge clk)
            if(!rst && fifo_push[lane]) mem[tail_q[lane]]<=$bits(result_t)'(write_data);
        // One asynchronous read is shared by result, exception, bypass and pop.
        assign fifo_head[lane]=read_data;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            heu_rr_q<='0;kind_tx_q<='{default:o3_types_pkg::SQ_NORMAL};kind_s1_q<='{default:o3_types_pkg::SQ_NORMAL};kind_s3_q<='{default:o3_types_pkg::SQ_NORMAL};s3_tag_q<='{default:'0};
            replay_rr_q<='{default:'0};ag_q<='{default:'0};tx_q<='{default:'0};tx_req_q<='{default:'0};s1_q<='{default:'0};s3_q<='{default:'0};
            s2_q<='{default:'0};kind_s2_q<='{default:o3_types_pkg::SQ_NORMAL};s2_tag_q<='{default:'0};s2_pa_q<='{default:'0};
            ad_block_s2_q<='{default:0};d_need_s2_q<='{default:0};response_q<='{default:'0};
            s1_req_q<='{default:'0};s3_pa_q<='{default:'0};ad_block_s3_q<='{default:0};d_need_s3_q<='{default:0};
            count_q<='{default:0};head_q<='{default:0};tail_q<='{default:0};
            d_pending_q<=0;d_reserved_q<=0;d_refresh_q<=0;d_fence_q<=0;d_uop_q<='0;d_fault_q<=0;d_fault_exc_q<='0;d_va_q<=0;
        end else begin
            heu_rr_q<='0;
            if(heu_valid_i && heu_ready_o) begin
                heu_rr_q.valid<=1;heu_rr_q.head<=1;heu_rr_q.h<=heu_req_i;
                heu_rr_q.r.va<=heu_req_i.vaddr;heu_rr_q.r.uop.valid<=1;
                heu_rr_q.r.uop.rob_idx<=heu_req_i.rob_idx;
            end
            for(int p=0;p<P;p++) begin
                replay_rr_q[p]<='0;
                if(lq_replay_valid_i[p] && lq_replay_ready_o[p]) replay_rr_q[p]<='{valid:1'b1,replay:1'b1,r:lq_replay_i[p],default:'0};
                else if(sq_replay_valid_i[p] && sq_replay_ready_o[p]) replay_rr_q[p]<='{valid:1'b1,replay:1'b1,r:sq_replay_i[p],default:'0};
                ag_q[p]<='0;
                if(replay_rr_q[p].valid && !killed(replay_rr_q[p].r.uop)) begin ag_q[p]<=replay_rr_q[p];ag_q[p].r.uop.branch_mask<=replay_rr_q[p].r.uop.branch_mask & ~(resolution_valid_i ? (branch_mask_t'(1)<<resolution_tag_i):'0);end
                else if(mem_uop_i[p].valid && !killed(mem_uop_i[p])) begin
                    ag_q[p].valid<=1;ag_q[p].atomic<=atomic_i[p];ag_q[p].r.uop<=mem_uop_i[p];ag_q[p].r.uop.branch_mask<=mem_uop_i[p].branch_mask & ~(resolution_valid_i ? (branch_mask_t'(1)<<resolution_tag_i):'0);ag_q[p].r.va<=mem_uop_i[p].base_value+mem_uop_i[p].imm_value;
                end
                if(p==CFG.lsu.mem_pipes-1 && heu_rr_q.valid) begin ag_q[p]<=heu_rr_q;end
                tx_q[p]<=ag_q[p];tx_req_q[p]<=ag_req[p];tx_q[p].valid<=ag_q[p].valid && !killed(ag_q[p].r.uop);
                kind_tx_q[p]<=deferred[p] ? deferred_kind[p]:o3_types_pkg::SQ_NORMAL;
                s1_q[p]<=tx_q[p];s1_req_q[p]<=translation_req[p];s1_q[p].valid<=tx_q[p].valid && !killed(tx_q[p].r.uop);
                kind_s1_q[p]<=kind_tx_q[p];
                kind_s2_q[p]<=kind_s1_q[p];s2_tag_q[p]<=s1_req_q[p].lq_tag;
                s2_q[p]<=s1_q[p];s2_pa_q[p]<=dc_s1_o[p].paddr;
                s2_q[p].valid<=s1_q[p].valid && !killed(s1_q[p].r.uop);
                ad_block_s2_q[p]<=ad_block[p];d_need_s2_q[p]<=d_needed[p];
                // R captures the actual cache decision and its stationary owner.
                // No ready loop or serialization; both lanes advance every edge.
                response_q[p]<=dc_resp_i[p];
                response_q[p].valid<=dc_resp_i[p].valid && s2_q[p].valid && !killed(s2_q[p].r.uop);
                kind_s3_q[p]<=kind_s2_q[p];s3_tag_q[p]<=s2_tag_q[p];
                s3_q[p]<=s2_q[p];s3_pa_q[p]<=s2_pa_q[p];
                s3_q[p].valid<=s2_q[p].valid && !killed(s2_q[p].r.uop);
                ad_block_s3_q[p]<=ad_block_s2_q[p];d_need_s3_q[p]<=d_need_s2_q[p];
                if(s1_q[p].valid && d_pick==p && d_needed[p] && !d_pending_q && !d_reserved_q) begin d_reserved_q<=1; d_uop_q<=s1_q[p].r.uop;d_va_q<=s1_q[p].r.va;end
                if(sq_update_valid_o[p] && s3_q[p].r.uop.rob_idx==d_uop_q.rob_idx && update_o[p].status==o3_types_pkg::DC_ERROR) d_reserved_q<=0;
                if(resolution_valid_i) begin
                    tx_q[p].r.uop.branch_mask<=ag_q[p].r.uop.branch_mask & ~(branch_mask_t'(1)<<resolution_tag_i);
                    tx_req_q[p].br_mask<=ag_req[p].br_mask & ~(branch_mask_t'(1)<<resolution_tag_i);
                    s1_q[p].r.uop.branch_mask<=tx_q[p].r.uop.branch_mask & ~(branch_mask_t'(1)<<resolution_tag_i);
                    s1_req_q[p].br_mask<=translation_req[p].br_mask & ~(branch_mask_t'(1)<<resolution_tag_i);
                    s2_q[p].r.uop.branch_mask<=s1_q[p].r.uop.branch_mask & ~(branch_mask_t'(1)<<resolution_tag_i);
                    s3_q[p].r.uop.branch_mask<=s2_q[p].r.uop.branch_mask & ~(branch_mask_t'(1)<<resolution_tag_i);
                end
                if(fifo_push[p]) begin assert(count_q[p]<DEPTH || fifo_pop[p]);tail_q[p]<=FIFO_PTR_W'((int'(tail_q[p])+1)%DEPTH);end
                if(fifo_pop[p]) head_q[p]<=FIFO_PTR_W'((int'(head_q[p])+1)%DEPTH);
                count_q[p]<=FIFO_COUNT_W'(int'(count_q[p])+int'(fifo_push[p])-int'(fifo_pop[p]));
                if(flush_all_i) begin count_q[p]<=0;head_q[p]<=0;tail_q[p]<=0;end
                if(dc_req_valid_o[p]) assert(dc_req_ready_i[p]);
            end
            if(d_mark_o) d_pending_q<=1;
            if(d_pending_q && d_done_i) begin
                if(d_exc_i.valid) begin
                    d_fault_q<=1;d_fault_exc_q<=d_exc_i;d_pending_q<=0;d_reserved_q<=0;
                end else d_fence_q<=1;
            end
            if(d_fence_q && dtlb_sf_done) begin d_fence_q<=0;d_refresh_q<=1;end
            if(d_fault_q && exc_ready_i[0]) d_fault_q<=0;
            if(flush_all_i) d_fault_q<=0;
            if(d_clear_o || flush_all_i || ((d_pending_q || d_reserved_q) && killed(d_uop_q))) begin d_pending_q<=0;d_reserved_q<=0;d_refresh_q<=0;d_fence_q<=0;end
            if(resolution_valid_i) d_uop_q.branch_mask[resolution_tag_i]<=0;
        end
    end
endmodule
