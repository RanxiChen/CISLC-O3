/** B33/B34 completion capacity and delivery queue.
 * 当前实现状态：目标实现。Credits cover both pipeline and completed entries.
 * rsv_pair reserves two; enq_pair appends two; rsv_release returns canceled
 * pipeline credits at the original exit edge. Queued cancellation returns credits here.
 * N combinational head/bypass stays visible through the PRF write edge. next-head
 * promise names exactly the result visible at N+1 (including a blocked FIFO becoming
 * empty, or a tail becoming head); no promises for inaccessible tails.
 * N edge compacts live entries, consumes head, appends results, updates credits.
 * N+1 new head is bypass-visible, or previous head is already in PRF.
 * Tests: sim/cocotb/fu_completion_fifo/, mdu/.
 */
module fu_completion_fifo import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,
    parameter int DEPTH
)(
    input logic clk, rst,
    input logic rsv_req_i, rsv_pair_i,
    output logic rsv_ok_o, rsv_single_ok_o, rsv_pair_ok_o,
    input logic [1:0] rsv_release_i,
    input logic enq_valid_i, enq_pair_i,
    input o3_types_pkg::wb_req_t enq_i, enq2_i,
    input o3_types_pkg::wake_promise_t promise_i,
    output o3_types_pkg::wake_promise_t promise_o,
    output logic head_valid_o,
    output o3_types_pkg::wb_req_t head_o,
    input logic head_consume_i,
    output o3_types_pkg::cpl_bypass_t bypass_o,
    input branch_resolution_t resolution_i,
    output logic busy_o
);
    import o3_types_pkg::*;
    localparam int CW=$clog2(DEPTH+1);
    wb_req_t queue_q [DEPTH-1:0], queue_d [DEPTH-1:0];
    logic [CW-1:0] used_q, used_d;
    int count_d, returns;
    assign head_valid_o=queue_q[0].valid && !br_killed(queue_q[0].tag.br_mask,resolution_i) && !rst;
    assign head_o=queue_q[0];
    assign busy_o=used_q!=0;
    always_comb begin
        bypass_o='0;
        bypass_o.valid=head_valid_o && head_o.tag.dst_write_en;
        bypass_o.dom=head_o.tag.dst_dom; bypass_o.preg=head_o.tag.dst_preg; bypass_o.data=head_o.data;
    end
    // Capacity is deliberately based on registered credits, avoiding a ready->grant
    // loop through writeback or the shared read arbiter. A returned credit is usable next cycle.
    assign rsv_single_ok_o=!rst && (int'(used_q)+1<=DEPTH);
    assign rsv_pair_ok_o=!rst && (int'(used_q)+2<=DEPTH);
    assign rsv_ok_o=rsv_pair_i ? rsv_pair_ok_o:rsv_single_ok_o;
    always_comb begin
        queue_d='{default:'0}; count_d=0; returns=int'(rsv_release_i);
        for(int i=0;i<DEPTH;i++) if(queue_q[i].valid) begin
            if(br_killed(queue_q[i].tag.br_mask,resolution_i) || (i==0 && head_consume_i)) returns++;
            else begin
                queue_d[count_d]=queue_q[i];
                queue_d[count_d].tag.br_mask=br_resolved_mask(queue_q[i].tag.br_mask,resolution_i);
                count_d++;
            end
        end
        if(enq_valid_i) begin
            if(br_killed(enq_i.tag.br_mask,resolution_i)) returns++;
            else if(count_d<DEPTH) begin
                queue_d[count_d]=enq_i; queue_d[count_d].valid=1;
                queue_d[count_d].tag.br_mask=br_resolved_mask(enq_i.tag.br_mask,resolution_i); count_d++;
            end
            if(enq_pair_i) begin
                if(br_killed(enq2_i.tag.br_mask,resolution_i)) returns++;
                else if(count_d<DEPTH) begin
                    queue_d[count_d]=enq2_i; queue_d[count_d].valid=1;
                    queue_d[count_d].tag.br_mask=br_resolved_mask(enq2_i.tag.br_mask,resolution_i); count_d++;
                end
            end
        end
        used_d=CW'(int'(used_q)-returns+((rsv_req_i && rsv_ok_o)?(rsv_pair_i?2:1):0));
        promise_o='0;
        if(!rst && queue_d[0].valid && queue_d[0].tag.dst_write_en &&
           (!head_valid_o || head_consume_i)) begin
            promise_o.valid=1; promise_o.dom=queue_d[0].tag.dst_dom;
            promise_o.preg=queue_d[0].tag.dst_preg; promise_o.br_mask=queue_d[0].tag.br_mask;
        end
        // promise_i is retained for FU timing metadata; the actual next-head test
        // above owns permission to wake (so an upstream promise can never expose a tail).
    end
    always_ff @(posedge clk) begin
        if(rst) begin queue_q<='{default:'0}; used_q<=0; end
        else begin
            queue_q<=queue_d; used_q<=used_d;
            assert(used_d<=DEPTH) else $fatal(1,"completion credit overflow/underflow");
            assert(count_d<=int'(used_d)) else $fatal(1,"unreserved completion");
            if(enq_valid_i) assert(count_d<=DEPTH);
        end
    end
endmodule
