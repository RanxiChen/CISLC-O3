/** One SNP in flight. Retain engine ownership after collection until S2
 * consumes the answer; an EVICT write-buffer retry does not release it. */
module l2_probe_engine import o3_types_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG
)(input logic clk,rst,input logic job_valid_i,output logic job_ready_o,input l2_work_t job_i,
    output logic snp_valid_o,input logic snp_ready_i,output coh_snp_t snp_o,
    input logic answer_valid_i,input coh_rsp_up_t answer_i,
    output logic collected_o,output logic [L2_SLOT_W-1:0] collected_slot_o,
    input logic release_i,output logic active_o);
    logic busy_q,sent_q,done_q;l2_work_t job_q;
    assign job_ready_o=!busy_q;
    assign snp_valid_o=busy_q && !sent_q;
    assign snp_o='{op:job_q.probe_op,owner:job_q.probe_owner,
        addr:(job_q.is_probe ? job_q.req.addr:job_q.victim_addr)};
    assign collected_o=answer_valid_i && busy_q && !done_q;
    assign collected_slot_o=job_q.slot;assign active_o=busy_q && !done_q;
    always_ff @(posedge clk) begin
        if(rst) begin busy_q<=0;sent_q<=0;done_q<=0;job_q<='0;end
        else begin
            if(job_valid_i && job_ready_o) begin busy_q<=1;sent_q<=0;done_q<=0;job_q<=job_i;end
            if(snp_valid_o && snp_ready_i) sent_q<=1;
            if(answer_valid_i) begin
                assert(busy_q && !done_q && (sent_q || (snp_valid_o && snp_ready_i)));
                assert(answer_i.addr==snp_o.addr && (!answer_i.has_data || job_q.probe_owner));
                assert(answer_i.op==(job_q.probe_op==COH_INV ? COH_INVACK:COH_DOWNACK));
                done_q<=1;
            end
            if(release_i) begin assert(busy_q && done_q);busy_q<=0;end
            if($past(snp_valid_o && !snp_ready_i && !rst)) assert(snp_valid_o && $stable(snp_o));
        end
    end
endmodule
