module mdu_tb_top import o3_pkg::*; #(parameter bit DIV_UNIT=0)(
    input logic clk,rst,req_valid_i,resp_ready_i,
    input logic [3:0] op_i,
    input logic [63:0] a_i,b_i,
    input logic [ROB_IDX_WIDTH-1:0] rob_i,lo_rob_i,
    input logic [PREG_IDX_WIDTH-1:0] preg_i,lo_preg_i,
    input branch_mask_t mask_i,lo_mask_i,
    input logic fuse_i,write_i,kill_valid_i,kill_mispredict_i,
    input branch_tag_t kill_tag_i,
    output logic req_ready_o,resp_valid_o,bypass_valid_o,wake_valid_o,busy_o,
    output logic [63:0] data_o,bypass_data_o,
    output logic [PREG_IDX_WIDTH-1:0] preg_o,wake_preg_o,
    output logic [ROB_IDX_WIDTH-1:0] rob_o,
    output logic [31:0] cfg_div_o,cfg_slots_o
);
    import o3_types_pkg::*;
    mdu_req_t req; mdu_resp_t resp;cpl_bypass_t bypass;wake_promise_t wake;
    branch_resolution_t res;
    always_comb begin
        req='0;req.op=mdu_op_e'(op_i);req.src1=a_i;req.src2=b_i;
        req.tag='{rob_idx:rob_i,br_mask:mask_i,dst_dom:RD_INT,dst_preg:preg_i,dst_write_en:write_i};
        req.fuse.valid=fuse_i;
        req.fuse.lo_tag='{rob_idx:lo_rob_i,br_mask:lo_mask_i,dst_dom:RD_INT,dst_preg:lo_preg_i,dst_write_en:write_i};
        res='0;res.valid=kill_valid_i;res.mispredict=kill_mispredict_i;res.branch_tag=kill_tag_i;
    end
    if(DIV_UNIT) begin
        div_execute_unit #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(
            .clk(clk),.rst(rst),.req_valid_i(req_valid_i),.req_ready_o(req_ready_o),.req_i(req),
            .resp_valid_o(resp_valid_o),.resp_ready_i(resp_ready_i),.resp_o(resp),
            .bypass_o(bypass),.wake_o(wake),.resolution_i(res),.busy_o(busy_o));
    end else begin
        mul_execute_unit #(.CFG(o3_cfg_pkg::O3_CFG.be)) dut(
            .clk(clk),.rst(rst),.req_valid_i(req_valid_i),.req_ready_o(req_ready_o),.req_single_ready_o(),.req_pair_ready_o(),.req_i(req),
            .resp_valid_o(resp_valid_o),.resp_ready_i(resp_ready_i),.resp_o(resp),
            .bypass_o(bypass),.wake_o(wake),.resolution_i(res),.busy_o(busy_o));
    end
    assign data_o=resp.result;assign preg_o=resp.tag.dst_preg;assign rob_o=resp.tag.rob_idx;
    assign bypass_valid_o=bypass.valid;assign bypass_data_o=bypass.data;
    assign wake_valid_o=wake.valid;assign wake_preg_o=wake.preg;
    assign cfg_div_o=32'(DIV_UNIT);assign cfg_slots_o=DIV_UNIT?2:o3_cfg_pkg::O3_CFG.be.exec.mul_result_slots;
endmodule
