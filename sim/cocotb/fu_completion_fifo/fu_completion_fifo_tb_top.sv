module fu_completion_fifo_tb_top import o3_pkg::*; (
    input logic clk,rst,rsv_i,pair_i,enq_i,enq_pair_i,consume_i,kill_i,correct_i,
    input logic [1:0] release_i,
    input logic [63:0] data_i,data2_i,
    input branch_mask_t mask_i,mask2_i,
    output logic ready_o,head_valid_o,wake_valid_o,bypass_valid_o,busy_o,
    output logic [63:0] data_o,bypass_data_o,
    output logic [PREG_IDX_WIDTH-1:0] preg_o,wake_preg_o
);
    import o3_types_pkg::*;
    wb_req_t a,b,h;branch_resolution_t res;cpl_bypass_t bp;wake_promise_t w;
    always_comb begin
        a='0;b='0;res='0;
        a.valid=1;a.tag.dst_write_en=1;a.tag.dst_dom=RD_INT;a.tag.dst_preg=33;a.tag.br_mask=mask_i;a.data=data_i;
        b=a;b.tag.dst_preg=34;b.tag.br_mask=mask2_i;b.data=data2_i;
        res.valid=kill_i || correct_i;res.mispredict=kill_i;res.branch_tag=0;
    end
    fu_completion_fifo #(.CFG(o3_cfg_pkg::O3_CFG.be),.DEPTH(2)) dut(
        .clk(clk),.rst(rst),.rsv_req_i(rsv_i),.rsv_pair_i(pair_i),.rsv_ok_o(ready_o),.rsv_single_ok_o(),.rsv_pair_ok_o(),
        .rsv_release_i(release_i),.enq_valid_i(enq_i),.enq_pair_i(enq_pair_i),.enq_i(a),.enq2_i(b),
        .promise_i('0),.promise_o(w),.head_valid_o(head_valid_o),.head_o(h),.head_consume_i(consume_i),
        .bypass_o(bp),.resolution_i(res),.busy_o(busy_o));
    assign data_o=h.data;assign preg_o=h.tag.dst_preg;assign wake_valid_o=w.valid;assign wake_preg_o=w.preg;
    assign bypass_valid_o=bp.valid;assign bypass_data_o=bp.data;
endmodule
