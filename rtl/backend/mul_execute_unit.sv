/** B13/B33/B34/B43 integer MUL wrapper.
 * 当前实现状态：目标实现。Four DSP datapath registers, II=1 subject to credits;
 * independent high/low tags, per-entry cancellation, dual enqueue to completion FIFO.
 * N accepts/reserves 1 or 2 credits and captures stage0. N+1..N+3 advance;
 * N+4 edge enqueues surviving results and returns canceled credits. The cycle before
 * a result becomes head broadcasts wake; head remains bypass-visible until WB grant.
 * Tests: sim/cocotb/mdu/.
 */
module mul_execute_unit import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,
    localparam int STAGES=CFG.exec.mul_stages,
    localparam int RESULT_SLOTS=CFG.exec.mul_result_slots
)(
    input logic clk,rst,req_valid_i,
    output logic req_ready_o, req_single_ready_o, req_pair_ready_o,
    input o3_types_pkg::mdu_req_t req_i,
    output logic resp_valid_o,
    input logic resp_ready_i,
    output o3_types_pkg::mdu_resp_t resp_o,
    output o3_types_pkg::cpl_bypass_t bypass_o,
    output o3_types_pkg::wake_promise_t wake_o,
    input branch_resolution_t resolution_i,
    output logic busy_o
);
    import o3_types_pkg::*;
    logic [64:0] a,b;
    logic [129:0] product;
    mdu_req_t pipe_q [0:3];
    logic [3:0] valid_q, hi_live_q,lo_live_q;
    logic fifo_busy, enq_valid,enq_pair;
    logic [1:0] release_count;
    wb_req_t hi,lo,head;
    logic hi_live,lo_live;
    always_comb begin
        a={req_i.src1[63] && req_i.op!=MDU_MULHU,req_i.src1};
        b={req_i.src2[63] && !(req_i.op inside {MDU_MULHU,MDU_MULHSU}),req_i.src2};
        hi='0;lo='0;
        hi.tag=pipe_q[3].tag; lo.tag=pipe_q[3].fuse.lo_tag;
        hi.tag.br_mask=br_resolved_mask(hi.tag.br_mask,resolution_i);
        lo.tag.br_mask=br_resolved_mask(lo.tag.br_mask,resolution_i);
        hi.data=pipe_q[3].op==MDU_MULW ? {{32{product[31]}},product[31:0]} :
            pipe_q[3].op==MDU_MUL ? product[63:0] : product[127:64];
        lo.data=product[63:0];
        hi_live=valid_q[3] && hi_live_q[3] && !br_killed(pipe_q[3].tag.br_mask,resolution_i);
        lo_live=valid_q[3] && lo_live_q[3] && !br_killed(pipe_q[3].fuse.lo_tag.br_mask,resolution_i);
        enq_valid=hi_live || lo_live; enq_pair=hi_live && lo_live;
        hi.valid=hi_live;lo.valid=lo_live;
        if(!hi_live && lo_live) hi=lo;
        release_count=0;
        if(valid_q[3]) release_count=2'((pipe_q[3].fuse.valid?2:1)-int'(hi_live)-int'(lo_live));
        resp_o='0;resp_o.valid=resp_valid_o;resp_o.tag=head.tag;resp_o.result=head.data;
        busy_o=fifo_busy || (|valid_q);
    end
    signed_mul65x65 u_data(.clk(clk),.en_i(1'b1),.a_i(a),.b_i(b),.p_o(product));
    fu_completion_fifo #(.CFG(CFG),.DEPTH(RESULT_SLOTS)) u_completion(
        .clk(clk),.rst(rst),.rsv_req_i(req_valid_i && req_ready_o),.rsv_pair_i(req_i.fuse.valid),
        .rsv_ok_o(req_ready_o),.rsv_single_ok_o(req_single_ready_o),.rsv_pair_ok_o(req_pair_ready_o),.rsv_release_i(release_count),
        .enq_valid_i(enq_valid),.enq_pair_i(enq_pair),.enq_i(hi),.enq2_i(lo),
        .promise_i('0),.promise_o(wake_o),.head_valid_o(resp_valid_o),.head_o(head),
        .head_consume_i(resp_ready_i),.bypass_o(bypass_o),.resolution_i(resolution_i),.busy_o(fifo_busy));
    always_ff @(posedge clk) begin
        if(rst) begin valid_q<=0;hi_live_q<=0;lo_live_q<=0;pipe_q<='{default:'0}; end
        else begin
            valid_q[0]<=req_valid_i && req_ready_o;
            hi_live_q[0]<=!br_killed(req_i.tag.br_mask,resolution_i);
            lo_live_q[0]<=req_i.fuse.valid && !br_killed(req_i.fuse.lo_tag.br_mask,resolution_i);
            pipe_q[0]<=req_i;
            pipe_q[0].tag.br_mask<=br_resolved_mask(req_i.tag.br_mask,resolution_i);
            pipe_q[0].fuse.lo_tag.br_mask<=br_resolved_mask(req_i.fuse.lo_tag.br_mask,resolution_i);
            for(int i=1;i<4;i++) begin
                valid_q[i]<=valid_q[i-1];pipe_q[i]<=pipe_q[i-1];
                hi_live_q[i]<=hi_live_q[i-1] && !br_killed(pipe_q[i-1].tag.br_mask,resolution_i);
                lo_live_q[i]<=lo_live_q[i-1] && !br_killed(pipe_q[i-1].fuse.lo_tag.br_mask,resolution_i);
                pipe_q[i].tag.br_mask<=br_resolved_mask(pipe_q[i-1].tag.br_mask,resolution_i);
                pipe_q[i].fuse.lo_tag.br_mask<=br_resolved_mask(pipe_q[i-1].fuse.lo_tag.br_mask,resolution_i);
            end
        end
    end
    initial assert(STAGES==4) else $fatal(1,"B43 requires four multiplier registers");
endmodule
