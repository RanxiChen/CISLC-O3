module early_wakeup_tb_top import o3_pkg::*; (
    input logic clk,rst,launch_i,enq_i,wb_ready_i,
    output logic wake_o,bypass_o,issue_o,written_o,
    output logic [63:0] operand_o,
    output logic issued_o
);
    import o3_types_pkg::*;
    localparam o3_cfg_pkg::backend_cfg_t C=o3_cfg_pkg::O3_CFG.be;
    mdu_req_t req;mdu_resp_t resp;wake_promise_t wake;cpl_bypass_t bp;
    renamed_uop_t [C.dispatch.width-1:0] enq;
    renamed_uop_t [C.exec.num_alu-1:0] issue;
    logic [C.exec.num_alu-1:0] valid,ready;
    logic preg_ready [C.rename.int_phys_regs-1:0];logic wv [0:0];logic [PREG_IDX_WIDTH-1:0] wp [0:0];
    logic written_q;logic [63:0] prf_q;
    always_comb begin
        req='0;req.src1=7;req.src2=9;req.op=MDU_MUL;
        req.tag.dst_dom=RD_INT;req.tag.dst_preg=33;req.tag.dst_write_en=1;
        enq='0;enq[0].valid=enq_i;enq[0].rs1_read_en=1;enq[0].src1_preg=33;
        enq[0].is_int_uop=1;enq[0].rob_idx=1;
        for(int i=0;i<C.rename.int_phys_regs;i++) preg_ready[i]=(i!=33)||written_q;
        ready='1;
        wv[0]=wake.valid || bp.valid;wp[0]=wake.valid?wake.preg:bp.preg;
    end
    mul_execute_unit #(.CFG(C)) mul(.clk(clk),.rst(rst),.req_valid_i(launch_i),.req_ready_o(),.req_single_ready_o(),.req_pair_ready_o(),
        .req_i(req),.resp_valid_o(),.resp_ready_i(wb_ready_i),.resp_o(resp),.bypass_o(bp),.wake_o(wake),.resolution_i('0),.busy_o());
    backend_issue_queue #(.CFG(C),.KIND(IQ_INT),.WAKEUP_WIDTH(1)) iq(
        .clk(clk),.rst(rst),.enq_uop_i(enq),.enq_fire_i(enq_i),.free_count_o(),.preg_ready_i(preg_ready),
        .mul_ready_i(1'b1),.mul_pair_ready_i(1'b1),.div_ready_i(1'b1),.allow_load_i(1'b1),
        .wakeup_valid_i(wv),.wakeup_preg_i(wp),.issue_uop_o(issue),.issue_valid_o(valid),.issue_ready_i(ready),
        .resolution_valid_i(1'b0),.resolution_mispredict_i(1'b0),.resolution_tag_i('0));
    always_ff @(posedge clk) begin
        if(rst) begin written_q<=0;prf_q<=0;issued_o<=0;operand_o<=0;end
        else begin
            issued_o<=valid[0];
            if(valid[0]) operand_o<=bp.valid?bp.data:prf_q;
            if(resp.valid && wb_ready_i) begin written_q<=1;prf_q<=resp.result;end
        end
    end
    assign wake_o=wake.valid;assign bypass_o=bp.valid;assign issue_o=valid[0];assign written_o=written_q;
endmodule
