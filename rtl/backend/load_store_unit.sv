/** L8a two memory lanes. IS arbitration reserves RR/AG/cache/FIFO capacity.
 * LQ/SQ replays preserve VA and skip PRF/AGU. The cache lanes never hold.
 * SQ forwarding and protection are merged in S1; every wait exits S2 into
 * its queue. Numerical/exception FIFO heads remain until WB consumes them. */
module load_store_unit import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,localparam int P=CFG.lsu.agu_pipes,
    localparam int DEPTH=CFG.lsu.ld_result_fifo
)(input logic clk,rst,input mem_execute_uop_t mem_uop_i[P],
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
    output logic ad_wake_o,output o3_types_pkg::be_perf_t perf_o);
    typedef struct packed {logic valid,replay;lq_replay_t r;} pipe_t;
    pipe_t replay_rr_q[P],ag_q[P],s1_q[P],s2_q[P];
    logic tlb_valid[P],tlb_store[P],tlb_rsp_valid[P];o3_types_pkg::vaddr_t tlb_va[P];o3_types_pkg::tlb_resp_t tlb_rsp[P];
    o3_types_pkg::be_perf_t dtlb_perf;
    typedef struct packed {load_result_t load;o3_types_pkg::exc_info_t exc;} result_t;
    result_t fifo_q[P][DEPTH];int count_q[P],head_q[P],tail_q[P];
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
                int'(ag_q[p].valid)+int'(s1_q[p].valid)+int'(s2_q[p].valid);
            available=p<CFG.lsu.mem_pipes && inflight<DEPTH && !full_line_busy_i &&
                !(p==CFG.lsu.mem_pipes-1 && internal_busy_i) && !flush_all_i && !(resolution_valid_i && resolution_mispredict_i);
            lq_replay_ready_o[p]=available;
            sq_replay_ready_o[p]=available && !lq_replay_valid_i[p];
            issue_ready_o[p]=available && !lq_replay_valid_i[p] && !sq_replay_valid_i[p];
        end
    end
    always_comb begin
        for(int p=0;p<P;p++) begin
            lq_capture_valid_o[p]=ag_q[p].valid && ag_q[p].r.uop.is_load && !killed(ag_q[p].r.uop);
            sq_capture_valid_o[p]=ag_q[p].valid && ag_q[p].r.uop.is_store && !killed(ag_q[p].r.uop);
            dc_req_valid_o[p]=ag_q[p].valid && !killed(ag_q[p].r.uop);
            dc_req_o[p]='0;dc_req_o[p].src=o3_types_pkg::DC_SRC_LOAD;
            dc_req_o[p].vaddr=ag_q[p].r.va;dc_req_o[p].paddr=o3_types_pkg::paddr_t'(ag_q[p].r.va);
            dc_req_o[p].size=2'(ag_q[p].r.uop.mem_size);dc_req_o[p].is_signed=!ag_q[p].r.uop.mem_unsigned;
            dc_req_o[p].is_flw=ag_q[p].r.uop.dst_dom==o3_types_pkg::RD_FP && ag_q[p].r.uop.mem_size==MEM_SIZE_4B;
            dc_req_o[p].lq_tag=lq_tag_i[p];dc_req_o[p].sq_idx=ag_q[p].r.uop.sq_idx;
            dc_req_o[p].rob_idx=ag_q[p].r.uop.rob_idx;dc_req_o[p].br_mask=ag_q[p].r.uop.branch_mask;
            dc_req_o[p].is_rob_head=ag_q[p].r.uop.rob_idx==rob_head_i;
            dc_req_o[p].is_sta=ag_q[p].r.uop.is_store;dc_req_o[p].wdata=ag_q[p].r.uop.store_value;
            dc_req_o[p].wmask=size_mask(ag_q[p].r.uop.mem_size);dc_req_o[p].exc=ag_q[p].r.exc;
            tlb_valid[p]=dc_req_valid_o[p];tlb_va[p]=ag_q[p].r.va;tlb_store[p]=ag_q[p].r.uop.is_store;
        end
    end
    for(genvar p=0;p<P;p++) assign capture_o[p]=ag_q[p].r;
    o3_types_pkg::dcache_req_t translated_req[P];
    always_comb begin
        for(int p=0;p<P;p++) begin
            translated_req[p]=s1_req_q[p];
            translated_req[p].translation_miss=!tlb_rsp_valid[p] || tlb_rsp[p].miss || d_fence_q;
            if(tlb_rsp_valid[p] && tlb_rsp[p].hit) translated_req[p].paddr=o3_types_pkg::paddr_t'(
                csr_i.satp_mode==8 && csr_i.priv_eff!=3 ? o3_types_pkg::sv39_pa(tlb_rsp[p].ppn,s1_q[p].r.va,tlb_rsp[p].level):s1_q[p].r.va);
            // Protection precedes forwarding, RFO and all architectural effects.
            if(!translated_req[p].exc.valid && !translated_req[p].translation_miss) begin
                if(tlb_rsp[p].page_fault || tlb_rsp[p].access_fault ||
                    (!(csr_i.satp_mode==8 && csr_i.priv_eff!=3) && (s1_q[p].r.va>>o3_types_pkg::MEM_PADDR_W)!=0) ||
                    !o3_types_pkg::pma_main(64'(translated_req[p].paddr),1<<int'(translated_req[p].size)) ||
                    !o3_types_pkg::pmp_allow(pmp_i,translated_req[p].paddr,1<<int'(translated_req[p].size),csr_i.priv_eff,s1_q[p].r.uop.is_load,s1_q[p].r.uop.is_store,1'b0)) begin
                    translated_req[p].exc='{valid:1'b1,cause:(tlb_rsp[p].page_fault ?
                        (s1_q[p].r.uop.is_store ? o3_isa_pkg::EXCEPTION_CAUSE_STORE_PAGE_FAULT:o3_isa_pkg::EXCEPTION_CAUSE_LOAD_PAGE_FAULT):
                        (s1_q[p].r.uop.is_store ? o3_isa_pkg::EXCEPTION_CAUSE_STORE_ACCESS_FAULT:o3_isa_pkg::EXCEPTION_CAUSE_LOAD_ACCESS_FAULT)),tval:s1_q[p].r.va};
                end
            end
            sq_query_valid_o[p]=s1_q[p].valid && s1_q[p].r.uop.is_load && !translated_req[p].translation_miss && !translated_req[p].exc.valid;
            sq_query_rob_idx_o[p]=s1_q[p].r.uop.rob_idx;sq_query_addr_o[p]=64'(translated_req[p].paddr);
            sq_query_mask_o[p]=size_mask(s1_q[p].r.uop.mem_size);
            translated_req[p].forward_valid=0;translated_req[p].forward_data=0;translated_req[p].blocked=0;
            d_needed[p]=s1_q[p].valid && s1_q[p].r.uop.is_store && tlb_rsp_valid[p] && tlb_rsp[p].hit &&
                !tlb_rsp[p].perm_d && csr_i.adue && !translated_req[p].exc.valid;
            ad_block[p]=(d_pending_q || d_reserved_q) && age(s1_q[p].r.uop.rob_idx)>age(d_uop_q.rob_idx);
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
    o3_types_pkg::dcache_req_t s1_req_q[P];logic ad_block_s2_q[P],d_need_s2_q[P];
    always_comb begin
        d_mark_o=0;d_clear_o=0;d_idx_o=d_uop_q.rob_idx;d_va_o=d_va_q;d_sq_o=d_uop_q.sq_idx;
        ad_wake_o=d_refresh_q || ((d_pending_q || d_reserved_q) && killed(d_uop_q));
        for(int p=0;p<P;p++) begin
            update_o[p]=dc_resp_i[p];
            if(ad_block_s2_q[p]) begin update_o[p].status=o3_types_pkg::DC_REPLAY;update_o[p].reason=o3_types_pkg::LDW_AD_ORDER;end
            lq_update_valid_o[p]=s2_q[p].valid && s2_q[p].r.uop.is_load && dc_resp_i[p].valid && !killed(s2_q[p].r.uop);
            sq_update_valid_o[p]=s2_q[p].valid && s2_q[p].r.uop.is_store && dc_resp_i[p].valid && !killed(s2_q[p].r.uop);
            sq_execute_valid_o[p]=sq_update_valid_o[p] && dc_resp_i[p].status==o3_types_pkg::DC_OK && !ad_block_s2_q[p];
            if(d_need_s2_q[p] && sq_execute_valid_o[p] && !d_refresh_q) begin update_o[p].status=o3_types_pkg::DC_REPLAY;update_o[p].reason=o3_types_pkg::LDW_AD_ORDER;end
            sq_execute_idx_o[p]=s2_q[p].r.uop.sq_idx;sq_execute_addr_o[p]=64'(s2_pa_q[p]);
            sq_execute_rob_idx_o[p]=s2_q[p].r.uop.rob_idx;sq_execute_size_o[p]=s2_q[p].r.uop.mem_size;sq_execute_va_o[p]=s2_q[p].r.va;
            sq_execute_data_o[p]=s2_q[p].r.uop.store_value;sq_execute_mask_o[p]=size_mask(s2_q[p].r.uop.mem_size);
            store_complete_valid_o[p]=sq_execute_valid_o[p];
            store_complete_rob_idx_o[p]=s2_q[p].r.uop.rob_idx;
            if(sq_execute_valid_o[p] && d_need_s2_q[p] && !d_pending_q) begin d_mark_o=1;d_idx_o=s2_q[p].r.uop.rob_idx;end
            if(sq_execute_valid_o[p] && d_pending_q && s2_q[p].r.uop.rob_idx==d_uop_q.rob_idx && d_refresh_q) begin
                store_complete_valid_o[p]=1;d_clear_o=1;
            end
            fifo_push[p]=lq_update_valid_o[p] && update_o[p].status==o3_types_pkg::DC_OK;
            fifo_push[p]|=(lq_update_valid_o[p] || sq_update_valid_o[p]) && update_o[p].status==o3_types_pkg::DC_ERROR;
            fifo_new[p]='0;fifo_new[p].load.valid=1;fifo_new[p].load.instruction_id=s2_q[p].r.uop.instruction_id;
`ifdef O3_SIM
            fifo_new[p].load.kanata_id=s2_q[p].r.uop.kanata_id;
`endif
            fifo_new[p].load.rob_idx=s2_q[p].r.uop.rob_idx;fifo_new[p].load.lq_idx=s2_q[p].r.uop.lq_idx;
            fifo_new[p].load.dst_preg=s2_q[p].r.uop.dst_preg;fifo_new[p].load.dst_dom=s2_q[p].r.uop.dst_dom;
            fifo_new[p].load.result=update_o[p].rdata;fifo_new[p].load.branch_mask=s2_q[p].r.uop.branch_mask;
            fifo_new[p].load.va=s2_q[p].r.va;fifo_new[p].load.size=s2_q[p].r.uop.mem_size;
            fifo_new[p].exc=update_o[p].exc;
        end
        perf_o=dtlb_perf;
        for(int p=0;p<P;p++) begin
            perf_o[o3_types_pkg::BE_SQ_FORWARD]+=o3_types_pkg::BE_PERF_INC_W'(sq_query_valid_o[p] && sq_query_forward_valid_i[p]);
            perf_o[o3_types_pkg::BE_SQ_WAIT]+=o3_types_pkg::BE_PERF_INC_W'(sq_query_valid_o[p] && sq_query_block_i[p]);
        end
    end
    always_comb begin
        for(int p=0;p<P;p++) begin
            load_result_o[p]=fifo_q[p][head_q[p]].load;
            load_result_o[p].valid=count_q[p]>0 && !fifo_q[p][head_q[p]].exc.valid && !killed_result(fifo_q[p][head_q[p]].load);
            exc_valid_o[p]=count_q[p]>0 && fifo_q[p][head_q[p]].exc.valid && !killed_result(fifo_q[p][head_q[p]].load);
            exc_rob_idx_o[p]=fifo_q[p][head_q[p]].load.rob_idx;exc_o[p]=fifo_q[p][head_q[p]].exc;

        end
        if(d_fault_q) begin
            exc_valid_o[0]=!flush_all_i;exc_rob_idx_o[0]=d_uop_q.rob_idx;exc_o[0]=d_fault_exc_q;

        end
    end
    always_comb for(int p=0;p<P;p++) begin
        fifo_pop[p]=count_q[p]>0 && (killed_result(fifo_q[p][head_q[p]].load) ||
            (fifo_q[p][head_q[p]].exc.valid ? (!(p==0 && d_fault_q) && exc_ready_i[p]):load_result_ready_i[p]));
    end
    o3_types_pkg::paddr_t s2_pa_q[P];
    function automatic logic killed_result(input load_result_t r);
        return !r.valid || flush_all_i || (resolution_valid_i && resolution_mispredict_i && r.branch_mask[resolution_tag_i]);
    endfunction
    always_ff @(posedge clk) begin
        if(rst) begin
            replay_rr_q<='{default:'0};ag_q<='{default:'0};s1_q<='{default:'0};s2_q<='{default:'0};
            s1_req_q<='{default:'0};s2_pa_q<='{default:'0};ad_block_s2_q<='{default:0};d_need_s2_q<='{default:0};
            count_q<='{default:0};head_q<='{default:0};tail_q<='{default:0};
            d_pending_q<=0;d_reserved_q<=0;d_refresh_q<=0;d_fence_q<=0;d_uop_q<='0;d_fault_q<=0;d_fault_exc_q<='0;d_va_q<=0;
        end else begin
            for(int p=0;p<P;p++) begin
                replay_rr_q[p]<='0;
                if(lq_replay_valid_i[p] && lq_replay_ready_o[p]) replay_rr_q[p]<='{valid:1'b1,replay:1'b1,r:lq_replay_i[p]};
                else if(sq_replay_valid_i[p] && sq_replay_ready_o[p]) replay_rr_q[p]<='{valid:1'b1,replay:1'b1,r:sq_replay_i[p]};
                ag_q[p]<='0;
                if(replay_rr_q[p].valid && !killed(replay_rr_q[p].r.uop)) begin ag_q[p]<=replay_rr_q[p];ag_q[p].r.uop.branch_mask<=replay_rr_q[p].r.uop.branch_mask & ~(resolution_valid_i ? (branch_mask_t'(1)<<resolution_tag_i):'0);end
                else if(mem_uop_i[p].valid && !killed(mem_uop_i[p])) begin
                    ag_q[p].valid<=1;ag_q[p].r.uop<=mem_uop_i[p];ag_q[p].r.uop.branch_mask<=mem_uop_i[p].branch_mask & ~(resolution_valid_i ? (branch_mask_t'(1)<<resolution_tag_i):'0);ag_q[p].r.va<=mem_uop_i[p].base_value+mem_uop_i[p].imm_value;
                end
                s1_q[p]<=ag_q[p];s1_req_q[p]<=dc_req_o[p];s1_q[p].valid<=dc_req_valid_o[p];
                s2_q[p]<=s1_q[p];s2_pa_q[p]<=dc_s1_o[p].paddr;
                s2_q[p].valid<=s1_q[p].valid && !killed(s1_q[p].r.uop);
                ad_block_s2_q[p]<=ad_block[p];d_need_s2_q[p]<=d_needed[p];
                if(s1_q[p].valid && d_pick==p && d_needed[p] && !d_pending_q && !d_reserved_q) begin d_reserved_q<=1; d_uop_q<=s1_q[p].r.uop;d_va_q<=s1_q[p].r.va;end
                if(sq_update_valid_o[p] && s2_q[p].r.uop.rob_idx==d_uop_q.rob_idx && update_o[p].status==o3_types_pkg::DC_ERROR) d_reserved_q<=0;
                if(resolution_valid_i) begin
                    s1_q[p].r.uop.branch_mask<=ag_q[p].r.uop.branch_mask & ~(branch_mask_t'(1)<<resolution_tag_i);
                    s2_q[p].r.uop.branch_mask<=s1_q[p].r.uop.branch_mask & ~(branch_mask_t'(1)<<resolution_tag_i);
                    for(int f=0;f<DEPTH;f++) begin
                        if(resolution_mispredict_i && fifo_q[p][f].load.branch_mask[resolution_tag_i]) fifo_q[p][f].load.valid<=0;
                        fifo_q[p][f].load.branch_mask[resolution_tag_i]<=0;
                    end
                end
                if(fifo_push[p]) begin assert(count_q[p]<DEPTH || fifo_pop[p]);fifo_q[p][tail_q[p]]<=fifo_new[p];tail_q[p]<=(tail_q[p]+1)%DEPTH;end
                if(fifo_pop[p]) head_q[p]<=(head_q[p]+1)%DEPTH;
                count_q[p]<=count_q[p]+int'(fifo_push[p])-int'(fifo_pop[p]);
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
