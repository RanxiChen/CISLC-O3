/** B13/B21/B33 DIV/REM wrapper. 当前实现状态：目标实现。
 * One active arithmetic request, two completion credits. Zero and signed overflow
 * complete via the fast slot. Word operands normalized before magnitude calculation.
 * N accepts/reserves and starts radix4, or sets fast_valid. The cycle done/fast is
 * visible computes sign-restored enqueue; its edge makes a new head available.
 * Kill aborts active math and returns its one credit; queued results cancel separately.
 * Wake is issued only for a next-cycle deliverable FIFO head, never at DIV launch.
 * Tests: sim/cocotb/mdu/.
 */
module div_execute_unit import o3_pkg::*; #(
    parameter o3_cfg_pkg::backend_cfg_t CFG,
    localparam int MAX_ITERS=CFG.exec.div_max_iters
)(
    input logic clk,rst,req_valid_i,
    output logic req_ready_o,
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
    logic active_q,fast_q,word_q,rem_q,qneg_q,rneg_q;
    logic signed_op,word_op,rem_op,zero_case,overflow_case;
    logic [63:0] a,b,amag,bmag,q,r,fast_data_q,value;
    logic data_ready,done,kill_active,fifo_ready,fifo_busy,fire;
    fu_tag_t tag_q;
    wb_req_t enq,head;
    always_comb begin
        word_op=req_i.op inside {MDU_DIVW,MDU_DIVUW,MDU_REMW,MDU_REMUW};
        signed_op=req_i.op inside {MDU_DIV,MDU_REM,MDU_DIVW,MDU_REMW};
        rem_op=req_i.op inside {MDU_REM,MDU_REMU,MDU_REMW,MDU_REMUW};
        a=word_op ? {{32{signed_op && req_i.src1[31]}},req_i.src1[31:0]} : req_i.src1;
        b=word_op ? {{32{signed_op && req_i.src2[31]}},req_i.src2[31:0]} : req_i.src2;
        amag=signed_op && a[63] ? -a : a; bmag=signed_op && b[63] ? -b : b;
        zero_case=b==0;
        overflow_case=signed_op && b=='1 && a==(word_op ? 64'hffffffff80000000 : 64'h8000000000000000);
        value=fast_q ? fast_data_q : rem_q ? (rneg_q ? -r:r) : (qneg_q ? -q:q);
        if(word_q) value={{32{value[31]}},value[31:0]};
        enq='0;enq.valid=active_q && (done || fast_q) && !kill_active;
        enq.tag=tag_q;enq.tag.br_mask=br_resolved_mask(tag_q.br_mask,resolution_i);enq.data=value;
        resp_o='0;resp_o.valid=resp_valid_o;resp_o.tag=head.tag;resp_o.result=head.data;
    end
    assign kill_active=active_q && br_killed(tag_q.br_mask,resolution_i);
    assign req_ready_o=!rst && !active_q && data_ready && fifo_ready;
    assign fire=req_valid_i && req_ready_o;
    assign busy_o=active_q || fifo_busy;
    unsigned_radix4_divider u_data(.clk(clk),.rst(rst),.start_i(fire && !zero_case && !overflow_case),
        .ready_o(data_ready),.dividend_i(amag),.divisor_i(bmag),.abort_i(kill_active),
        .done_o(done),.quotient_o(q),.remainder_o(r));
    fu_completion_fifo #(.CFG(CFG),.DEPTH(2)) u_completion(
        .clk(clk),.rst(rst),.rsv_req_i(fire),.rsv_pair_i(1'b0),.rsv_ok_o(fifo_ready),.rsv_single_ok_o(),.rsv_pair_ok_o(),
        .rsv_release_i({1'b0,kill_active}),.enq_valid_i(enq.valid),.enq_pair_i(1'b0),.enq_i(enq),.enq2_i('0),
        .promise_i('0),.promise_o(wake_o),.head_valid_o(resp_valid_o),.head_o(head),
        .head_consume_i(resp_ready_i),.bypass_o(bypass_o),.resolution_i(resolution_i),.busy_o(fifo_busy));
    always_ff @(posedge clk) begin
        if(rst) begin active_q<=0;fast_q<=0;word_q<=0;rem_q<=0;qneg_q<=0;rneg_q<=0;tag_q<='0;fast_data_q<=0;end
        else begin
            if(active_q && (kill_active || done || fast_q)) begin active_q<=0;fast_q<=0;end
            if(resolution_i.valid) tag_q.br_mask<=br_resolved_mask(tag_q.br_mask,resolution_i);
            if(fire) begin
                active_q<=1;tag_q<=req_i.tag;tag_q.br_mask<=br_resolved_mask(req_i.tag.br_mask,resolution_i);
                word_q<=word_op;rem_q<=rem_op; qneg_q<=signed_op && (a[63]^b[63]);rneg_q<=signed_op && a[63];
                fast_q<=zero_case || overflow_case;
                fast_data_q<=zero_case ? (rem_op?a:64'hffffffffffffffff) : (rem_op?64'd0:a);
                assert(!req_i.fuse.valid) else $fatal(1,"DIV cannot fuse");
            end
        end
    end
endmodule
