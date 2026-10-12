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
    localparam int IW=DEPTH>1 ? $clog2(DEPTH):1;
    typedef logic [IW-1:0] slot_idx_t;
    // Wide result payload stays in its physical slot. Cancellation and dequeue
    // compact only a narrow ordered index list; two results can append per edge.
    wb_req_t payload_q[DEPTH];
    branch_mask_t mask_q[DEPTH];
    slot_idx_t order_q[DEPTH],order_d[DEPTH],append_slot[2];
    logic [DEPTH-1:0] occupied_q,occupied_d,keep;
    logic [CW-1:0] rank_before[DEPTH],count_q,count_d,used_q,used_d,survivors;
    logic [1:0] append;
    wb_req_t append_data[2],next_head;
    int returns;

    function automatic wb_req_t slot_data(input slot_idx_t index);
        wb_req_t item;
        item=payload_q[index];item.tag.br_mask=mask_q[index];
        return item;
    endfunction
    assign head_o=count_q!=0 ? slot_data(order_q[0]):wb_req_t'('0);
    assign head_valid_o=count_q!=0 && head_o.valid && !rst
        && !br_killed(head_o.tag.br_mask,resolution_i);
    assign busy_o=used_q!=0;
    assign rsv_single_ok_o=!rst && (int'(used_q)+1<=DEPTH);
    assign rsv_pair_ok_o=!rst && (int'(used_q)+2<=DEPTH);
    assign rsv_ok_o=rsv_pair_i ? rsv_pair_ok_o:rsv_single_ok_o;
    always_comb begin
        bypass_o='{valid:head_valid_o && head_o.tag.dst_write_en,
            dom:head_o.tag.dst_dom,preg:head_o.tag.dst_preg,data:head_o.data};
    end
    always_comb begin
        logic [DEPTH-1:0] available;
        survivors=0;returns=int'(rsv_release_i);keep='0;
        occupied_d='0;
        for(int pos=0;pos<DEPTH;pos++) begin
            rank_before[pos]=survivors;
            keep[pos]=pos<int'(count_q)
                && !br_killed(mask_q[order_q[pos]],resolution_i)
                && !(pos==0 && head_consume_i);
            survivors+=CW'(keep[pos]);
            if(pos<int'(count_q) && !keep[pos]) returns++;
            if(keep[pos]) occupied_d[order_q[pos]]=1;
        end
        append_data[0]=enq_i;append_data[1]=enq2_i;
        append='0;append_slot='{default:'0};available=~occupied_d;
        for(int lane=0;lane<2;lane++) begin
            logic found;
            found=0;
            if(enq_valid_i && (lane==0 || enq_pair_i)) begin
                if(br_killed(append_data[lane].tag.br_mask,resolution_i)) returns++;
                else begin
                    append[lane]=1;
                    for(int slot=0;slot<DEPTH;slot++)
                        if(available[slot] && !found) begin
                            append_slot[lane]=slot_idx_t'(slot);available[slot]=0;found=1;
                        end
                end
            end
            if(append[lane]) occupied_d[append_slot[lane]]=1;
        end
        count_d=survivors+CW'(append[0])+CW'(append[1]);
        order_d='{default:'0};
        for(int dst=0;dst<DEPTH;dst++) begin
            for(int pos=0;pos<DEPTH;pos++)
                if(keep[pos] && rank_before[pos]==CW'(dst)) order_d[dst]|=order_q[pos];
            if(append[0] && survivors==CW'(dst)) order_d[dst]|=append_slot[0];
            if(append[1] && survivors+CW'(append[0])==CW'(dst)) order_d[dst]|=append_slot[1];
        end
        used_d=CW'(int'(used_q)-returns+
            ((rsv_req_i && rsv_ok_o)?(rsv_pair_i?2:1):0));
        next_head='0;
        if(count_d!=0) begin
            next_head=slot_data(order_d[0]);
            for(int lane=0;lane<2;lane++)
                if(append[lane] && order_d[0]==append_slot[lane]) begin
                    next_head=append_data[lane];next_head.valid=1;
                end
            next_head.tag.br_mask=br_resolved_mask(next_head.tag.br_mask,resolution_i);
        end
        promise_o='0;
        if(!rst && next_head.valid && next_head.tag.dst_write_en
            && (!head_valid_o || head_consume_i))
            promise_o='{valid:1'b1,dom:next_head.tag.dst_dom,
                preg:next_head.tag.dst_preg,br_mask:next_head.tag.br_mask};
        // Existing next-head permission rule owns wakeup, not promise_i.
    end
    for(genvar slot=0;slot<DEPTH;slot++) begin : g_payload
        always_ff @(posedge clk) begin
            if(!rst) begin
                if(resolution_i.valid) mask_q[slot][resolution_i.branch_tag]<=0;
                for(int lane=0;lane<2;lane++)
                    if(append[lane] && append_slot[lane]==slot_idx_t'(slot)) begin
                        payload_q[slot]<=append_data[lane];
                        payload_q[slot].valid<=1;
                        payload_q[slot].tag.br_mask<='0;
                        mask_q[slot]<=br_resolved_mask(append_data[lane].tag.br_mask,resolution_i);
                    end
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            used_q<=0;count_q<=0;occupied_q<='0;order_q<='{default:'0};
        end else begin
            used_q<=used_d;count_q<=count_d;occupied_q<=occupied_d;order_q<=order_d;
            assert(used_d<=DEPTH) else $fatal(1,"completion credit overflow/underflow");
            assert(count_d<=used_d) else $fatal(1,"unreserved completion");
            assert(count_d<=DEPTH) else $fatal(1,"completion slot overflow");
            assert($countones(occupied_d)==int'(count_d)) else $fatal(1,"duplicate completion slot");
        end
    end
endmodule
