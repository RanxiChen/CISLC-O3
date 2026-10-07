/** L10 Svadu side path. One accepted physical CAS is owned until its response.
 * N accepts an A request, edge N stores its full expected PTE; N+1 presents
 * the DCache CAS. Kill/epoch prevents new CAS, but accepted operations drain.
 * A miss comparison restarts in PTW. Queue-head D requests snapshot context,
 * rewalk through PTW and use the same CAS channel with set_d only at commit.
 * No retry bound: software races retry in hardware (B49), no software trap.
 * Reservation conflict reports actual successful writes; reservation is L8.
 * Tests: sim/cocotb/mmu/ and sim/cocotb/commit_ctrl/.
 */
module pte_ad_updater import o3_types_pkg::*; #(parameter o3_cfg_pkg::backend_cfg_t CFG)(
    input logic clk,rst,
    input logic ptw_a_req_valid_i,output logic ptw_a_req_ready_o,input pte_ad_req_t ptw_a_req_i,output pte_ad_resp_t ptw_a_resp_o,
    input logic st_d_req_valid_i,output logic st_d_req_ready_o,input vaddr_t st_d_vaddr_i,input sq_idx_t st_d_sq_idx_i,
    output logic st_d_done_o,output exc_info_t st_d_exc_o,
    output logic rewalk_req_valid_o,input logic rewalk_req_ready_i,output ptw_req_t rewalk_req_o,input ptw_resp_t rewalk_resp_i,
    output logic dc_req_valid_o,input logic dc_req_ready_i,output pte_ad_req_t dc_req_o,input pte_ad_resp_t dc_resp_i,
    input dmmu_csr_t csr_i,input xlate_epoch_t cur_epoch_i,input logic kill_i,
    output rsv_conflict_t rsv_conflict_o,output logic busy_o,output be_perf_t perf_o
);
    typedef enum logic[1:0] {A_IDLE,A_SEND,A_WAIT,A_RESP} astate_t;
    typedef enum logic[1:0] {D_IDLE,D_SEND,D_WAIT,D_RESP} dstate_t;
    astate_t astate_q;dstate_t dstate_q;
    pte_ad_req_t a_req_q;pte_ad_resp_t a_resp_q;
    ptw_req_t d_req_q;vaddr_t d_va_q;exc_info_t d_exc_q;
    logic a_canceled_q,d_canceled_q;
    assign ptw_a_req_ready_o=astate_q==A_IDLE && !kill_i;
    assign dc_req_valid_o=astate_q==A_SEND && a_req_q.epoch==cur_epoch_i && !kill_i;
    assign dc_req_o=a_req_q;
    assign ptw_a_resp_o=astate_q==A_RESP ? a_resp_q : '0;
    assign st_d_req_ready_o=dstate_q==D_IDLE && !kill_i;
    assign rewalk_req_valid_o=dstate_q==D_SEND && d_req_q.epoch==cur_epoch_i && !kill_i;
    assign rewalk_req_o=d_req_q;
    assign st_d_done_o=dstate_q==D_RESP && !d_canceled_q && !kill_i && d_req_q.epoch==cur_epoch_i;
    assign st_d_exc_o=d_exc_q;
    assign busy_o=astate_q!=A_IDLE || dstate_q!=D_IDLE;
    assign rsv_conflict_o='{valid:(astate_q==A_WAIT && dc_resp_i.valid && dc_resp_i.updated),paddr:a_req_q.pte_paddr};
    always_comb begin
        perf_o='0;
        perf_o[BE_PTE_A_UPDATE]=BE_PERF_INC_W'(astate_q==A_WAIT && dc_resp_i.valid && dc_resp_i.updated && a_req_q.set_a && !a_req_q.expected_pte[6]);
        perf_o[BE_PTE_D_UPDATE]=BE_PERF_INC_W'(astate_q==A_WAIT && dc_resp_i.valid && dc_resp_i.updated && a_req_q.set_d && !a_req_q.expected_pte[7]);
    end
    always_ff @(posedge clk) begin
        if(rst) begin astate_q<=A_IDLE;dstate_q<=D_IDLE;a_req_q<='0;a_resp_q<='0;d_req_q<='0;d_va_q<=0;d_exc_q<='0;a_canceled_q<=0;d_canceled_q<=0;end
        else begin
            case(astate_q)
                A_IDLE: if(ptw_a_req_valid_i && ptw_a_req_ready_o) begin a_req_q<=ptw_a_req_i;a_canceled_q<=0;astate_q<=A_SEND;end
                A_SEND: if(kill_i || a_req_q.epoch!=cur_epoch_i) begin
                    a_resp_q<='{valid:1'b1,mismatch:1'b1,default:'0};astate_q<=A_RESP;
                end else if(dc_req_ready_i) astate_q<=A_WAIT;
                A_WAIT: begin
                    if(kill_i || a_req_q.epoch!=cur_epoch_i) a_canceled_q<=1;
                    if(dc_resp_i.valid) begin a_resp_q<=dc_resp_i;astate_q<=A_RESP;end
                end
                A_RESP: astate_q<=A_IDLE;
                default: astate_q<=A_IDLE;
            endcase
            case(dstate_q)
                D_IDLE: if(st_d_req_valid_i && st_d_req_ready_o) begin
                    d_req_q<='{vpn:st_d_vaddr_i[38:12],asid:csr_i.satp_asid,epoch:cur_epoch_i,src:PTW_SRC_DCOMMIT,
                        root_ppn:csr_i.satp_ppn,priv:csr_i.priv_eff,is_store:1'b1,sum:csr_i.sum,mxr:csr_i.mxr,adue:csr_i.adue};
                    d_va_q<=st_d_vaddr_i;d_exc_q<='0;d_canceled_q<=0;dstate_q<=D_SEND;
                end
                D_SEND: if(kill_i || d_req_q.epoch!=cur_epoch_i) dstate_q<=D_IDLE;
                    else if(rewalk_req_ready_i) dstate_q<=D_WAIT;
                D_WAIT: begin
                    if(kill_i || d_req_q.epoch!=cur_epoch_i) d_canceled_q<=1;
                    if(rewalk_resp_i.valid && rewalk_resp_i.src==PTW_SRC_DCOMMIT && rewalk_resp_i.epoch==d_req_q.epoch) begin
                        d_exc_q<='{valid:(rewalk_resp_i.page_fault || rewalk_resp_i.access_fault),
                            cause:(rewalk_resp_i.access_fault ? EXCEPTION_CAUSE_STORE_ACCESS_FAULT : EXCEPTION_CAUSE_STORE_PAGE_FAULT),tval:d_va_q};
                        dstate_q<=D_RESP;
                    end
                end
                D_RESP: dstate_q<=D_IDLE;
                default: dstate_q<=D_IDLE;
            endcase
        end
    end
endmodule
